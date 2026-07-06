#!/usr/bin/env python3
import concurrent.futures
import http.client
import json
import os
import socket
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit


DOCKER_SOCKET = os.environ.get("DOCKER_SOCKET", "/var/run/docker.sock")
LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "9101"))
DOCKER_TIMEOUT_SECONDS = float(os.environ.get("DOCKER_TIMEOUT_SECONDS", "3"))
REFRESH_INTERVAL_SECONDS = float(os.environ.get("REFRESH_INTERVAL_SECONDS", "5"))

cache_lock = threading.Lock()
metrics_cache = ""
last_error = ""
last_success = 0
last_refresh = 0.0


class UnixHTTPConnection(http.client.HTTPConnection):
    def __init__(self, socket_path, timeout=DOCKER_TIMEOUT_SECONDS):
        super().__init__("localhost", timeout=timeout)
        self.socket_path = socket_path

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect(self.socket_path)


def docker_get(path, timeout=DOCKER_TIMEOUT_SECONDS):
    conn = UnixHTTPConnection(DOCKER_SOCKET, timeout=timeout)
    try:
        conn.request("GET", path)
        response = conn.getresponse()
        body = response.read()
        if response.status >= 400:
            raise RuntimeError(f"Docker API returned HTTP {response.status}")
        return json.loads(body.decode())
    finally:
        conn.close()


def prometheus_escape(value):
    return str(value).replace("\\", "\\\\").replace("\n", "\\n").replace('"', '\\"')


def label(name, value):
    return f'{name}="{prometheus_escape(value)}"'


def container_name(container):
    names = container.get("Names") or []
    if names:
        return names[0].lstrip("/")
    return container.get("Id", "")[:12]


def container_ids(container_id):
    if not container_id:
        return []

    return [
        f"/system.slice/docker-{container_id}.scope",
        f"/docker/{container_id}",
        f"/docker/{container_id[:12]}",
    ]


def docker_stats(container_id):
    try:
        return docker_get(f"/containers/{container_id}/stats?stream=false")
    except Exception:
        return {}


def network_totals(stats):
    totals = {
        "receive_bytes": 0,
        "transmit_bytes": 0,
        "receive_errors": 0,
        "transmit_errors": 0,
        "receive_dropped": 0,
        "transmit_dropped": 0,
    }

    for iface in (stats.get("networks") or {}).values():
        totals["receive_bytes"] += int(iface.get("rx_bytes") or 0)
        totals["transmit_bytes"] += int(iface.get("tx_bytes") or 0)
        totals["receive_errors"] += int(iface.get("rx_errors") or 0)
        totals["transmit_errors"] += int(iface.get("tx_errors") or 0)
        totals["receive_dropped"] += int(iface.get("rx_dropped") or 0)
        totals["transmit_dropped"] += int(iface.get("tx_dropped") or 0)

    return totals


def emit_metric(lines, name, labels, value):
    label_text = ",".join(label(k, v) for k, v in labels.items())
    lines.append(f"{name}{{{label_text}}} {value}")


def base_labels(container):
    container_id = container.get("Id", "")
    labels = container.get("Labels") or {}
    return {
        "container_id": container_id,
        "container_short_id": container_id[:12],
        "container_name": container_name(container),
        "image": container.get("Image", ""),
        "state": container.get("State", ""),
        "compose_project": labels.get("com.docker.compose.project", ""),
        "compose_service": labels.get("com.docker.compose.service", ""),
    }


def container_metric_lines(container):
    container_id = container.get("Id", "")
    labels = base_labels(container)
    lines = []

    for cadvisor_id in container_ids(container_id):
        metric_labels = {"id": cadvisor_id, **labels}
        emit_metric(lines, "autografana_container_info", metric_labels, 1)

    stats = docker_stats(container_id)
    totals = network_totals(stats)
    emit_metric(lines, "autografana_container_network_receive_bytes_total", labels, totals["receive_bytes"])
    emit_metric(lines, "autografana_container_network_transmit_bytes_total", labels, totals["transmit_bytes"])
    emit_metric(lines, "autografana_container_network_receive_errors_total", labels, totals["receive_errors"])
    emit_metric(lines, "autografana_container_network_transmit_errors_total", labels, totals["transmit_errors"])
    emit_metric(lines, "autografana_container_network_receive_packets_dropped_total", labels, totals["receive_dropped"])
    emit_metric(lines, "autografana_container_network_transmit_packets_dropped_total", labels, totals["transmit_dropped"])

    return lines


