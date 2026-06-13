# service-wait Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a "wait until healthy" ops script (`service-wait`) in Bash + PowerShell that polls Ping / TCP / HTTP targets defined in a `.lst` file, and exits 0 once N consecutive rounds all succeed, or 3 on timeout.

**Architecture:** Two implementations (Bash for Linux, PowerShell 5.1 for Windows) share the same conf file, list format, log format, and exit code semantics. Both delegate logging and config loading to the repo's common libs (`scripts_linux/lib/`, `scripts_windows/lib/`). A Windows `.bat` launcher invokes the `.ps1`.

**Tech Stack:** Bash 4+, PowerShell 5.1, bats-core, Pester 5, repo's `logging.sh` / `config.sh` / `Logging.psm1` / `Config.psm1`.

**Spec:** [docs/superpowers/specs/2026-06-14-service-wait-design.md](../specs/2026-06-14-service-wait-design.md)

---

## File Structure

| Path | Role |
|---|---|
| `config/default/service_wait.conf` | Default behavior parameters |
| `scripts_linux/os/service_wait.sh` | Bash implementation |
| `scripts_windows/os/ServiceWait.ps1` | PowerShell 5.1 implementation |
| `scripts_windows/os/service_wait.bat` | bat launcher wrapping the `.ps1` |
| `docs_linux/os/service_wait.md` | Linux-side reference doc |
| `docs_windows/os/ServiceWait.md` | Windows-side reference doc |
| `tests/bats/service_wait.bats` | bats unit tests |
| `tests/pester/ServiceWait.Tests.ps1` | Pester unit tests |
| `CHANGELOG.md` | Add `[Unreleased]` entry |

Sample fixture used by tests:

| Path | Role |
|---|---|
| `tests/bats/fixtures/service_wait/sample.lst` | sample targets for parser tests |
| `tests/pester/fixtures/service_wait/sample.lst` | same content for Pester |

---

## Task 1: Scaffold config file and changelog entry

**Files:**
- Create: `config/default/service_wait.conf`
- Modify: `CHANGELOG.md` — add Unreleased entry

- [ ] **Step 1: Create the default conf**

Create `config/default/service_wait.conf` (LF, no BOM):

```ini
# service-wait default behavior parameters
# Overridden per-environment by config/<env>/service_wait.conf.

# Initial wait (seconds) before the first round.
initial_wait_sec      = 0
# Sleep between rounds (seconds).
interval_sec          = 5
# Consecutive all-OK rounds required for success.
success_threshold     = 3
# Overall timeout (seconds). Exit 3 if exceeded.
timeout_sec           = 600
# Per-target check timeout (seconds). Overridable per target line.
per_check_timeout_sec = 5

# Log file (empty = console only). Path is created if needed.
LogFile               =
# DEBUG | INFO | WARN | ERROR
LogLevel              = INFO
```

- [ ] **Step 2: Add the changelog entry**

Open `CHANGELOG.md`. Under the `[Unreleased]` section (create one if missing, before the most recent released version), add:

```markdown
### Added
- `scripts_*/os/service-wait` ヘルスチェック待ちスクリプト。Ping / TCP / HTTP の連続成功でブロック解除、タイムアウト時 exit 3。
```

- [ ] **Step 3: Commit**

```bash
git add config/default/service_wait.conf CHANGELOG.md
git commit -m "feat(service-wait): add default conf and changelog entry"
```

---

## Task 2: Sample list fixture and parser test (Bash, failing)

**Files:**
- Create: `tests/bats/fixtures/service_wait/sample.lst`
- Create: `tests/bats/service_wait.bats`

- [ ] **Step 1: Create the sample list fixture**

```
# type, target, description [, key=value ...]
ping, 127.0.0.1,             loopback
tcp,  127.0.0.1:65535,       closed port (for timeout tests)
http, http://127.0.0.1/health, http health,   per_check_timeout_sec=2
# blank line below should be skipped

```

- [ ] **Step 2: Write the bats skeleton + parser tests**

Create `tests/bats/service_wait.bats`:

```bash
#!/usr/bin/env bats

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    SCRIPT="$REPO_ROOT/scripts_linux/os/service_wait.sh"
    FIXTURE_DIR="$BATS_TEST_DIRNAME/fixtures/service_wait"
    export OPS_LIB="$REPO_ROOT/scripts_linux/lib"
    export OPS_CONFIG_DIR="$REPO_ROOT/config"
    export TZ=Asia/Tokyo
}

@test "rejects missing target list argument" {
    run bash "$SCRIPT"
    [ "$status" -eq 1 ]
}

@test "rejects non-existent list file" {
    run bash "$SCRIPT" /does/not/exist.lst
    [ "$status" -eq 2 ]
}

@test "rejects list with unknown type" {
    tmp=$(mktemp)
    cat > "$tmp" <<EOF
foo, 127.0.0.1, bad type
EOF
    run bash "$SCRIPT" "$tmp"
    [ "$status" -eq 2 ]
    rm -f "$tmp"
}

@test "rejects list with unknown override key" {
    tmp=$(mktemp)
    cat > "$tmp" <<EOF
ping, 127.0.0.1, ok, success_threshold=99
EOF
    run bash "$SCRIPT" "$tmp"
    [ "$status" -eq 2 ]
    rm -f "$tmp"
}

@test "parses sample.lst and reports start (timeout 1s)" {
    # Force quick failure so test does not hang.
    export OPS_OVERRIDE_TIMEOUT_SEC=1
    export OPS_OVERRIDE_INITIAL_WAIT_SEC=0
    export OPS_OVERRIDE_INTERVAL_SEC=1
    run bash "$SCRIPT" "$FIXTURE_DIR/sample.lst"
    # 3 = timeout (expected since http://127.0.0.1/health is not up here)
    [ "$status" -eq 3 ]
    [[ "$output" == *"start targets=3"* ]]
}
```

