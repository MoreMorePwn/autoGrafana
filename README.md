# autoGrafana

autoGrafana is a small Docker Compose monitoring stack modeled after the monitoring setup in the local `CTFd` folder. It starts Grafana, Prometheus, cAdvisor, and node-exporter with generated credentials and a pre-provisioned Grafana datasource/dashboard.

## What it runs

- Grafana on `http://localhost:3000`
- Prometheus on `http://localhost:9090` with basic auth
- cAdvisor on `http://localhost:8080` behind an nginx basic-auth proxy
- node-exporter for host-level metrics used by Prometheus

Grafana is provisioned automatically with:

- Prometheus datasource named `prometheus`
- Container monitoring dashboard copied from the CTFd monitoring setup

## Requirements

- Docker
- Docker Compose v2 (`docker compose version`)
- Python 3
- `htpasswd` from `apache2-utils` or Docker access so the script can use the `httpd:2.4-alpine` image to generate auth hashes

The cAdvisor and node-exporter containers mount host paths such as `/var/run`, `/sys`, `/proc`, and `/var/lib/docker`. Run this on Linux or WSL with Docker available.

## Run

Run `./run.sh` with no arguments to print command help.

```bash
chmod +x run.sh monitoring/generate-config.sh
./run.sh start
```

`start` creates `.env` if it does not exist, generates Prometheus/cAdvisor auth files under `monitoring/generated`, and starts the Compose stack with the current local data.

After startup, the script prints all local URLs and credentials. The credentials are stored in `.env`, which is intentionally ignored by Git.

## Start fresh

```bash
./run.sh new
```

`new` removes the previous autoGrafana containers, networks, and named volumes, deletes generated credentials/config, then creates a fresh instance.

During a fresh run, `run.sh` auto-detects the local Docker socket and Docker root directory from:

```bash
docker context inspect --format '{{.Endpoints.docker.Host}}'
docker info --format '{{.DockerRootDir}}'
```

It also enables Docker and containerd discovery for cAdvisor, then checks whether cAdvisor exposes container metrics after startup and prints the status in the final output.

## Stop

```bash
docker compose down
```

To remove persisted Grafana and Prometheus data too:

```bash
docker compose down -v
```

## Troubleshooting

If Grafana or Prometheus is restarting, pull the latest project files and run:

```bash
./run.sh start
```

The stack includes a one-shot `permissions` container that fixes the Grafana and Prometheus named-volume ownership before those services start.

If a service still restarts, check its logs:

```bash
docker logs autografana-grafana --tail=100
docker logs autografana-prometheus --tail=100
```

If Prometheus targets are up but container panels have no data, check whether cAdvisor exposes non-root container metrics:

```bash
curl -u "$PROMETHEUS_BASIC_USER:$PROMETHEUS_BASIC_PASSWORD" http://localhost:8080/metrics | grep '^container_last_seen'
```

Only `id="/"` means cAdvisor can see the host root cgroup but not the containers. Find the Docker socket and root directory:

```bash
docker context inspect --format '{{json .Endpoints.docker.Host}}'
docker info --format '{{.DockerRootDir}}'
```

Then set them in `.env` and restart. If the socket value starts with `unix://`, keep the path part only or paste the full value; `run.sh` normalizes it.

```env
DOCKER_SOCKET_PATH=/var/run/docker.sock
DOCKER_RUN_DIR=/var/run
DOCKER_ROOT_DIR=/var/lib/docker
CONTAINERD_NAMESPACE=moby
CONTAINERD_ROOT_DIR=/var/lib/containerd
```

```bash
./run.sh start
docker compose restart cadvisor cadvisor-auth prometheus grafana
```

## Configuration

Edit `.env` after the first run if you want different ports or credentials:

```env
GRAFANA_PORT=3000
PROMETHEUS_PORT=9090
CADVISOR_PORT=8080
CADVISOR_IMAGE=gcr.io/cadvisor/cadvisor:v0.55.1
DOCKER_SOCKET_PATH=/var/run/docker.sock
DOCKER_ROOT_DIR=/var/lib/docker
GRAFANA_ADMIN_USER=admin
```

Run `./run.sh start` again after editing `.env` to regenerate the Prometheus and Grafana datasource config from those values.

## Git-tracked vs generated files

Tracked files include the Compose definition, setup scripts, nginx proxy config, Grafana provisioning config, and dashboard JSON.

Generated and local-only files are ignored:

- `.env`
- `monitoring/generated/*`
- Docker named volumes managed by Compose
