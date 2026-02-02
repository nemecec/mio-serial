#!/usr/bin/env bash
#
# Run tests inside a Docker container with socat for virtual serial ports.
# Works on local machines and CI environments.
#
# Caching:
#   - Docker image with socat is built once and reused
#     (auto-rebuilds when Dockerfile.test changes via hash in image tag)
#   - Cargo registry and git checkouts are cached in a named volume
#   - Build artifacts are cached in target/docker/
#
# Usage:
#   ./scripts/test-in-docker.sh                    # Run all tests
#   ./scripts/test-in-docker.sh --release          # Run tests in release mode
#   ./scripts/test-in-docker.sh --rust-version=1.80  # Use specific Rust version
#   ./scripts/test-in-docker.sh -- --nocapture     # Pass args to cargo test
#   ./scripts/test-in-docker.sh --clean            # Remove all caches and start fresh
#
set -euo pipefail

RUST_VERSION="${RUST_VERSION:-1.78}"
CLEAN_CACHES=false
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Parse arguments
CARGO_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --)
            shift
            CARGO_ARGS+=("$@")
            break
            ;;
        --rust-version=*)
            RUST_VERSION="${1#*=}"
            shift
            ;;
        --rust-version)
            RUST_VERSION="$2"
            shift 2
            ;;
        --clean)
            CLEAN_CACHES=true
            shift
            ;;
        *)
            CARGO_ARGS+=("$1")
            shift
            ;;
    esac
done

DOCKERFILE="${SCRIPT_DIR}/Dockerfile.test"
DOCKERFILE_HASH=$(md5sum "$DOCKERFILE" 2>/dev/null | cut -d' ' -f1 || md5 -q "$DOCKERFILE")
IMAGE_NAME="mio-serial-test:rust-${RUST_VERSION}-${DOCKERFILE_HASH:0:8}"
CARGO_CACHE_VOLUME="mio-serial-cargo-cache-${RUST_VERSION}"

# Clean all caches if requested
if [[ "$CLEAN_CACHES" == true ]]; then
    echo "Cleaning all caches..."
    docker volume rm "$CARGO_CACHE_VOLUME" 2>/dev/null || true
    docker images --format '{{.Repository}}:{{.Tag}}' \
        | grep "^mio-serial-test:rust-${RUST_VERSION}-" \
        | xargs -r docker rmi 2>/dev/null || true
    rm -rf "${PROJECT_DIR}/target/docker"
    echo "Caches cleaned."
fi

# Build Docker image if it doesn't exist
# Image tag includes Dockerfile hash, so changes auto-invalidate cache
if ! docker image inspect "$IMAGE_NAME" &>/dev/null; then
    echo "Building Docker image ${IMAGE_NAME}..."
    docker build \
        --build-arg "RUST_VERSION=${RUST_VERSION}" \
        -t "$IMAGE_NAME" \
        -f "$DOCKERFILE" \
        "${SCRIPT_DIR}"

    # Clean up old images for this Rust version
    docker images --format '{{.Repository}}:{{.Tag}}' \
        | grep "^mio-serial-test:rust-${RUST_VERSION}-" \
        | grep -v "$IMAGE_NAME" \
        | xargs -r docker rmi 2>/dev/null || true
else
    echo "Using cached Docker image ${IMAGE_NAME}"
fi

echo "Project directory: ${PROJECT_DIR}"
if [[ ${#CARGO_ARGS[@]} -gt 0 ]]; then
    echo "Cargo test args: ${CARGO_ARGS[*]}"
fi

# Run tests in Docker with caching:
# - Named volume for cargo registry (fast dependency downloads)
# - Mounted target/docker for build artifacts (fast incremental builds)
docker run --rm \
    -v "${PROJECT_DIR}:/app" \
    -v "${PROJECT_DIR}/target/docker:/app/target" \
    -v "${CARGO_CACHE_VOLUME}:/usr/local/cargo/registry" \
    -w /app \
    "$IMAGE_NAME" \
    cargo test "${CARGO_ARGS[@]:-}"

echo "Tests completed successfully."
