#!/usr/bin/env python3
import http.client
import json
import os
import socket
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit


DOCKER_SOCKET = os.environ.get("DOCKER_SOCKET", "/var/run/docker.sock")
LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "9101"))


class UnixHTTPConnection(http.client.HTTPConnection):
    def __init__(self, socket_path):
        super().__init__("localhost")
        self.socket_path = socket_path

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(self.socket_path)


def docker_get(path):
    conn = UnixHTTPConnection(DOCKER_SOCKET)
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

    ids = [
        f"/system.slice/docker-{container_id}.scope",
        f"/docker/{container_id}",
        f"/docker/{container_id[:12]}",
    ]

    return ids


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


def metrics():
    containers = docker_get("/containers/json?all=1")
    lines = [
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

    for container in containers:
        container_id = container.get("Id", "")
        labels = container.get("Labels") or {}
        base_labels = {
            "container_id": container_id,
            "container_short_id": container_id[:12],
            "container_name": container_name(container),
            "image": container.get("Image", ""),
            "state": container.get("State", ""),
            "compose_project": labels.get("com.docker.compose.project", ""),
            "compose_service": labels.get("com.docker.compose.service", ""),
        }

        for cadvisor_id in container_ids(container_id):
            metric_labels = {"id": cadvisor_id, **base_labels}
            label_text = ",".join(label(k, v) for k, v in metric_labels.items())
            lines.append(f"autografana_container_info{{{label_text}}} 1")

        stats = docker_stats(container_id)
        totals = network_totals(stats)
        network_labels = base_labels.copy()
        emit_metric(
            lines,
            "autografana_container_network_receive_bytes_total",
            network_labels,
            totals["receive_bytes"],
        )
        emit_metric(
            lines,
            "autografana_container_network_transmit_bytes_total",
            network_labels,
            totals["transmit_bytes"],
        )
        emit_metric(
            lines,
            "autografana_container_network_receive_errors_total",
            network_labels,
            totals["receive_errors"],
        )
        emit_metric(
            lines,
            "autografana_container_network_transmit_errors_total",
            network_labels,
            totals["transmit_errors"],
        )
        emit_metric(
            lines,
            "autografana_container_network_receive_packets_dropped_total",
            network_labels,
            totals["receive_dropped"],
        )
        emit_metric(
            lines,
            "autografana_container_network_transmit_packets_dropped_total",
            network_labels,
            totals["transmit_dropped"],
        )

    return "\n".join(lines) + "\n"


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

        try:
            payload = metrics().encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
        except Exception as exc:
            payload = f"container-name-exporter error: {exc}\n".encode()
            self.send_response(500)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

    def log_message(self, fmt, *args):
        return


if __name__ == "__main__":
    server = ThreadingHTTPServer(("0.0.0.0", LISTEN_PORT), Handler)
    server.serve_forever()