- [ ] **Step 3: Run the tests to see they fail**

```bash
bash tests/run_unit.sh
```

Expected: bats fails because `scripts_linux/os/service_wait.sh` does not exist.

- [ ] **Step 4: Commit**

```bash
git add tests/bats/fixtures/service_wait/sample.lst tests/bats/service_wait.bats
git commit -m "test(service-wait): add bats skeleton and sample fixture"
```

---

## Task 3: Bash script Phase 1–3 (header, config, parser, validation)

**Files:**
- Create: `scripts_linux/os/service_wait.sh`

- [ ] **Step 1: Write the script header and lib resolution**

Create `scripts_linux/os/service_wait.sh` (UTF-8, **no BOM**, LF). Open with:

```bash
#!/usr/bin/env bash
# ============================================================================
# service_wait.sh
#   Wait until Ping/TCP/HTTP targets in a list file pass N consecutive rounds.
#   (Linux / Bash version)
#
# Usage:
#   service_wait.sh <targets-list-file>
#
# Targets list format (CSV, '#' = comment):
#   type, target, description [, key=value ...]
#     type   : ping | tcp | http
#     target : ping=host  tcp=host:port  http=url
#     overrides: per_check_timeout_sec=<int>
#
# Exit codes:
#   0  success (success_threshold consecutive rounds all OK)
#   1  bad usage / args
#   2  list parse error
#   3  overall timeout
#   10 missing prerequisite command
# ============================================================================
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

# --- lib resolution (mirrors rotate_log.sh) ---------------------------------
_ops_find_lib() {
    local d="$1"
    while [[ -n "$d" && "$d" != "/" ]]; do
        [[ -f "$d/lib/logging.sh" ]]       && { echo "$d/lib";       return 0; }
        [[ -f "$d/lib/linux/logging.sh" ]] && { echo "$d/lib/linux"; return 0; }
        [[ -f "$d/.ops-deploy-root" ]] && return 1
        d=$(dirname -- "$d")
    done
    return 1
}
if [[ -n "${OPS_LIB:-}" ]]; then
    _ops_lib="$OPS_LIB"
elif ! _ops_lib=$(_ops_find_lib "$SCRIPT_DIR"); then
    echo "[ERROR] lib/logging.sh not found from $SCRIPT_DIR (set OPS_LIB to override)" >&2
    exit 1
fi
# shellcheck source=/dev/null
source "$_ops_lib/logging.sh"
# shellcheck source=/dev/null
source "$_ops_lib/config.sh"

usage() { sed -n '2,21p' "$0" >&2; exit 1; }
```

- [ ] **Step 2: Add argument handling, config load, and trap**

Append:

```bash
status="unknown"
rounds=0
consec=0

cleanup() {
    local rc=$?
    if [[ "$status" == "unknown" && "$rc" -eq 0 ]]; then status="success"; fi
    local elapsed=$(( $(date +%s) - start_epoch ))
    log_info "[RESULT] status=$status rounds=$rounds elapsed=${elapsed}s consec=$consec"
}

[[ $# -lt 1 ]] && usage
list_file="$1"

start_epoch=$(date +%s)
trap cleanup EXIT

load_ops_config "service_wait"

initial_wait_sec="${OPS_CONFIG[initial_wait_sec]:-0}"
interval_sec="${OPS_CONFIG[interval_sec]:-5}"
success_threshold="${OPS_CONFIG[success_threshold]:-3}"
timeout_sec="${OPS_CONFIG[timeout_sec]:-600}"
default_per_check="${OPS_CONFIG[per_check_timeout_sec]:-5}"

# Test hooks: env vars can override conf for fast tests.
[[ -n "${OPS_OVERRIDE_INITIAL_WAIT_SEC:-}"  ]] && initial_wait_sec="$OPS_OVERRIDE_INITIAL_WAIT_SEC"
[[ -n "${OPS_OVERRIDE_INTERVAL_SEC:-}"      ]] && interval_sec="$OPS_OVERRIDE_INTERVAL_SEC"
[[ -n "${OPS_OVERRIDE_TIMEOUT_SEC:-}"       ]] && timeout_sec="$OPS_OVERRIDE_TIMEOUT_SEC"
[[ -n "${OPS_OVERRIDE_SUCCESS_THRESHOLD:-}" ]] && success_threshold="$OPS_OVERRIDE_SUCCESS_THRESHOLD"

# Optional file logging
if [[ -n "${OPS_CONFIG[LogFile]:-}" ]]; then
    set_ops_log_config "${OPS_CONFIG[LogFile]}" "${OPS_CONFIG[LogLevel]:-INFO}" || true
fi

for v in initial_wait_sec interval_sec success_threshold timeout_sec default_per_check; do
    val="${!v}"
    if ! [[ "$val" =~ ^[0-9]+$ ]]; then
        log_error "Config $v must be a non-negative integer, got '$val'"
        status="failed"; exit 1
    fi
done

if [[ ! -f "$list_file" ]]; then
    log_error "Target list file not found: $list_file"
    status="failed"; exit 2
fi
```

- [ ] **Step 3: Add list parser**

Append:

