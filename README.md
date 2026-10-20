# Personal Tidbyt Apps

Displays aggregate NVIDIA GPU power in **watts**, using DCGM metrics in Prometheus.
Data is read from your LAN; images are uploaded to the Tidbyt cloud API.

![prometheus-monitoring](prometheus-monitoring/tidbyt-prometheus-monitoring.png)

## Setup and operation

For a new checkout, copy `.env.example` to `.env` and fill in `DEVICE_ID` and
`TIDBYT_API_TOKEN` from your Tidbyt account. Keep an existing `.env`; merge any
optional settings you want from the example. Credentials are ignored by Git
and are outside the Docker build context.

```sh
# Build and start only the uploader.
docker compose up -d --build daemonize

# View timestamped upload status and telemetry.
docker compose logs --tail=100 -f daemonize

# Check uploader health.
docker compose ps daemonize

# Render once, without uploading. Output: prometheus-monitoring/prometheus-monitoring.webp
docker compose run --rm --build render

# Optional browser preview, still available on http://<host>:18080
docker compose up -d --build serve
```

The daemon contains a copy of the code. Rebuild it after source changes with
`docker compose up -d --build daemonize`. The preview and one-shot renderer
bind-mount the source for development. `docker compose up` without a service
name still starts all three services.

## Configuration

| Setting | Default | Purpose |
| --- | --- | --- |
| `PROMETHEUS_URL` | `http://192.168.1.234:30500` | Prometheus base URL; the existing NodePort is preserved |
| `POLL_INTERVAL_SECONDS` | `30` | Delay after a successful render/upload cycle |
| `RETRY_INTERVAL_SECONDS` | `90` | Delay after rendering or uploading fails |
| `COMMAND_TIMEOUT_SECONDS` | `30` | Overall time limit for each render or upload, followed by a 5-second forced-stop grace period |
| `EXPECTED_GPU_COUNT` | `0` | Optional expected count of power series; `0` disables this check |
| `HEALTH_MAX_AGE_SECONDS` | Derived; normally `270` | Maximum age of the last successful upload |
| `PIXLET_VERSION` | `0.34.0` | Release downloaded and checksum-verified during the build |
| `BASE_IMAGE` | `ubuntu:24.04` | Ubuntu release used for the image; may also be pinned to a digest |

The URL and GPU count from `.env` apply to the daemon and one-shot renderer.
For `serve`, use the preview's configuration form; it starts with the same LAN
URL and disabled count check. The preview remains bound to `0.0.0.0:18080`.
Existing LAN client access, authentication, and Prometheus ports should be
preserved when adding network rules.

## Fixed Docker subnet

All three services use the Compose default network with these fixed settings:

| Property | Value |
| --- | --- |
| Network name | `tidbyt_default` |
| Driver | `bridge` |
| Subnet | `172.30.50.0/24` |
| Gateway | `172.30.50.1` |
| Prometheus destination | `192.168.1.234`, TCP port `30500` |

For rules that inspect the original container source address, use
`172.30.50.0/24` as the source CIDR for access to that Prometheus destination.
Add this access alongside the existing LAN rules. The preview's published
port remains `18080:8080`.

Docker bridges normally masquerade outbound traffic, so a firewall on a remote
LAN device may see the Docker host's LAN IP instead of this subnet. Match the
source address at the point where your rule is enforced.
[Docker bridge networking](https://docs.docker.com/engine/network/drivers/bridge/)

The subnet was checked against this host's Docker networks and routes. Compose
creates the network on the next `up` or `run`; editing the file does not create
it or change firewall rules. Container IPs may change within this fixed subnet.
Once created, inspect the assignment with:

```sh
docker network inspect tidbyt_default --format '{{json .IPAM.Config}}'
```

On another host, check for overlapping networks before deploying. If a network
named `tidbyt_default` already exists with a different subnet, plan its migration
with its attached consumers; do not remove an in-use network just to recreate it.

## Failure behavior

- Power, maximum temperature, and power-series count are queried in one
  Prometheus snapshot. The display rounds the total to whole watts.
- Missing or invalid power displays **Unavailable**. Missing or invalid
  temperature preserves valid wattage, using a neutral gray color.
- Setting `EXPECTED_GPU_COUNT` detects both fewer and more series than expected
  and displays **Incomplete**. The review observed five series; this setting is
  deliberately opt-in because your GPU inventory may change. It checks series
  count, not GPU identity or scrape freshness.
- The daemon and one-shot renderer turn network failures into a newly rendered
  **Unavailable** image. If even that render fails, nothing is uploaded.
  An old output file is never selected as a fallback.
- Every upload is time-bounded. Failed uploads retry with a fresh render.
  If the Tidbyt API or device is unreachable, an offline image cannot be
  delivered; whatever the device already displays may remain.
- Successful uploads atomically update `/tmp/tidbyt-status/last-success` inside
  the container. Docker health checks inspect this timestamp. An uploaded
  **Unavailable** frame counts as a successful delivery. Health therefore
  measures delivery, not telemetry availability. Docker does not automatically
  restart a container solely because it becomes unhealthy.

The standalone Pixlet browser preview handles empty/invalid responses, but
Pixlet itself reports transport failures in its UI; the daemon's offline
fallback applies to uploads and the one-shot render command.

A successful one-shot render can therefore produce **Unavailable**; inspect its
telemetry logs as well as its exit status. If Prometheus works from the host but
times out inside Docker, check the existing container-to-LAN route and firewall
configuration. Keep the working LAN endpoints and client access intact.

## Tests

The regression suite uses only Python's standard library. Daemon tests use a
fake Pixlet executable and dummy credentials; renderer tests use a loopback
HTTP server and a real Pixlet binary. Tests never contact your Tidbyt.

```sh
python3 -m unittest discover -s tests -v

# If Pixlet is not on PATH:
PIXLET_BIN=/path/to/pixlet python3 -m unittest discover -s tests -v
```

Renderer tests are explicitly skipped when Pixlet is unavailable. They cover
healthy readings, zero watts, missing temperature/power, malformed JSON,
non-finite values, HTTP errors, and incomplete totals. Daemon tests cover
failed renders, offline fallback, empty output, upload errors/timeouts,
health timestamps, credential validation, and shutdown.

## Updating and rollback

Before applying an update, save the working configuration and image:

```sh
backup="backups/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$backup"
chmod 700 "$backup"
cp -a docker-compose.yaml .env prometheus-monitoring "$backup/"
docker image save loca-tidbyt/tidbyt:prometheus-monitoring > "$backup/tidbyt-image.tar"
```

After rebuilding, check logs, container health, and the physical display.
If the preview is in use, verify port `18080` from an ordinary LAN client.
To roll back using the saved backup directory:

```sh
cp -a "$backup/docker-compose.yaml" "$backup/.env" .
cp -a "$backup/prometheus-monitoring/." prometheus-monitoring/
docker image load < "$backup/tidbyt-image.tar"
docker compose up -d --no-build --force-recreate daemonize
# If the preview was running:
docker compose up -d --no-build --force-recreate serve
```
