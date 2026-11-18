"""
Pruebas de integración para:
- Pilar 1: Targets Prometheus / OpenTelemetry multipuerto, rutas personalizadas, HTTP/HTTPS,
  generación de `targets_dynamic.json` y autodetección en vivo de firma (ej. ORA-TUI).
- Pilar 2: Sistema dual de Plantillas Reutilizables (`TelemetryProfile`, incluyendo pack `oratui_oracle`)
  + Gráficas PromQL individuales por servidor (`AssetCustomChart`) y promoción a plantilla.
"""

import json
import os
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Dict

from fastapi.testclient import TestClient


SAMPLE_ORATUI_METRICS = """# HELP oratui_info Static metadata about the monitored Oracle host and cluster
# TYPE oratui_info gauge
oratui_info{version="1.10.0",host="ora-rac01",cluster="racprod",topology="RAC",oracle_version="19.24"} 1
# HELP oratui_instance_up Oracle Database instance status (1=OPEN, 0.5=MOUNTED, 0=DOWN)
# TYPE oratui_instance_up gauge
oratui_instance_up{host="ora-rac01",cluster="racprod",instance="PROD1",db_name="PROD",open_mode="READ WRITE"} 1
# HELP oratui_tablespace_used_percent Real used percentage of tablespace considering AUTOEXTEND MAXBYTES
# TYPE oratui_tablespace_used_percent gauge
oratui_tablespace_used_percent{host="ora-rac01",cluster="racprod",tablespace="USERS",autoextend="YES"} 88.4
oratui_tablespace_used_percent{host="ora-rac01",cluster="racprod",tablespace="SYSTEM",autoextend="YES"} 74.2
# HELP oratui_sessions_active_total Number of ACTIVE user sessions
# TYPE oratui_sessions_active_total gauge
oratui_sessions_active_total{host="ora-rac01",cluster="racprod"} 14
# HELP oratui_sessions_blocking_locks_total Number of sessions involved in TX/TM blocking locks
# TYPE oratui_sessions_blocking_locks_total gauge
oratui_sessions_blocking_locks_total{host="ora-rac01",cluster="racprod"} 0
"""


class _MockOraTuiHandler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:  # noqa: N802
        if self.path == "/custom-otel/metrics":
            body = SAMPLE_ORATUI_METRICS.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, format: str, *args) -> None:  # noqa: A002
        return