```bash
# Parsed targets stored as TAB-separated lines: type \t target \t desc \t per_check
targets_text=""

parse_list_line() {
    local lineno="$1" raw="$2"
    # Split on commas with surrounding whitespace.
    local IFS=','
    # shellcheck disable=SC2206
    local -a cols=( $raw )
    unset IFS
    # Trim each column.
    local i
    for ((i=0; i<${#cols[@]}; i++)); do
        cols[$i]="${cols[$i]#"${cols[$i]%%[![:space:]]*}"}"
        cols[$i]="${cols[$i]%"${cols[$i]##*[![:space:]]}"}"
    done
    if [[ "${#cols[@]}" -lt 3 ]]; then
        log_error "List parse error: line=$lineno reason=need_3_cols raw='$raw'"
        status="failed"; exit 2
    fi
    local p_type="${cols[0]}"
    local p_target="${cols[1]}"
    local p_desc="${cols[2]}"
    local p_per_check="$default_per_check"

    case "$p_type" in
        ping|tcp|http) ;;
        *)
            log_error "List parse error: line=$lineno reason=unknown_type type='$p_type'"
            status="failed"; exit 2 ;;
    esac

    if [[ "$p_type" == "tcp" && "$p_target" != *:* ]]; then
        log_error "List parse error: line=$lineno reason=tcp_needs_host_port target='$p_target'"
        status="failed"; exit 2
    fi
    if [[ "$p_type" == "http" && "$p_target" != http://* && "$p_target" != https://* ]]; then
        log_error "List parse error: line=$lineno reason=http_needs_url target='$p_target'"
        status="failed"; exit 2
    fi

    # Parse "key=value" tokens in column 4..end (space-separated within a single column).
    local extra=""
    if [[ "${#cols[@]}" -ge 4 ]]; then
        extra="${cols[3]}"
        # Append any further comma-split columns too, to be permissive.
        local j
        for ((j=4; j<${#cols[@]}; j++)); do extra="$extra ${cols[$j]}"; done
    fi
    if [[ -n "$extra" ]]; then
        # shellcheck disable=SC2206
        local -a kvs=( $extra )
        local kv key val
        for kv in "${kvs[@]}"; do
            if [[ ! "$kv" =~ ^([^=]+)=(.*)$ ]]; then
                log_error "List parse error: line=$lineno reason=bad_token token='$kv'"
                status="failed"; exit 2
            fi
            key="${BASH_REMATCH[1]}"
            val="${BASH_REMATCH[2]}"
            case "$key" in
                per_check_timeout_sec)
                    if ! [[ "$val" =~ ^[0-9]+$ ]]; then
                        log_error "List parse error: line=$lineno reason=bad_per_check value='$val'"
                        status="failed"; exit 2
                    fi
                    p_per_check="$val" ;;
                *)
                    log_error "List parse error: line=$lineno reason=unknown_key key='$key'"
                    status="failed"; exit 2 ;;
            esac
        done
    fi

    targets_text+="${p_type}"$'\t'"${p_target}"$'\t'"${p_desc}"$'\t'"${p_per_check}"$'\n'
}

lineno=0
while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno+1))
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" ]] && continue
    [[ "$line" == \#* ]] && continue
    parse_list_line "$lineno" "$line"
done < "$list_file"

target_count=$(printf '%s' "$targets_text" | grep -c '^' || true)
if [[ "$target_count" -eq 0 ]]; then
    log_error "Target list is empty: $list_file"
    status="failed"; exit 2
fi
```

- [ ] **Step 4: Add prerequisite command checks**

Append:

```bash
needs_ping=0; needs_http=0
while IFS=$'\t' read -r t_type _ _ _; do
    [[ -z "$t_type" ]] && continue
    [[ "$t_type" == "ping" ]] && needs_ping=1
    [[ "$t_type" == "http" ]] && needs_http=1
done <<< "$targets_text"

if [[ "$needs_ping" -eq 1 ]] && ! command -v ping >/dev/null 2>&1; then
    log_error "Prerequisite missing: ping"
    status="failed"; exit 10
fi
if [[ "$needs_http" -eq 1 ]] && ! command -v curl >/dev/null 2>&1; then
    log_error "Prerequisite missing: curl"
    status="failed"; exit 10
fi

log_info "start targets=$target_count timeout=$timeout_sec success=$success_threshold interval=$interval_sec initial=$initial_wait_sec"
```

- [ ] **Step 5: Add a minimal Phase 4 stub to allow parser tests to run**

Append (will be replaced in Task 5):

```bash
# Temporary: succeed immediately if timeout is 0, otherwise time out.
sleep "$initial_wait_sec"
deadline=$(( start_epoch + timeout_sec ))
while [[ $(date +%s) -lt $deadline ]]; do
    rounds=$((rounds+1))
    log_info "[ROUND $rounds] stub (not implemented)"
    sleep "$interval_sec"
done
status="timeout"
exit 3
```

- [ ] **Step 6: Make executable and run parser tests**

```bash
chmod +x scripts_linux/os/service_wait.sh
bash tests/run_unit.sh
```

Expected: parser tests pass; the "timeout 1s" test exits 3 as expected.

- [ ] **Step 7: Commit**

```bash
git add scripts_linux/os/service_wait.sh
git commit -m "feat(service-wait): bash phase 1-3 (parsing, validation)"
```

---

## Task 4: Bash check functions (ping / tcp / http) + tests

**Files:**
- Modify: `scripts_linux/os/service_wait.sh`
- Modify: `tests/bats/service_wait.bats`

- [ ] **Step 1: Add failing tests for each check type**

Append to `tests/bats/service_wait.bats`:

