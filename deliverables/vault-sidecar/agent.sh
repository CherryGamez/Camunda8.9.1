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

# In-cluster Kubernetes API access
KSA_DIR="/var/run/secrets/kubernetes.io/serviceaccount"
APISERVER="https://${KUBERNETES_SERVICE_HOST:-}:${KUBERNETES_SERVICE_PORT:-443}"

# ---------------------------------------------------------------------------
# curl helpers
# ---------------------------------------------------------------------------
vault_curl_opts() {
  # echo extra curl opts for talking to Vault
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
# Vault: login via Kubernetes auth -> client token
# ---------------------------------------------------------------------------
vault_login() {
  if [ -n "$VAULT_TOKEN" ]; then
    echo "$VAULT_TOKEN"
    return 0
  fi
  [ -n "$VAULT_ADDR" ] || die "VAULT_ADDR is required"
  [ -n "$VAULT_ROLE" ] || die "VAULT_ROLE is required"
  [ -f "$VAULT_SA_TOKEN_PATH" ] || die "ServiceAccount token not found at $VAULT_SA_TOKEN_PATH"
  jwt="$(cat "$VAULT_SA_TOKEN_PATH")"
  body="$(jq -nc --arg role "$VAULT_ROLE" --arg jwt "$jwt" '{role:$role, jwt:$jwt}')"
  # shellcheck disable=SC2046
  resp="$(curl -sS $(vault_curl_opts) $(vault_hdr_ns) \
    -X POST "$VAULT_ADDR/v1/auth/$VAULT_AUTH_PATH/login" \
    -H 'Content-Type: application/json' -d "$body")"
  token="$(echo "$resp" | jq -r '.auth.client_token // empty')"
  [ -n "$token" ] || die "Vault login failed: $(echo "$resp" | jq -c '.errors // .' 2>/dev/null || echo "$resp")"
  echo "$token"
}

# vault_read <token> <path> -> JSON payload (KV v2 .data.data merged with KV v1 .data)
vault_read() {
  _t="$1"; _p="$2"
  # shellcheck disable=SC2046
  resp="$(curl -sS $(vault_curl_opts) $(vault_hdr_ns) \
    -H "X-Vault-Token: $_t" "$VAULT_ADDR/v1/$_p")"
  if echo "$resp" | jq -e '.errors and (.errors|length>0)' >/dev/null 2>&1; then
    die "Vault read $_p failed: $(echo "$resp" | jq -c '.errors')"
  fi
  echo "$resp" | jq -c 'if .data.data then .data.data else .data end'
}

# ---------------------------------------------------------------------------
# Kubernetes API helpers (in-cluster)
# ---------------------------------------------------------------------------
k_token() { cat "$KSA_DIR/token"; }

resolve_namespace() {
  if [ -n "$POD_NAMESPACE" ]; then echo "$POD_NAMESPACE"; return; fi
  cfg_ns="$(jq -r '.secretNamespace // empty' "$CONFIG_FILE")"
  if [ -n "$cfg_ns" ]; then echo "$cfg_ns"; return; fi
  [ -f "$KSA_DIR/namespace" ] && cat "$KSA_DIR/namespace" && return
  die "could not determine namespace (set POD_NAMESPACE)"
}

# k_api <method> <path> [body] [content-type] -> writes body to stdout, returns http code via $K_CODE
k_api() {
  _m="$1"; _path="$2"; _body="${3:-}"; _ct="${4:-application/json}"
  if [ -n "$_body" ]; then
    K_CODE="$(curl -sS --cacert "$KSA_DIR/ca.crt" -H "Authorization: Bearer $(k_token)" \
      -o /tmp/k_resp -w '%{http_code}' -X "$_m" -H "Content-Type: $_ct" \
      -d "$_body" "$APISERVER$_path")"
  else
    K_CODE="$(curl -sS --cacert "$KSA_DIR/ca.crt" -H "Authorization: Bearer $(k_token)" \
      -o /tmp/k_resp -w '%{http_code}' -X "$_m" "$APISERVER$_path")"
  fi
  cat /tmp/k_resp
}

# ---------------------------------------------------------------------------
# fetch: reconcile Vault -> Kubernetes Secret + files
# ---------------------------------------------------------------------------
fetch_once() {
  [ -f "$CONFIG_FILE" ] || die "mapping config not found: $CONFIG_FILE"
  token="$(vault_login)"
  changed=0

  secret_name="$(jq -r '.secretName // "camunda-credentials"' "$CONFIG_FILE")"

  # ---- shared files (bitnami *_FILE convention / app config) ----
  files_n="$(jq '.files | length' "$CONFIG_FILE")"
  i=0
  while [ "$i" -lt "$files_n" ]; do
    vp="$(jq -r ".files[$i].vaultPath" "$CONFIG_FILE")"
    fld="$(jq -r ".files[$i].field" "$CONFIG_FILE")"
    path="$(jq -r ".files[$i].path" "$CONFIG_FILE")"
    val="$(vault_read "$token" "$vp" | jq -r --arg f "$fld" '.[$f] // empty')"
    [ -n "$val" ] || die "field '$fld' not found at '$vp'"
    if [ ! -f "$path" ] || [ "$(cat "$path" 2>/dev/null)" != "$val" ]; then
      mkdir -p "$(dirname "$path")"
      printf '%s' "$val" > "$path"; chmod 0400 "$path" 2>/dev/null || true
      log "wrote file $path"; changed=1
    fi
    i=$((i+1))
  done

  # ---- Kubernetes Secret ----
  entries_n="$(jq '.entries | length' "$CONFIG_FILE")"
  if [ "$entries_n" -gt 0 ]; then
    ns="$(resolve_namespace)"
    desired='{}'
    i=0
    while [ "$i" -lt "$entries_n" ]; do
      vp="$(jq -r ".entries[$i].vaultPath" "$CONFIG_FILE")"
      fld="$(jq -r ".entries[$i].field" "$CONFIG_FILE")"
      key="$(jq -r ".entries[$i].secretKey" "$CONFIG_FILE")"
      val="$(vault_read "$token" "$vp" | jq -r --arg f "$fld" '.[$f] // empty')"
      [ -n "$val" ] || die "field '$fld' not found at '$vp'"
      b64="$(printf '%s' "$val" | base64 | tr -d '\n')"
      desired="$(echo "$desired" | jq -c --arg k "$key" --arg v "$b64" '. + {($k):$v}')"
      i=$((i+1))
    done

    body="$(k_api GET "/api/v1/namespaces/$ns/secrets/$secret_name")"
    if [ "$K_CODE" = "404" ]; then
      payload="$(jq -nc --arg name "$secret_name" --argjson data "$desired" \
        '{apiVersion:"v1",kind:"Secret",metadata:{name:$name,labels:{"app.kubernetes.io/managed-by":"camunda-vault-agent"}},type:"Opaque",data:$data}')"
      out="$(k_api POST "/api/v1/namespaces/$ns/secrets" "$payload")"
      [ "$K_CODE" = "201" ] || die "create secret failed ($K_CODE): $out"
      log "created secret $ns/$secret_name with $entries_n keys"
      changed=1
    elif [ "$K_CODE" = "200" ]; then
      # diff: keep only keys whose base64 value differs from current
      diff="$(echo "$body" | jq -c --argjson d "$desired" '
        (.data // {}) as $cur | reduce ($d|to_entries[]) as $e ({}; if $cur[$e.key] == $e.value then . else . + {($e.key):$e.value} end)')"
      if [ "$(echo "$diff" | jq 'length')" -gt 0 ]; then
        patch="$(jq -nc --argjson data "$diff" '{data:$data}')"
        out="$(k_api PATCH "/api/v1/namespaces/$ns/secrets/$secret_name" "$patch" "application/merge-patch+json")"
        [ "$K_CODE" = "200" ] || die "patch secret failed ($K_CODE): $out"
        log "updated $(echo "$diff" | jq 'length') key(s) in secret $ns/$secret_name"
        changed=1
      fi
    else
      die "get secret failed ($K_CODE): $body"
    fi
  fi

  echo "$changed"
}

# ---------------------------------------------------------------------------
# restart the attached module
# ---------------------------------------------------------------------------
restart_module() {
  case "$RESTART_MODE" in
    none)
      log "secret changed but RESTART_MODE=none; skipping restart" ;;
    signal)
      [ -n "$RESTART_PROCESS_MATCH" ] || die "RESTART_PROCESS_MATCH required for signal mode"
      found=0
      for p in /proc/[0-9]*; do
        pid="${p#/proc/}"
        [ "$pid" = "$$" ] && continue
        [ "$pid" = "1" ] && continue
        cl="$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null || true)"
        case "$cl" in
          *"$RESTART_PROCESS_MATCH"*)
            if kill -TERM "$pid" 2>/dev/null; then
              log "sent SIGTERM to pid $pid ($cl)"; found=1
            fi ;;
        esac
      done
      [ "$found" = "1" ] || log "WARN: no process matching '$RESTART_PROCESS_MATCH' found" ;;
    rollout)
      [ -n "$RESTART_TARGET_NAME" ] || die "RESTART_TARGET_NAME required for rollout mode"
      ns="$(resolve_namespace)"
      case "$RESTART_TARGET_KIND" in
        Deployment|deployment) res="deployments" ;;
        StatefulSet|statefulset) res="statefulsets" ;;
        *) die "unsupported RESTART_TARGET_KIND '$RESTART_TARGET_KIND'" ;;
      esac
      ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      patch="$(jq -nc --arg ts "$ts" '{spec:{template:{metadata:{annotations:{"camunda-vault-agent/restartedAt":$ts}}}}}')"
      out="$(k_api PATCH "/apis/apps/v1/namespaces/$ns/$res/$RESTART_TARGET_NAME" "$patch" "application/strategic-merge-patch+json")"
      [ "$K_CODE" = "200" ] || die "rollout restart failed ($K_CODE): $out"
      log "triggered rollout restart of $RESTART_TARGET_KIND/$RESTART_TARGET_NAME" ;;
    *)
      die "unknown RESTART_MODE '$RESTART_MODE'" ;;
  esac
}

