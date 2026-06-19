#!/usr/bin/env bash
# =============================================================================
# setup-vault.sh — one-time Vault configuration for the Camunda vault-agent
#
# Configures (per-app, least privilege):
#   1. KV v2 secrets engine at `secret/`
#   2. Kubernetes auth method
#   3. ONE read-only policy + role PER app, each scoped to only that app's paths
#      and bound to only that app's ServiceAccount:
#        camunda-bootstrap     SA camunda-vault-bootstrap     read camunda/*
#        camunda-orchestration SA camunda-vault-orchestration read camunda/elasticsearch
#        camunda-optimize      SA camunda-vault-optimize      read camunda/elasticsearch
#        camunda-web-modeler   SA camunda-vault-web-modeler   read camunda/postgres/webmodeler
#   4. Seed random PostgreSQL / Keycloak / Elasticsearch passwords (idempotent)
#
# Requires: vault CLI, and VAULT_ADDR + a privileged VAULT_TOKEN exported.
# =============================================================================
set -euo pipefail

K8S_NAMESPACE="${K8S_NAMESPACE:-camunda}"
VAULT_AUTH_PATH="${VAULT_AUTH_PATH:-kubernetes}"
KV_MOUNT="${KV_MOUNT:-secret}"
TOKEN_TTL="${TOKEN_TTL:-1h}"

KUBERNETES_HOST="${KUBERNETES_HOST:-https://kubernetes.default.svc:443}"
KUBERNETES_CA_CERT="${KUBERNETES_CA_CERT:-/var/run/secrets/kubernetes.io/serviceaccount/ca.crt}"
TOKEN_REVIEWER_JWT="${TOKEN_REVIEWER_JWT:-}"

rand() { LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${1:-24}"; }

echo ">> [1/5] Enable KV v2 at '${KV_MOUNT}/' (if needed)"
vault secrets enable -path="${KV_MOUNT}" -version=2 kv 2>/dev/null || echo "   already enabled"

echo ">> [2/5] Enable Kubernetes auth at '${VAULT_AUTH_PATH}/' (if needed)"
vault auth enable -path="${VAULT_AUTH_PATH}" kubernetes 2>/dev/null || echo "   already enabled"

echo ">> Configure Kubernetes auth backend"
CONFIG_ARGS=( "kubernetes_host=${KUBERNETES_HOST}" )
[ -f "${KUBERNETES_CA_CERT}" ] && CONFIG_ARGS+=( "kubernetes_ca_cert=@${KUBERNETES_CA_CERT}" )
[ -n "${TOKEN_REVIEWER_JWT}" ] && CONFIG_ARGS+=( "token_reviewer_jwt=${TOKEN_REVIEWER_JWT}" )
vault write "auth/${VAULT_AUTH_PATH}/config" "${CONFIG_ARGS[@]}"

# write_policy <name> <path-glob...> : a read-only policy over the given KV v2 paths
write_policy() {
  local name="$1"; shift
  local body=""
  for p in "$@"; do
    body+=$'path "'"${KV_MOUNT}/data/${p}"$'" {\n  capabilities = ["read"]\n}\n'
    body+=$'path "'"${KV_MOUNT}/metadata/${p}"$'" {\n  capabilities = ["read", "list"]\n}\n'
  done
  printf '%s' "$body" | vault policy write "$name" -
}

# write_role <role> <sa> <policy> : bind a Vault role to a single ServiceAccount
write_role() {
  local role="$1" sa="$2" policy="$3"
  vault write "auth/${VAULT_AUTH_PATH}/role/${role}" \
    bound_service_account_names="${sa}" \
    bound_service_account_namespaces="${K8S_NAMESPACE}" \
    policies="${policy}" \
    ttl="${TOKEN_TTL}"
}

echo ">> [3/5] Write per-app read-only policies"
write_policy camunda-bootstrap     "camunda/*"
write_policy camunda-orchestration "camunda/elasticsearch"
write_policy camunda-optimize      "camunda/elasticsearch"
write_policy camunda-web-modeler   "camunda/postgres/webmodeler"

echo ">> [4/5] Create per-app roles bound to each ServiceAccount"
write_role camunda-bootstrap     camunda-vault-bootstrap     camunda-bootstrap
write_role camunda-orchestration camunda-vault-orchestration camunda-orchestration
write_role camunda-optimize      camunda-vault-optimize      camunda-optimize
write_role camunda-web-modeler   camunda-vault-web-modeler   camunda-web-modeler

echo ">> [5/5] Seed secrets (only writes a key if it does not already exist)"
seed() {
  local p="$1"; shift
  if vault kv get "${KV_MOUNT}/${p}" >/dev/null 2>&1; then
    echo "   ${p} already present, skipping"
  else
    vault kv put "${KV_MOUNT}/${p}" "$@" >/dev/null
    echo "   wrote ${p}"
  fi
}
seed "camunda/elasticsearch"        "username=elastic"          "password=$(rand 28)"
seed "camunda/keycloak"             "admin-password=$(rand 24)"
seed "camunda/postgres/keycloak"    "admin-password=$(rand 24)" "user-password=$(rand 24)"
seed "camunda/postgres/webmodeler"  "admin-password=$(rand 24)" "user-password=$(rand 24)"

echo
echo "Done. Each app role can read only its own secret paths using its own SA in"
echo "namespace '${K8S_NAMESPACE}'. The bootstrap role seeds all camunda/* secrets."
