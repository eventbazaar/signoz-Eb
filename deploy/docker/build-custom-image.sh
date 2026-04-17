#!/usr/bin/env bash
set -euo pipefail

# Build a custom SigNoz Docker image from the current source code.
# Run from the repo root: bash deploy/docker/build-custom-image.sh
#
# After building, update docker-compose.eventbazaar.yaml to use the custom image:
#   image: signoz-eb-custom:latest
# Then recreate:
#   docker compose -f docker-compose.eventbazaar.yaml --env-file .env.eventbazaar.local up -d --force-recreate signoz

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

IMAGE_NAME="${1:-signoz-eb-custom}"
IMAGE_TAG="${2:-latest}"
COMMIT_SHA="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
BRANCH_NAME="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
TIMESTAMP="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

# Detect architecture
ARCH="$(uname -m)"
case "$ARCH" in
    x86_64)  TARGETARCH="amd64" ;;
    aarch64|arm64) TARGETARCH="arm64" ;;
    *) echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac

echo "Building ${IMAGE_NAME}:${IMAGE_TAG} for ${TARGETARCH}..."
echo "  Commit: ${COMMIT_SHA}"
echo "  Branch: ${BRANCH_NAME}"

docker build \
    -t "${IMAGE_NAME}:${IMAGE_TAG}" \
    -f cmd/enterprise/Dockerfile.eventbazaar \
    --build-arg TARGETARCH="${TARGETARCH}" \
    --build-arg VERSION="${BRANCH_NAME}-${COMMIT_SHA}" \
    --build-arg COMMIT_SHA="${COMMIT_SHA}" \
    --build-arg TIMESTAMP="${TIMESTAMP}" \
    --build-arg BRANCH_NAME="${BRANCH_NAME}" \
    .

echo ""
echo "Done! Image built: ${IMAGE_NAME}:${IMAGE_TAG}"
echo ""
echo "Next steps:"
echo "  1. Update docker-compose.eventbazaar.yaml:"
echo "     Change: image: signoz/signoz:\${VERSION:-v0.118.0}"
echo "     To:     image: ${IMAGE_NAME}:${IMAGE_TAG}"
echo ""
echo "  2. Redeploy:"
echo "     cd deploy/docker"
echo "     docker compose -f docker-compose.eventbazaar.yaml --env-file .env.eventbazaar.local up -d --force-recreate signoz"
