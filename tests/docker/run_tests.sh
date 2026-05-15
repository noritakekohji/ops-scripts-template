#!/usr/bin/env bash
# ============================================================================
# run_tests.sh  -  Host-side runner: build Docker image and execute tests
#
# Usage:
#   ./run_tests.sh              # Build image (if needed) and run all tests
#   ./run_tests.sh --build      # Force rebuild of Docker image
#   ./run_tests.sh --no-build   # Skip build, use existing image
#   ./run_tests.sh --shell      # Drop into container shell for debugging
#
# Requirements:
#   Docker Desktop (Linux containers mode) must be running
# ============================================================================
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
IMAGE="ops-scripts-test:latest"
FORCE_BUILD=0
NO_BUILD=0
SHELL_MODE=0

for arg in "$@"; do
    case "$arg" in
        --build)    FORCE_BUILD=1 ;;
        --no-build) NO_BUILD=1 ;;
        --shell)    SHELL_MODE=1 ;;
        *) echo "Unknown option: $arg" >&2; exit 1 ;;
    esac
done

echo ""
echo "=== Docker Tool Test Runner ==="
echo "  Repo root : $REPO_ROOT"
echo "  Image     : $IMAGE"
echo ""

# ---- Docker check -----------------------------------------------------------
if ! docker info > /dev/null 2>&1; then
    echo "ERROR: Docker is not running." >&2
    echo "  Please start Docker Desktop (Linux containers mode) and try again." >&2
    exit 1
fi
echo "  Docker    : $(docker info --format '{{.ServerVersion}}' 2>/dev/null) [$(docker info --format '{{.OSType}}' 2>/dev/null) containers]"
echo ""

# ---- Build image ------------------------------------------------------------
BUILD_NEEDED=0
if [[ "$NO_BUILD" -eq 0 ]]; then
    if [[ "$FORCE_BUILD" -eq 1 ]]; then
        BUILD_NEEDED=1
    elif ! docker image inspect "$IMAGE" > /dev/null 2>&1; then
        echo "  Image '$IMAGE' not found — building..."
        BUILD_NEEDED=1
    fi
fi

if [[ "$BUILD_NEEDED" -eq 1 ]]; then
    echo "=== Building Docker image ==="
    docker build -t "$IMAGE" "$SCRIPT_DIR"
    echo ""
fi

# ---- Common docker run args -------------------------------------------------
DOCKER_ARGS=(
    --rm
    --cap-add=NET_RAW                         # for ping (ICMP)
    -v "${REPO_ROOT}/tools:/ops/tools:ro"     # mount tools (read-only)
    -v "${SCRIPT_DIR}:/ops/tests:ro"          # mount test scripts (read-only)
    -e TERM=xterm-256color
    "$IMAGE"
)

# ---- Shell mode (debug) -----------------------------------------------------
if [[ "$SHELL_MODE" -eq 1 ]]; then
    echo "=== Dropping into container shell ==="
    echo "  Tools mounted at: /ops/tools"
    echo "  Tests mounted at: /ops/tests"
    echo "  Run tests with:   bash /ops/tests/container_tests.sh"
    echo ""
    docker run -it "${DOCKER_ARGS[@]}" bash
    exit 0
fi

# ---- Run tests --------------------------------------------------------------
echo "=== Running tests in container ==="
echo ""

ts_start=$(date +%s)

set +e
docker run "${DOCKER_ARGS[@]}" bash /ops/tests/container_tests.sh
EXIT_CODE=$?
set -e

ts_end=$(date +%s)
elapsed=$((ts_end - ts_start))

echo ""
echo "=== Completed in ${elapsed}s (exit code: $EXIT_CODE) ==="

exit $EXIT_CODE
