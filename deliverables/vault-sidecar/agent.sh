#!/bin/sh
# =============================================================================
# camunda-vault-agent  (shell + curl edition)
#
# A tiny, auditable sidecar/init helper for Camunda 8 Self-Managed that:
#
#   gencert  - generate a self-signed certificate (init container use-case)
#   fetch    - log in to HashiCorp Vault with the pod ServiceAccount
#              (Kubernetes auth), read the configured secrets and reconcile
#              them into ONE Kubernetes Secret + optional shared files
#   watch    - same as fetch on a loop; restarts the attached module on change
#
# Dependencies: sh, curl, jq, openssl, base64  (all from the alpine base image)
# Designed for air-gapped, least-privilege clusters: no Vault SDK, no client-go,
# no mutating webhooks. Only stdlib tools.
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
VAULT_CACERT="${VAULT_CACERT:-}"                # CA file for Vault TLS (optional)
VAULT_SKIP_VERIFY="${VAULT_SKIP_VERIFY:-false}"
VAULT_SA_TOKEN_PATH="${VAULT_SA_TOKEN_PATH:-/var/run/secrets/kubernetes.io/serviceaccount/token}"
VAULT_TOKEN="${VAULT_TOKEN:-}"                  # if set, skip login (testing / static-token mode)

CONFIG_FILE="${CONFIG_FILE:-/etc/camunda-vault-agent/config.json}"
POD_NAMESPACE="${POD_NAMESPACE:-}"

RESTART_MODE="${RESTART_MODE:-rollout}"         # rollout | signal | none
RESTART_TARGET_KIND="${RESTART_TARGET_KIND:-Deployment}"
RESTART_TARGET_NAME="${RESTART_TARGET_NAME:-}"
RESTART_PROCESS_MATCH="${RESTART_PROCESS_MATCH:-}"
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
  elif [ -n "$VAULT_CACERT" ]; then
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
    log "       If Vault uses a private CA, set VAULT_CACERT (vaultAgent.vault.caCert)."
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
    log "       If Vault uses a private CA, set VAULT_CACERT (vaultAgent.vault.caCert)."
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
  cfg_ns="$(jq -r '.secretNamespace // empty' "$CONFIG_FILE")"
  if [ -n "$cfg_ns" ]; then echo "$cfg_ns"; return 0; fi
  [ -f "$KSA_DIR/namespace" ] && { cat "$KSA_DIR/namespace"; return 0; }
  return 1
}

# k_api <method> <path> [body] [content-type]; body->/tmp/k_resp, code->$K_CODE. Returns non-zero on transport error.
k_api() {
  _m="$1"; _path="$2"; _body="${3:-}"; _ct="${4:-application/json}"
  if [ -n "$_body" ]; then
    K_CODE="$(curl -sS --cacert "$KSA_DIR/ca.crt" -H "Authorization: Bearer $(k_token)" \
      -o /tmp/k_resp -w '%{http_code}' -X "$_m" -H "Content-Type: $_ct" \
      -d "$_body" "$APISERVER$_path" 2>/tmp/cva_err)" || { log "ERROR: kube API transport error: $(cat /tmp/cva_err 2>/dev/null)"; return 1; }
  else
    K_CODE="$(curl -sS --cacert "$KSA_DIR/ca.crt" -H "Authorization: Bearer $(k_token)" \
      -o /tmp/k_resp -w '%{http_code}' -X "$_m" "$APISERVER$_path" 2>/tmp/cva_err)" || { log "ERROR: kube API transport error: $(cat /tmp/cva_err 2>/dev/null)"; return 1; }
  fi
  cat /tmp/k_resp
}

