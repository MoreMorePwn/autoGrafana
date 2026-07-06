#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
umask 077

quiet=false
if [ "${1:-}" = "--quiet" ]; then
  quiet=true
fi

random_alnum() {
  python3 - "${1:-32}" <<'PY'
import secrets
import string
import sys

length = int(sys.argv[1])
alphabet = string.ascii_letters + string.digits
print("".join(secrets.choice(alphabet) for _ in range(length)))
PY
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Required command not found: $1" >&2
    exit 1
  fi
}

htpasswd_line() {
  local mode="$1"
  local username="$2"
  local password="$3"

  if command -v htpasswd >/dev/null 2>&1; then
    htpasswd -n -b "${mode}" "${username}" "${password}"
    return
  fi

  if command -v docker >/dev/null 2>&1; then
    docker run --rm httpd:2.4-alpine htpasswd -n -b "${mode}" "${username}" "${password}"
    return
  fi

  echo "Need either htpasswd or Docker to generate monitoring auth files." >&2
  exit 1
}

docker_context_socket() {
  if ! command -v docker >/dev/null 2>&1; then
    return 0
  fi

  docker context inspect --format '{{.Endpoints.docker.Host}}' 2>/dev/null | head -n 1 || true
}

docker_root_dir() {
  if ! command -v docker >/dev/null 2>&1; then
    return 0
  fi

  docker info --format '{{.DockerRootDir}}' 2>/dev/null | head -n 1 || true
}

normalize_socket_path() {
  local value="$1"

  value="${value#unix://}"
  printf '%s\n' "${value}"
}

detect_docker_socket_path() {
  local configured="${DOCKER_SOCKET_PATH:-}"
  local context_host="${DOCKER_HOST:-}"
  local candidate

  configured="$(normalize_socket_path "${configured}")"
  if [ -n "${configured}" ] && [ -S "${configured}" ]; then
    printf '%s\n' "${configured}"
    return
  fi

  if [ -z "${context_host}" ]; then
    context_host="$(docker_context_socket)"
  fi

  case "${context_host}" in
    unix://*)
      candidate="$(normalize_socket_path "${context_host}")"
      if [ -S "${candidate}" ]; then
        printf '%s\n' "${candidate}"
        return
      fi
      ;;
  esac

  for candidate in "/var/run/docker.sock" "/run/user/$(id -u)/docker.sock"; do
    if [ -S "${candidate}" ]; then
      printf '%s\n' "${candidate}"
      return
    fi
  done

  if [ -n "${configured}" ]; then
    printf '%s\n' "${configured}"
    return
  fi

  if [ "${context_host#unix://}" != "${context_host}" ]; then
    normalize_socket_path "${context_host}"
    return
  fi

  printf '%s\n' "/var/run/docker.sock"
}

detect_docker_root_dir() {
  local configured="${DOCKER_ROOT_DIR:-}"
  local detected

  if [ -n "${configured}" ] && [ -d "${configured}" ]; then
    printf '%s\n' "${configured}"
    return
  fi

  detected="$(docker_root_dir)"
  if [ -n "${detected}" ]; then
    printf '%s\n' "${detected}"
    return
  fi

  if [ -n "${configured}" ]; then
    printf '%s\n' "${configured}"
    return
  fi

  printf '%s\n' "/var/lib/docker"
}

require_command python3

if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
fi

COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-autografana}"
GRAFANA_PORT="${GRAFANA_PORT:-3000}"
PROMETHEUS_PORT="${PROMETHEUS_PORT:-9090}"
CADVISOR_PORT="${CADVISOR_PORT:-8080}"
CADVISOR_IMAGE="${CADVISOR_IMAGE:-gcr.io/cadvisor/cadvisor:v0.55.1}"
DOCKER_SOCKET_PATH="$(detect_docker_socket_path)"
DOCKER_ROOT_DIR="$(detect_docker_root_dir)"
GRAFANA_ADMIN_USER="${GRAFANA_ADMIN_USER:-admin}"
GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-$(random_alnum 36)}"
PROMETHEUS_BASIC_USER="${PROMETHEUS_BASIC_USER:-monitor_$(random_alnum 8)}"
PROMETHEUS_BASIC_PASSWORD="${PROMETHEUS_BASIC_PASSWORD:-$(random_alnum 36)}"