def test_custom_port_oratui_target_autodetection_and_file_sd(
    client: TestClient,
    editor_headers: Dict[str, str],
) -> None:
    """
    Verifica que:
    1. Se puede dar de alta un servidor Linux+Oracle y conectarle un agente OpenTelemetry/Prometheus
       en un puerto no estándar y ruta personalizada (`/custom-otel/metrics`).
    2. El endpoint `/probe` detecta la firma `oratui_oracle` y sus familias de métricas reales.
    3. `targets_dynamic.json` recibe `__scheme__`, `__metrics_path__`, `__scrape_interval__` y `asset_code`.
    4. La vista de telemetría activa automáticamente el pack `oratui_oracle` junto a `system_base`.
    """
    server = ThreadingHTTPServer(("127.0.0.1", 0), _MockOraTuiHandler)
    ephemeral_port = server.server_address[1]
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()

    try:
        create_host = client.post(
            "/api/v1/network-hosts/hosts",
            headers=editor_headers,
            json={
                "code": "ORA-RAC-01",
                "name": "Nodo 1 Cluster Oracle RAC 19c",
                "hostname": "ora-rac01",
                "fqdn": "ora-rac01.corp.local",
                "primary_ip": "127.0.0.1",
                "asset_class": "physical_server",
                "os_or_firmware": "Oracle Linux 9.4",
                "enable_icmp_ping": False,
                "exporters": [],
            },
        )
        assert create_host.status_code == 200, create_host.text
        asset_id = create_host.json()["created_host"]["asset_id"]

        # 1. Probar en vivo el puerto dinámico con ruta custom antes de guardar
        probe_resp = client.post(
            "/api/v1/network-hosts/telemetry-targets/probe",
            headers=editor_headers,
            json={
                "asset_id": asset_id,
                "target_host": "127.0.0.1",
                "port": ephemeral_port,
                "metrics_path": "/custom-otel/metrics",
                "scheme": "http",
            },
        )
        assert probe_resp.status_code == 200, probe_resp.text
        pr = probe_resp.json()
        assert pr["ok"] is True
        assert pr["detected_exporter_type"] == "oratui_oracle"
        assert pr["suggested_profile_code"] == "oratui_oracle"
        assert pr["families_count"] >= 5
        assert "ORA-TUI 1.10.0" in pr["signature_detail"]

        # 2. Guardar target con exporter_type='custom_prometheus' y auto_probe=True -> debe autodetectar 'oratui_oracle'
        tgt_resp = client.post(
            f"/api/v1/network-hosts/assets/{asset_id}/telemetry-targets",
            headers=editor_headers,
            json={
                "name": "ORA-TUI Daemon Puerto Custom",
                "exporter_type": "custom_prometheus",
                "mode": "pull",
                "target_host": "127.0.0.1",
                "port": ephemeral_port,
                "metrics_path": "/custom-otel/metrics",
                "scheme": "http",
                "scrape_interval": "10s",
                "extra_labels": {"rac_cluster": "racprod"},
                "auto_probe": True,
            },
        )
        assert tgt_resp.status_code == 200, tgt_resp.text
        tgt_body = tgt_resp.json()
        assert tgt_body["target"]["exporter_type"] == "oratui_oracle"
        assert tgt_body["target"]["port"] == ephemeral_port
        assert tgt_body["target"]["metrics_path"] == "/custom-otel/metrics"

        # 3. Verificar generación de targets_dynamic.json con meta-etiquetas de Prometheus
        sd_path = Path(os.environ["RACKDOC_DATA_DIR"]) / "prometheus" / "targets_dynamic.json"
        assert sd_path.exists()
        sd_entries = json.loads(sd_path.read_text(encoding="utf-8"))
        ora_entry = next(
            e for e in sd_entries if f"127.0.0.1:{ephemeral_port}" in e["targets"]
        )
        assert ora_entry["labels"]["__scheme__"] == "http"
        assert ora_entry["labels"]["__metrics_path__"] == "/custom-otel/metrics"
        assert ora_entry["labels"]["__scrape_interval__"] == "10s"
        assert ora_entry["labels"]["asset_code"] == "ORA-RAC-01"
        assert ora_entry["labels"]["exporter_type"] == "oratui_oracle"
        assert ora_entry["labels"]["rac_cluster"] == "racprod"

        # 4. Verificar autocompletado de métricas disponibles (con fallback en vivo sobre el target)
        avail_resp = client.get(
            f"/api/v1/network-hosts/telemetry/{asset_id}/available-metrics",
            headers=editor_headers,
        )
        assert avail_resp.status_code == 200, avail_resp.text
        avail = avail_resp.json()
        metric_names = {m["name"] for m in avail["metrics"]}
        assert "oratui_tablespace_used_percent" in metric_names
        assert "oratui_sessions_active_total" in metric_names

        # 5. Verificar que la telemetría del activo activa automáticamente 'system_base' + 'oratui_oracle'
        tel_resp = client.get(
            f"/api/v1/network-hosts/telemetry/{asset_id}",
            headers=editor_headers,
        )
        assert tel_resp.status_code == 200, tel_resp.text
        tel = tel_resp.json()
        active_codes = [p["code"] for p in tel["active_profiles"]]
        assert "system_base" in active_codes
        assert "oratui_oracle" in active_codes
        ora_prof = next(p for p in tel["active_profiles"] if p["code"] == "oratui_oracle")
        assert len(ora_prof["evaluated_kpis"]) == 6
        assert len(ora_prof["evaluated_panels"]) == 6
    finally:
        server.shutdown()
        server.server_close()


