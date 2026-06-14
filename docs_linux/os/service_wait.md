# service_wait.sh

Wait until Ping / TCP / HTTP targets in a list file pass N consecutive rounds. Used after a deploy or restart to gate the next step in a runbook.

## Usage

```bash
scripts_linux/os/service_wait.sh <targets-list-file>
```

## Targets list format

CSV, `#` is a comment, blank lines skipped. A `.lst` file is composed of an
**optional header block** of `key = value` lines followed by **CSV target rows**.

```
# Monitoring parameters (all optional; hardcoded defaults apply when absent)
initial_wait_sec      = 10
interval_sec          = 5
success_threshold     = 3
timeout_sec           = 600
per_check_timeout_sec = 5

# ---- Targets ----
ping, 10.0.0.1,                node-A
tcp,  10.0.0.1:8080,           Tomcat
http, https://api/health,      API
http, https://slow/health,     slow API,   per_check_timeout_sec=30
```

### Header block

| Key | Default | Meaning |
|---|---|---|
| initial_wait_sec | 0 | Sleep before the first round |
| interval_sec | 5 | Sleep between rounds |
| success_threshold | 3 | Consecutive all-OK rounds for exit 0 |
| timeout_sec | 600 | Overall timeout |
| per_check_timeout_sec | 5 | Default per-target check timeout (overridable per row) |

- All values are non-negative integers
- Unknown header key or non-integer value → exit 2
- A `key = value` line appearing after a target row is rejected (`header_after_targets`)
- Header values can be a different set in each .lst, so a single script can be reused for different monitoring runs (e.g. short rolling checks vs. long startup waits)

### Target rows

- `type`: `ping` | `tcp` | `http` | `service` | `process`
- `target`:
    - ping = host (DNS name or IP)
    - tcp  = host:port
    - http = URL
    - service = systemd unit name (`[A-Za-z0-9._@-]+`)
    - process = executable name (`[A-Za-z0-9._-]+`), matched exactly by `pgrep -x`
- Row-level overrides (column 4+, space-separated): `per_check_timeout_sec=<int>` only
- Unknown type or unknown row override key → exit 2

Pass criteria (fixed):
- ping = ICMP reply
- tcp  = TCP connect success
- http = 2xx status code
- service = `systemctl is-active --quiet <name>` returns 0
- process = `pgrep -x <name>` finds ≥ 1 match

Prerequisite commands (exit 10 if missing):
- ping → `ping`
- http → `curl`
- service → `systemctl`
- process → `pgrep`

`service` and `process` only inspect the **local** node. Same `.lst` is not portable across OSes.

### Resolution order

```
1. Row-level override (per_check_timeout_sec only)
2. .lst header
3. Hardcoded default (table above)
```

## Configuration

`config/<env>/service_wait.conf` → `config/default/service_wait.conf` order. Holds **script-level settings only**:

| Key | Default | Meaning |
|---|---|---|
| LogFile | (empty) | Log file path (console only when empty) |
| LogLevel | INFO | DEBUG / INFO / WARN / ERROR |

Monitoring parameters (`initial_wait_sec` etc.) are no longer read from conf.
If a stale conf contains them, a WARN is logged and the value is ignored.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | All-OK reached `success_threshold` consecutive rounds |
| 1 | Bad arguments or invalid config value |
| 2 | List parse error |
| 3 | Timeout |
| 10 | Missing prerequisite command (`ping`, `curl`) |
