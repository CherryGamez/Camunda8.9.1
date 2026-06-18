#!/usr/bin/env bash
# Build and push the camunda-vault-agent image to your (air-gapped) registry.
#
#   REGISTRY=icr.io/my-namespace ./build-and-push.sh 1.0.0
#
set -euo pipefail
REGISTRY="${REGISTRY:-icr.io/camunda-airgap}"
TAG="${1:-1.0.0}"
IMAGE="${REGISTRY}/camunda-vault-agent:${TAG}"
DIR="$(cd "$(dirname "$0")" && pwd)"

echo ">> Building ${IMAGE}"
# Use buildx for multi-arch (amd64 + the ppc64le/s390x options common on IBM Z/Power).
if docker buildx version >/dev/null 2>&1; then
  docker buildx build --platform "${PLATFORMS:-linux/amd64,linux/arm64}" \
    -t "${IMAGE}" --push "${DIR}"
else
  docker build -t "${IMAGE}" "${DIR}"
  docker push "${IMAGE}"
fi
echo ">> Pushed ${IMAGE}"
echo ">> Remember to set vaultAgent.image and the literal image: in values.yaml to ${IMAGE}"
