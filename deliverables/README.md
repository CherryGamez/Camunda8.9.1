# Camunda 8.9 Self-Managed + HashiCorp Vault (air-gapped, least-privilege)

A **production-style umbrella Helm chart** for Camunda 8.9 (`camunda-platform`
`14.0.1`) where **every PostgreSQL, Keycloak and Elasticsearch password is fetched
dynamically from HashiCorp Vault** by a tiny, auditable shell+curl agent — built
for **air-gapped OpenShift / ROKS on IBM Cloud** and shipped via **ArgoCD**
(manifests rendered in GitLab CI).

```
deliverables/
├── umbrella/                      # Umbrella Helm chart (Camunda + Vault wiring)
│   ├── Chart.yaml                 #   depends on camunda-platform 14.0.1 (vendored tgz)
│   ├── values.yaml                #   << THE complete umbrella values (all apps + Vault)
│   └── templates/                 #   per-app SA/RBAC, ConfigMaps, trusted-ca,
│                                  #   bootstrap Job, HAProxy, NetworkPolicy
├── vault-sidecar/                 # The agent (shell + curl), Dockerfile, image build
│   ├── agent.sh                   #   fetch | watch
│   ├── Dockerfile                 #   minimal alpine image, non-root
│   ├── config.example.json
│   └── build-and-push.sh
├── vault/                         # Vault configuration
│   ├── policy-camunda.hcl         #   broad-read policy (bootstrap role)
│   └── setup-vault.sh             #   KV + k8s auth + per-app roles/policies + seed
└── docs/
    ├── ARCHITECTURE.md            # design, per-app model, NetworkPolicy alternatives
    ├── HAPROXY.md                 # single entry point + service-ca TLS
    └── IBM-Cloud-deploy.md        # step-by-step OpenShift / ArgoCD deploy
```

## What you get

| Requirement | How it is met |
|---|---|
| Umbrella `values.yaml`, **all modules working & talking to each other** | Orchestration (Zeebe+Operate+Tasklist), Identity, **Keycloak**, Connectors, Optimize, Web Modeler, Console, Elasticsearch, 2× PostgreSQL — all enabled, OIDC via Keycloak. |
| **Postgres & ES passwords from Vault, dynamic** | The agent reads them from Vault (KV v2) and reconciles **per-app** Kubernetes Secrets each component references via `existingSecret`. |
| **Fetch secrets using the ServiceAccount name (k8s auth)** | Each app has its **own** SA + **own** Vault role/policy; the pod SA JWT is exchanged for a short-lived Vault token scoped to that app's paths only. |
| **Sidecar restarts the attached module** | `RESTART_MODE=rollout`: each sidecar patches **only its own** Deployment/StatefulSet (RBAC scoped to that one workload). |
| **Enterprise PKI / no self-signed certs** | Trust comes from the OpenShift **service-ca** via the `trusted-ca` ConfigMap (`service-ca.crt` → `tls-ca-bundle.pem`); HAProxy uses a service-serving-cert. |
| **Minimal rights / air-gapped** | Per-app RBAC = create + get/update/patch on **its own** Secret + get/patch on **its own** workload. No Vault Injector, no webhooks, no client-go. Non-root, read-only rootfs, all caps dropped. |
| **Single external entry point via HAProxy** | One HAProxy Service fronts everything by path prefix + proxies Zeebe gRPC; TLS via service-ca. A dedicated **monitoring port (9090)** exposes each app's `/actuator/health` + `/actuator/prometheus`. See **docs/HAPROXY.md**. |
| **ArgoCD-native delivery** | Point an ArgoCD Application at this Helm chart (`source.helm`); ArgoCD runs `helm template` and **natively converts the install hooks** (pre-install → PreSync), so SA/RBAC/ConfigMaps/`trusted-ca` and the bootstrap Job run before the datastores/apps. **No GitLab CI / Helm post-renderer needed.** |

## TL;DR deploy (release `camunda`, namespace `camunda`)

```bash
# 0. Build & push the agent image, then set it in values.yaml
REGISTRY=icr.io/<your-namespace> vault-sidecar/build-and-push.sh 1.0.0

# 1. Configure Vault (KV v2, k8s auth, per-app roles/policies, seed passwords)
export VAULT_ADDR=https://vault.example.com VAULT_TOKEN=<admin-token>
K8S_NAMESPACE=camunda vault/setup-vault.sh

# 2. Deploy via ArgoCD (point an Application at this Helm chart):
#    source.helm + destination.namespace=camunda + automated sync.
#    Local dry-run of the same output:
cd umbrella && helm dependency build . && \
  helm template camunda . -n camunda | kubectl apply --dry-run=server -f -
```

See **docs/IBM-Cloud-deploy.md** for the full OpenShift / ArgoCD walkthrough and
**docs/ARCHITECTURE.md** for the per-app design, TLS model and NetworkPolicy
alternatives.

## Verified in this delivery
- `helm dependency build` + `helm template` render the full stack cleanly; every
  document parses as valid YAML.
- Per-app **ServiceAccounts, Roles (scoped to one Secret + one workload),
  RoleBindings**, per-app **Vault roles/policies**, per-app **Secrets** and
  **rollout** restart targets all render correctly (orchestration→`camunda-zeebe`
  StatefulSet, optimize→`camunda-optimize`, web-modeler→`camunda-web-modeler-restapi`).
- `trusted-ca` ConfigMap carries the OpenShift `inject-cabundle` annotation;
  HAProxy Service carries the `serving-cert-secret-name` annotation.
- Agent `fetch`/`watch` parse the new multi-secret config schema (jq-validated).

## Not verified here (needs a real OpenShift cluster)
The sandbox has no OpenShift service-ca operator and cannot boot the heavy Camunda
Java pods. Smoke-test on a non-prod ROKS cluster per docs/IBM-Cloud-deploy.md
(bootstrap Job completes, secrets created, service-ca injected, pods Ready).
