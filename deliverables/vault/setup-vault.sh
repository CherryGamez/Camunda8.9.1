#!/usr/bin/env bash
# =============================================================================
# setup-vault.sh — one-time Vault configuration for the Camunda vault-agent
#
# Configures:
#   1. KV v2 secrets engine at `secret/`
#   2. Kubernetes auth method
#   3. A read-only policy scoped to secret/camunda/*
#   4. A Vault role bound to the `camunda-vault-agent` ServiceAccount
#   5. Seed random PostgreSQL / Keycloak / Elasticsearch passwords (idempotent)
#
# Requires: vault CLI, and VAULT_ADDR + a privileged VAULT_TOKEN exported.
# Run it from a machine that can reach Vault. The Kubernetes host/CA are read
# from the values below (defaults assume running inside the target cluster).
# =============================================================================
set -euo pipefail

# ---- configurable ----------------------------------------------------------
K8S_NAMESPACE="${K8S_NAMESPACE:-camunda}"
SA_NAME="${SA_NAME:-camunda-vault-agent}"
VAULT_ROLE="${VAULT_ROLE:-camunda}"
VAULT_AUTH_PATH="${VAULT_AUTH_PATH:-kubernetes}"
KV_MOUNT="${KV_MOUNT:-secret}"
TOKEN_TTL="${TOKEN_TTL:-1h}"

# Kubernetes API reachable from Vault. When Vault runs in-cluster these defaults work.
KUBERNETES_HOST="${KUBERNETES_HOST:-https://kubernetes.default.svc:443}"
KUBERNETES_CA_CERT="${KUBERNETES_CA_CERT:-/var/run/secrets/kubernetes.io/serviceaccount/ca.crt}"
# Optional reviewer JWT (long-lived SA token). If empty, Vault uses the client JWT's reviewer.
TOKEN_REVIEWER_JWT="${TOKEN_REVIEWER_JWT:-}"

rand() { LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${1:-24}"; }

echo ">> [1/5] Enable KV v2 at '${KV_MOUNT}/' (if needed)"
vault secrets enable -path="${KV_MOUNT}" -version=2 kv 2>/dev/null || echo "   already enabled"

echo ">> [2/5] Enable Kubernetes auth at '${VAULT_AUTH_PATH}/' (if needed)"
vault auth enable -path="${VAULT_AUTH_PATH}" kubernetes 2>/dev/null || echo "   already enabled"

echo ">> Configure Kubernetes auth backend"
CONFIG_ARGS=( "kubernetes_host=${KUBERNETES_HOST}" )
if [ -f "${KUBERNETES_CA_CERT}" ]; then
  CONFIG_ARGS+=( "kubernetes_ca_cert=@${KUBERNETES_CA_CERT}" )
fi
if [ -n "${TOKEN_REVIEWER_JWT}" ]; then
  CONFIG_ARGS+=( "token_reviewer_jwt=${TOKEN_REVIEWER_JWT}" )
fi
vault write "auth/${VAULT_AUTH_PATH}/config" "${CONFIG_ARGS[@]}"

echo ">> [3/5] Write read-only policy 'camunda'"
vault policy write camunda "$(dirname "$0")/policy-camunda.hcl"

echo ">> [4/5] Create role '${VAULT_ROLE}' bound to SA ${K8S_NAMESPACE}/${SA_NAME}"
vault write "auth/${VAULT_AUTH_PATH}/role/${VAULT_ROLE}" \
  bound_service_account_names="${SA_NAME}" \
  bound_service_account_namespaces="${K8S_NAMESPACE}" \
  policies="camunda" \
  ttl="${TOKEN_TTL}"

echo ">> [5/5] Seed secrets (only writes a key if it does not already exist)"
seed() { # path key1=val1 key2=val2 ...
  local p="$1"; shift
  if vault kv get "${KV_MOUNT}/${p}" >/dev/null 2>&1; then
    echo "   ${p} already present, skipping"
  else
    vault kv put "${KV_MOUNT}/${p}" "$@" >/dev/null
    echo "   wrote ${p}"
  fi
}
seed "camunda/elasticsearch"        "username=elastic"       "password=$(rand 28)"
seed "camunda/keycloak"             "admin-password=$(rand 24)"
seed "camunda/postgres/keycloak"    "admin-password=$(rand 24)" "user-password=$(rand 24)"
seed "camunda/postgres/webmodeler"  "admin-password=$(rand 24)" "user-password=$(rand 24)"

echo
echo "Done. The agent role '${VAULT_ROLE}' can now read secret/camunda/* using"
echo "the '${SA_NAME}' ServiceAccount in namespace '${K8S_NAMESPACE}'."