```bash
@test "tcp check succeeds against bash's own bound port" {
    # Listen on an ephemeral port using bash's coproc.
    port=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
    nc -l 127.0.0.1 "$port" >/dev/null 2>&1 &
    nc_pid=$!
    sleep 0.2
    tmp=$(mktemp)
    cat > "$tmp" <<EOF
tcp, 127.0.0.1:${port}, listener
EOF
    export OPS_OVERRIDE_INITIAL_WAIT_SEC=0
    export OPS_OVERRIDE_INTERVAL_SEC=1
    export OPS_OVERRIDE_TIMEOUT_SEC=5
    export OPS_OVERRIDE_SUCCESS_THRESHOLD=1
    run bash "$SCRIPT" "$tmp"
    kill "$nc_pid" 2>/dev/null || true
    rm -f "$tmp"
    [ "$status" -eq 0 ]
}

@test "tcp check fails on closed port and times out" {
    tmp=$(mktemp)
    cat > "$tmp" <<EOF
tcp, 127.0.0.1:1, closed
EOF
    export OPS_OVERRIDE_INITIAL_WAIT_SEC=0
    export OPS_OVERRIDE_INTERVAL_SEC=1
    export OPS_OVERRIDE_TIMEOUT_SEC=2
    export OPS_OVERRIDE_SUCCESS_THRESHOLD=1
    run bash "$SCRIPT" "$tmp"
    rm -f "$tmp"
    [ "$status" -eq 3 ]
}
```

- [ ] **Step 2: Implement check functions in the script**

Open `scripts_linux/os/service_wait.sh`. **Delete the Phase 4 stub** added in Task 3 Step 5 (the block from `sleep "$initial_wait_sec"` through `exit 3`). Insert above where the stub was:

```bash
check_ping() {
    local host="$1" to="$2"
    # ping -W is seconds on Linux. macOS differs but we target Linux here.
    ping -c 1 -W "$to" -- "$host" >/dev/null 2>&1
}

check_tcp() {
    local target="$1" to="$2"
    local host="${target%:*}" port="${target##*:}"
    # /dev/tcp + timeout(1). Use a subshell so the redirect failure is caught.
    timeout "$to" bash -c "exec 3<>/dev/tcp/$host/$port" >/dev/null 2>&1
}

check_http() {
    local url="$1" to="$2"
    local code
    code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time "$to" -- "$url" 2>/dev/null || echo "000")
    [[ "$code" =~ ^2[0-9][0-9]$ ]]
}

run_check() {
    local type="$1" target="$2" to="$3"
    case "$type" in
        ping) check_ping "$target" "$to" ;;
        tcp)  check_tcp  "$target" "$to" ;;
        http) check_http "$target" "$to" ;;
        *) return 1 ;;
    esac
}
```

- [ ] **Step 3: Verify (will be replaced when round loop lands)**

Skip running tests; Task 5 wires checks into a real loop and tests will pass then. Move on.

- [ ] **Step 4: Commit**

```bash
git add scripts_linux/os/service_wait.sh tests/bats/service_wait.bats
git commit -m "feat(service-wait): bash check functions for ping/tcp/http"
```

---

## Task 5: Bash round loop (Phase 4) + ensure tests pass

**Files:**
- Modify: `scripts_linux/os/service_wait.sh`

- [ ] **Step 1: Replace the stub with the real round loop**

The Phase 4 stub was deleted in Task 4 Step 2. Append the real loop where the stub used to live (after `run_check` is defined and after the `log_info "start ..."` line):

```bash
sleep "$initial_wait_sec"
deadline=$(( start_epoch + timeout_sec ))

while [[ $(date +%s) -lt $deadline ]]; do
    rounds=$((rounds+1))
    round_ok=1
    while IFS=$'\t' read -r t_type t_target t_desc t_per_check; do
        [[ -z "$t_type" ]] && continue
        if run_check "$t_type" "$t_target" "$t_per_check"; then
            log_info "[ROUND $rounds] $t_type $t_target -> OK (desc=$t_desc)"
        else
            log_warn "[ROUND $rounds] $t_type $t_target -> NG (desc=$t_desc)"
            round_ok=0
        fi
    done <<< "$targets_text"

    if [[ "$round_ok" -eq 1 ]]; then
        consec=$((consec+1))
    else
        consec=0
    fi

    if [[ "$round_ok" -eq 1 ]]; then
        log_info "[ROUND $rounds] PASS consec=$consec/$success_threshold"
    else
        log_info "[ROUND $rounds] FAIL consec=$consec/$success_threshold"
    fi

    if [[ "$consec" -ge "$success_threshold" ]]; then
        status="success"
        exit 0
    fi

    # Sleep, but don't oversleep the deadline.
    now=$(date +%s)
    remain=$(( deadline - now ))
    if [[ "$remain" -le 0 ]]; then break; fi
    sleep_n="$interval_sec"
    [[ "$sleep_n" -gt "$remain" ]] && sleep_n="$remain"
    sleep "$sleep_n"
done

status="timeout"
exit 3
```

- [ ] **Step 2: Run all bats tests**

```bash
bash tests/run_unit.sh
```

Expected: all `@test` cases pass.

- [ ] **Step 3: Run template-check**

```bash
bash ci/template-check/check_template.sh
```

Expected: passes.

- [ ] **Step 4: Commit**

```bash
git add scripts_linux/os/service_wait.sh
git commit -m "feat(service-wait): bash round loop with success/timeout semantics"
```

---

## Task 6: Pester fixture and failing tests

**Files:**
- Create: `tests/pester/fixtures/service_wait/sample.lst`
- Create: `tests/pester/ServiceWait.Tests.ps1`

- [ ] **Step 1: Copy the sample list**

Create `tests/pester/fixtures/service_wait/sample.lst` with the same content as the bats fixture from Task 2 Step 1.

- [ ] **Step 2: Create the Pester test file**

Create `tests/pester/ServiceWait.Tests.ps1` (UTF-8 BOM):

