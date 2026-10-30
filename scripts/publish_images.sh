#!/usr/bin/env bash
set -euo pipefail

# RackDoc Docker Image Publishing Script
#
# Builds the rackdoc-backend and rackdoc-frontend images and pushes them to
# Docker Hub under the `cloudresources` organization, tagged with the version
# in the root `VERSION` file and with `latest`.
#
#   docker login                    # once, with your Docker Hub account
#   ./scripts/publish_images.sh     # build and push both images
#
# Environment overrides:
#   RACKDOC_REGISTRY    Docker Hub namespace (default: cloudresources)
#   PLATFORMS           Target platforms (default: linux/amd64,linux/arm64)
#   NO_LATEST=1         Do not move the `latest` tag

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "${ROOT_DIR}/VERSION")"
REGISTRY="${RACKDOC_REGISTRY:-cloudresources}"
PLATFORMS="${PLATFORMS:-linux/amd64,linux/arm64}"
BUILDER="${BUILDX_BUILDER:-multiarch-builder}"

if ! [[ "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Invalid version in VERSION file: ${VERSION}" >&2
    exit 1
fi

if ! docker buildx inspect "${BUILDER}" >/dev/null 2>&1; then
    docker buildx create --name "${BUILDER}" --driver docker-container >/dev/null
fi

echo "=========================================="
echo "   RackDoc Image Publisher v${VERSION}"
echo "   Registry : docker.io/${REGISTRY}"
echo "   Platforms: ${PLATFORMS}"
echo "=========================================="

publish() {
    local name="$1" context="$2"
    local image="${REGISTRY}/${name}"
    local tags=(--tag "${image}:${VERSION}")
    [ "${NO_LATEST:-0}" = "1" ] || tags+=(--tag "${image}:latest")

    echo "--> Building and pushing ${image}:${VERSION}"
    docker buildx build \
        --builder "${BUILDER}" \
        --platform "${PLATFORMS}" \
        --label "org.opencontainers.image.title=${name}" \
        --label "org.opencontainers.image.version=${VERSION}" \
        --label "org.opencontainers.image.revision=$(git -C "${ROOT_DIR}" rev-parse HEAD)" \
        --label "org.opencontainers.image.source=https://github.com/mario-ezquerro/rackdoc" \
        "${tags[@]}" \
        --push \
        "${context}"
}

publish rackdoc-backend "${ROOT_DIR}/backend"
publish rackdoc-frontend "${ROOT_DIR}/frontend"

echo "=========================================="
echo "Published:"
echo "  ${REGISTRY}/rackdoc-backend:${VERSION}"
echo "  ${REGISTRY}/rackdoc-backend:latest"
echo "  ${REGISTRY}/rackdoc-frontend:${VERSION}"
echo "  ${REGISTRY}/rackdoc-frontend:latest"
echo "=========================================="
