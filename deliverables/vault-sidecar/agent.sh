#!/bin/sh
# =============================================================================
# camunda-vault-agent  (shell + curl edition)
#
# A tiny, auditable sidecar/init helper for Camunda 8 Self-Managed that:
#
#   fetch    - log in to HashiCorp Vault with the pod ServiceAccount
#              (Kubernetes auth), read the configured secrets and reconcile
#              them into one or more per-app Kubernetes Secrets
#   watch    - same as fetch on a loop; rollout-restarts the attached workload
#              (RESTART_TARGET_KIND/NAME) when its secret changes
#
# Dependencies: sh, curl, jq, base64  (all from the alpine base image).
# Designed for air-gapped, least-privilege clusters: no Vault SDK, no client-go,
# no mutating webhooks. Only stdlib tools.
#
# Config file schema (CONFIG_FILE, default /etc/camunda-vault-agent/config.json):
#   {
#     "secrets": [
#       { "secretName": "camunda-optimize-secret",
#         "entries": [ { "vaultPath": "secret/data/...", "field": "password",
#                        "secretKey": "elasticsearch-password" } ] }
#     ]
#   }
# A watch sidecar has exactly one entry in "secrets"; the bootstrap Job has many.
# =============================================================================
set -eu

log() { echo "[camunda-vault-agent] $*" >&2; }
die() { log "FATAL: $*"; exit 1; }

# ---------------------------------------------------------------------------
# Configuration (environment variables)
# ---------------------------------------------------------------------------
VAULT_ADDR="${VAULT_ADDR:-}"
VAULT_AUTH_PATH="${VAULT_AUTH_PATH:-kubernetes}"
VAULT_ROLE="${VAULT_ROLE:-}"
VAULT_NAMESPACE="${VAULT_NAMESPACE:-}"          # Vault Enterprise namespace (optional)
VAULT_CACERT="${VAULT_CACERT:-}"                # CA file for Vault TLS (trusted-ca bundle)
VAULT_SKIP_VERIFY="${VAULT_SKIP_VERIFY:-false}"
VAULT_SA_TOKEN_PATH="${VAULT_SA_TOKEN_PATH:-/var/run/secrets/kubernetes.io/serviceaccount/token}"
VAULT_TOKEN="${VAULT_TOKEN:-}"                  # if set, skip login (testing / static-token mode)

CONFIG_FILE="${CONFIG_FILE:-/etc/camunda-vault-agent/config.json}"
POD_NAMESPACE="${POD_NAMESPACE:-}"

RESTART_MODE="${RESTART_MODE:-rollout}"         # rollout | none
RESTART_TARGET_KIND="${RESTART_TARGET_KIND:-Deployment}"
RESTART_TARGET_NAME="${RESTART_TARGET_NAME:-}"
INTERVAL_SECONDS="${INTERVAL_SECONDS:-300}"

KSA_DIR="/var/run/secrets/kubernetes.io/serviceaccount"
APISERVER="https://${KUBERNETES_SERVICE_HOST:-}:${KUBERNETES_SERVICE_PORT:-443}"

CHANGED=0   # set by fetch_once

# ---------------------------------------------------------------------------
# curl helpers
# ---------------------------------------------------------------------------
vault_curl_opts() {
  if [ "$VAULT_SKIP_VERIFY" = "true" ]; then
    printf -- '-k'
  elif [ -n "$VAULT_CACERT" ] && [ -f "$VAULT_CACERT" ]; then
    printf -- '--cacert %s' "$VAULT_CACERT"
  fi
}
vault_hdr_ns() {
  [ -n "$VAULT_NAMESPACE" ] && printf -- '-H X-Vault-Namespace:%s' "$VAULT_NAMESPACE"
}

