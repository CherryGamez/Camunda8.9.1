# HAProxy — single external entry point

All external traffic enters the platform through one HAProxy Service. HAProxy
routes by URL **path prefix** to the internal Camunda module ClusterIP services,
and proxies **Zeebe gRPC** in TCP mode. The modules talk to each other over
in-cluster DNS (unchanged); HAProxy is only the north-south edge.

## Routing table

| External path | Backend Service | Port | Module |
|---|---|---|---|
| `/auth/**` | `camunda-keycloak` | 80 | Keycloak (OIDC) |
| `/identity/**` | `camunda-identity` | 80 | Management Identity |
| `/optimize/**` | `camunda-optimize` | 80 | Optimize |
| `/modeler/**` | `camunda-web-modeler-restapi` | 80 | Web Modeler (REST/UI) |
| `/modeler-ws/**` + WS upgrades on `/modeler` | `camunda-web-modeler-websockets` | 80 | Web Modeler (collab) |
| `/console/**` | `camunda-console` | 80 | Console |
| `/connectors/**` | `camunda-connectors` | 8080 | Connectors |
| everything else (Operate, Tasklist, REST `/v2`, login) | `camunda-zeebe-gateway` | 8080 | Orchestration |
| gRPC `:26500` (TCP) | `camunda-zeebe-gateway` | 26500 | Zeebe gateway |

Each module is configured with the matching `contextPath` (e.g.
`identity.contextPath: /identity`) so it serves under that prefix and emits
correct links — HAProxy passes the full path through without rewriting.

## Ports
- HAProxy container binds **8080** (HTTP), **26500** (gRPC), **8404** (stats/health) — all unprivileged, so it runs **non-root, read-only rootfs**.
- The Service maps external **80 → 8080** and **26500 → 26500** (`haproxy.service.httpPort/grpcPort`).
- `GET /healthz` on 8404 backs the readiness/liveness probes; `/stats` exposes the HAProxy stats page (cluster-internal).

## Configuration (values)
```yaml
haproxy:
  enabled: true
  host: "camunda.example.com"      # must equal camunda-platform.global.host
  image: haproxytech/haproxy-alpine:3.0
  replicas: 2
  service:
    type: LoadBalancer             # IKS; use NodePort or ClusterIP+Route on OpenShift
    httpPort: 80
    grpcPort: 26500
```

## Set your hostname (one value, several places)
The external host appears in `haproxy.host`, `camunda-platform.global.host`,
`global.identity.auth.publicIssuerUrl`, and the per-module `redirectUrl`s. Replace
the placeholder consistently:
```bash
grep -rl camunda.example.com umbrella/values.yaml | \
  xargs sed -i 's/camunda.example.com/<your-host>/g'
```

## Access after install (IKS LoadBalancer)
```bash
kubectl -n camunda get svc camunda-haproxy -o wide      # EXTERNAL-IP
# Point your DNS (or /etc/hosts) <your-host> -> EXTERNAL-IP, then browse:
#   http://<your-host>/operate     http://<your-host>/tasklist
#   http://<your-host>/identity    http://<your-host>/optimize
#   http://<your-host>/modeler     http://<your-host>/console
# Zeebe clients: grpc -> <your-host>:26500 (plaintext)
```

## OpenShift
Set `haproxy.service.type: ClusterIP` and expose it with a Route:
```bash
oc -n camunda create route edge camunda --service=camunda-haproxy --port=http
```
(Or `passthrough`/`reencrypt` if you terminate TLS at HAProxy.)

## TLS (built-in, default ON — OpenShift service-serving-cert)
HAProxy terminates TLS on **:8443** (Service **443 → 8443**) and 301-redirects
HTTP → HTTPS. All external URLs in `values.yaml` are `https://`.

```yaml
haproxy:
  tls:
    enabled: true
    redirectHttp: true
    openshiftServiceCA: true        # annotate the Service so OpenShift mints the cert
    secretName: camunda-haproxy-tls # the kubernetes.io/tls secret HAProxy mounts
```

- **OpenShift / ROKS (default):** the HAProxy Service is annotated
  `service.beta.openshift.io/serving-cert-secret-name: camunda-haproxy-tls`; the
  OpenShift **service-ca operator** creates that `kubernetes.io/tls` secret. An
  init container assembles `/etc/haproxy/tls/tls.pem` (cert+key) from it. The cert
  is signed by the cluster service-ca (trusted in-cluster; expose externally via a
  Route with `reencrypt`, or front it with your own edge cert).
- **Vanilla Kubernetes:** set `openshiftServiceCA: false`, create your own
  `kubernetes.io/tls` Secret (CA / cert-manager) and set `secretName` to it.
- **Disable TLS:** `--set haproxy.tls.enabled=false` and switch the `https://`
  URLs in `values.yaml` back to `http://`.

> NOTE: there is no self-signed `gencert` fallback — the HAProxy pod waits for
> `secretName` to exist. On OpenShift the service-ca operator creates it within
> seconds of the Service being applied.

The HTTPS bind advertises `alpn h2,http/1.1`. Zeebe **gRPC stays plaintext** on
`:26500`; to secure it add a second `ssl` bind on the `zeebe_grpc` listener.

## Air-gap
Mirror `haproxytech/haproxy-alpine:3.0` into your registry and set `haproxy.image`.
