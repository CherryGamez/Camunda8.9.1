# Deploying on IBM Cloud — OpenShift / ROKS (ArgoCD + GitLab CI)

Release name `camunda`, namespace `camunda` are assumed throughout. If you change
them, update `vaultAgent.targets[].sidecar.workload.name` in `umbrella/values.yaml`
(the rollout targets) and the SA/namespace bindings in `vault/setup-vault.sh`.

## 0. Prerequisites
- **Red Hat OpenShift on IBM Cloud (ROKS)** with the **service-ca operator**
  available (standard on OpenShift) for cert injection.
- A reachable **HashiCorp Vault** (in-cluster or external) with admin access for setup.
- A mirrored registry (e.g. **IBM Container Registry `icr.io`**) holding the
  Camunda/Bitnami images and your built `camunda-vault-agent:1.0.0`.
  Set `camunda-platform.global.image.registry` (and per-image repos) to your mirror.
- **ArgoCD** installed, and a **GitLab** project with a runner that can reach the
  mirror + the GitOps repo.

## 1. Build & push the agent image
```bash
cd deliverables/vault-sidecar
REGISTRY=icr.io/<your-namespace> ./build-and-push.sh 1.0.0
```
Then set the image in `umbrella/values.yaml`:
- `vaultAgent.image`
- every literal `image:` inside the `camunda-platform` section's vault init/sidecar
  containers (Helm cannot template values passed to a subchart — keep them in sync).

## 2. Node prerequisite for Elasticsearch
The chart disables the privileged `sysctl` init container, so ensure
`vm.max_map_count=262144` on worker nodes via a **Tuned**/`MachineConfig` profile.

## 3. Configure Vault (per-app roles & policies)
```bash
export VAULT_ADDR=https://<vault-host>:8200 VAULT_TOKEN=<admin-token>
cd deliverables/vault
K8S_NAMESPACE=camunda ./setup-vault.sh
```
This enables KV v2 + Kubernetes auth, writes **one read-only policy and one role
per app** (`camunda-bootstrap`, `camunda-orchestration`, `camunda-optimize`,
`camunda-web-modeler`), each bound to its own ServiceAccount in `camunda`, and
seeds random passwords at `secret/camunda/*`.

> If Vault runs **outside** the cluster, pass `KUBERNETES_HOST`, `KUBERNETES_CA_CERT`
> and a `TOKEN_REVIEWER_JWT` (a long-lived SA token allowed to call TokenReview).

## 4. Set your hostname
The external host appears in `haproxy.host`, `camunda-platform.global.host`,
`global.identity.auth.publicIssuerUrl` and the per-module `redirectUrl`s:
```bash
grep -rl camunda.example.com umbrella/values.yaml | \
  xargs sed -i 's/camunda.example.com/<your-host>/g'
```

## 5. Deploy via ArgoCD (chart consumed directly — no CI rendering)
Point an ArgoCD **Application** at this Helm chart; ArgoCD runs `helm template`
and honours the install hooks natively:

1. Commit `deliverables/umbrella` to your Git repo.
2. Create an ArgoCD Application with a **Helm** source:
   ```yaml
   spec:
     source:
       repoURL: <your-git-repo>
       path: umbrella
       helm:
         valueFiles: [values.yaml]
     destination: { namespace: camunda, server: https://kubernetes.default.svc }
     syncPolicy:
       automated: { prune: true, selfHeal: true }
       syncOptions: [CreateNamespace=true]
   ```
3. ArgoCD converts the `pre-install`/`pre-upgrade` hooks to **PreSync** (ordered
   by hook-weight): SA/RBAC/ConfigMaps/`trusted-ca` → **bootstrap Job** (seeds all
   secrets) → main sync brings up Elasticsearch/Keycloak/PostgreSQL + the apps.

> Local dry-run of the same output:
> ```bash
> cd deliverables/umbrella && helm dependency build .
> helm template camunda . -n camunda | kubectl apply --dry-run=server -f -
> ```

## 6. OpenShift specifics
- The agent and HAProxy run **non-root** with `RuntimeDefault` seccomp, so the
  `restricted-v2` SCC is sufficient — **no extra SCC / `oc adm policy` needed**.
- If you hit fsGroup/runAsUser SCC conflicts on the Camunda pods, set
  `camunda-platform.global.compatibility.openshift.adaptSecurityContext=force`.
- **TLS** is handled by the service-ca operator (HAProxy serving cert +
  `trusted-ca` bundle) — see docs/HAPROXY.md and docs/ARCHITECTURE.md.

## 7. Verify
```bash
oc -n camunda get job camunda-vault-bootstrap                 # Completed
oc -n camunda get secret | grep camunda-                      # per-app secrets exist
oc -n camunda get pods                                        # all Running/Ready
oc -n camunda logs sts/camunda-zeebe -c vault-agent           # watch loop
oc -n camunda get cm trusted-ca -o jsonpath='{.data.service-ca\.crt}' | head -1  # injected
```

## 8. Access (through HAProxy — the single entry point)
```bash
oc -n camunda get svc camunda-haproxy            # ClusterIP (front with a Route)
oc -n camunda create route reencrypt camunda --service=camunda-haproxy --port=https
#   https://<route-host>/operate  /tasklist  /identity  /optimize  /modeler  /console
# Zeebe gRPC clients -> via a passthrough Route or LoadBalancer on :26500
```
See **docs/HAPROXY.md** for the routing table. No chart Ingress is used.

## 9. Rotating a password
```bash
vault kv put secret/camunda/elasticsearch password=<new> username=elastic
```
Within `INTERVAL_SECONDS` the **orchestration** and **optimize** sidecars patch
their own secret and rollout-restart their own workload. Datastore passwords
(Keycloak/Postgres admin, ES) require re-running the bootstrap (next sync) **and**
rotating the password inside the engine itself.

## Troubleshooting
- **App pod `CreateContainerConfigError` on its `*-secret`** → bootstrap Job
  didn't complete; check `oc -n camunda logs job/camunda-vault-bootstrap`
  (Vault address/role/policy, SA binding, `trusted-ca` injected yet?).
- **`vault login failed`** → the app's role `bound_service_account_names`/
  `namespaces` must match its SA / `camunda`; check `auth/kubernetes/config`.
- **Vault TLS error** → confirm `trusted-ca` carries `service-ca.crt` and that
  Vault presents a service-ca-signed cert (or set `vaultAgent.vault.skipVerify`
  only for testing).
- **Restart not happening** → check the sidecar's Role allows `get/patch` on its
  workload and `RESTART_TARGET_KIND/NAME` match the rendered resource.
