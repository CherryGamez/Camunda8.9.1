# Architecture

Camunda 8.9 Self-Managed on **OpenShift / ROKS (IBM Cloud)**, where every
PostgreSQL / Keycloak / Elasticsearch password is fetched from **HashiCorp Vault**
by a tiny shell+curl agent. Designed for **air-gapped, least-privilege** clusters
and deployed via **ArgoCD** (manifests rendered in GitLab CI).

## Components deployed (all enabled, talking to each other)

```
                       ┌─────────────────────────────────────────┐
                       │              Keycloak (OIDC)             │◄── admin-password
                       │      + embedded PostgreSQL (StatefulSet) │◄── admin/user-password
                       └───────────────▲─────────────────────────┘
                                       │ OIDC
        ┌──────────────┬───────────────┼───────────────┬──────────────┬───────────┐
   Orchestration   Management       Optimize        Connectors    Web Modeler   Console
   (Zeebe+Operate+ Identity                                       (+ PostgreSQL)
    Tasklist)      (Deployment)     (Deployment)    (Deployment)   (Deployments)  (Deployment)
   StatefulSet
   camunda-zeebe
        │                              │                              │
        └──────────────┬───────────────┴──────────────────────────────┘
                        │
               Elasticsearch (X-Pack security) — elastic / <vault password>
               StatefulSet camunda-elasticsearch-master
```

## Per-app secret model (Msg 309)

Each **app that consumes a Vault-sourced secret at runtime** gets full isolation.
The Vault sidecar runs in the **same pod as the main container and therefore uses
the same ServiceAccount** — the app's own (chart-owned) SA. We do **not** create a
separate SA for the agent; we attach a scoped Role + RoleBinding to the app SA and
bind the Vault auth role to it. Each app also has its own Vault policy and its own
Kubernetes Secret, and a watch sidecar that rollout-restarts **only that workload**.

| App | ServiceAccount (shared by main container + sidecar) | Vault role/policy (read) | Secret | Restarts (rollout) |
|---|---|---|---|---|
| Orchestration | `camunda-orchestration` | `camunda/elasticsearch` | `camunda-orchestration-secret` | `StatefulSet/camunda-zeebe` |
| Optimize | `camunda-optimize` | `camunda/elasticsearch` | `camunda-optimize-secret` | `Deployment/camunda-optimize` |
| Web Modeler | `camunda-web-modeler` | `camunda/postgres/webmodeler` | `camunda-web-modeler-db-secret` | `Deployment/camunda-web-modeler-restapi` |

The **bootstrap Job** has no app/main container, so it keeps its **own dedicated**
ServiceAccount `camunda-vault-bootstrap` (broad-read Vault role, may create/patch
all the named secrets, performs no restarts).

**Datastore secrets** (no sidecar) are seeded once by the bootstrap Job and
consumed natively via `existingSecret`:

| Secret | Consumed by |
|---|---|
| `camunda-elasticsearch-secret` | Elasticsearch StatefulSet |
| `camunda-keycloak-secret` | Keycloak (admin) |
| `camunda-keycloak-db-secret` | Keycloak PostgreSQL |
| `camunda-web-modeler-db-secret` | Web Modeler PostgreSQL (same secret the restapi sidecar maintains) |

**Identity / Connectors / Console get no sidecar** — they authenticate via
Keycloak (OIDC) and hold no Vault-sourced DB password, so attaching an agent
would add RBAC for no benefit. (To change this, add a `sidecar:` block under the
relevant entry in `vaultAgent.targets`.)

## Secret flow

```
HashiCorp Vault (KV v2)                         Kubernetes
  secret/camunda/elasticsearch ─┐
  secret/camunda/keycloak        │  bootstrap Job (broad-read role)
  secret/camunda/postgres/keycloak ─► creates ALL *-secret objects ──► datastores boot
  secret/camunda/postgres/webmodeler ┘

  secret/camunda/elasticsearch ──► orchestration sidecar (narrow role) ──► camunda-orchestration-secret ──► restart camunda-zeebe
  secret/camunda/elasticsearch ──► optimize sidecar     (narrow role) ──► camunda-optimize-secret      ──► restart camunda-optimize
  secret/camunda/postgres/webmodeler ► web-modeler sidecar (narrow role) ► camunda-web-modeler-db-secret ► restart restapi
```

1. **Bootstrap Job** (Helm `pre-install`/`pre-upgrade` hook) runs `agent fetch`
   once and seeds **every** secret before any datastore pod boots.
2. Each sidecar-enabled app pod gets a `vault-fetch` **init** (reconcile before
   start) + a `vault-agent` **watch** sidecar (reconcile on interval, then
   `rollout restart` its own workload on change).

## TLS trust — OpenShift service-ca (no `gencert`)

There is **no self-signed certificate generation**. Trust comes from the cluster:

- The chart creates an empty **`trusted-ca` ConfigMap** annotated
  `service.beta.openshift.io/inject-cabundle: "true"`. The OpenShift **service-ca
  operator** populates the `service-ca.crt` key.
