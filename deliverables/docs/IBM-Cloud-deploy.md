# Deploying on IBM Cloud (IKS & OpenShift)

Release name `camunda`, namespace `camunda` are assumed throughout. If you
change them, update the workload names in `umbrella/post-render/kustomization.yaml`
and the optional rollout RBAC rule in `umbrella/templates/vault-rbac.yaml`.

## 0. Prerequisites
- An IBM Cloud cluster: **IKS** (vanilla k8s) or **Red Hat OpenShift on IBM Cloud**.
- A reachable **HashiCorp Vault** (in-cluster or external) with admin access for setup.
- A container registry you can pull from in the air-gap (e.g. **IBM Container
  Registry `icr.io`**). Mirror these images into it:
  - `camunda/camunda:8.9.x`, `camunda/identity:8.9.1`, `camunda/optimize:8.9.1`,
    `camunda/connectors-bundle:8.9.1`, `camunda/console:8.9.x`,
    `camunda/web-modeler-restapi|webapp|websockets:8.9.x`
  - `bitnamilegacy/keycloak`, `bitnamilegacy/postgresql:15.10.0-debian-12-r2`,
    `bitnamilegacy/elasticsearch:8.x`
  - your built `camunda-vault-agent:1.0.0`
  Set `camunda-platform.global.image.registry` (and per-image repos) to your mirror.

## 1. Build & push the agent image
```bash
cd deliverables/vault-sidecar
REGISTRY=icr.io/<your-namespace> ./build-and-push.sh 1.0.0
```
Then set the image in **two** places in `umbrella/values.yaml`:
- `vaultAgent.image`
- the literal `image:` inside the `_vaultAgentTemplates` anchors
(they must match; Helm cannot template values passed to a subchart).

## 2. Node prerequisite for Elasticsearch
The chart disables the privileged `sysctl` init container (policy-friendly), so set
`vm.max_map_count=262144` on worker nodes (IKS):
```bash
# Example DaemonSet or node bootstrap (run once per node pool)
sysctl -w vm.max_map_count=262144
```
On OpenShift, use a `MachineConfig` / `Tuned` profile to set the same.

## 3. Configure Vault
```bash
export VAULT_ADDR=https://<vault-host>:8200 VAULT_TOKEN=<admin-token>
cd deliverables/vault
K8S_NAMESPACE=camunda SA_NAME=camunda-vault-agent VAULT_ROLE=camunda ./setup-vault.sh
```
This enables KV v2, Kubernetes auth, writes the read-only `camunda` policy, binds a
role to the `camunda-vault-agent` ServiceAccount in `camunda`, and seeds random
passwords at `secret/camunda/*`.

> If Vault runs **outside** the cluster, pass `KUBERNETES_HOST`, `KUBERNETES_CA_CERT`
> and a `TOKEN_REVIEWER_JWT` (a long-lived SA token allowed to call TokenReview).

## 4. Resolve chart dependencies
```bash
cd deliverables/umbrella
helm dependency build .
```

## 5. Install

### IKS (vanilla) — signal restart (recommended, zero restart-RBAC)
```bash
helm install camunda . -n camunda --create-namespace \
  --post-renderer ./post-render/post-render.sh
```
The post-renderer injects `shareProcessNamespace: true` so the in-pod agent can
SIGTERM the JVM on rotation. (`kustomize` or `kubectl` must be on your PATH.)

### Without a post-renderer — rollout restart
1. In `values.yaml` set `vaultAgent.restart.mode: rollout`.
2. In `templates/vault-rbac.yaml` uncomment the scoped `apps` rule.
3. `helm install camunda . -n camunda --create-namespace`

### OpenShift specifics
- Allow the non-root UID and (only if you use **signal** mode) the shared process
  namespace. The `restricted-v2` SCC permits non-root + `RuntimeDefault` seccomp,
  which this chart already targets. Set
  `camunda-platform.global.compatibility.openshift.adaptSecurityContext=force`
  if you hit fsGroup/runAsUser SCC conflicts.
- `oc adm policy` is **not** required for the agent — it needs no extra SCC.

## 6. Verify
```bash
kubectl -n camunda get job camunda-vault-bootstrap            # Completed
kubectl -n camunda get secret camunda-credentials -o jsonpath='{.data}' | tr ',' '\n'
kubectl -n camunda get pods                                   # all Running/Ready
kubectl -n camunda logs <orchestration-pod> -c vault-agent    # watch loop
```

## 7. Access (through HAProxy — the single entry point)
HAProxy is the only external ingress. Get its address and point DNS at it:
```bash
kubectl -n camunda get svc camunda-haproxy -o wide   # EXTERNAL-IP (IKS LoadBalancer)
# DNS / /etc/hosts: <your-host> -> EXTERNAL-IP
#   http://<your-host>/operate   /tasklist   /identity   /optimize   /modeler   /console
# Zeebe gRPC clients -> <your-host>:26500
```
Replace the `camunda.example.com` placeholder everywhere first:
```bash
grep -rl camunda.example.com umbrella/values.yaml | xargs sed -i 's/camunda.example.com/<your-host>/g'
```
On OpenShift use `haproxy.service.type: ClusterIP` + an `oc create route`. See
**docs/HAPROXY.md** for the routing table and production TLS. (No chart Ingress is
used; `global.ingress.enabled` stays false.)

## 8. Rotating a password
```bash
vault kv put secret/camunda/elasticsearch password=<new> username=elastic
```
Within `INTERVAL_SECONDS` each module's `vault-agent` sidecar detects the change,
patches `camunda-credentials`, and restarts its module. (Also rotate the password
inside Elasticsearch/PostgreSQL itself per their procedures.)

## Troubleshooting
- **Pods stuck `CreateContainerConfigError` on `camunda-credentials`** → the
  bootstrap Job did not complete; check `kubectl -n camunda logs job/camunda-vault-bootstrap`
  (Vault address/role/policy, SA binding).
- **`vault login failed`** → role `bound_service_account_names`/`namespaces` must
  match `camunda-vault-agent` / `camunda`; check `auth/kubernetes/config` host & CA.
- **Signal mode not restarting** → confirm `shareProcessNamespace: true` is present
  (`kubectl get pod -o yaml | grep shareProcessNamespace`) and the agent runs as UID 1001.
