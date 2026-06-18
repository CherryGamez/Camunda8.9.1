# Architecture

## Components deployed (all enabled, talking to each other)

```
                       ┌─────────────────────────────────────────┐
                       │              Keycloak (OIDC)             │◄── identity-keycloak-admin-password
                       │      + embedded PostgreSQL (StatefulSet) │◄── identity-keycloak-postgresql-*-password
                       └───────────────▲─────────────────────────┘
                                       │ OIDC
        ┌──────────────┬───────────────┼───────────────┬──────────────┬───────────┐
        │              │               │               │              │           │
   Orchestration   Management       Optimize        Connectors    Web Modeler   Console
   (Zeebe broker/  Identity                                       (+ PostgreSQL)
   gateway +       (Deployment)                                    StatefulSet
   Operate +           │               │                              │
   Tasklist)           │               │                              │
   StatefulSet         │               │                              │
        │              │               │                              │
        └──────────────┴───────────────┴──────────────────────────────┘
                                   │
                          Elasticsearch (X-Pack security)
                          StatefulSet, elastic / <vault password>
```

- **Auth**: `global.security.authentication.method=oidc` + internal **Keycloak**.
  Operate/Tasklist/Optimize/Web Modeler/Console authenticate via Keycloak.
- **Secondary storage**: Orchestration + Optimize use the bundled **Elasticsearch**
  with X-Pack security; the `elastic` password comes from Vault.
- **Databases**: Keycloak's embedded PostgreSQL and Web Modeler's PostgreSQL;
  both passwords come from Vault.

## Secret flow (dynamic, from Vault)

```
HashiCorp Vault (KV v2)                      Kubernetes
  secret/camunda/elasticsearch  ─┐
  secret/camunda/keycloak        │  vault-agent     ┌────────────────────────┐
  secret/camunda/postgres/keycloak ─► (k8s auth,    │ Secret camunda-creds   │
  secret/camunda/postgres/webmodeler │  SA JWT) ───► │  elasticsearch-password│
                                  ┘                  │  identity-keycloak-*   │
                                                     │  web-modeler-*         │
                                                     └──────────▲─────────────┘
                                                                │ existingSecret
                       ES / Keycloak / PostgreSQL / Orchestration / Optimize / WebModeler
```

1. **Bootstrap Job** (Helm `pre-install`/`pre-upgrade` hook) runs `agent fetch`
   first, so `camunda-credentials` exists **before** any database pod boots.
2. Every Camunda **application** pod gets:
   - `vault-gencert` init → self-signed cert into a shared volume
   - `vault-fetch` init → re-reconciles `camunda-credentials` before the app starts
   - `vault-agent` sidecar → `watch`es Vault and restarts the module on rotation
3. The bundled **Elasticsearch / Keycloak / PostgreSQL** pods simply consume
   `camunda-credentials` via their native `existingSecret` settings (no sidecar
   needed; the bootstrap Job guarantees the secret is present).

## Why this is least-privilege / air-gap friendly

- **No Vault Agent Injector** → no cluster-wide mutating webhook, no broad RBAC.
- **Vault Kubernetes auth** → no static secrets in the cluster; tokens are short-lived.
- **Agent RBAC** = `create` on secrets + `get/update/patch` on the single
  `camunda-credentials` secret. Nothing else.
- **Restart via SIGNAL** (shared PID namespace) → **zero** RBAC for restarts.
- **Image** = alpine + curl/jq/openssl; runs **non-root (UID 1001)**,
  `readOnlyRootFilesystem`, `allowPrivilegeEscalation: false`, all capabilities dropped.
- Everything is mirror-able into a private registry; no external pulls at runtime.

## Trade-offs / notes

- **Signal restart** requires `shareProcessNamespace: true`, injected by the
  `post-render/` kustomize overlay because the upstream chart does not expose it.
  If you cannot use a post-renderer, switch `vaultAgent.restart.mode=rollout` and
  enable the scoped `apps` RBAC rule in `templates/vault-rbac.yaml`.
- **Elasticsearch REST** is HTTP + basic-auth (internal ClusterIP). Transport TLS
  is auto-generated. For end-to-end REST TLS, enable `security.tls.restEncryption`
  and feed the orchestration/optimize truststore (the `gencert` init container or
  a CA ConfigMap can provide the material).
- **Rotating a database's *stored* password** (vs. the client-side credential) is a
  separate operational procedure (change it in the DB engine too); this delivery
  rotates the credential the clients use and restarts the clients.