- It is mounted into every agent container **and** every app container at
  `/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem`, so curl (→ Vault) and the
  JVM (→ Elasticsearch/Keycloak) trust in-cluster service-serving certificates.
- **HAProxy TLS** uses an OpenShift **service-serving-cert**: the HAProxy Service
  is annotated `service.beta.openshift.io/serving-cert-secret-name: camunda-haproxy-tls`
  and OpenShift mints that `kubernetes.io/tls` secret.

On vanilla Kubernetes set `vaultAgent.trustedCa.openshiftInject=false` and paste
your PEM into `vaultAgent.trustedCa.caBundle`; set `haproxy.tls.openshiftServiceCA=false`
and provide your own `kubernetes.io/tls` secret in `haproxy.tls.secretName`.

## Deployment — ArgoCD consumes the Helm chart directly (no post-render, no CI)

The Helm `--post-renderer` step is **gone**: per-app rollout restarts removed the
need to inject `shareProcessNamespace`, so nothing post-processes the output.

Point an **ArgoCD Application** straight at this chart (a `source.helm` source).
ArgoCD runs `helm template` itself and **natively converts Helm install hooks**
(`helm.sh/hook: pre-install,pre-upgrade` → ArgoCD `PreSync`, ordered by
`hook-weight` → sync-wave). So SA/RBAC/ConfigMaps/`trusted-ca` apply first, then
the **bootstrap Job** seeds all secrets, then the datastores/apps sync. No GitLab
CI rendering pipeline and no Helm post-renderer are required.

```yaml
# argocd Application (excerpt)
spec:
  source:
    repoURL: <your git repo with deliverables/umbrella>
    path: umbrella
    helm:
      valueFiles: [values.yaml]
  destination: { namespace: camunda, server: https://kubernetes.default.svc }
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true]
```

## Why this is least-privilege / air-gap friendly

- **No Vault Agent Injector** → no cluster-wide mutating webhook.
- **Vault Kubernetes auth**, **per-app role+policy** → each app's token can read
  only its own Vault paths; no static secrets in the cluster.
- **Per-app RBAC** = `create` secrets + `get/update/patch` on **its own** Secret +
  `get/patch` on **its own** workload. Nothing else, nothing cross-app.
- **Image** = alpine + curl/jq; runs **non-root**, `readOnlyRootFilesystem`,
  `allowPrivilegeEscalation:false`, all capabilities dropped, `RuntimeDefault` seccomp.
- Everything mirror-able into a private registry; no external pulls at runtime.

## NetworkPolicy and alternatives (for clusters without NetworkPolicy)

The chart ships **one egress NetworkPolicy** scoped to the **bootstrap Job** pod
(`vaultAgent.networkPolicy.enabled=true`): it allows only DNS + Vault (`vaultPort`)
+ the Kubernetes API server (`apiServerPort`). The per-app **sidecars share their
module's pod network**, so they cannot be isolated by a Job-scoped policy.

If your cluster **does not support `networking.k8s.io/v1` NetworkPolicy**, or you
need to constrain the sidecars too, use one of these instead:

- **OpenShift `EgressFirewall`** (per-namespace, OVN-Kubernetes): allow egress
  only to the Vault CIDR + API server, deny the rest. This is the recommended
  control on ROKS where the SDN supports it cluster-wide.
- **`EgressNetworkPolicy`** (older OpenShift SDN) — equivalent, namespace-scoped.
- **Egress gateway / proxy**: force all pod egress through a controlled HTTP(S)
  proxy (set `HTTPS_PROXY`) that only whitelists the Vault host; the agent's curl
  honors the proxy env vars.
- **Calico/Cilium GlobalNetworkPolicy** if a CNI with its own CRD is installed
  (these work even where stock `NetworkPolicy` enforcement is absent).
- **Service mesh (Istio/OSSM) `Sidecar` + `AuthorizationPolicy`**: restrict
  egress to the Vault ServiceEntry only.
- **No-policy fallback**: rely on Vault's own `bound_service_account_*` (a stolen
  token from another namespace can't authenticate) + per-app Vault policies (a
  compromised app token reads only its own paths). Set
  `vaultAgent.networkPolicy.enabled=false` and document the compensating control.

To also constrain the **app/sidecar** pods directly, add a module-level egress
NetworkPolicy keyed on the Camunda component labels (e.g.
`app.kubernetes.io/component: zeebe-broker`).

## Trade-offs / notes

- **Rotating a *datastore* password** (ES/Keycloak/Postgres) only re-seeds the
  secret on the next bootstrap run; those pods have no sidecar, so restart them
  (and rotate the password inside the engine) per the runbook. The **app** side
  (orchestration/optimize/web-modeler restapi) auto-reconciles + restarts.
- **Elasticsearch REST** is HTTP + basic-auth on the internal ClusterIP; transport
  TLS is auto-generated. For end-to-end REST TLS, enable
  `security.tls.restEncryption` and feed the orchestration/optimize truststore
  from the `trusted-ca` bundle.
- **service-ca injection race**: the bootstrap Job may start a moment before the
  service-ca operator populates `trusted-ca`; the Job's `backoffLimit` absorbs
  this (it retries and succeeds once the bundle is present).
