# camunda-vault-agent (shell + curl)

A small POSIX shell helper that fetches Camunda secrets from HashiCorp Vault and
reconciles them into **per-app Kubernetes Secrets**, then rollout-restarts the
attached workload on change. Built for air-gapped, least-privilege clusters: no
Vault SDK, no client-go, no mutating webhooks — only `sh`, `curl`, `jq`, `base64`.

## Commands

| Command | Container role | What it does |
|---|---|---|
| `fetch` | init / Job | Logs in to Vault (k8s auth), reads the mapped fields, creates/patches the configured Secret(s). Idempotent. |
| `watch` | sidecar | Loops `fetch` every `INTERVAL_SECONDS`; on change, `rollout restart`s the attached workload. |

(There is **no `gencert`** — TLS trust comes from the cluster `trusted-ca` bundle.)

## Authentication
Vault **Kubernetes auth**. The pod ServiceAccount JWT
(`/var/run/secrets/kubernetes.io/serviceaccount/token`) is POSTed to
`auth/<VAULT_AUTH_PATH>/login` with `VAULT_ROLE`; the returned short-lived token
is used for reads. `VAULT_ROLE` may be supplied via env **or** the config file
(`.vaultRole`), so the shared env ConfigMap stays role-agnostic and each pod's
per-app config carries its own role. Set `VAULT_TOKEN` to bypass login (testing).

## Environment variables

| Var | Default | Purpose |
|---|---|---|
| `VAULT_ADDR` | — | Vault base URL (required) |
| `VAULT_ROLE` | (from `.vaultRole` in config) | Vault k8s auth role |
| `VAULT_AUTH_PATH` | `kubernetes` | k8s auth mount path |
| `VAULT_NAMESPACE` | "" | Vault Enterprise namespace |
| `VAULT_CACERT` | "" | CA file for Vault TLS (the mounted `trusted-ca` bundle) |
| `VAULT_SKIP_VERIFY` | `false` | skip Vault TLS verify (testing only) |
| `VAULT_SA_TOKEN_PATH` | in-cluster SA token | JWT used for login |
| `VAULT_TOKEN` | "" | if set, skip login |
| `CONFIG_FILE` | `/etc/camunda-vault-agent/config.json` | mapping file |
| `POD_NAMESPACE` | (downward API / SA file) | target namespace for the Secret(s) |
| `INTERVAL_SECONDS` | `300` | watch interval |
| `RESTART_MODE` | `rollout` | `rollout` \| `none` |
| `RESTART_TARGET_KIND` / `RESTART_TARGET_NAME` | `Deployment` / — | workload to restart on change |

## Mapping config (JSON, from a ConfigMap)
```json
{
  "vaultRole": "camunda-optimize",
  "secrets": [
    {
      "secretName": "camunda-optimize-secret",
      "entries": [
        { "vaultPath": "secret/data/camunda/elasticsearch", "field": "password", "secretKey": "elasticsearch-password" }
      ]
    }
  ]
}
```
- A **watch sidecar** has exactly one entry in `secrets` (its own app secret).
- The **bootstrap Job** lists every secret so all are seeded before datastores boot.
- `vaultPath` uses the KV v2 read path (note the `/data/` segment).

## Restart modes
- **rollout** (default): patches the workload's pod-template annotation (like
  `kubectl rollout restart`). Needs `get`/`patch` on that specific
  Deployment/StatefulSet only.
- **none**: update the Secret only; restart manually / on next deploy.

## Local smoke test
```bash
vault server -dev -dev-root-token-id=root &
export VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=root
vault kv put secret/camunda/elasticsearch password=secret123 username=elastic
CONFIG_FILE=./config.example.json POD_NAMESPACE=camunda ./agent.sh fetch
```