```powershell
#Requires -Version 5.1
Set-StrictMode -Version Latest

BeforeAll {
    $script:RepoRoot   = (Resolve-Path "$PSScriptRoot\..\..").Path
    $script:Script     = Join-Path $RepoRoot 'scripts_windows\os\ServiceWait.ps1'
    $script:Fixture    = Join-Path $PSScriptRoot 'fixtures\service_wait\sample.lst'
    $env:OPS_LIB        = Join-Path $RepoRoot 'scripts_windows\lib'
    $env:OPS_CONFIG_DIR = Join-Path $RepoRoot 'config'
}

function Invoke-SW {
    param([string[]]$Args)
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:Script @Args 2>&1
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($out -join "`n") }
}

Describe 'ServiceWait.ps1 argument and list parsing' {
    It 'fails with exit 1 when no list given' {
        $r = Invoke-SW @()
        $r.ExitCode | Should -Be 1
    }
    It 'fails with exit 2 when list file does not exist' {
        $r = Invoke-SW @('-TargetList', 'C:\does\not\exist.lst')
        $r.ExitCode | Should -Be 2
    }
    It 'fails with exit 2 on unknown type' {
        $tmp = [IO.Path]::GetTempFileName()
        'foo, 127.0.0.1, bad type' | Set-Content -Path $tmp -Encoding ASCII
        $r = Invoke-SW @('-TargetList', $tmp)
        Remove-Item $tmp -Force
        $r.ExitCode | Should -Be 2
    }
    It 'fails with exit 2 on unknown override key' {
        $tmp = [IO.Path]::GetTempFileName()
        'ping, 127.0.0.1, desc, success_threshold=99' | Set-Content -Path $tmp -Encoding ASCII
        $r = Invoke-SW @('-TargetList', $tmp)
        Remove-Item $tmp -Force
        $r.ExitCode | Should -Be 2
    }
    It 'reports start line and times out (exit 3) on closed targets' {
        $env:OPS_OVERRIDE_TIMEOUT_SEC       = '1'
        $env:OPS_OVERRIDE_INITIAL_WAIT_SEC  = '0'
        $env:OPS_OVERRIDE_INTERVAL_SEC      = '1'
        $r = Invoke-SW @('-TargetList', $script:Fixture)
        $env:OPS_OVERRIDE_TIMEOUT_SEC       = $null
        $env:OPS_OVERRIDE_INITIAL_WAIT_SEC  = $null
        $env:OPS_OVERRIDE_INTERVAL_SEC      = $null
        $r.ExitCode | Should -Be 3
        $r.Output   | Should -Match 'start targets=3'
    }
}
```

- [ ] **Step 3: Run Pester (should fail because script missing)**

```powershell
pwsh -File tests/run_unit.ps1
```

Expected: tests error out because `ServiceWait.ps1` does not exist.

- [ ] **Step 4: Commit**

```bash
git add tests/pester/fixtures/service_wait/sample.lst tests/pester/ServiceWait.Tests.ps1
git commit -m "test(service-wait): add pester skeleton and sample fixture"
```

---

## Task 7: PowerShell script Phase 1–3 (header, config, parser)

**Files:**
- Create: `scripts_windows/os/ServiceWait.ps1`

- [ ] **Step 1: Create the script with UTF-8 BOM**

Create `scripts_windows/os/ServiceWait.ps1` (UTF-8 **with BOM**, CRLF or LF — both acceptable, repo uses LF for `.ps1`):

```powershell
#Requires -Version 5.1
<#
.SYNOPSIS
    Wait until Ping/TCP/HTTP targets in a list pass N consecutive rounds.

.PARAMETER TargetList
    Path to the targets list file (CSV, '#' = comment).

.NOTES
    Exit codes: 0 success, 1 usage, 2 list parse error, 3 timeout, 10 prereq missing.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$TargetList
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:Status  = 'unknown'
$script:Rounds  = 0
$script:Consec  = 0
$script:Start   = Get-Date

# --- lib resolution -----------------------------------------------------------
function Resolve-OpsLib {
    param([string]$From)
    $d = $From
    while ($d -and (Split-Path $d -Parent)) {
        $candidate = Join-Path $d 'lib\Logging.psm1'
        if (Test-Path $candidate) { return (Join-Path $d 'lib') }
        $candidate = Join-Path $d 'lib\windows\Logging.psm1'
        if (Test-Path $candidate) { return (Join-Path $d 'lib\windows') }
        if (Test-Path (Join-Path $d '.ops-deploy-root')) { return $null }
        $parent = Split-Path $d -Parent
        if ($parent -eq $d) { return $null }
        $d = $parent
    }
    return $null
}