monitoring_dir="monitoring/generated"
grafana_datasource_dir="${monitoring_dir}/grafana-datasources"
prometheus_config="${monitoring_dir}/prometheus.yml"
prometheus_web_config="${monitoring_dir}/prometheus-web.yml"
cadvisor_htpasswd_file="${monitoring_dir}/cadvisor.htpasswd"
grafana_datasource_config="${grafana_datasource_dir}/prometheus.yml"

mkdir -p "${grafana_datasource_dir}"
chmod 0755 "${monitoring_dir}" "${grafana_datasource_dir}"

cat > .env <<EOF
COMPOSE_PROJECT_NAME=${COMPOSE_PROJECT_NAME}
GRAFANA_PORT=${GRAFANA_PORT}
PROMETHEUS_PORT=${PROMETHEUS_PORT}
CADVISOR_PORT=${CADVISOR_PORT}
CADVISOR_IMAGE=${CADVISOR_IMAGE}
DOCKER_SOCKET_PATH=${DOCKER_SOCKET_PATH}
DOCKER_ROOT_DIR=${DOCKER_ROOT_DIR}
GRAFANA_ADMIN_USER=${GRAFANA_ADMIN_USER}
GRAFANA_ADMIN_PASSWORD=${GRAFANA_ADMIN_PASSWORD}
PROMETHEUS_BASIC_USER=${PROMETHEUS_BASIC_USER}
PROMETHEUS_BASIC_PASSWORD=${PROMETHEUS_BASIC_PASSWORD}
EOF

prometheus_htpasswd="$(htpasswd_line -B "${PROMETHEUS_BASIC_USER}" "${PROMETHEUS_BASIC_PASSWORD}")"
prometheus_bcrypt="${prometheus_htpasswd#*:}"
cadvisor_htpasswd="$(htpasswd_line -m "${PROMETHEUS_BASIC_USER}" "${PROMETHEUS_BASIC_PASSWORD}")"

cat > "${prometheus_web_config}" <<EOF
basic_auth_users:
  ${PROMETHEUS_BASIC_USER}: "${prometheus_bcrypt}"
EOF

cat > "${cadvisor_htpasswd_file}" <<EOF
${cadvisor_htpasswd}
EOF

cat > "${prometheus_config}" <<EOF
global:
  scrape_interval: 15s

scrape_configs:
  - job_name: "prometheus"
    scrape_interval: 5s
    basic_auth:
      username: "${PROMETHEUS_BASIC_USER}"
      password: "${PROMETHEUS_BASIC_PASSWORD}"
    static_configs:
      - targets: ["prometheus:9090"]

  - job_name: "cadvisor"
    scrape_interval: 5s
    basic_auth:
      username: "${PROMETHEUS_BASIC_USER}"
      password: "${PROMETHEUS_BASIC_PASSWORD}"
    static_configs:
      - targets: ["cadvisor-auth:8080"]

  - job_name: "node-exporter"
    scrape_interval: 5s
    static_configs:
      - targets: ["node-exporter:9100"]
EOF

cat > "${grafana_datasource_config}" <<EOF
apiVersion: 1

deleteDatasources:
  - name: prometheus-1
    orgId: 1

datasources:
  - name: prometheus
    uid: prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
    editable: true
    basicAuth: true
    basicAuthUser: ${PROMETHEUS_BASIC_USER}
    secureJsonData:
      basicAuthPassword: ${PROMETHEUS_BASIC_PASSWORD}
EOF

chmod 0644 \
  "${prometheus_config}" \
  "${prometheus_web_config}" \
  "${cadvisor_htpasswd_file}" \
  "${grafana_datasource_config}"

if [ "${quiet}" = false ]; then
  echo "Monitoring config written to ${monitoring_dir}"
  echo "Grafana: username=${GRAFANA_ADMIN_USER} password=${GRAFANA_ADMIN_PASSWORD}"
  echo "Prometheus/cAdvisor: username=${PROMETHEUS_BASIC_USER} password=${PROMETHEUS_BASIC_PASSWORD}"
fi
