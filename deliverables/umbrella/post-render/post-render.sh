#!/usr/bin/env sh
# Helm post-renderer. Helm streams the fully rendered manifests on stdin; we
# capture them and run them through kustomize to inject shareProcessNamespace.
#
# Usage:
#   helm install camunda . -n camunda --post-renderer ./post-render/post-render.sh
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
cat > "$DIR/all.yaml"

if command -v kustomize >/dev/null 2>&1; then
  kustomize build "$DIR"
elif command -v kubectl >/dev/null 2>&1; then
  kubectl kustomize "$DIR"
else
  echo "post-render: neither 'kustomize' nor 'kubectl' found in PATH" >&2
  exit 1
fi