def test_dual_custom_charts_per_server_and_reusable_profiles(
    client: TestClient,
    editor_headers: Dict[str, str],
) -> None:
    """
    Verifica el modelo dual solicitado:
    - Gráficas exclusivas de un servidor concreto (`AssetCustomChart`).
    - Plantillas reutilizables (`TelemetryProfile`) asignables a varios servidores.
    - Promoción de una gráfica individual a plantilla reutilizable generalizando `{{asset_code}}`.
    """
    h1 = client.post(
        "/api/v1/network-hosts/hosts",
        headers=editor_headers,
        json={
            "code": "SRV-CUSTOM-A",
            "name": "Servidor Aplicaciones A",
            "hostname": "srv-custom-a",
            "primary_ip": "10.252.90.11",
            "enable_icmp_ping": False,
        },
    ).json()["created_host"]["asset_id"]

    h2 = client.post(
        "/api/v1/network-hosts/hosts",
        headers=editor_headers,
        json={
            "code": "SRV-CUSTOM-B",
            "name": "Servidor Aplicaciones B",
            "hostname": "srv-custom-b",
            "primary_ip": "10.252.90.12",
            "enable_icmp_ping": False,
        },
    ).json()["created_host"]["asset_id"]

    # 1. Crear gráfica exclusiva solo para SRV-CUSTOM-A
    cc_resp = client.post(
        f"/api/v1/network-hosts/assets/{h1}/custom-charts",
        headers=editor_headers,
        json={
            "title": "Heap JVM Servicio Pagos (MB)",
            "unit": "MB",
            "chart_type": "line",
            "promql_a": 'jvm_memory_used_bytes{asset_code="SRV-CUSTOM-A",area="heap"} / 1048576',
            "label_a": "Heap Usado MB",
            "color_a": "#10B981",
            "warn_threshold": 1536.0,
            "crit_threshold": 1900.0,
        },
    )
    assert cc_resp.status_code == 200, cc_resp.text
    chart_id = cc_resp.json()["custom_chart"]["id"]
    assert len(cc_resp.json()["telemetry"]["custom_charts"]) == 1

    # SRV-CUSTOM-B NO debe tener esa gráfica individual
    tel_b_initial = client.get(
        f"/api/v1/network-hosts/telemetry/{h2}", headers=editor_headers
    ).json()
    assert len(tel_b_initial["custom_charts"]) == 0

    # 2. Promover la gráfica individual de SRV-CUSTOM-A a una nueva Plantilla Reutilizable
    prom_resp = client.post(
        f"/api/v1/network-hosts/custom-charts/{chart_id}/promote-to-profile",
        headers=editor_headers,
        json={
            "new_profile_name": "Pack Microservicios JVM",
            "new_profile_code": "jvm_microservices",
            "assign_to_current_asset": True,
        },
    )
    assert prom_resp.status_code == 200, prom_resp.text
    new_prof = prom_resp.json()["profile"]
    assert new_prof["code"] == "jvm_microservices"
    # El literal "SRV-CUSTOM-A" debe haberse generalizado a "{{asset_code}}"
    promoted_query = new_prof["panels"][0]["queries"][0]["promql"]
    assert "{{asset_code}}" in promoted_query
    assert "SRV-CUSTOM-A" not in promoted_query

    # 3. Asignar la nueva plantilla reutilizable también a SRV-CUSTOM-B con un clic (/toggle)
    tog_resp = client.post(
        f"/api/v1/network-hosts/assets/{h2}/telemetry-profiles/{new_prof['id']}/toggle",
        headers=editor_headers,
    )
    assert tog_resp.status_code == 200, tog_resp.text
    assert tog_resp.json()["assigned"] is True
    active_b_codes = [p["code"] for p in tog_resp.json()["telemetry"]["active_profiles"]]
    assert "jvm_microservices" in active_b_codes

    # Verificar que al renderizarse en SRV-CUSTOM-B sustituye {{asset_code}} por SRV-CUSTOM-B
    jvm_prof_b = next(
        p for p in tog_resp.json()["telemetry"]["active_profiles"] if p["code"] == "jvm_microservices"
    )
    assert 'asset_code="SRV-CUSTOM-B"' in jvm_prof_b["evaluated_panels"][0]["promql_display"]

    # 4. Las plantillas builtin están protegidas frente a borrado accidental
    all_profs = client.get("/api/v1/network-hosts/telemetry-profiles", headers=editor_headers).json()["profiles"]
    builtin_id = next(p["id"] for p in all_profs if p["is_builtin"])
    assert (
        client.delete(
            f"/api/v1/network-hosts/telemetry-profiles/{builtin_id}",
            headers=editor_headers,
        ).status_code
        == 400
    )

    # 5. Borrar gráfica individual y plantilla personalizada funciona limpiamente
    assert (
        client.delete(
            f"/api/v1/network-hosts/custom-charts/{chart_id}",
            headers=editor_headers,
        ).status_code
        == 200
    )
    assert (
        client.delete(
            f"/api/v1/network-hosts/telemetry-profiles/{new_prof['id']}",
            headers=editor_headers,
        ).status_code
        == 200
    )