$opsLib = if ($env:OPS_LIB) { $env:OPS_LIB } else { Resolve-OpsLib -From $PSScriptRoot }
if (-not $opsLib) {
    Write-Error '[ERROR] lib/Logging.psm1 not found (set OPS_LIB to override)'
    exit 1
}
Import-Module (Join-Path $opsLib 'Logging.psm1') -Force
Import-Module (Join-Path $opsLib 'Config.psm1')  -Force
```

- [ ] **Step 2: Argument validation, config load, cleanup trap**

Append:

```powershell
function Emit-Result {
    $elapsed = [int]((Get-Date) - $script:Start).TotalSeconds
    Write-OpsLog -Level INFO -Message ("[RESULT] status={0} rounds={1} elapsed={2}s consec={3}" -f `
        $script:Status, $script:Rounds, $elapsed, $script:Consec)
}

if (-not $TargetList) {
    Write-Error 'Usage: ServiceWait.ps1 -TargetList <path>'
    exit 1
}

$cfg = Get-OpsConfig -Name 'service_wait'

$initialWait = [int]($cfg['initial_wait_sec']      | ForEach-Object { if ($_) { $_ } else { 0 } })
$interval    = [int]($cfg['interval_sec']          | ForEach-Object { if ($_) { $_ } else { 5 } })
$successN    = [int]($cfg['success_threshold']     | ForEach-Object { if ($_) { $_ } else { 3 } })
$timeoutSec  = [int]($cfg['timeout_sec']           | ForEach-Object { if ($_) { $_ } else { 600 } })
$defaultPerCheck = [int]($cfg['per_check_timeout_sec'] | ForEach-Object { if ($_) { $_ } else { 5 } })

# Test hooks
if ($env:OPS_OVERRIDE_INITIAL_WAIT_SEC)  { $initialWait = [int]$env:OPS_OVERRIDE_INITIAL_WAIT_SEC }
if ($env:OPS_OVERRIDE_INTERVAL_SEC)      { $interval    = [int]$env:OPS_OVERRIDE_INTERVAL_SEC }
if ($env:OPS_OVERRIDE_TIMEOUT_SEC)       { $timeoutSec  = [int]$env:OPS_OVERRIDE_TIMEOUT_SEC }
if ($env:OPS_OVERRIDE_SUCCESS_THRESHOLD) { $successN    = [int]$env:OPS_OVERRIDE_SUCCESS_THRESHOLD }

if ($cfg['LogFile']) {
    try { Set-OpsLogConfig -File $cfg['LogFile'] -Level ($cfg['LogLevel'] | ForEach-Object { if ($_) { $_ } else { 'INFO' } }) } catch { }
}

if (-not (Test-Path -LiteralPath $TargetList -PathType Leaf)) {
    Write-OpsLog -Level ERROR -Message "Target list file not found: $TargetList"
    $script:Status = 'failed'; Emit-Result; exit 2
}
```

- [ ] **Step 3: List parser**

Append:

```powershell
$targets = New-Object System.Collections.Generic.List[hashtable]
$lineno  = 0
foreach ($raw in (Get-Content -LiteralPath $TargetList)) {
    $lineno++
    $line = $raw.Trim()
    if (-not $line)            { continue }
    if ($line.StartsWith('#')) { continue }
    $cols = $line -split ',' | ForEach-Object { $_.Trim() }
    if ($cols.Count -lt 3) {
        Write-OpsLog -Level ERROR -Message "List parse error: line=$lineno reason=need_3_cols raw='$line'"
        $script:Status = 'failed'; Emit-Result; exit 2
    }
    $t = @{ type = $cols[0]; target = $cols[1]; desc = $cols[2]; per_check = $defaultPerCheck }

    if ($t.type -notin @('ping','tcp','http')) {
        Write-OpsLog -Level ERROR -Message "List parse error: line=$lineno reason=unknown_type type='$($t.type)'"
        $script:Status = 'failed'; Emit-Result; exit 2
    }
    if ($t.type -eq 'tcp' -and $t.target -notmatch ':\d+$') {
        Write-OpsLog -Level ERROR -Message "List parse error: line=$lineno reason=tcp_needs_host_port target='$($t.target)'"
        $script:Status = 'failed'; Emit-Result; exit 2
    }
    if ($t.type -eq 'http' -and $t.target -notmatch '^(http|https)://') {
        Write-OpsLog -Level ERROR -Message "List parse error: line=$lineno reason=http_needs_url target='$($t.target)'"
        $script:Status = 'failed'; Emit-Result; exit 2
    }

    # Columns 4..end may carry key=value tokens (space-separated within a column).
    if ($cols.Count -ge 4) {
        $extra = ($cols[3..($cols.Count - 1)] -join ' ').Trim()
        foreach ($kv in ($extra -split '\s+' | Where-Object { $_ })) {
            $m = [regex]::Match($kv, '^([^=]+)=(.*)$')
            if (-not $m.Success) {
                Write-OpsLog -Level ERROR -Message "List parse error: line=$lineno reason=bad_token token='$kv'"
                $script:Status = 'failed'; Emit-Result; exit 2
            }
            $key = $m.Groups[1].Value
            $val = $m.Groups[2].Value
            switch ($key) {
                'per_check_timeout_sec' {
                    if ($val -notmatch '^\d+$') {
                        Write-OpsLog -Level ERROR -Message "List parse error: line=$lineno reason=bad_per_check value='$val'"
                        $script:Status = 'failed'; Emit-Result; exit 2
                    }
                    $t.per_check = [int]$val
                }
                default {
                    Write-OpsLog -Level ERROR -Message "List parse error: line=$lineno reason=unknown_key key='$key'"
                    $script:Status = 'failed'; Emit-Result; exit 2
                }
            }
        }
    }
    $targets.Add($t) | Out-Null
}

if ($targets.Count -eq 0) {
    Write-OpsLog -Level ERROR -Message "Target list is empty: $TargetList"
    $script:Status = 'failed'; Emit-Result; exit 2
}

Write-OpsLog -Level INFO -Message ("start targets={0} timeout={1} success={2} interval={3} initial={4}" -f `
    $targets.Count, $timeoutSec, $successN, $interval, $initialWait)
```

- [ ] **Step 4: Add a temporary loop stub so parser tests can run**

Append (will be replaced in Task 9):

```powershell
Start-Sleep -Seconds $initialWait
$deadline = $script:Start.AddSeconds($timeoutSec)
while ((Get-Date) -lt $deadline) {
    $script:Rounds++
    Write-OpsLog -Level INFO -Message "[ROUND $($script:Rounds)] stub (not implemented)"
    Start-Sleep -Seconds $interval
}
$script:Status = 'timeout'
Emit-Result
exit 3
```

- [ ] **Step 5: Run Pester parser tests**

```powershell
pwsh -File tests/run_unit.ps1
```

Expected: argument / parser tests pass; the timeout test exits 3 as expected.

- [ ] **Step 6: Verify encoding**

```bash
file scripts_windows/os/ServiceWait.ps1
```

Expected output contains "UTF-8 (with BOM)".

- [ ] **Step 7: Commit**

```bash
git add scripts_windows/os/ServiceWait.ps1
git commit -m "feat(service-wait): powershell phase 1-3 (parsing, validation)"
```

---

## Task 8: PowerShell check functions (Ping / TCP / HTTP)

**Files:**
- Modify: `scripts_windows/os/ServiceWait.ps1`

- [ ] **Step 1: Insert check functions before the stub loop**

Open `ServiceWait.ps1`. **Delete the stub loop block** added in Task 7 Step 4 (from `Start-Sleep -Seconds $initialWait` through `exit 3`). Insert above the deleted location:

```powershell
function Test-PingHost {
    param([string]$Host, [int]$TimeoutSec)
    try {
        $p = New-Object System.Net.NetworkInformation.Ping
        $r = $p.Send($Host, ($TimeoutSec * 1000))
        return $r.Status -eq 'Success'
    } catch {
        return $false
    }
}

function Test-TcpEndpoint {
    param([string]$Target, [int]$TimeoutSec)
    $hostName, $port = $Target -split ':', 2
    $client = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $task   = $client.ConnectAsync($hostName, [int]$port)
        if ($task.Wait([TimeSpan]::FromSeconds($TimeoutSec))) {
            return $client.Connected
        }
        return $false
    } catch {
        return $false
    } finally {
        if ($client) { $client.Close() }
    }
}

