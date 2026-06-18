# PRD — Camunda 8.9 Self-Managed + HashiCorp Vault (air-gapped, IBM Cloud)

## Problem statement (verbatim intent)
Prepare an umbrella `values.yaml` for the Camunda 8.9.1 charts (camunda-platform
14.0.1) with all modules working and communicating (including Keycloak). The
PostgreSQL and Elasticsearch passwords must be fetched **dynamically** from
HashiCorp Vault by a **sidecar**. Provide the sidecar's Dockerfile and Helm
charts so it can be deployed to an IBM Cloud cluster. Add an init container for a
self-signed certificate. The sidecar must work for all modules, fetch secrets
from Vault **using a ServiceAccount name** (k8s auth), and **restart the attached
module**. Keep rights minimal (air-gapped + enterprise policy): minimal
functionality, fetch secrets for the module and restart it.

## User choices (gathered)
- Target cluster: **both** IKS and OpenShift.
- Vault auth: **Kubernetes auth** (pod ServiceAccount JWT).
- Secret delivery: agent's choice → single `camunda-credentials` Kubernetes Secret
  (chart-native), plus optional shared-file mode.
- Restart: **in-pod signal** (shared process namespace) as default; rollout as fallback.
- Modules: **all** (Orchestration, Identity, Keycloak, Connectors, Optimize,
  Web Modeler, Console, Elasticsearch, 2× PostgreSQL).
- Sidecar language: switched from Go to **shell + curl** per user request.

## Architecture (implemented)
- Umbrella Helm chart depends on `camunda-platform` 14.0.1 (vendored tgz for air-gap).
- `camunda-vault-agent` (shell+curl, alpine, non-root): `gencert | fetch | watch`.
- Vault k8s auth → reads `secret/camunda/*` (KV v2) → reconciles `camunda-credentials`.
- Pre-install/upgrade **bootstrap Job** creates the secret before DB pods boot.
- Each Camunda app module gets: `vault-gencert` init, `vault-fetch` init,
  `vault-agent` watch sidecar, shared volumes.
- Restart: signal mode via `shareProcessNamespace` injected by post-render kustomize.
- RBAC: create + get/update/patch on the single `camunda-credentials` secret. No more.

## Status — implemented & verified (2026-06-18)
- `helm dependency build` / `helm lint` / `helm template`: clean (62 manifests).
- Agent verified against a **live Vault dev server**: login(token), KV v2 read,
  create/patch logic (file path), idempotency, rotation detection. `gencert` verified
  (subject + SANs). Post-render injects `shareProcessNamespace` into all 6 modules.
- All component Secret refs resolve to `camunda-credentials` with correct keys
  (ES, Keycloak admin, Keycloak-PG, WebModeler-PG, Orchestration, Optimize).

## NOT verified here (needs a real cluster)
- Full Camunda end-to-end boot on IBM Cloud (no cluster/Vault/registry in build env).
- Live Kubernetes Secret create/patch and signal/rollout restart on a running pod.
  → Smoke-test on non-prod per docs/IBM-Cloud-deploy.md before production.

## Backlog / next
- P1: Optional REST TLS for Elasticsearch (truststore wiring into orchestration/optimize).
- P1: Projected SA token (audience=vault) volume for stricter Vault audience binding.
- P2: Ingress + external OIDC issuer/redirect URLs for browser access.
- P2: DB-side password rotation runbook (rotate stored password in engine + Vault).
- P2: NetworkPolicies restricting agent egress to Vault + API server only.

## Deliverables location
`/app/deliverables/` (umbrella/, vault-sidecar/, vault/, docs/). Push to the user's
GitHub repo via the chat "Save to Github" feature.
