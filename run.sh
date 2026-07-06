#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

usage() {
  cat <<'EOF'
Usage:
  ./run.sh        Generate missing config and start the monitoring stack.
  ./run.sh new    Delete the previous autoGrafana instance and start fresh.
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

if [ "$#" -gt 1 ]; then
  usage >&2
  exit 1
fi

reset=false
case "${1:-}" in
  "")
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
  echo "Removing previous autoGrafana containers, networks, and volumes..."
  docker compose down -v --remove-orphans || true
  rm -rf monitoring/generated .env
  mkdir -p monitoring/generated/grafana-datasources
  : > monitoring/generated/.gitkeep
  : > monitoring/generated/grafana-datasources/.gitkeep
fi

bash monitoring/generate-config.sh --quiet

set -a
# shellcheck disable=SC1091
. ./.env
set +a

docker compose up -d

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

Credentials are stored locally in .env.
EOF
