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

## Stop

```bash
docker compose down
```

To remove persisted Grafana and Prometheus data too:

```bash
docker compose down -v
```

## Configuration

Edit `.env` after the first run if you want different ports or credentials:

```env
GRAFANA_PORT=3000
PROMETHEUS_PORT=9090
CADVISOR_PORT=8080
GRAFANA_ADMIN_USER=admin
```

Run `./run.sh start` again after editing `.env` to regenerate the Prometheus and Grafana datasource config from those values.

## Git-tracked vs generated files

Tracked files include the Compose definition, setup scripts, nginx proxy config, Grafana provisioning config, and dashboard JSON.

Generated and local-only files are ignored:

- `.env`
- `monitoring/generated/*`
- Docker named volumes managed by Compose