# ---------------------------------------------------------------------------
# Vault: login via Kubernetes auth -> client token (stdout). Returns non-zero on error.
# ---------------------------------------------------------------------------
vault_login() {
  if [ -n "$VAULT_TOKEN" ]; then printf '%s' "$VAULT_TOKEN"; return 0; fi
  # Per-app Vault role can be supplied via the config file (.vaultRole) so the
  # shared env ConfigMap stays role-agnostic.
  if [ -z "$VAULT_ROLE" ] && [ -f "$CONFIG_FILE" ]; then
    VAULT_ROLE="$(jq -r '.vaultRole // empty' "$CONFIG_FILE")"
  fi
  [ -n "$VAULT_ADDR" ] || { log "ERROR: VAULT_ADDR is required"; return 1; }
  [ -n "$VAULT_ROLE" ] || { log "ERROR: VAULT_ROLE is required"; return 1; }
  [ -f "$VAULT_SA_TOKEN_PATH" ] || { log "ERROR: ServiceAccount token not found at $VAULT_SA_TOKEN_PATH"; return 1; }
  jwt="$(cat "$VAULT_SA_TOKEN_PATH")"
  body="$(jq -nc --arg role "$VAULT_ROLE" --arg jwt "$jwt" '{role:$role, jwt:$jwt}')"
  # shellcheck disable=SC2046
  if ! resp="$(curl -sS $(vault_curl_opts) $(vault_hdr_ns) \
        -X POST "$VAULT_ADDR/v1/auth/$VAULT_AUTH_PATH/login" \
        -H 'Content-Type: application/json' -d "$body" 2>/tmp/cva_err)"; then
    log "ERROR: Vault login transport error talking to $VAULT_ADDR (TLS/connection): $(cat /tmp/cva_err 2>/dev/null)."
    log "       If Vault uses a private CA, ensure the trusted-ca bundle is mounted (VAULT_CACERT=$VAULT_CACERT)."
    return 1
  fi
  token="$(printf '%s' "$resp" | jq -r '.auth.client_token // empty')"
  if [ -z "$token" ]; then
    log "ERROR: Vault login failed: $(printf '%s' "$resp" | jq -c '.errors // .' 2>/dev/null || printf '%s' "$resp")"
    return 1
  fi
  printf '%s' "$token"
}

# vault_read <token> <path> -> JSON payload (stdout). Returns non-zero on error.
vault_read() {
  _t="$1"; _p="$2"
  # shellcheck disable=SC2046
  if ! resp="$(curl -sS $(vault_curl_opts) $(vault_hdr_ns) \
        -H "X-Vault-Token: $_t" "$VAULT_ADDR/v1/$_p" 2>/tmp/cva_err)"; then
    log "ERROR: Vault read $_p transport error talking to $VAULT_ADDR (TLS/connection): $(cat /tmp/cva_err 2>/dev/null)."
    return 1
  fi
  if printf '%s' "$resp" | jq -e '.errors and (.errors|length>0)' >/dev/null 2>&1; then
    log "ERROR: Vault read $_p failed: $(printf '%s' "$resp" | jq -c '.errors')"
    return 1
  fi
  printf '%s' "$resp" | jq -c 'if .data.data then .data.data else .data end'
}

# ---------------------------------------------------------------------------
# Kubernetes API helpers (in-cluster)
# ---------------------------------------------------------------------------
k_token() { cat "$KSA_DIR/token"; }

resolve_namespace() {
  if [ -n "$POD_NAMESPACE" ]; then echo "$POD_NAMESPACE"; return 0; fi
  [ -f "$KSA_DIR/namespace" ] && { cat "$KSA_DIR/namespace"; return 0; }
  return 1
}