# ---------------------------------------------------------------------------
# gencert: self-signed certificate via openssl
# ---------------------------------------------------------------------------
gencert() {
  dir="${CERT_DIR:-/tls}"
  cn="${CERT_CN:-localhost}"
  days="${CERT_DAYS:-825}"
  sans="${CERT_SANS:-}"
  mkdir -p "$dir"
  if [ -f "$dir/tls.crt" ] && openssl x509 -checkend $((30*24*3600)) -noout -in "$dir/tls.crt" >/dev/null 2>&1; then
    log "gencert: valid certificate already present at $dir/tls.crt, skipping"
    return 0
  fi
  san_line="subjectAltName=DNS:$cn"
  if [ -n "$sans" ]; then
    OLDIFS="$IFS"; IFS=','
    for s in $sans; do
      s="$(echo "$s" | tr -d ' ')"
      [ -z "$s" ] && continue
      if echo "$s" | grep -Eq '^[0-9]+(\.[0-9]+){3}$'; then
        san_line="$san_line,IP:$s"
      else
        san_line="$san_line,DNS:$s"
      fi
    done
    IFS="$OLDIFS"
  fi
  openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$dir/tls.key" -out "$dir/tls.crt" \
    -days "$days" -subj "/O=Camunda Self-Managed/CN=$cn" \
    -addext "$san_line" >/dev/null 2>&1
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
    c="$(fetch_once)"; log "fetch complete (changed=$c)" ;;
  watch)
    log "watch mode: interval=${INTERVAL_SECONDS}s restartMode=$RESTART_MODE target=$RESTART_TARGET_KIND/$RESTART_TARGET_NAME"
    while true; do
      if c="$(fetch_once)"; then
        [ "$c" = "1" ] && restart_module || true
      else
        log "WARN: reconcile failed; will retry"
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
