# PRD — Camunda 8.9 Self-Managed + HashiCorp Vault (air-gapped, OpenShift/ROKS)

## Problem statement (verbatim intent)
Prepare an umbrella `values.yaml` for the Camunda 8.9.1 charts (camunda-platform
14.0.1) with all modules working and communicating (incl. Keycloak). PostgreSQL
and Elasticsearch passwords must be fetched **dynamically** from HashiCorp Vault
by a **sidecar** (Dockerfile + Helm charts for IBM Cloud). The sidecar must use
**Kubernetes ServiceAccount auth**, have **minimal rights** (air-gapped), and
**restart the attached module**. HAProxy is the single external entry point with
TLS.

### Msg 309 corrections (current scope)
- **Per-app ServiceAccounts** + per-app Vault roles/policies + per-app Secrets.
- The sidecar restarts **only its own** workload (rollout mode, scoped RBAC).
- Drop self-signed `gencert` → mount the OpenShift **service-ca** `trusted-ca`
  ConfigMap (key `service-ca.crt` → `tls-ca-bundle.pem`).
- HAProxy TLS via OpenShift **service-serving-cert** (no self-signed).
- Deploy via **ArgoCD**: point an Application at the Helm chart directly
  (`source.helm`); ArgoCD natively converts install hooks → PreSync. **No GitLab
  CI / Helm post-renderer.**
- Document **NetworkPolicy alternatives** for clusters without NetworkPolicy.
- **Complete, self-contained `values.yaml`**: per-app image registry (air-gap),
  resources, replicas, persistence, env hooks, OIDC, OpenShift compat; HAProxy
  block documents the external path → Service mapping for every app.

## User choices (gathered)
- Restart model: **per-app rollout** (a).
- Platform: **OpenShift / ROKS on IBM Cloud**, service-ca annotations (a).
- Secrets: **per-app secrets** (strongest isolation) (a).
- Sidecar language: **shell + curl**.

## Architecture (implemented 2026-06-19)
- Umbrella chart depends on `camunda-platform` 14.0.1 (vendored tgz, offline).
- `vaultAgent.targets[]` drives everything: each target = a Secret + mappings;
  targets with a `sidecar:` block also get an SA, Vault role, watch sidecar and a
  rollout target.
  - Sidecar apps: **orchestration** (StatefulSet `camunda-zeebe`), **optimize**
    (Deployment `camunda-optimize`), **web-modeler** (Deployment
    `camunda-web-modeler-restapi`). The Vault sidecar shares the app's OWN
    (chart-owned) ServiceAccount with the main container; scoped Role/RoleBinding
    + Vault auth role are attached to that SA (no separate vault SA). Bootstrap
    Job keeps its own dedicated SA `camunda-vault-bootstrap`.
  - Datastore-only secrets (bootstrap-seeded, no sidecar): elasticsearch,
    keycloak (admin), keycloak-db, web-modeler-db.
  - Identity / Connectors / Console: **no sidecar** (OIDC, no Vault DB secret).
- `agent.sh` (shell+curl): `fetch` | `watch`. Multi-secret config schema
  (`{vaultRole, secrets:[{secretName, entries}]}`); `rollout`/`none` restart.
- Bootstrap Job (pre-install hook) seeds ALL secrets before datastores boot.
- Per-app RBAC: create secrets + get/update/patch **own** Secret + get/patch
  **own** workload. Bootstrap SA: create + get/update/patch the named secrets.
- TLS trust: `trusted-ca` ConfigMap (OpenShift `inject-cabundle`), mounted into
  every agent + app container; `VAULT_CACERT` points at the bundle.
- HAProxy single entry point: path routing + Zeebe gRPC TCP + TLS via service-ca
  serving cert (`service.beta.openshift.io/serving-cert-secret-name`).
- HAProxy **monitoring port 9090**: per-app actuator routes (health + prometheus)
  with path-prefix rewrite to each component's management port; optional
  `allowedCidrs` src-ACL. Validated with `haproxy -c`.
- `.gitlab-ci.yml`: `helm template` → yq converts Helm hooks → ArgoCD PreSync +
  sync-waves → kubeconform → commit to GitOps repo.

## Status — validated in build env (2026-06-19)
- `helm lint` clean; `helm template` renders 81 docs; all parse as valid YAML.
- Verified rendered: per-app SAs/Roles(scoped to one secret + one workload)/
  RoleBindings; per-app Vault roles in config; per-app Secrets wired via
  `existingSecret`; correct rollout `RESTART_TARGET_*`; `trusted-ca`
  inject-cabundle annotation; HAProxy serving-cert annotation.
- `agent.sh` multi-secret config parsing jq-validated; bash `-n` syntax OK.
- GitLab CI yq hook→ArgoCD transform tested on real render: 0 helm hooks left,
  17 ArgoCD hooks, sync-waves -20..0 in correct dependency order.
- Removed: `umbrella/post-render/`, `vault-ca-configmap.yaml`, `gencert`.

## NOT verified here (needs a real OpenShift cluster)
- service-ca operator injection of `trusted-ca` / HAProxy serving cert.
- Full Camunda Java pods boot, live secret create/patch + rollout restart.
- End-to-end ArgoCD sync of the rendered manifests.
→ Smoke-test on non-prod ROKS per docs/IBM-Cloud-deploy.md.

## Backlog / next
- P1: Optional REST TLS for Elasticsearch (truststore from trusted-ca into
  orchestration/optimize).
- P1: Projected SA token (audience=vault) for stricter Vault audience binding.
- P2: DB-side password rotation runbook (rotate stored password in engine + Vault).
- P2: Module-level egress NetworkPolicies for the sidecar pods (labels-based).
- P2: OpenShift EgressFirewall sample manifest (referenced in ARCHITECTURE.md).

## Deliverables location
`/app/deliverables/` (`.gitlab-ci.yml`, umbrella/, vault-sidecar/, vault/, docs/).
Push to the user's GitHub via the chat "Save to Github" feature.

## Credentials
No app credentials created. Vault admin token + seeded passwords are user/Vault
provided at runtime; nothing hardcoded. (test_credentials.md not applicable.)
