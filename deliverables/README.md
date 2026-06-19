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
│   ├── templates/                 #   SA, minimal RBAC, ConfigMaps, bootstrap Job, HAProxy
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
| **Single external entry point via HAProxy** | One HAProxy Service fronts everything; routes by path prefix to each module + proxies Zeebe gRPC. Modules talk to each other over in-cluster DNS. See **docs/HAPROXY.md**. |

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
- `helm dependency build`, `helm lint`, `helm template` (full stack renders cleanly).
- **Live integration test against a REAL Kubernetes API server (k3s control-plane) + REAL Vault:**
  - Vault **Kubernetes auth** — agent SA JWT validated via real TokenReview → Vault token.
  - Agent **created** `camunda-credentials` in the live API server (6 keys, values matching Vault).
  - **Idempotent** re-run (no-op), **rotation** (patches only the changed key), **rollout-restart** (real Deployment pod-template annotation patched).
  - **Least-privilege RBAC enforced by the apiserver**: create + get own secret only — `kubectl auth can-i` denies delete/list/other secrets/pods.
  - All **66 rendered manifests pass `kubectl apply --dry-run=server`** (real schema/admission validation).
  - HTTPS to Vault validated against a TLS Vault (custom CA, clean fatal on TLS error, skip-verify).
  - `haproxy -c` validates the generated HAProxy config (incl. the TLS bind).
- A real latent bug was found by the live test (shell subshell var scope on the k8s path) and fixed.

## Not verified here (needs a bigger cluster)
The sandbox is capped at **2 GB RAM** and the **kubelet is blocked** (no `/dev/kmsg`
device access), so the heavy Camunda **Java pods cannot boot here** (they need
~8–16 GB + a kubelet). The control-plane test above covers the Vault/sidecar/RBAC
integration; boot the full stack on your IBM Cloud cluster per docs/IBM-Cloud-deploy.md.
