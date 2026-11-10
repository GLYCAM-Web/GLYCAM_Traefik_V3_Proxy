# Access Log Rotation & Analytics Stack (VictoriaLogs + Vector + Grafana)

This directory contains the configuration and helper scripts for:
1. **Permanent Monthly Log Rotation (`./ACCESS_LOGS/access-YYYY-MM.log.gz`)**
2. **Real-Time Log Shipping (`Vector`)**
3. **Multi-Year Log Database (`VictoriaLogs`)**
4. **AWStats-Style Dashboards & Public Reporting (`Grafana`)**

---

## 1. How Monthly File Rotation Works

Traefik writes JSON access logs to `./ACCESS_LOGS/access.log`. Because Traefik does not natively rotate access logs, `docker-compose.traefik.swarm.yml` runs a lightweight companion service (`traefik-logrotate`):

- **Schedule**: Runs automatically at `00:00` on the **1st of every month** (`0 0 1 * *`).
- **Zero-Downtime Signal**: Moves `access.log` to `access-YYYY-MM.log` (labeled with the month that just finished) and immediately sends `SIGUSR1` to the Traefik container so Traefik opens a fresh `access.log` without dropping a single request.
- **Compression & Infinite Retention**: Waits 10 seconds for in-flight writes and `vector` to finish tailing the rotated file, then compresses it with `gzip -9` to `access-YYYY-MM.log.gz`. Old monthly archives are **never deleted**.
- **Manual Rotation Test**: You can trigger a rotation at any time with:
  ```bash
  docker exec $(docker ps -q -f name=traefik_traefik-logrotate) /bin/sh /scripts/rotate-access-logs.sh
  ```

---

## 2. Splitting & Backfilling Your Existing ~220 GB `access.log`

If you already have a large multi-month `./ACCESS_LOGS/access.log` (e.g., from February to now), use the included `split-and-backfill-existing-logs.sh` script after starting the stack:

```bash
# Splits ./ACCESS_LOGS/access.log by month (StartUTC), backfills all months
# into VictoriaLogs so they appear in Grafana, and compresses each month to .log.gz:
bash logging/split-and-backfill-existing-logs.sh --backfill
```

If you only want to split and compress the file into monthly `access-YYYY-MM.log.gz` files without loading into VictoriaLogs, omit `--backfill`:

```bash
bash logging/split-and-backfill-existing-logs.sh
```

> **Note**: The script keeps the original file as `./ACCESS_LOGS/access-pre-split.log` until you verify your new `access-YYYY-MM.log.gz` files and remove `access-pre-split.log`.

---

## 3. Accessing Grafana & VictoriaLogs

When `bash start.sh` runs, it deploys both `docker-compose.traefik.swarm.yml` and `docker-compose.logging.swarm.yml` (unless `export ENABLE_LOGGING_STACK="NO"` is set in `config.bash`).

### Configuration (`config.bash`)
You can optionally set credentials in `config.bash`:
```bash
export LE_EMAIL="your@email.address"
export GRAFANA_ADMIN_USER="admin"
export GRAFANA_ADMIN_PASSWORD="your-strong-password"
```

### Web Interfaces
- **Grafana**: `http://<swarm-node>:3000`
  - Pre-provisioned under the **Traefik** folder with two dashboards:
    1. **GLYCAM Traefik Access Analytics (AWStats Overview)**: Full admin view with Total Requests, Unique Visitor IPs, Total Bandwidth, POST/Job Submissions, Traffic History by Host, Top Virtual Hosts, HTTP Status Codes, Top URLs, Top POST Endpoints, Top Client IPs, Top Referrers, Top User-Agents, and a live **Access Log Explorer & Investigation** panel.
    2. **GLYCAM Public Usage Statistics (Safe for Public Sharing)**: Aggregate usage metrics without raw IP addresses or raw logs, designed to be shared publicly.
- **VictoriaLogs Built-in UI (VMUI)**: Kept internal to `traefik_proxy_net` (not exposed on public interfaces). To access it from your workstation, use an SSH port-forward through a temporary container or inspect via Grafana.

---

## 4. Teaching Grafana Custom Stats (`LogsQL` Examples)

VictoriaLogs indexes every JSON field produced by Traefik automatically. You can duplicate any panel in Grafana (or add a new panel) and write simple `LogsQL` queries:

