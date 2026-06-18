# camunda-vault-agent (shell + curl)

A ~250-line POSIX shell helper that fetches Camunda secrets from HashiCorp Vault
and reconciles them into a Kubernetes Secret, with optional module restart.
Built for air-gapped, least-privilege clusters: no Vault SDK, no client-go, no
mutating webhooks — only `sh`, `curl`, `jq`, `openssl`, `base64`.

## Commands

| Command | Container role | What it does |
|---|---|---|
| `gencert` | init | Generates a self-signed `tls.crt`/`tls.key`/`ca.crt` into `CERT_DIR`. |
| `fetch` | init / Job | Logs in to Vault (k8s auth), reads the mapped fields, creates/patches the `camunda-credentials` Secret, optionally writes shared files. Idempotent. |
| `watch` | sidecar | Loops `fetch` every `INTERVAL_SECONDS`; on change, restarts the attached module. |

## Authentication
Vault **Kubernetes auth**. The pod ServiceAccount JWT
(`/var/run/secrets/kubernetes.io/serviceaccount/token`) is POSTed to
`auth/<VAULT_AUTH_PATH>/login` with the configured `VAULT_ROLE`; the returned
short-lived token is used for reads. Set `VAULT_TOKEN` to bypass login (local
testing / static-token mode).

## Environment variables

| Var | Default | Purpose |
|---|---|---|
| `VAULT_ADDR` | — | Vault base URL (required) |
| `VAULT_ROLE` | — | Vault k8s auth role (required unless `VAULT_TOKEN` set) |
| `VAULT_AUTH_PATH` | `kubernetes` | k8s auth mount path |
| `VAULT_NAMESPACE` | "" | Vault Enterprise namespace |
| `VAULT_CACERT` | "" | CA file for Vault TLS |
| `VAULT_SKIP_VERIFY` | `false` | skip Vault TLS verify (testing only) |
| `VAULT_SA_TOKEN_PATH` | in-cluster SA token | JWT used for login (use a projected token for audience binding) |
| `VAULT_TOKEN` | "" | if set, skip login |
| `CONFIG_FILE` | `/etc/camunda-vault-agent/config.json` | mapping file |
| `POD_NAMESPACE` | (downward API / SA file) | target namespace for the Secret |
| `INTERVAL_SECONDS` | `300` | watch interval |
| `RESTART_MODE` | `rollout` | `signal` \| `rollout` \| `none` |
| `RESTART_TARGET_KIND` / `RESTART_TARGET_NAME` | `Deployment` / — | workload for rollout mode |
| `RESTART_PROCESS_MATCH` | — | substring of the app cmdline for signal mode (e.g. `java`) |
| `CERT_DIR` / `CERT_CN` / `CERT_SANS` / `CERT_DAYS` | `/tls` / `localhost` / "" / `825` | gencert options |

## Mapping config (JSON, from a ConfigMap)
```json
{
  "secretName": "camunda-credentials",
  "entries": [
    { "vaultPath": "secret/data/camunda/elasticsearch", "field": "password", "secretKey": "elasticsearch-password" }
  ],
  "files": [
    { "vaultPath": "secret/data/camunda/elasticsearch", "field": "password", "path": "/vault/secrets/es-password" }
  ]
}
```
- `entries` → keys written into the Kubernetes Secret (base64).
- `files`   → values written to a shared volume (bitnami `*_FILE` convention / app config).
- `vaultPath` uses the KV v2 read path (note the `/data/` segment).

## Restart modes
- **signal** (default in the umbrella): requires `shareProcessNamespace: true` on the
  pod (injected by the post-render overlay). Sends `SIGTERM` to the matched process;
  the kubelet restarts the container. **No Kubernetes RBAC needed.** The agent must
  run as the **same UID** as the app (1001 for Camunda images) to be allowed to signal it.
- **rollout**: patches the workload's pod-template annotation (like `kubectl rollout
  restart`). Needs `get`/`patch` on that specific Deployment/StatefulSet.
- **none**: update the Secret only; restart manually / rely on the next deploy.

## Local smoke test
```bash
vault server -dev -dev-root-token-id=root &
export VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=root VAULT_ROLE=x
vault kv put secret/camunda/elasticsearch password=secret123 username=elastic
CONFIG_FILE=./config.example.json ./agent.sh fetch     # file/secret reconcile
CERT_DIR=/tmp/tls ./agent.sh gencert                    # self-signed cert
```