def metric_headers():
    return [
        "# HELP autografana_container_exporter_last_refresh_success Whether the last Docker refresh succeeded.",
        "# TYPE autografana_container_exporter_last_refresh_success gauge",
        "# HELP autografana_container_exporter_last_refresh_timestamp_seconds Unix timestamp of the last Docker refresh attempt.",
        "# TYPE autografana_container_exporter_last_refresh_timestamp_seconds gauge",
        "# HELP autografana_container_info Docker container metadata keyed by cAdvisor cgroup id.",
        "# TYPE autografana_container_info gauge",
        "# HELP autografana_container_network_receive_bytes_total Docker container network receive bytes.",
        "# TYPE autografana_container_network_receive_bytes_total counter",
        "# HELP autografana_container_network_transmit_bytes_total Docker container network transmit bytes.",
        "# TYPE autografana_container_network_transmit_bytes_total counter",
        "# HELP autografana_container_network_receive_errors_total Docker container network receive errors.",
        "# TYPE autografana_container_network_receive_errors_total counter",
        "# HELP autografana_container_network_transmit_errors_total Docker container network transmit errors.",
        "# TYPE autografana_container_network_transmit_errors_total counter",
        "# HELP autografana_container_network_receive_packets_dropped_total Docker container network receive dropped packets.",
        "# TYPE autografana_container_network_receive_packets_dropped_total counter",
        "# HELP autografana_container_network_transmit_packets_dropped_total Docker container network transmit dropped packets.",
        "# TYPE autografana_container_network_transmit_packets_dropped_total counter",
    ]


def render_metrics():
    containers = docker_get("/containers/json?all=1")
    lines = metric_headers()

    if containers:
        workers = min(16, len(containers))
        with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as executor:
            futures = [executor.submit(container_metric_lines, container) for container in containers]
            done, _ = concurrent.futures.wait(futures, timeout=DOCKER_TIMEOUT_SECONDS + 2)
            for future in done:
                try:
                    lines.extend(future.result())
                except Exception:
                    continue

    return "\n".join(lines) + "\n"


def status_metrics():
    with cache_lock:
        success = last_success
        refreshed = last_refresh
        error = last_error

    labels = {"error": error[:200]}
    label_text = ",".join(label(k, v) for k, v in labels.items())
    return (
        f'autografana_container_exporter_last_refresh_success{{{label_text}}} {success}\n'
        f"autografana_container_exporter_last_refresh_timestamp_seconds {refreshed:.0f}\n"
    )


def refresh_once():
    global last_error, last_success, last_refresh, metrics_cache

    now = time.time()
    try:
        payload = render_metrics()
        with cache_lock:
            metrics_cache = payload
            last_error = ""
            last_success = 1
            last_refresh = now
    except Exception as exc:
        with cache_lock:
            last_error = str(exc)
            last_success = 0
            last_refresh = now


def refresh_loop():
    while True:
        started = time.monotonic()
        refresh_once()
        elapsed = time.monotonic() - started
        time.sleep(max(1, REFRESH_INTERVAL_SECONDS - elapsed))


def current_metrics():
    with cache_lock:
        payload = metrics_cache

    if not payload:
        payload = "\n".join(metric_headers()) + "\n"

    return payload + status_metrics()


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        path = urlsplit(self.path).path
        if path == "/healthz":
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"ok\n")
            return

        if path != "/metrics":
            self.send_response(404)
            self.end_headers()
            return

        payload = current_metrics().encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, fmt, *args):
        return


if __name__ == "__main__":
    threading.Thread(target=refresh_loop, daemon=True).start()
    server = ThreadingHTTPServer(("0.0.0.0", LISTEN_PORT), Handler)
    server.serve_forever()