- **Count requests to a specific modeling tool or path over any multi-year range**:
  ```text
  RequestHost:glycam.org RequestPath:"/cb/" | stats count() as hits, count_uniq(ClientHost) as unique_users
  ```
- **Count POST job submissions excluding internal/test IPs**:
  ```text
  RequestMethod:POST -ClientHost:192.0.2.* | stats by (RequestPath) count() as jobs | sort by (jobs desc)
  ```
- **Investigate everything a specific IP did**:
  ```text
  ClientHost:"203.0.113.42"
  ```
- **Find slow requests taking longer than 5 seconds (`Duration` is in nanoseconds in Traefik JSON)**:
  ```text
  Duration:>5000000000 | stats by (RequestHost, RequestPath) count() as slow_hits, max(Duration) as max_ns | sort by (slow_hits desc)
  ```

---

## 5. Securely Publishing Statistics Online at `glycam.org/stats`

Grafana natively supports running under a URL subpath (such as `https://glycam.org/stats`) via `GF_SERVER_SERVE_FROM_SUB_PATH=true`, which is now pre-configured in `docker-compose.logging.swarm.yml`.

### Step-by-Step Setup for `glycam.org/stats`

1. **Configure `config.bash`**:
   ```bash
   export GRAFANA_HOST="glycam.org"
   export GRAFANA_SUBPATH="/stats"
   export GRAFANA_ROOT_URL="https://glycam.org/stats/"
   ```
2. **Enable Traefik Routing in `docker-compose.logging.swarm.yml`**:
   Uncomment the Traefik labels on the `grafana` service (and comment out `traefik.enable=false`):
   ```yaml
   - "traefik.enable=true"
   - "traefik.swarm.network=traefik_proxy_net"
   - "traefik.http.routers.grafana.rule=Host(`${GRAFANA_HOST:-glycam.org}`) && PathPrefix(`${GRAFANA_SUBPATH:-/stats}`)"
   - "traefik.http.routers.grafana.priority=500"
   - "traefik.http.routers.grafana.entrypoints=websecure"
   - "traefik.http.routers.grafana.tls=true"
   - "traefik.http.routers.grafana.tls.certresolver=le"
   - "traefik.http.services.grafana.loadbalancer.server.port=3000"
   ```
   *(Note: `priority=500` ensures `glycam.org/stats` matches before the main `glycam.org` website router. Look at `Examples/docker-compose.proxy.swarm.traefik.ratelimits.yml` to make sure `500` is higher than your main website router's priority.)*
3. **Publish the Public Dashboard**:
   - Open Grafana (on LAN at `http://<swarm-node>:3000/stats/`), go to **Dashboards -> Traefik -> GLYCAM Public Usage Statistics (Safe for Public Sharing)**.
   - Click **Share** (top right) -> **Public Dashboard** tab -> enable **Make dashboard public**.
   - Grafana will provide a public link: `https://glycam.org/stats/public-dashboards/<token>`.

### Optional: Lock Down `/stats` So Only the Public Dashboard Is Externally Reachable

If you want external visitors on `glycam.org/stats` to **only** be able to load the public dashboard (while keeping the Grafana login page `/stats/login` and admin UI reachable only on your internal LAN via `:3000`), use this router rule instead:

```yaml
- "traefik.http.routers.grafana.rule=Host(`glycam.org`) && (PathPrefix(`/stats/public-dashboards`) || PathPrefix(`/stats/api/public`) || PathPrefix(`/stats/public/`))"
```

With that rule, Grafana's login page and admin API aren't even exposed to the public internet—only the read-only public dashboard and its static frontend assets are routed through Traefik.

---

## 6. Optional: Converting JSON Logs to Apache Combined Format for Classic AWStats

If you ever want to run classic **AWStats** on any monthly `access-YYYY-MM.log.gz` file, you can convert Traefik JSON to Apache Combined Log Format on the fly using `jq`:

```bash
zcat ACCESS_LOGS/access-2026-10.log.gz | jq -r '
  "\(.ClientHost // "-") - \(.ClientUsername // "-") [\(.StartUTC)] \"\(.RequestMethod) \(.RequestPath) \(.RequestProtocol)\" \(.DownstreamStatus) \(.DownstreamContentSize) \"\(.["request_Referer"] // "-")\" \"\(.["request_User-Agent"] // "-")\""
' > access-2026-10.combined.log
```
