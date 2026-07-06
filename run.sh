#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

usage() {
  cat <<'EOF'
Usage:
  ./run.sh          Show this help.
  ./run.sh start    Generate missing config and start the monitoring stack.
  ./run.sh new      Delete the previous autoGrafana instance and start fresh.
EOF
}

if [ "$#" -eq 0 ] || [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

if [ "$#" -gt 1 ]; then
  usage >&2
  exit 1
fi

reset=false
case "${1:-}" in
  start)
    ;;
  new)
    reset=true
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker is required but was not found in PATH." >&2
  exit 1
fi

if ! docker compose version >/dev/null 2>&1; then
  echo "Docker Compose v2 is required. Install the Docker Compose plugin first." >&2
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  echo "Docker is installed, but the Docker daemon is not reachable. Start Docker and rerun ./run.sh." >&2
  exit 1
fi

if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
fi

export COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-autografana}"

if [ "${reset}" = true ]; then
  fresh_compose_project="${COMPOSE_PROJECT_NAME:-autografana}"
  echo "Removing previous autoGrafana containers, networks, and volumes..."
  docker compose down -v --remove-orphans || true
  rm -rf monitoring/generated .env
  mkdir -p monitoring/generated/grafana-datasources
  : > monitoring/generated/.gitkeep
  : > monitoring/generated/grafana-datasources/.gitkeep
  unset GRAFANA_PORT
  unset PROMETHEUS_PORT
  unset CADVISOR_PORT
  unset CADVISOR_IMAGE
  unset DOCKER_SOCKET_PATH
  unset DOCKER_RUN_DIR
  unset DOCKER_ROOT_DIR
  unset CONTAINERD_NAMESPACE
  unset CONTAINERD_ROOT_DIR
  unset GRAFANA_ADMIN_USER
  unset GRAFANA_ADMIN_PASSWORD
  unset PROMETHEUS_BASIC_USER
  unset PROMETHEUS_BASIC_PASSWORD
  export COMPOSE_PROJECT_NAME="${fresh_compose_project}"
fi

bash monitoring/generate-config.sh --quiet

set -a
# shellcheck disable=SC1091
. ./.env
set +a

if [ ! -S "${DOCKER_SOCKET_PATH}" ]; then
  echo "Warning: Docker socket was not found at ${DOCKER_SOCKET_PATH}." >&2
  echo "cAdvisor will not show container data until DOCKER_SOCKET_PATH in .env points to the Docker socket." >&2
fi

if [ ! -d "${DOCKER_ROOT_DIR}" ]; then
  echo "Warning: Docker root directory was not found at ${DOCKER_ROOT_DIR}." >&2
  echo "Set DOCKER_ROOT_DIR in .env to the value from: docker info --format '{{.DockerRootDir}}'" >&2
fi

if [ ! -d "${CONTAINERD_ROOT_DIR}" ]; then
  echo "Warning: containerd root directory was not found at ${CONTAINERD_ROOT_DIR}." >&2
fi

if [ "${reset}" = true ]; then
  docker compose up -d --force-recreate --build
else
  docker compose up -d --build
fi

cadvisor_container_status="unknown"
if python3 - "${CADVISOR_PORT}" "${PROMETHEUS_BASIC_USER}" "${PROMETHEUS_BASIC_PASSWORD}" <<'PY'
import base64
import re
import sys
import time
import urllib.error
import urllib.request

port, username, password = sys.argv[1:4]
token = base64.b64encode(f"{username}:{password}".encode()).decode()
url = f"http://127.0.0.1:{port}/metrics"
metric = re.compile(r'^container_last_seen\{([^}]*)\}')
container_id = re.compile(r'id="([^"]*)"')
container_cgroup = re.compile(
    r'(^/docker/[0-9a-f]{12,64}$'
    r'|^/system\.slice/docker-[0-9a-f]{12,64}\.scope$'
    r'|.*/kubepods.*'
    r'|.*/cri-containerd.*'
    r'|.*/containerd.*[0-9a-f]{12,64}.*'
    r'|.*/libpod.*)'
)

for _ in range(30):
    request = urllib.request.Request(url, headers={"Authorization": f"Basic {token}"})
    try:
        with urllib.request.urlopen(request, timeout=2) as response:
            payload = response.read().decode(errors="replace")
        for line in payload.splitlines():
            match = metric.match(line)
            if not match:
                continue
            labels = match.group(1)
            id_match = container_id.search(labels)
            id_value = id_match.group(1) if id_match else ""
            if container_cgroup.search(id_value):
                sys.exit(0)
    except (OSError, urllib.error.URLError):
        pass
    time.sleep(2)

sys.exit(1)
PY
then
  cadvisor_container_status="container metrics detected"
else
  cadvisor_container_status="no container metrics detected"
fi

cat <<EOF

autoGrafana is running.

Grafana:    http://localhost:${GRAFANA_PORT}
Prometheus: http://localhost:${PROMETHEUS_PORT}
cAdvisor:   http://localhost:${CADVISOR_PORT}

Grafana login:
  username: ${GRAFANA_ADMIN_USER}
  password: ${GRAFANA_ADMIN_PASSWORD}

Prometheus and cAdvisor basic auth:
  username: ${PROMETHEUS_BASIC_USER}
  password: ${PROMETHEUS_BASIC_PASSWORD}

Docker paths used by cAdvisor:
  socket: ${DOCKER_SOCKET_PATH}
  run dir: ${DOCKER_RUN_DIR}
  root: ${DOCKER_ROOT_DIR}
  containerd namespace: ${CONTAINERD_NAMESPACE}
  containerd root: ${CONTAINERD_ROOT_DIR}
  cAdvisor container metrics: ${cadvisor_container_status}

Credentials are stored locally in .env.
EOF

if [ "${cadvisor_container_status}" != "container metrics detected" ]; then
  cat >&2 <<EOF

Warning: cAdvisor is running but is not reporting container metrics.
Container panels in Grafana may be empty until cAdvisor can read Docker or containerd.

Check these host values:
  docker context inspect --format '{{.Endpoints.docker.Host}}'
  docker info --format '{{.DockerRootDir}}'

Then run:
  ./run.sh new
EOF
fi
