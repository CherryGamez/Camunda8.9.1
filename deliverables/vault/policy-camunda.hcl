# Vault policy for the Camunda vault-agent.
# READ-ONLY access to exactly the Camunda secret tree. Nothing else.
# (KV v2 stores data under .../data/... and metadata under .../metadata/...)

path "secret/data/camunda/*" {
  capabilities = ["read"]
}

path "secret/metadata/camunda/*" {
  capabilities = ["read", "list"]
}
