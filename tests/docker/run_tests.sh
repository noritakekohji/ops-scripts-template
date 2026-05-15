#!/usr/bin/env bash
# ============================================================================
# run_tests.sh  -  Host-side runner: build images and run all test suites
#
# Usage:
#   bash run_tests.sh [options]
#
# Options:
#   --linux-only     Run Linux bash tests only
#   --ps-only        Run PowerShell tests only
#   --build          Force rebuild of both Docker images
#   --no-build       Skip image build (use existing images)
#   --shell-linux    Drop into Linux container shell (debug)
#   --shell-ps       Drop into PowerShell container shell (debug)
#
# Requires:
#   Docker Desktop running in Linux containers mode
# ============================================================================
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

LINUX_IMAGE="ops-test-linux:latest"
PS_IMAGE="ops-test-powershell:latest"

RUN_LINUX=1
RUN_PS=1
FORCE_BUILD=0
NO_BUILD=0
SHELL_LINUX=0
SHELL_PS=0

for arg in "$@"; do
    case "$arg" in
        --linux-only)  RUN_PS=0 ;;
        --ps-only)     RUN_LINUX=0 ;;
        --build)       FORCE_BUILD=1 ;;
        --no-build)    NO_BUILD=1 ;;
        --shell-linux) SHELL_LINUX=1 ;;
        --shell-ps)    SHELL_PS=1 ;;
        *) echo "Unknown option: $arg" >&2; exit 1 ;;
    esac
done

SEP="════════════════════════════════════════════════════════════"
echo ""
echo "$SEP"
echo "  Docker Test Runner"
echo "  Repo : $REPO_ROOT"
echo "$SEP"

# ---- Docker availability check ----------------------------------------------
if ! docker info > /dev/null 2>&1; then
    echo ""
    echo "ERROR: Docker is not running." >&2
    echo "  → Please start Docker Desktop (Linux containers mode) and try again." >&2
    exit 1
fi
echo "  Docker  : $(docker info --format '{{.ServerVersion}}') [$(docker info --format '{{.OSType}}') containers]"
echo ""

# ---- Image build helper -----------------------------------------------------
build_image() {
    local tag="$1" dockerfile="$2"
    if [[ "$NO_BUILD" -eq 1 ]]; then return; fi

    if [[ "$FORCE_BUILD" -eq 1 ]] || ! docker image inspect "$tag" > /dev/null 2>&1; then
        echo "  Building $tag from $dockerfile ..."
        docker build -t "$tag" -f "$SCRIPT_DIR/$dockerfile" "$SCRIPT_DIR"
        echo ""
    else
        echo "  Image $tag already exists (use --build to rebuild)"
    fi
}

# ---- Build images -----------------------------------------------------------
echo "── Building Docker images ──────────────────────────────────"
[[ "$RUN_LINUX" -eq 1 ]] && build_image "$LINUX_IMAGE" "Dockerfile.linux"
[[ "$RUN_PS"    -eq 1 ]] && build_image "$PS_IMAGE"    "Dockerfile.powershell"
echo ""

# ---- Common volume mounts ---------------------------------------------------
LINUX_RUN_ARGS=(
    --rm
    --cap-add=NET_RAW
    -v "${REPO_ROOT}:/repo:ro"
    -e TERM=xterm-256color
)
PS_RUN_ARGS=(
    --rm
    -v "${REPO_ROOT}:/repo:ro"
    -e TERM=xterm-256color
)

# ---- Shell modes (debug) ----------------------------------------------------
if [[ "$SHELL_LINUX" -eq 1 ]]; then
    echo "=== Linux container shell ==="
    echo "  Run tests: bash /repo/tests/docker/linux_tests.sh"
    echo ""
    docker run -it "${LINUX_RUN_ARGS[@]}" "$LINUX_IMAGE" bash
    exit 0
fi
if [[ "$SHELL_PS" -eq 1 ]]; then
    echo "=== PowerShell container shell ==="
    echo "  Run tests: pwsh /repo/tests/docker/powershell_tests.ps1"
    echo ""
    docker run -it "${PS_RUN_ARGS[@]}" "$PS_IMAGE" pwsh
    exit 0
fi

# ---- Run test suites --------------------------------------------------------
LINUX_EXIT=0
PS_EXIT=0
TS_TOTAL=$(date +%s)

if [[ "$RUN_LINUX" -eq 1 ]]; then
    echo "── Linux bash tests ────────────────────────────────────────"
    TS=$(date +%s)
    set +e
    docker run "${LINUX_RUN_ARGS[@]}" "$LINUX_IMAGE" \
        bash /repo/tests/docker/linux_tests.sh
    LINUX_EXIT=$?
    set -e
    echo "  ($(( $(date +%s) - TS ))s)"
    echo ""
fi

if [[ "$RUN_PS" -eq 1 ]]; then
    echo "── PowerShell tests ────────────────────────────────────────"
    TS=$(date +%s)
    set +e
    docker run "${PS_RUN_ARGS[@]}" "$PS_IMAGE" \
        pwsh -NonInteractive -File /repo/tests/docker/powershell_tests.ps1
    PS_EXIT=$?
    set -e
    echo "  ($(( $(date +%s) - TS ))s)"
    echo ""
fi

# ---- Final summary ----------------------------------------------------------
ELAPSED=$(( $(date +%s) - TS_TOTAL ))
echo "$SEP"
if [[ "$LINUX_EXIT" -eq 0 && "$PS_EXIT" -eq 0 ]]; then
    printf "\033[32m\033[1m  ✓ ALL SUITES PASSED\033[0m\n"
else
    printf "\033[31m\033[1m  ✗ SOME SUITES FAILED\033[0m\n"
    [[ "$LINUX_EXIT" -ne 0 ]] && echo "    Linux bash tests  : FAIL (exit $LINUX_EXIT)"
    [[ "$PS_EXIT"    -ne 0 ]] && echo "    PowerShell tests  : FAIL (exit $PS_EXIT)"
fi
echo "  Total time: ${ELAPSED}s"
echo "$SEP"
echo ""

exit $(( LINUX_EXIT + PS_EXIT > 0 ? 1 : 0 ))