# ---------------------------------------------------------------------------
# fetch: reconcile Vault -> Kubernetes Secret + files.
# Sets global CHANGED. Returns non-zero on any error (so `fetch` exits non-zero
# and `watch` retries on the next interval without crashing the loop).
# ---------------------------------------------------------------------------
fetch_once() {
  CHANGED=0
  [ -f "$CONFIG_FILE" ] || { log "ERROR: mapping config not found: $CONFIG_FILE"; return 1; }
  token="$(vault_login)" || return 1

  secret_name="$(jq -r '.secretName // "camunda-credentials"' "$CONFIG_FILE")"

  # ---- shared files (bitnami *_FILE convention / app config) ----
  files_n="$(jq '.files | length' "$CONFIG_FILE")"
  i=0
  while [ "$i" -lt "$files_n" ]; do
    vp="$(jq -r ".files[$i].vaultPath" "$CONFIG_FILE")"
    fld="$(jq -r ".files[$i].field" "$CONFIG_FILE")"
    path="$(jq -r ".files[$i].path" "$CONFIG_FILE")"
    raw="$(vault_read "$token" "$vp")" || return 1
    val="$(printf '%s' "$raw" | jq -r --arg f "$fld" '.[$f] // empty')"
    [ -n "$val" ] || { log "ERROR: field '$fld' not found at '$vp'"; return 1; }
    if [ ! -f "$path" ] || [ "$(cat "$path" 2>/dev/null)" != "$val" ]; then
      mkdir -p "$(dirname "$path")"
      printf '%s' "$val" > "$path"; chmod 0400 "$path" 2>/dev/null || true
      log "wrote file $path"; CHANGED=1
    fi
    i=$((i+1))
  done

  # ---- Kubernetes Secret ----
  entries_n="$(jq '.entries | length' "$CONFIG_FILE")"
  if [ "$entries_n" -gt 0 ]; then
    ns="$(resolve_namespace)" || { log "ERROR: could not determine namespace (set POD_NAMESPACE)"; return 1; }
    desired='{}'
    i=0
    while [ "$i" -lt "$entries_n" ]; do
      vp="$(jq -r ".entries[$i].vaultPath" "$CONFIG_FILE")"
      fld="$(jq -r ".entries[$i].field" "$CONFIG_FILE")"
      key="$(jq -r ".entries[$i].secretKey" "$CONFIG_FILE")"
      raw="$(vault_read "$token" "$vp")" || return 1
      val="$(printf '%s' "$raw" | jq -r --arg f "$fld" '.[$f] // empty')"
      [ -n "$val" ] || { log "ERROR: field '$fld' not found at '$vp'"; return 1; }
      b64="$(printf '%s' "$val" | base64 | tr -d '\n')"
      desired="$(printf '%s' "$desired" | jq -c --arg k "$key" --arg v "$b64" '. + {($k):$v}')"
      i=$((i+1))
    done

    body="$(k_api GET "/api/v1/namespaces/$ns/secrets/$secret_name")" || return 1
    if [ "$K_CODE" = "404" ]; then
      payload="$(jq -nc --arg name "$secret_name" --argjson data "$desired" \
        '{apiVersion:"v1",kind:"Secret",metadata:{name:$name,labels:{"app.kubernetes.io/managed-by":"camunda-vault-agent"}},type:"Opaque",data:$data}')"
      out="$(k_api POST "/api/v1/namespaces/$ns/secrets" "$payload")" || return 1
      [ "$K_CODE" = "201" ] || { log "ERROR: create secret failed ($K_CODE): $out"; return 1; }
      log "created secret $ns/$secret_name with $entries_n keys"; CHANGED=1
    elif [ "$K_CODE" = "200" ]; then
      diff="$(printf '%s' "$body" | jq -c --argjson d "$desired" '
        (.data // {}) as $cur | reduce ($d|to_entries[]) as $e ({}; if $cur[$e.key] == $e.value then . else . + {($e.key):$e.value} end)')"
      if [ "$(printf '%s' "$diff" | jq 'length')" -gt 0 ]; then
        patch="$(jq -nc --argjson data "$diff" '{data:$data}')"
        out="$(k_api PATCH "/api/v1/namespaces/$ns/secrets/$secret_name" "$patch" "application/merge-patch+json")" || return 1
        [ "$K_CODE" = "200" ] || { log "ERROR: patch secret failed ($K_CODE): $out"; return 1; }
        log "updated $(printf '%s' "$diff" | jq 'length') key(s) in secret $ns/$secret_name"; CHANGED=1
      fi
    else
      log "ERROR: get secret failed ($K_CODE): $body"; return 1
    fi
  fi
  return 0
}

# ---------------------------------------------------------------------------
# restart the attached module (errors are logged, never crash the watch loop)
# ---------------------------------------------------------------------------
restart_module() {
  case "$RESTART_MODE" in
    none)
      log "secret changed but RESTART_MODE=none; skipping restart" ;;
    signal)
      if [ -z "$RESTART_PROCESS_MATCH" ]; then log "ERROR: RESTART_PROCESS_MATCH required for signal mode"; return 1; fi
      found=0
      for p in /proc/[0-9]*; do
        pid="${p#/proc/}"
        [ "$pid" = "$$" ] && continue
        [ "$pid" = "1" ] && continue
        cl="$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null || true)"
        case "$cl" in
          *"$RESTART_PROCESS_MATCH"*)
            if kill -TERM "$pid" 2>/dev/null; then log "sent SIGTERM to pid $pid ($cl)"; found=1; fi ;;
        esac
      done
      [ "$found" = "1" ] || log "WARN: no process matching '$RESTART_PROCESS_MATCH' found (is shareProcessNamespace enabled?)" ;;
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
      out="$(k_api PATCH "/apis/apps/v1/namespaces/$ns/$res/$RESTART_TARGET_NAME" "$patch" "application/strategic-merge-patch+json")" || return 1
      [ "$K_CODE" = "200" ] || { log "ERROR: rollout restart failed ($K_CODE): $out"; return 1; }
      log "triggered rollout restart of $RESTART_TARGET_KIND/$RESTART_TARGET_NAME" ;;
    *)
      log "ERROR: unknown RESTART_MODE '$RESTART_MODE'"; return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# gencert: self-signed certificate via openssl
