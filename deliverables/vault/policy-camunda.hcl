# Vault policy for the Camunda vault-agent BOOTSTRAP role (broad read).
# READ-ONLY access to the whole Camunda secret tree so the bootstrap Job can
# seed every per-app Secret. The per-app *runtime* roles are far narrower and
# are created inline by setup-vault.sh (each reads only its own paths).
# (KV v2 stores data under .../data/... and metadata under .../metadata/...)

path "secret/data/camunda/*" {
  capabilities = ["read"]
}

path "secret/metadata/camunda/*" {
  capabilities = ["read", "list"]
}
