# HAProxy — single entry point for Camunda 8.9

HAProxy is the one external ingress for the whole platform: it terminates TLS,
routes application traffic by URL path, proxies the Zeebe gRPC stream, and exposes
each app's Spring Boot management endpoints (health + Prometheus).

## Files
| File | What it is |
|---|---|
| `haproxy.cfg` | The plain, `haproxy -c`-validated config (release `camunda`). |
| `haproxy-standalone.yaml` | ConfigMap + Service + Deployment, ready to `kubectl apply`. |

> The umbrella Helm chart (`umbrella/templates/haproxy.yaml`) renders this **same**
> config automatically — you normally deploy via the chart. These files are a
> standalone copy for review or for running HAProxy outside the chart.

## Routing summary

**Application traffic — ports 80→8080 (HTTP) / 443→8443 (HTTPS, TLS):**

| Path | Backend Service:port |
|---|---|
| `/auth` | `camunda-keycloak:80` |
| `/identity` | `camunda-identity:80` |
| `/optimize` | `camunda-optimize:80` |
| `/modeler` | `camunda-web-modeler-restapi:80` |
| `/modeler-ws` (or `Upgrade: websocket`) | `camunda-web-modeler-websockets:80` |
| `/console` | `camunda-console:80` |
| `/connectors` | `camunda-connectors:8080` |
| `/` (default: Operate, Tasklist, REST v2) | `camunda-zeebe-gateway:8080` |
| gRPC `:26500` | `camunda-zeebe-gateway:26500` |

**Monitoring traffic — port 9090 (keep internal):**

| Path | Backend Service:port |
|---|---|
| `/orchestration/actuator/**` | `camunda-zeebe-gateway:9600` |
| `/optimize/actuator/**` | `camunda-optimize:8092` |
| `/identity/actuator/**` | `camunda-identity:82` |
| `/console/actuator/**` | `camunda-console:9100` |
| `/web-modeler/actuator/**` | `camunda-web-modeler-restapi:8091` |
| `/connectors/actuator/**` | `camunda-connectors:8080` |

## Apply standalone
```bash
# TLS secret must exist first (OpenShift service-ca serving cert OR your own):
#   the Service annotation service.beta.openshift.io/serving-cert-secret-name
#   creates camunda-haproxy-tls on OpenShift automatically.
kubectl apply -n camunda -f haproxy-standalone.yaml

# Regenerate the ConfigMap from the plain file instead, if you prefer:
kubectl -n camunda create configmap camunda-haproxy \
  --from-file=haproxy.cfg=haproxy.cfg --dry-run=client -o yaml | kubectl apply -f -
```

Before deploying: replace the image placeholder `icr.io/camunda-airgap/...` and,
if you renamed the Helm release, swap the `camunda-` Service prefixes.

See `../docs/HAPROXY.md` for TLS (service-ca), gRPC TLS notes, and the Prometheus
scrape config.