# ---------------------------------------------------------------------------
gencert() {
  dir="${CERT_DIR:-/tls}"; cn="${CERT_CN:-localhost}"; days="${CERT_DAYS:-825}"; sans="${CERT_SANS:-}"
  mkdir -p "$dir"
  if [ -f "$dir/tls.crt" ] && openssl x509 -checkend $((30*24*3600)) -noout -in "$dir/tls.crt" >/dev/null 2>&1; then
    log "gencert: valid certificate already present at $dir/tls.crt, skipping"; return 0
  fi
  san_line="subjectAltName=DNS:$cn"
  if [ -n "$sans" ]; then
    OLDIFS="$IFS"; IFS=','
    for s in $sans; do
      s="$(echo "$s" | tr -d ' ')"; [ -z "$s" ] && continue
      if echo "$s" | grep -Eq '^[0-9]+(\.[0-9]+){3}$'; then san_line="$san_line,IP:$s"; else san_line="$san_line,DNS:$s"; fi
    done
    IFS="$OLDIFS"
  fi
  openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$dir/tls.key" -out "$dir/tls.crt" \
    -days "$days" -subj "/O=Camunda Self-Managed/CN=$cn" \
    -addext "$san_line" >/dev/null 2>&1 || die "openssl failed to generate certificate"
  cp "$dir/tls.crt" "$dir/ca.crt"
  chmod 0400 "$dir/tls.key" 2>/dev/null || true
  chmod 0444 "$dir/tls.crt" "$dir/ca.crt" 2>/dev/null || true
  log "gencert: wrote self-signed certificate for CN=$cn (valid $days days) with $san_line to $dir"
}

# ---------------------------------------------------------------------------
# entrypoint
# ---------------------------------------------------------------------------
cmd="${1:-}"
case "$cmd" in
  gencert)
    gencert ;;
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
  gencert   generate a self-signed certificate into CERT_DIR
  fetch     reconcile Vault secrets into a Kubernetes Secret once, then exit
  watch     reconcile on an interval and restart the module on change
EOF
    [ -z "$cmd" ] && exit 2 || exit 0 ;;
  *)
    die "unknown command '$cmd' (use gencert|fetch|watch)" ;;
esac