function Test-HttpUrl {
    param([string]$Url, [int]$TimeoutSec)
    try {
        $resp = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec $TimeoutSec -ErrorAction Stop
        return ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 300)
    } catch {
        return $false
    }
}

function Invoke-Check {
    param([hashtable]$T)
    switch ($T.type) {
        'ping' { return (Test-PingHost     -Host  $T.target -TimeoutSec $T.per_check) }
        'tcp'  { return (Test-TcpEndpoint  -Target $T.target -TimeoutSec $T.per_check) }
        'http' { return (Test-HttpUrl      -Url   $T.target -TimeoutSec $T.per_check) }
        default { return $false }
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add scripts_windows/os/ServiceWait.ps1
git commit -m "feat(service-wait): powershell check functions for ping/tcp/http"
```

---

## Task 9: PowerShell round loop + Pester tests pass

**Files:**
- Modify: `scripts_windows/os/ServiceWait.ps1`
- Modify: `tests/pester/ServiceWait.Tests.ps1`

- [ ] **Step 1: Add the real round loop**

Append to `ServiceWait.ps1` (after `Invoke-Check` is defined):

```powershell
Start-Sleep -Seconds $initialWait
$deadline = $script:Start.AddSeconds($timeoutSec)

try {
    while ((Get-Date) -lt $deadline) {
        $script:Rounds++
        $roundOk = $true
        foreach ($t in $targets) {
            if (Invoke-Check -T $t) {
                Write-OpsLog -Level INFO -Message ("[ROUND {0}] {1} {2} -> OK (desc={3})" -f $script:Rounds, $t.type, $t.target, $t.desc)
            } else {
                Write-OpsLog -Level WARN -Message ("[ROUND {0}] {1} {2} -> NG (desc={3})" -f $script:Rounds, $t.type, $t.target, $t.desc)
                $roundOk = $false
            }
        }

        if ($roundOk) { $script:Consec++ } else { $script:Consec = 0 }
        $verdict = if ($roundOk) { 'PASS' } else { 'FAIL' }
        Write-OpsLog -Level INFO -Message ("[ROUND {0}] {1} consec={2}/{3}" -f $script:Rounds, $verdict, $script:Consec, $successN)

        if ($script:Consec -ge $successN) {
            $script:Status = 'success'
            Emit-Result
            exit 0
        }

        $remain = ($deadline - (Get-Date)).TotalSeconds
        if ($remain -le 0) { break }
        $sleepN = [Math]::Min($interval, [int][Math]::Ceiling($remain))
        Start-Sleep -Seconds $sleepN
    }
} finally {
    if ($script:Status -eq 'unknown') { $script:Status = 'timeout' }
    Emit-Result
}
exit 3
```

- [ ] **Step 2: Add a success-path Pester test**

Append to `tests/pester/ServiceWait.Tests.ps1`:

```powershell
Describe 'ServiceWait.ps1 round semantics' {
    It 'exits 0 when a TCP listener is up' {
        # Bind an ephemeral port and accept once.
        $listener = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback), 0
        $listener.Start()
        $port = $listener.LocalEndpoint.Port
        try {
            $tmp = [IO.Path]::GetTempFileName()
            "tcp, 127.0.0.1:$port, listener" | Set-Content -Path $tmp -Encoding ASCII
            $env:OPS_OVERRIDE_INITIAL_WAIT_SEC  = '0'
            $env:OPS_OVERRIDE_INTERVAL_SEC      = '1'
            $env:OPS_OVERRIDE_TIMEOUT_SEC       = '5'
            $env:OPS_OVERRIDE_SUCCESS_THRESHOLD = '1'
            $r = Invoke-SW @('-TargetList', $tmp)
            Remove-Item $tmp -Force
            $r.ExitCode | Should -Be 0
        } finally {
            $listener.Stop()
            $env:OPS_OVERRIDE_INITIAL_WAIT_SEC  = $null
            $env:OPS_OVERRIDE_INTERVAL_SEC      = $null
            $env:OPS_OVERRIDE_TIMEOUT_SEC       = $null
            $env:OPS_OVERRIDE_SUCCESS_THRESHOLD = $null
        }
    }
}
```

- [ ] **Step 3: Run Pester**

```powershell
pwsh -File tests/run_unit.ps1
```

Expected: all `It` blocks pass.

- [ ] **Step 4: Commit**

```bash
git add scripts_windows/os/ServiceWait.ps1 tests/pester/ServiceWait.Tests.ps1
git commit -m "feat(service-wait): powershell round loop with success/timeout"
```

---

## Task 10: bat launcher

**Files:**
- Create: `scripts_windows/os/service_wait.bat`

- [ ] **Step 1: Create the launcher (CRLF)**

```batch
@echo off
setlocal
set "SCRIPT_DIR=%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%ServiceWait.ps1" -TargetList %1
exit /b %ERRORLEVEL%
```

- [ ] **Step 2: Sanity-check line endings**

```bash
file scripts_windows/os/service_wait.bat
```

Expected: "ASCII text, with CRLF line terminators".

- [ ] **Step 3: Commit**

```bash
git add scripts_windows/os/service_wait.bat
git commit -m "feat(service-wait): bat launcher"
```

---

## Task 11: Documentation

**Files:**
- Create: `docs_linux/os/service_wait.md`
- Create: `docs_windows/os/ServiceWait.md`

- [ ] **Step 1: Create the Linux doc**

Create `docs_linux/os/service_wait.md`:

````markdown
# service_wait.sh

Wait until Ping / TCP / HTTP targets in a list file pass N consecutive rounds. Used after a deploy or restart to gate the next step in a runbook.

## Usage

```bash
scripts_linux/os/service_wait.sh <targets-list-file>
```

## Targets list format

CSV, `#` is a comment, blank lines skipped.

```
# type, target, description [, key=value ...]
ping, 10.0.0.1,                node-A
tcp,  10.0.0.1:8080,           Tomcat
http, https://api/health,      API
http, https://slow/health,     slow API,   per_check_timeout_sec=30
```

- `type`: `ping` | `tcp` | `http`
- `target`: ping=host, tcp=host:port, http=URL
- Overrides (column 4+, space-separated): `per_check_timeout_sec=<int>`
- Unknown type or unknown override key → exit 2

Pass criteria (fixed): ping = ICMP reply, tcp = connect success, http = 2xx.

## Configuration

Loaded from `config/<env>/service_wait.conf` (env via `OPS_ENV`) or `config/default/service_wait.conf`.

| Key | Default | Meaning |
|---|---|---|
| initial_wait_sec | 0 | Sleep before the first round |
| interval_sec | 5 | Sleep between rounds |
| success_threshold | 3 | Consecutive all-OK rounds for exit 0 |
| timeout_sec | 600 | Overall timeout |
| per_check_timeout_sec | 5 | Per-target check timeout (overridable per row) |
| LogFile | (empty) | Log file path (console only when empty) |
| LogLevel | INFO | DEBUG / INFO / WARN / ERROR |

## Exit codes

| Code | Meaning |
|---|---|
| 0 | All-OK reached `success_threshold` consecutive rounds |
| 1 | Bad arguments |
| 2 | List parse error |
| 3 | Timeout |
| 10 | Missing prerequisite command (`ping`, `curl`) |
````

- [ ] **Step 2: Create the Windows doc**

Create `docs_windows/os/ServiceWait.md` — same content as the Linux doc, but adjust the Usage section to:

```powershell
scripts_windows\os\ServiceWait.ps1 -TargetList <path>
# or via the launcher
scripts_windows\os\service_wait.bat <path>
```

and note that the HTTP check uses `Invoke-WebRequest -UseBasicParsing` and ICMP uses `System.Net.NetworkInformation.Ping`.

- [ ] **Step 3: Commit**

```bash
git add docs_linux/os/service_wait.md docs_windows/os/ServiceWait.md
git commit -m "docs(service-wait): linux and windows reference docs"
```

---

## Task 12: Encoding audit, template check, final test pass

- [ ] **Step 1: Run encoding audit**

```bash
# /encoding-audit triggers ci's check; minimum we can do here:
file scripts_windows/os/ServiceWait.ps1   # should mention "UTF-8 (with BOM)"
file scripts_linux/os/service_wait.sh     # should NOT mention BOM
file scripts_windows/os/service_wait.bat  # should say "CRLF"
```

If any file is wrong: rewrite it with the correct encoding via your editor and re-stage.

- [ ] **Step 2: Run template-check**

```bash
bash ci/template-check/check_template.sh
```

Expected: 0 violations.

- [ ] **Step 3: Run full unit tests on Linux**

```bash
bash tests/run_unit.sh
```

Expected: all bats tests pass.

- [ ] **Step 4: Run Pester (if running on Windows)**

```powershell
pwsh -File tests/run_unit.ps1
```

Expected: all `It` blocks pass.

- [ ] **Step 5: Final commit if anything was tidied**

```bash
git status --short
# If anything is modified:
git add -u
git commit -m "chore(service-wait): final tidy after audits"
```

---

## Self-review notes

- **Spec coverage:** all 12 acceptance criteria covered (config defaults → Task 1; list parser → Task 3/7; check functions → Task 4/8; round loop → Task 5/9; bat → Task 10; docs → Task 11; encoding/template → Task 12).
- **Placeholders:** none — every step has concrete code or a concrete command.
- **Naming consistency:** `parse_list_line`, `run_check`, `check_ping/tcp/http` in Bash; `Invoke-Check`, `Test-PingHost/TcpEndpoint/HttpUrl` in PS — function names are not reused across implementations but each implementation is internally consistent.
- **Test hooks:** `OPS_OVERRIDE_*` env vars are documented in the script and used in tests; they collapse to conf when unset.
