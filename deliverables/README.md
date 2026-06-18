# Camunda 8.9 Self-Managed + HashiCorp Vault (air-gapped, least-privilege)

This repository delivers a **production-style umbrella Helm chart** for Camunda 8.9
(`camunda-platform` chart `14.0.1`) where **every PostgreSQL, Keycloak and
Elasticsearch password is fetched dynamically from HashiCorp Vault** by a tiny,
auditable sidecar — designed for **air-gapped IBM Cloud clusters (IKS & OpenShift)**
under strict enterprise policy.

```
deliverables/
├── umbrella/                      # Umbrella Helm chart (Camunda + Vault wiring)
│   ├── Chart.yaml                 #   depends on camunda-platform 14.0.1
│   ├── values.yaml                #   << THE umbrella values: all modules + Vault
│   ├── templates/                 #   SA, minimal RBAC, ConfigMaps, bootstrap Job
│   └── post-render/               #   kustomize overlay for signal-mode restart
├── vault-sidecar/                 # The agent (shell + curl), Dockerfile, image build
│   ├── agent.sh                   #   gencert | fetch | watch
│   ├── Dockerfile                 #   minimal alpine image, non-root
│   ├── config.example.json
│   └── build-and-push.sh
├── vault/                         # Vault configuration
│   ├── policy-camunda.hcl         #   read-only, scoped to secret/camunda/*
│   └── setup-vault.sh             #   KV + k8s auth + role + seed secrets
└── docs/
    ├── ARCHITECTURE.md
    └── IBM-Cloud-deploy.md        # step-by-step IKS / OpenShift deploy
```

## What you get

| Requirement | How it is met |
|---|---|
| Umbrella `values.yaml`, **all modules working & talking to each other** | Orchestration (Zeebe+Operate+Tasklist), Identity, **Keycloak**, Connectors, Optimize, Web Modeler, Console, Elasticsearch, 2× PostgreSQL — all enabled and wired (OIDC auth via Keycloak). |
| **Postgres & ES passwords from Vault, dynamic** | The agent reads them from Vault (KV v2) and reconciles a single `camunda-credentials` Secret every component already references. |
| **Sidecar fetches secrets using the ServiceAccount name** | Vault **Kubernetes auth**: the pod's `camunda-vault-agent` SA JWT is exchanged for a short-lived Vault token. No static credentials. |
| **Sidecar can restart the attached module** | `RESTART_MODE=signal`: in shared PID namespace the agent SIGTERMs the JVM (no RBAC). `rollout` mode available as a scoped-RBAC alternative. |
| **Init container for self-signed certificate** | `vault-gencert` init container generates `tls.crt/tls.key/ca.crt` into a shared volume. |
| **Minimal rights / air-gapped / enterprise policy** | Agent RBAC = create + get/update/patch on **one** Secret. Signal-restart needs **zero** workload RBAC. No mutating webhooks, no Vault Injector, no client-go. Non-root, read-only rootfs, all caps dropped. Image = alpine + curl/jq/openssl only. |

## TL;DR deploy (release name `camunda`, namespace `camunda`)

```bash
# 0. Build & push the agent image to your registry, then set it in values.yaml
REGISTRY=icr.io/<your-namespace> vault-sidecar/build-and-push.sh 1.0.0

# 1. Configure Vault (KV v2, k8s auth, role bound to the SA, seed passwords)
export VAULT_ADDR=https://vault.example.com VAULT_TOKEN=<admin-token>
K8S_NAMESPACE=camunda vault/setup-vault.sh

# 2. Resolve chart deps
helm dependency build umbrella/

# 3a. Install (signal restart — honours shareProcessNamespace via post-render)
helm install camunda umbrella/ -n camunda --create-namespace \
  --post-renderer umbrella/post-render/post-render.sh

# 3b. ...or install without post-render and use rollout restart:
#     set vaultAgent.restart.mode=rollout and uncomment the apps rule in vault-rbac.yaml
```

See **docs/IBM-Cloud-deploy.md** for the full IKS / OpenShift walkthrough and
**docs/ARCHITECTURE.md** for the design and the secret flow.

## Verified in this delivery
- `helm dependency build`, `helm lint`, `helm template` (62 manifests render cleanly).
- The agent (`gencert`, `fetch`, change-detection, rotation) tested against a **live Vault dev server**.
- Post-render correctly injects `shareProcessNamespace: true` into all 6 Camunda modules.
- All component Secret references resolve to `camunda-credentials` with the correct keys.

## Not verified here (needs your cluster)
A full end-to-end boot of Camunda requires a real Kubernetes cluster + Vault +
your registry, which is out of scope of this build environment. The Kubernetes
Secret write/patch and `rollout`/`signal` restart paths are implemented to spec
but should be smoke-tested on a non-prod cluster first (see IBM-Cloud-deploy.md).
