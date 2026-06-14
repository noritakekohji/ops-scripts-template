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
- Unknown type or unknown override key -> exit 2

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