# k_api <method> <path> [body] [content-type]; prints HTTP code, body to /tmp/k_resp.
k_api() {
  _m="$1"; _path="$2"; _body="${3:-}"; _ct="${4:-application/json}"
  if [ -n "$_body" ]; then
    code="$(curl -sS --cacert "$KSA_DIR/ca.crt" -H "Authorization: Bearer $(k_token)" \
      -o /tmp/k_resp -w '%{http_code}' -X "$_m" -H "Content-Type: $_ct" \
      -d "$_body" "$APISERVER$_path" 2>/tmp/cva_err)" || { log "ERROR: kube API transport error: $(cat /tmp/cva_err 2>/dev/null)"; return 1; }
  else
    code="$(curl -sS --cacert "$KSA_DIR/ca.crt" -H "Authorization: Bearer $(k_token)" \
      -o /tmp/k_resp -w '%{http_code}' -X "$_m" "$APISERVER$_path" 2>/tmp/cva_err)" || { log "ERROR: kube API transport error: $(cat /tmp/cva_err 2>/dev/null)"; return 1; }
  fi
  printf '%s' "$code"
}

# ---------------------------------------------------------------------------
# reconcile_secret <token> <namespace> <secretName> <entriesJson>
# Creates or patches a single Kubernetes Secret. Sets CHANGED=1 on change.
# ---------------------------------------------------------------------------
reconcile_secret() {
  _token="$1"; ns="$2"; secret_name="$3"; entries="$4"
  entries_n="$(printf '%s' "$entries" | jq 'length')"
  [ "$entries_n" -gt 0 ] || { log "WARN: secret $secret_name has no entries; skipping"; return 0; }

  desired='{}'
  i=0
  while [ "$i" -lt "$entries_n" ]; do
    vp="$(printf '%s' "$entries" | jq -r ".[$i].vaultPath")"
    fld="$(printf '%s' "$entries" | jq -r ".[$i].field")"
    key="$(printf '%s' "$entries" | jq -r ".[$i].secretKey")"
    raw="$(vault_read "$_token" "$vp")" || return 1
    val="$(printf '%s' "$raw" | jq -r --arg f "$fld" '.[$f] // empty')"
    [ -n "$val" ] || { log "ERROR: field '$fld' not found at '$vp'"; return 1; }
    b64="$(printf '%s' "$val" | base64 | tr -d '\n')"
    desired="$(printf '%s' "$desired" | jq -c --arg k "$key" --arg v "$b64" '. + {($k):$v}')"
    i=$((i+1))
  done

  code="$(k_api GET "/api/v1/namespaces/$ns/secrets/$secret_name")" || return 1
  body="$(cat /tmp/k_resp)"
  if [ "$code" = "404" ]; then
    payload="$(jq -nc --arg name "$secret_name" --argjson data "$desired" \
      '{apiVersion:"v1",kind:"Secret",metadata:{name:$name,labels:{"app.kubernetes.io/managed-by":"camunda-vault-agent"}},type:"Opaque",data:$data}')"
    code="$(k_api POST "/api/v1/namespaces/$ns/secrets" "$payload")" || return 1
    [ "$code" = "201" ] || { log "ERROR: create secret $secret_name failed ($code): $(cat /tmp/k_resp)"; return 1; }
    log "created secret $ns/$secret_name with $entries_n key(s)"; CHANGED=1
  elif [ "$code" = "200" ]; then
    diff="$(printf '%s' "$body" | jq -c --argjson d "$desired" '
      (.data // {}) as $cur | reduce ($d|to_entries[]) as $e ({}; if $cur[$e.key] == $e.value then . else . + {($e.key):$e.value} end)')"
    if [ "$(printf '%s' "$diff" | jq 'length')" -gt 0 ]; then
      patch="$(jq -nc --argjson data "$diff" '{data:$data}')"
      code="$(k_api PATCH "/api/v1/namespaces/$ns/secrets/$secret_name" "$patch" "application/merge-patch+json")" || return 1
      [ "$code" = "200" ] || { log "ERROR: patch secret $secret_name failed ($code): $(cat /tmp/k_resp)"; return 1; }
      log "updated $(printf '%s' "$diff" | jq 'length') key(s) in secret $ns/$secret_name"; CHANGED=1
    fi
  else
    log "ERROR: get secret $secret_name failed ($code): $body"; return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# fetch: reconcile every secret in CONFIG_FILE. Sets global CHANGED.
# ---------------------------------------------------------------------------
fetch_once() {
  CHANGED=0
  [ -f "$CONFIG_FILE" ] || { log "ERROR: mapping config not found: $CONFIG_FILE"; return 1; }
  token="$(vault_login)" || return 1
  ns="$(resolve_namespace)" || { log "ERROR: could not determine namespace (set POD_NAMESPACE)"; return 1; }

  secrets_n="$(jq '.secrets | length' "$CONFIG_FILE")"
  [ "$secrets_n" -gt 0 ] || { log "ERROR: config has no .secrets[]"; return 1; }
  i=0
  while [ "$i" -lt "$secrets_n" ]; do
    sname="$(jq -r ".secrets[$i].secretName" "$CONFIG_FILE")"
    entries="$(jq -c ".secrets[$i].entries" "$CONFIG_FILE")"
    reconcile_secret "$token" "$ns" "$sname" "$entries" || return 1
    i=$((i+1))
  done
  return 0
}

# ---------------------------------------------------------------------------
# restart the attached workload (errors are logged, never crash the watch loop)
# ---------------------------------------------------------------------------
restart_module() {
  case "$RESTART_MODE" in
    none)
      log "secret changed but RESTART_MODE=none; skipping restart" ;;
    rollout)
      if [ -z "$RESTART_TARGET_NAME" ]; then log "ERROR: RESTART_TARGET_NAME required for rollout mode"; return 1; fi
      ns="$(resolve_namespace)" || { log "ERROR: namespace unknown"; return 1; }
      case "$RESTART_TARGET_KIND" in
        Deployment|deployment) res="deployments" ;;
        StatefulSet|statefulset) res="statefulsets" ;;
        *) log "ERROR: unsupported RESTART_TARGET_KIND '$RESTART_TARGET_KIND'"; return 1 ;;
      esac
      ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      patch="$(jq -nc --arg ts "$ts" '{spec:{template:{metadata:{annotations:{"camunda-vault-agent/restartedAt":$ts}}}}}')"
      code="$(k_api PATCH "/apis/apps/v1/namespaces/$ns/$res/$RESTART_TARGET_NAME" "$patch" "application/strategic-merge-patch+json")" || return 1
      [ "$code" = "200" ] || { log "ERROR: rollout restart failed ($code): $(cat /tmp/k_resp)"; return 1; }
      log "triggered rollout restart of $RESTART_TARGET_KIND/$RESTART_TARGET_NAME" ;;
    *)
      log "ERROR: unknown RESTART_MODE '$RESTART_MODE'"; return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# entrypoint
# ---------------------------------------------------------------------------
cmd="${1:-}"
case "$cmd" in
  fetch)
    if fetch_once; then log "fetch complete (changed=$CHANGED)"; else die "fetch failed"; fi ;;
  watch)
    log "watch mode: interval=${INTERVAL_SECONDS}s restartMode=$RESTART_MODE target=$RESTART_TARGET_KIND/$RESTART_TARGET_NAME"
    while true; do
      if fetch_once; then
        if [ "$CHANGED" = "1" ]; then restart_module || log "WARN: restart failed; secret was updated"; fi
      else
        log "WARN: reconcile failed; will retry in ${INTERVAL_SECONDS}s"
      fi
      sleep "$INTERVAL_SECONDS"
    done ;;
  ""|-h|--help|help)
    cat >&2 <<EOF
camunda-vault-agent <command>
  fetch     reconcile Vault secrets into Kubernetes Secret(s) once, then exit
  watch     reconcile on an interval and rollout-restart the workload on change
EOF
    [ -z "$cmd" ] && exit 2 || exit 0 ;;
  *)
    die "unknown command '$cmd' (use fetch|watch)" ;;
esac
