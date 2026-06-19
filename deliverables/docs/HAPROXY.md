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
- HAProxy container binds **8080** (HTTP), **8443** (HTTPS), **26500** (gRPC), **9090** (monitoring), **8404** (stats/health) — all unprivileged, so it runs **non-root, read-only rootfs**.
- The Service maps external **80 → 8080**, **443 → 8443**, **26500 → 26500**, **9090 → 9090** (`haproxy.service.*` / `haproxy.monitoring.port`).
- `GET /healthz` on 8404 backs the readiness/liveness probes; `/stats` exposes the HAProxy stats page (cluster-internal).

## Monitoring / management endpoints (Spring Boot actuator)
Every Camunda app's management port is exposed through HAProxy on a **dedicated
monitoring port (9090)**, under a per-app path prefix that HAProxy strips before
forwarding, so the backend receives the native `/actuator/...` path.

| Monitoring URL (port 9090) | Backend Service | Mgmt port | Endpoints |
|---|---|---|---|
| `/orchestration/actuator/**` | `camunda-zeebe-gateway` | 9600 | health, prometheus |
| `/optimize/actuator/**` | `camunda-optimize` | 8092 | health, prometheus |
| `/identity/actuator/**` | `camunda-identity` | 82 | health, prometheus |
| `/console/actuator/**` | `camunda-console` | 9100 | health, prometheus |
| `/web-modeler/actuator/**` | `camunda-web-modeler-restapi` | 8091 | health, prometheus |
| `/connectors/actuator/**` | `camunda-connectors` | 8080 | health, prometheus |
| `/healthz` | HAProxy itself | — | 200 OK |

Examples:
```bash
curl http://<host>:9090/orchestration/actuator/health
curl http://<host>:9090/orchestration/actuator/prometheus
curl http://<host>:9090/optimize/actuator/prometheus
```

Prometheus scrape config (one job per app, since each has its own prefix):
```yaml
- job_name: camunda-orchestration
  metrics_path: /orchestration/actuator/prometheus
  static_configs: [{ targets: ["camunda-haproxy.camunda.svc:9090"] }]
- job_name: camunda-optimize
  metrics_path: /optimize/actuator/prometheus
  static_configs: [{ targets: ["camunda-haproxy.camunda.svc:9090"] }]
# ...identity, console, web-modeler, connectors likewise
```

```yaml
haproxy:
  monitoring:
    enabled: true
    port: 9090
    allowedCidrs: []      # e.g. ["10.0.0.0/8"] — restrict to Prometheus networks
```

> **SECURITY**: actuator endpoints can expose runtime/config details. Keep port
> 9090 internal: set `monitoring.allowedCidrs` (HAProxy `src` ACL denies all
> others) and/or a NetworkPolicy so only your Prometheus can reach it. Do **not**
> map 9090 on a public LoadBalancer.
>
> Alternative: if you run the **Prometheus Operator**, you can scrape the pods
> directly instead of via HAProxy by setting `camunda-platform.prometheusServiceMonitor.enabled=true`.


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
