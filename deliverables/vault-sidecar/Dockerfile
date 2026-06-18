# =============================================================================
# camunda-vault-agent — shell + curl edition
# Minimal, auditable image for air-gapped / least-privilege clusters.
# =============================================================================
FROM alpine:3.20

# busybox already provides sh / base64 / cat / tr / date / grep.
# Add only curl (HTTP), jq (JSON), openssl (self-signed certs), ca-certificates.
RUN apk add --no-cache ca-certificates curl jq openssl \
 && rm -rf /var/cache/apk/*

COPY agent.sh /usr/local/bin/camunda-vault-agent
RUN chmod 0555 /usr/local/bin/camunda-vault-agent

# Run as a non-root, well-known UID (works with restricted PSS / OpenShift SCC).
USER 65532:65532

ENTRYPOINT ["/usr/local/bin/camunda-vault-agent"]
