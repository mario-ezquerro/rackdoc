"""
Gestión avanzada de Targets Prometheus/OpenTelemetry multipuerto, autodetección de agentes
(incluyendo ORA-TUI para Oracle RAC/Single & Linux SAN), Plantillas Reutilizables de Gráficas
(`TelemetryProfile`) y Gráficas PromQL individuales por servidor (`AssetCustomChart`).
"""

import json
import logging
import math
import os
import re
import ssl
import time
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional, Set, Tuple

from sqlalchemy.orm import Session, joinedload

from ..models import (
    AssetCustomChart,
    AssetTelemetryTarget,
    CmdbAsset,
    HostGroup,
    MonitoredServiceCheck,
    TelemetryProfile,
)
from ..security import decrypt_vault_secret, encrypt_vault_secret
from ..time_utils import utcnow

logger = logging.getLogger(__name__)

PROMETHEUS_URL = os.getenv("PROMETHEUS_URL", "http://rackdoc-prometheus:9090").rstrip("/")

SERIES_COLOR_PALETTE: List[str] = [
    "#3B82F6",  # Azul
    "#A855F7",  # Púrpura
    "#14B8A6",  # Teal
    "#F59E0B",  # Ámbar
    "#EF4444",  # Coral/Rojo
    "#06B6D4",  # Cyan
    "#10B981",  # Esmeralda
    "#EC4899",  # Rosa
]

EXPORTER_PRESETS: List[Dict[str, Any]] = [
    {
        "exporter_type": "oratui_oracle",
        "label": "ORA-TUI Oracle DB, RAC & Linux SAN (:9161)",
        "default_port": 9161,
        "default_path": "/metrics",
        "default_scheme": "http",
        "default_mode": "pull",
        "suggested_profile": "oratui_oracle",
        "description": "Demonio OpenTelemetry/Prometheus de ORA-TUI (--opentelemetry --daemon --otel-port=9161).",
    },
    {
        "exporter_type": "node_exporter",
        "label": "Linux Prometheus Node Exporter (:9100)",
        "default_port": 9100,
        "default_path": "/metrics",
        "default_scheme": "http",
        "default_mode": "pull",
        "suggested_profile": "system_base",
        "description": "Métricas de CPU, RAM, carga, filesystems y red en servidores Linux/Proxmox.",
    },
    {
        "exporter_type": "windows_exporter",
        "label": "Windows Prometheus Exporter (:9182)",
        "default_port": 9182,
        "default_path": "/metrics",
        "default_scheme": "http",
        "default_mode": "pull",
        "suggested_profile": "system_base",
        "description": "Métricas WMI/Performance Counters en Windows Server (AD, IIS, SQL, Hyper-V).",
    },
    {
        "exporter_type": "otel_collector",
        "label": "OpenTelemetry Collector Pull (:8889)",
        "default_port": 8889,
        "default_path": "/metrics",
        "default_scheme": "http",
        "default_mode": "pull",
        "suggested_profile": "otel_collector",
        "description": "Exporter Prometheus de OpenTelemetry Collector en puerto personalizado.",
    },
    {
        "exporter_type": "otlp_push",
        "label": "OpenTelemetry Push OTLP HTTP ( hacia RackDoc )",
        "default_port": 4318,
        "default_path": "/api/v1/automation/otlp/v1/metrics",
        "default_scheme": "http",
        "default_mode": "push_otlp",
        "suggested_profile": "otel_collector",
        "description": "El agente remoto envía métricas por OTLP HTTP Push a la pasarela de RackDoc.",
    },
    {
        "exporter_type": "postgres_exporter",
        "label": "PostgreSQL Exporter (:9187)",
        "default_port": 9187,
        "default_path": "/metrics",
        "default_scheme": "http",
        "default_mode": "pull",
        "suggested_profile": "postgres_db",
        "description": "Sesiones, transacciones, locks, replicación y tamaño de bases PostgreSQL.",
    },
    {
        "exporter_type": "nginx_exporter",
        "label": "Nginx Prometheus Exporter (:9113)",
        "default_port": 9113,
        "default_path": "/metrics",
        "default_scheme": "http",
        "default_mode": "pull",
        "suggested_profile": "system_base",
        "description": "Conexiones activas y peticiones HTTP/s de nginx-prometheus-exporter.",
    },
    {
        "exporter_type": "haproxy_stats",
        "label": "HAProxy Prometheus Stats (:8404)",
        "default_port": 8404,
        "default_path": "/metrics",
        "default_scheme": "http",
        "default_mode": "pull",
        "suggested_profile": "system_base",
        "description": "Métricas nativas de frontends, backends y colas HAProxy.",
    },
    {
        "exporter_type": "docker_engine",
        "label": "Docker Engine / cAdvisor (:9323)",
        "default_port": 9323,
        "default_path": "/metrics",
        "default_scheme": "http",
        "default_mode": "pull",
        "suggested_profile": "system_base",
        "description": "Métricas de motor Docker o contenedores cAdvisor.",
    },
    {
        "exporter_type": "custom_prometheus",
        "label": "Exporter / Agente Personalizado (Puerto y Path libres)",
        "default_port": 9100,
        "default_path": "/metrics",
        "default_scheme": "http",
        "default_mode": "pull",
        "suggested_profile": "system_base",
        "description": "Cualquier endpoint Prometheus / OpenMetrics en puerto, ruta o HTTPS a medida.",
    },
]


BUILTIN_TELEMETRY_PROFILES: List[Dict[str, Any]] = [
    {
        "code": "system_base",
        "name": "Sistema, Red & Heartbeat",
        "description": "Paneles universales de CPU/RAM, latencia ICMP/HTTP, tráfico de red RX/TX y ocupación de almacenamiento.",
        "icon_key": "memory",
        "is_builtin": True,
        "auto_match_exporter_types": [
            "node_exporter",
            "windows_exporter",
            "nginx_exporter",
            "haproxy_stats",
            "docker_engine",
            "custom_prometheus",
        ],
        "kpi_badges": [
            {
                "id": "host_up",
                "label": "Estado Host",
                "promql": 'max(rackdoc_host_up{asset_code="{{asset_code}}"})',
                "unit": "",
                "mode": "state_up",
            },
            {
                "id": "ping_rtt",
                "label": "Latencia RTT",
                "promql": 'avg(rackdoc_host_ping_latency_ms{asset_code="{{asset_code}}"})',
                "unit": "ms",
                "warn_above": 80.0,
                "crit_above": 200.0,
            },
        ],
        "panels": [
            {
                "id": "sys_cpu_ram",
                "title": "1. USO DE CPU (%) & MEMORIA RAM (%)",
                "unit": "%",
                "chart_type": "line",
                "warn_threshold": 75.0,
                "crit_threshold": 90.0,
                "legend_label": "",
                "queries": [
                    {
                        "label": "CPU %",
                        "promql": (
                            '100 - (avg(rate(node_cpu_seconds_total{asset_code="{{asset_code}}",mode="idle"}[2m])) * 100) '
                            'or 100 - (avg(rate(node_cpu_seconds_total{instance=~"{{instance_regex}}",mode="idle"}[2m])) * 100) '
                            'or 100 - (avg(rate(windows_cpu_time_total{asset_code="{{asset_code}}",mode="idle"}[2m])) * 100) '
                            'or max(oratui_os_metric_used_percent{asset_code="{{asset_code}}",category=~"(?i)cpu.*"}) '
                            'or rackdoc_host_cpu_usage_percent{asset_code="{{asset_code}}"}'
                        ),
                        "color_hex": "#3B82F6",
                    },
                    {
                        "label": "RAM %",
                        "promql": (
                            '(1 - (node_memory_MemAvailable_bytes{asset_code="{{asset_code}}"} / node_memory_MemTotal_bytes{asset_code="{{asset_code}}"})) * 100 '
                            'or (1 - (node_memory_MemAvailable_bytes{instance=~"{{instance_regex}}"} / node_memory_MemTotal_bytes{instance=~"{{instance_regex}}"})) * 100 '
                            'or (1 - (windows_os_physical_memory_free_bytes{asset_code="{{asset_code}}"} / windows_cs_physical_memory_bytes{asset_code="{{asset_code}}"})) * 100 '
                            'or max(oratui_os_metric_used_percent{asset_code="{{asset_code}}",category=~"(?i)mem.*|ram.*"}) '
                            'or rackdoc_host_ram_usage_percent{asset_code="{{asset_code}}"}'
                        ),
                        "color_hex": "#A855F7",
                    },
                ],
            },
            {
                "id": "sys_latency",
                "title": "2. LATENCIA DEL HEARTBEAT ICMP/HTTP (MS)",
                "unit": "ms",
                "chart_type": "line",
                "warn_threshold": 80.0,
                "crit_threshold": 200.0,
                "legend_label": "",
                "queries": [
                    {
                        "label": "RTT ms",
                        "promql": 'rackdoc_host_ping_latency_ms{asset_code="{{asset_code}}"} or max(rackdoc_service_latency_ms{asset_code="{{asset_code}}"})',
                        "color_hex": "#14B8A6",
                    },
                ],
            },
            {
                "id": "sys_net_rx_tx",
                "title": "3. TRÁFICO DE RED RX / TX (MBPS)",
                "unit": "Mbps",
                "chart_type": "line",
                "warn_threshold": None,
                "crit_threshold": None,
                "legend_label": "",
                "queries": [
                    {
                        "label": "RX (Mbps)",
                        "promql": (
                            'sum(rate(node_network_receive_bytes_total{asset_code="{{asset_code}}",device!~"lo|veth.*"}[2m])) * 8 / 1000000 '
                            'or sum(rate(node_network_receive_bytes_total{instance=~"{{instance_regex}}",device!~"lo|veth.*"}[2m])) * 8 / 1000000 '
                            'or sum(rackdoc_switch_port_rx_mbps{switch_code="{{asset_code}}"})'
                        ),
                        "color_hex": "#06B6D4",
                    },
                    {
                        "label": "TX (Mbps)",
                        "promql": (
                            'sum(rate(node_network_transmit_bytes_total{asset_code="{{asset_code}}",device!~"lo|veth.*"}[2m])) * 8 / 1000000 '
                            'or sum(rate(node_network_transmit_bytes_total{instance=~"{{instance_regex}}",device!~"lo|veth.*"}[2m])) * 8 / 1000000 '
                            'or sum(rackdoc_switch_port_tx_mbps{switch_code="{{asset_code}}"})'
                        ),
                        "color_hex": "#F59E0B",
                    },
                ],
            },
            {
                "id": "sys_disk_usage",
                "title": "4. OCUPACIÓN DE DISCO RAÍZ (%) & SERVICIOS",
                "unit": "%",
                "chart_type": "line",
                "warn_threshold": 80.0,
                "crit_threshold": 90.0,
                "legend_label": "",
                "queries": [
                    {
                        "label": "Disco / (%)",
                        "promql": (
                            '(1 - (node_filesystem_avail_bytes{asset_code="{{asset_code}}",mountpoint="/"} / node_filesystem_size_bytes{asset_code="{{asset_code}}",mountpoint="/"})) * 100 '
                            'or (1 - (node_filesystem_avail_bytes{instance=~"{{instance_regex}}",mountpoint="/"} / node_filesystem_size_bytes{instance=~"{{instance_regex}}",mountpoint="/"})) * 100 '
                            'or max(oratui_filesystem_used_percent{asset_code="{{asset_code}}",mountpoint="/"}) '
                            'or rackdoc_host_disk_usage_percent{asset_code="{{asset_code}}"}'
                        ),
                        "color_hex": "#EF4444",
                    },
                ],
            },
        ],
    },
    {
        "code": "oratui_oracle",
        "name": "Oracle DB, RAC & Linux SAN (ORA-TUI)",
        "description": (
            "Pack oficial de telemetría para servidores con ORA-TUI (--opentelemetry): "
            "Instancias Oracle, Clusterware CRS/ASM, Tablespaces, FRA, Bloqueos TX/TM, "
            "Data Guard Lag, RMAN, SQL Plan Flips y Multipath SAN."
        ),
        "icon_key": "storage",
        "is_builtin": True,
        "auto_match_exporter_types": ["oratui_oracle"],
        "kpi_badges": [
            {
                "id": "ora_inst_up",
                "label": "Instancias Oracle",
                "promql": 'min(oratui_instance_up{asset_code="{{asset_code}}"}) or min(oratui_instance_up{instance=~"{{instance_regex}}"})',
                "unit": "",
                "mode": "oracle_instance",
            },
            {
                "id": "ora_crs_up",
                "label": "Clusterware / CRS",
                "promql": 'min(oratui_cluster_daemon_up{asset_code="{{asset_code}}"}) or min(oratui_cluster_daemon_up{instance=~"{{instance_regex}}"})',
                "unit": "",
                "mode": "state_up",
            },
            {
                "id": "ora_lsnr_up",
                "label": "Listeners",
                "promql": 'min(oratui_listener_up{asset_code="{{asset_code}}"}) or min(oratui_listener_up{instance=~"{{instance_regex}}"})',
                "unit": "",
                "mode": "state_up",
            },
            {
                "id": "ora_san_ok",
                "label": "SAN Multipath",
                "promql": 'min(oratui_storage_path_healthy{asset_code="{{asset_code}}"}) or min(oratui_storage_path_healthy{instance=~"{{instance_regex}}"})',
                "unit": "",
                "mode": "state_up",
            },
            {
                "id": "ora_locks",
                "label": "Locks TX/TM",
                "promql": 'sum(oratui_sessions_blocking_locks_total{asset_code="{{asset_code}}"}) or sum(oratui_sessions_blocking_locks_total{instance=~"{{instance_regex}}"})',
                "unit": "",
                "warn_above": 1.0,
                "crit_above": 3.0,
            },
            {
                "id": "ora_errors",
                "label": "Errores ORA-*",
                "promql": 'sum(oratui_alert_ora_errors_total{asset_code="{{asset_code}}"}) or sum(oratui_alert_ora_errors_total{instance=~"{{instance_regex}}"})',
                "unit": "",
                "warn_above": 1.0,
                "crit_above": 5.0,
            },
        ],
        "panels": [
            {
                "id": "ora_sessions_locks",
                "title": "1. SESIONES ACTIVAS VS BLOQUEOS TX/TM (GV$SESSION)",
                "unit": "ses",
                "chart_type": "line",
                "warn_threshold": None,
                "crit_threshold": None,
                "legend_label": "",
                "queries": [
                    {
                        "label": "Sesiones Activas",
                        "promql": 'sum(oratui_sessions_active_total{asset_code="{{asset_code}}"}) or sum(oratui_sessions_active_total{instance=~"{{instance_regex}}"})',
                        "color_hex": "#3B82F6",
                    },
                    {
                        "label": "Locks Bloqueantes",
                        "promql": 'sum(oratui_sessions_blocking_locks_total{asset_code="{{asset_code}}"}) or sum(oratui_sessions_blocking_locks_total{instance=~"{{instance_regex}}"})',
                        "color_hex": "#EF4444",
                    },
                ],
            },
            {
                "id": "ora_tablespaces",
                "title": "2. TOP TABLESPACES USADOS (% CON AUTOEXTEND REAL)",
                "unit": "%",
                "chart_type": "multi_line",
                "warn_threshold": 85.0,
                "crit_threshold": 92.0,
                "legend_label": "tablespace",
                "queries": [
                    {
                        "label": "Tablespace",
                        "promql": 'topk(6, oratui_tablespace_used_percent{asset_code="{{asset_code}}"}) or topk(6, oratui_tablespace_used_percent{instance=~"{{instance_regex}}"})',
                        "color_hex": "#A855F7",
                    },
                ],
            },
            {
                "id": "ora_fra_asm",
                "title": "3. FAST RECOVERY AREA (FRA %) & ASM DISKGROUPS (%)",
                "unit": "%",
                "chart_type": "multi_line",
                "warn_threshold": 85.0,
                "crit_threshold": 90.0,
                "legend_label": "diskgroup",
                "queries": [
                    {
                        "label": "FRA %",
                        "promql": 'max by (instance) (oratui_instance_fra_used_percent{asset_code="{{asset_code}}"}) or max by (instance) (oratui_instance_fra_used_percent{instance=~"{{instance_regex}}"})',
                        "color_hex": "#F59E0B",
                    },
                    {
                        "label": "ASM",
                        "promql": 'oratui_asm_diskgroup_used_percent{asset_code="{{asset_code}}"} or oratui_asm_diskgroup_used_percent{instance=~"{{instance_regex}}"}',
                        "color_hex": "#14B8A6",
                    },
                ],
            },
            {
                "id": "ora_dataguard_lag",
                "title": "4. DATA GUARD APPLY & TRANSPORT LAG (SEGUNDOS)",
                "unit": "s",
                "chart_type": "line",
                "warn_threshold": 120.0,
                "crit_threshold": 300.0,
                "legend_label": "standby_db",
                "queries": [
                    {
                        "label": "Apply Lag (s)",
                        "promql": 'max(oratui_dataguard_apply_lag_seconds{asset_code="{{asset_code}}"}) or max(oratui_dataguard_apply_lag_seconds{instance=~"{{instance_regex}}"})',
                        "color_hex": "#06B6D4",
                    },
                    {
                        "label": "Transport Lag (s)",
                        "promql": 'max(oratui_dataguard_transport_lag_seconds{asset_code="{{asset_code}}"}) or max(oratui_dataguard_transport_lag_seconds{instance=~"{{instance_regex}}"})',
                        "color_hex": "#F59E0B",
                    },
                ],
            },
            {
                "id": "ora_rman_planflips",
                "title": "5. THROUGHPUT RMAN (MB/S) & SQL PLAN FLIPS (MS)",
                "unit": "",
                "chart_type": "line",
                "warn_threshold": None,
                "crit_threshold": None,
                "legend_label": "",
                "queries": [
                    {
                        "label": "RMAN MB/s",
                        "promql": 'sum(oratui_rman_channel_throughput_mbps{asset_code="{{asset_code}}"}) or sum(oratui_rman_channel_throughput_mbps{instance=~"{{instance_regex}}"})',
                        "color_hex": "#10B981",
                    },
                    {
                        "label": "SQL Flip ms",
                        "promql": 'max(oratui_sql_plan_instability_elapsed_ms{asset_code="{{asset_code}}"}) or max(oratui_sql_plan_instability_elapsed_ms{instance=~"{{instance_regex}}"})',
                        "color_hex": "#EC4899",
                    },
                ],
            },
            {
                "id": "ora_linux_fs_inodes",
                "title": "6. FILESYSTEMS LINUX/SAN & USO DE INODOS (%)",
                "unit": "%",
                "chart_type": "multi_line",
                "warn_threshold": 80.0,
                "crit_threshold": 90.0,
                "legend_label": "mountpoint",
                "queries": [
                    {
                        "label": "FS %",
                        "promql": 'topk(5, oratui_filesystem_used_percent{asset_code="{{asset_code}}"}) or topk(5, oratui_filesystem_used_percent{instance=~"{{instance_regex}}"})',
                        "color_hex": "#3B82F6",
                    },
                    {
                        "label": "Máx Inodos %",
                        "promql": 'max(oratui_filesystem_inodes_used_percent{asset_code="{{asset_code}}"}) or max(oratui_filesystem_inodes_used_percent{instance=~"{{instance_regex}}"})',
                        "color_hex": "#EF4444",
                    },
                ],
            },
        ],
    },
    {
        "code": "otel_collector",
        "name": "OpenTelemetry Collector & Host Metrics",
        "description": "Métricas estándar OpenTelemetry (hostmetricsreceiver y salud interna del colector OTel).",
        "icon_key": "hub",
        "is_builtin": True,
        "auto_match_exporter_types": ["otel_collector", "otlp_push"],
        "kpi_badges": [
            {
                "id": "otel_up",
                "label": "Colector OTel",
                "promql": 'max(up{asset_code="{{asset_code}}",exporter_type=~"otel.*"})',
                "unit": "",
                "mode": "state_up",
            },
        ],
        "panels": [
            {
                "id": "otel_cpu_mem",
                "title": "1. UTILIZACIÓN CPU & MEMORIA OPENTELEMETRY (%)",
                "unit": "%",
                "chart_type": "line",
                "warn_threshold": 75.0,
                "crit_threshold": 90.0,
                "legend_label": "",
                "queries": [
                    {
                        "label": "OTel CPU %",
                        "promql": 'avg(system_cpu_utilization{asset_code="{{asset_code}}",state!="idle"}) * 100 or avg(system_cpu_utilization_ratio{asset_code="{{asset_code}}",state!="idle"}) * 100',
                        "color_hex": "#3B82F6",
                    },
                    {
                        "label": "OTel RAM %",
                        "promql": 'avg(system_memory_utilization{asset_code="{{asset_code}}",state="used"}) * 100 or avg(system_memory_utilization_ratio{asset_code="{{asset_code}}",state="used"}) * 100',
                        "color_hex": "#A855F7",
                    },
                ],
            },
            {
                "id": "otel_pipeline_pts",
                "title": "2. PUNTOS DE MÉTRICA RECIBIDOS / RECHAZADOS (OTELCOL)",
                "unit": "pts/s",
                "chart_type": "line",
                "warn_threshold": None,
                "crit_threshold": None,
                "legend_label": "",
                "queries": [
                    {
                        "label": "Aceptados/s",
                        "promql": 'sum(rate(otelcol_receiver_accepted_metric_points_total{asset_code="{{asset_code}}"}[2m])) or sum(rate(otelcol_receiver_accepted_metric_points{asset_code="{{asset_code}}"}[2m]))',
                        "color_hex": "#10B981",
                    },
                    {
                        "label": "Rechazados/s",
                        "promql": 'sum(rate(otelcol_receiver_refused_metric_points_total{asset_code="{{asset_code}}"}[2m])) or sum(rate(otelcol_receiver_refused_metric_points{asset_code="{{asset_code}}"}[2m]))',
                        "color_hex": "#EF4444",
                    },
                ],
            },
        ],
    },
    {
        "code": "postgres_db",
        "name": "PostgreSQL Database Exporter",
        "description": "Conexiones activas, tasa de commits/rollbacks y rendimiento de caché de PostgreSQL.",
        "icon_key": "dns",
        "is_builtin": True,
        "auto_match_exporter_types": ["postgres_exporter", "postgres"],
        "kpi_badges": [
            {
                "id": "pg_up",
                "label": "PostgreSQL UP",
                "promql": 'max(pg_up{asset_code="{{asset_code}}"})',
                "unit": "",
                "mode": "state_up",
            },
        ],
        "panels": [
            {
                "id": "pg_backends",
                "title": "1. CONEXIONES ACTIVAS POR BASE DE DATOS",
                "unit": "conn",
                "chart_type": "multi_line",
                "warn_threshold": 80.0,
                "crit_threshold": 150.0,
                "legend_label": "datname",
                "queries": [
                    {
                        "label": "Backends",
                        "promql": 'topk(6, pg_stat_database_numbackends{asset_code="{{asset_code}}",datname!~"template.*"})',
                        "color_hex": "#3B82F6",
                    },
                ],
            },
            {
                "id": "pg_tx_rate",
                "title": "2. TRANSACCIONES COMMIT VS ROLLBACK (TX/S)",
                "unit": "tx/s",
                "chart_type": "line",
                "warn_threshold": None,
                "crit_threshold": None,
                "legend_label": "",
                "queries": [
                    {
                        "label": "Commits/s",
                        "promql": 'sum(rate(pg_stat_database_xact_commit{asset_code="{{asset_code}}"}[2m]))',
                        "color_hex": "#10B981",
                    },
                    {
                        "label": "Rollbacks/s",
                        "promql": 'sum(rate(pg_stat_database_xact_rollback{asset_code="{{asset_code}}"}[2m]))',
                        "color_hex": "#EF4444",
                    },
                ],
            },
        ],
    },
]


def ensure_telemetry_profiles_seeded(db: Session) -> None:
    """Siembra de forma idempotente las plantillas base de gráficas si aún no existen."""
    existing_codes = {
        row[0] for row in db.query(TelemetryProfile.code).all()
    }
    added = False
    for tpl in BUILTIN_TELEMETRY_PROFILES:
        if tpl["code"] not in existing_codes:
            db.add(
                TelemetryProfile(
                    code=tpl["code"],
                    name=tpl["name"],
                    description=tpl["description"],
                    icon_key=tpl["icon_key"],
                    is_builtin=True,
                    auto_match_exporter_types=list(tpl["auto_match_exporter_types"]),
                    assigned_asset_ids=[],
                    assigned_host_group_ids=[],
                    kpi_badges=list(tpl["kpi_badges"]),
                    panels=list(tpl["panels"]),
                )
            )
            added = True
    if added:
        db.commit()


def _resolve_asset_primary_ip(asset: CmdbAsset) -> str:
    return next(
        (ip.ip_address for ip in asset.ip_addresses if ip.is_heartbeat_ip),
        asset.ip_addresses[0].ip_address if asset.ip_addresses else "",
    )


def render_promql_for_asset(raw_promql: str, asset: CmdbAsset) -> str:
    """Sustituye variables de plantilla ({{asset_code}}, {{hostname}}, {{ip}}, {{instance_regex}}, $host) para un activo."""
    if not raw_promql:
        return ""
    hb_ip = _resolve_asset_primary_ip(asset)
    hostname = asset.hostname or asset.code.lower()
    inst_regex = f"{re.escape(hb_ip)}:.*" if hb_ip else f"{re.escape(asset.code)}.*"

    expr = raw_promql
    replacements = {
        "{{asset_code}}": asset.code,
        "{{hostname}}": hostname,
        "{{host}}": hostname,
        "{{ip}}": hb_ip,
        "{{instance_regex}}": inst_regex,
        "{{instance}}": inst_regex,
        "$asset_code": asset.code,
        "$host": hostname,
    }
    for token, val in replacements.items():
        expr = expr.replace(token, val)
    return expr.strip()


def _query_prom_instant_value(promql: str) -> Tuple[bool, Optional[float], Dict[str, str]]:
    """Consulta un valor instantáneo en Prometheus (/api/v1/query)."""
    if not promql:
        return False, None, {}
    try:
        q = urllib.parse.quote(promql)
        url = f"{PROMETHEUS_URL}/api/v1/query?query={q}"
        req = urllib.request.Request(url, method="GET")
        with urllib.request.urlopen(req, timeout=1.5) as resp:
            if resp.status == 200:
                body = json.loads(resp.read().decode("utf-8"))
                results = body.get("data", {}).get("result", [])
                if results:
                    first = results[0]
                    val_pair = first.get("value") or []
                    if len(val_pair) >= 2:
                        v = float(val_pair[1])
                        if not math.isnan(v) and not math.isinf(v):
                            return True, round(v, 2), dict(first.get("metric") or {})
                return True, None, {}
    except Exception:
        logger.debug("Consulta instantánea a Prometheus fallida.", exc_info=True)
    return False, None, {}


def _query_prom_range_multi_series(
    promql: str,
    start_ts: int,
    end_ts: int,
    step_sec: int,
    max_series: int = 8,
) -> Tuple[bool, List[Dict[str, Any]]]:
    """
    Consulta /api/v1/query_range devolviendo hasta `max_series` series temporales con sus labels.
    Permite pintar tanto 1 curva simple como N tablespaces, diskgroups o puntos de montaje.
    """
    if not promql:
        return False, []
    out: List[Dict[str, Any]] = []
    try:
        q = urllib.parse.quote(promql)
        url = f"{PROMETHEUS_URL}/api/v1/query_range?query={q}&start={start_ts}&end={end_ts}&step={step_sec}"
        req = urllib.request.Request(url, method="GET")
        with urllib.request.urlopen(req, timeout=2.0) as resp:
            if resp.status == 200:
                body = json.loads(resp.read().decode("utf-8"))
                results = body.get("data", {}).get("result", [])
                for item in results[:max_series]:
                    metric_labels = dict(item.get("metric") or {})
                    vals_map: Dict[int, float] = {}
                    for ts_val, str_v in item.get("values") or []:
                        v = float(str_v)
                        if not math.isnan(v) and not math.isinf(v):
                            vals_map[int(float(ts_val))] = round(v, 2)
                    if vals_map:
                        out.append(
                            {
                                "metric": metric_labels,
                                "values_by_ts": vals_map,
                            }
                        )
                return True, out
    except Exception:
        logger.debug("Consulta multi-serie a Prometheus fallida.", exc_info=True)
    return False, out


def _derive_series_label(
    base_label: str,
    metric_labels: Dict[str, str],
    legend_label: str,
    total_returned: int,
) -> str:
    """Construye una etiqueta legible cuando una query devuelve múltiples series."""
    if legend_label and metric_labels.get(legend_label):
        val = metric_labels[legend_label]
        if base_label and base_label.lower() not in val.lower() and total_returned == 1:
            return f"{base_label} ({val})"
        return val

    if total_returned > 1:
        for candidate in (
            "tablespace",
            "diskgroup",
            "pdb",
            "instance",
            "mountpoint",
            "datname",
            "standby_db",
            "channel",
            "sql_id",
            "component",
            "device",
            "daemon",
            "listener",
        ):
            if metric_labels.get(candidate):
                return metric_labels[candidate]
    return base_label or metric_labels.get("__name__", "Serie")


def evaluate_panel_definition(
    panel: Dict[str, Any],
    asset: CmdbAsset,
    start_ts: int,
    end_ts: int,
    step_sec: int,
    points_count: int,
) -> Tuple[bool, Dict[str, Any]]:
    """Evalúa todas las queries de un panel contra Prometheus y normaliza su eje X."""
    queries = panel.get("queries") or []
    legend_label = str(panel.get("legend_label") or "").strip()

    raw_series_collected: List[Dict[str, Any]] = []
    any_prom_ok = False
    rendered_exprs: List[str] = []

    for q_idx, q_def in enumerate(queries):
        raw_expr = str(q_def.get("promql") or "").strip()
        if not raw_expr:
            continue
        rendered = render_promql_for_asset(raw_expr, asset)
        rendered_exprs.append(rendered)
        base_lbl = str(q_def.get("label") or f"Serie {q_idx + 1}")
        preferred_color = str(q_def.get("color_hex") or "")

        ok, multi = _query_prom_range_multi_series(rendered, start_ts, end_ts, step_sec)
        if ok:
            any_prom_ok = True
        if multi:
            for m_idx, m_item in enumerate(multi):
                lbl = _derive_series_label(base_lbl, m_item["metric"], legend_label, len(multi))
                col = (
                    preferred_color
                    if (m_idx == 0 and preferred_color)
                    else SERIES_COLOR_PALETTE[(len(raw_series_collected)) % len(SERIES_COLOR_PALETTE)]
                )
                raw_series_collected.append(
                    {
                        "label": lbl,
                        "color_hex": col,
                        "values_by_ts": m_item["values_by_ts"],
                        "has_samples": True,
                    }
                )
        else:
            col = preferred_color or SERIES_COLOR_PALETTE[q_idx % len(SERIES_COLOR_PALETTE)]
            raw_series_collected.append(
                {
                    "label": base_lbl,
                    "color_hex": col,
                    "values_by_ts": {},
                    "has_samples": False,
                }
            )

    all_ts_set: Set[int] = set()
    for s in raw_series_collected:
        all_ts_set.update(s["values_by_ts"].keys())

    if all_ts_set:
        timeline = sorted(all_ts_set)
    else:
        timeline = [start_ts + (i * step_sec) for i in range(points_count)]

    time_labels = [datetime.fromtimestamp(t, timezone.utc).strftime("%H:%M") for t in timeline]
    evaluated_series: List[Dict[str, Any]] = []
    has_real_data = bool(all_ts_set)

    for idx, s in enumerate(raw_series_collected[:8]):
        vmap = s["values_by_ts"]
        # Rellenar huecos puntuales manteniendo 0.0 si no hubo muestra en ese instante
        vals = [round(float(vmap.get(t, 0.0)), 2) for t in timeline]
        non_empty_vals = list(vmap.values())
        last_v = non_empty_vals[-1] if non_empty_vals else 0.0
        min_v = min(non_empty_vals) if non_empty_vals else 0.0
        max_v = max(non_empty_vals) if non_empty_vals else 0.0
        avg_v = round(sum(non_empty_vals) / len(non_empty_vals), 2) if non_empty_vals else 0.0
        evaluated_series.append(
            {
                "key": f"s{idx}",
                "label": s["label"],
                "color_hex": s["color_hex"],
                "values": vals,
                "last": round(last_v, 2),
                "min": round(min_v, 2),
                "max": round(max_v, 2),
                "avg": avg_v,
                "has_samples": s["has_samples"],
            }
        )

    return any_prom_ok, {
        "id": str(panel.get("id") or "panel"),
        "title": str(panel.get("title") or "Gráfica Prometheus"),
        "unit": str(panel.get("unit") or ""),
        "chart_type": str(panel.get("chart_type") or "line"),
        "warn_threshold": panel.get("warn_threshold"),
        "crit_threshold": panel.get("crit_threshold"),
        "legend_label": legend_label,
        "promql_display": "  |  ".join(rendered_exprs),
        "timestamps": timeline,
        "time_labels": time_labels,
        "series": evaluated_series,
        "has_data": has_real_data,
    }


def evaluate_kpi_badge(badge: Dict[str, Any], asset: CmdbAsset) -> Dict[str, Any]:
    """Evalúa un indicador instantáneo KPI / Semáforo (ej. Instancia Oracle OPEN/MOUNTED/DOWN)."""
    rendered = render_promql_for_asset(str(badge.get("promql") or ""), asset)
    ok, val, _ = _query_prom_instant_value(rendered)
    mode = str(badge.get("mode") or "numeric")
    unit = str(badge.get("unit") or "")

    if not ok or val is None:
        return {
            "id": badge.get("id", "kpi"),
            "label": badge.get("label", "KPI"),
            "display_value": "SIN DATOS",
            "raw_value": None,
            "severity": "no_data",
            "promql": rendered,
        }

    severity = "ok"
    if mode == "oracle_instance":
        if val >= 1.0:
            display = "OPEN"
            severity = "ok"
        elif val >= 0.5:
            display = "MOUNTED"
            severity = "warning"
        else:
            display = "DOWN"
            severity = "critical"
    elif mode == "state_up":
        if val >= 1.0:
            display = "ONLINE"
            severity = "ok"
        else:
            display = "DOWN / DEGRADED"
            severity = "critical"
    else:
        crit_above = badge.get("crit_above")
        warn_above = badge.get("warn_above")
        if crit_above is not None and val >= float(crit_above):
            severity = "critical"
        elif warn_above is not None and val >= float(warn_above):
            severity = "warning"
        fmt_v = f"{int(val)}" if float(val).is_integer() else f"{val:.1f}"
        display = f"{fmt_v} {unit}".strip()

    return {
        "id": badge.get("id", "kpi"),
        "label": badge.get("label", "KPI"),
        "display_value": display,
        "raw_value": val,
        "severity": severity,
        "promql": rendered,
    }


def serialize_telemetry_target(t: AssetTelemetryTarget, asset: Optional[CmdbAsset] = None) -> Dict[str, Any]:
    eff_host = (t.target_host or "").strip()
    if not eff_host and asset is not None:
        eff_host = _resolve_asset_primary_ip(asset)
    path_str = t.metrics_path if str(t.metrics_path or "").startswith("/") else f"/{t.metrics_path or 'metrics'}"
    return {
        "id": t.id,
        "asset_id": t.asset_id,
        "name": t.name,
        "exporter_type": t.exporter_type,
        "mode": t.mode or "pull",
        "target_host": t.target_host or "",
        "effective_host": eff_host,
        "port": t.port,
        "metrics_path": path_str,
        "scheme": (t.scheme or "http").lower(),
        "scrape_interval": t.scrape_interval or "15s",
        "has_bearer_token": bool(t.bearer_token_encrypted),
        "extra_labels": dict(t.extra_labels or {}),
        "enabled": bool(t.enabled),
        "endpoint_preview": (
            f"POST /api/v1/automation/otlp/v1/metrics?asset_code={asset.code if asset else ''}"
            if t.mode == "push_otlp"
            else f"{(t.scheme or 'http').lower()}://{eff_host or '<IP>'}:{t.port}{path_str}"
        ),
        "last_probe_status": t.last_probe_status or "never",
        "last_probe_at": t.last_probe_at.isoformat() if t.last_probe_at else None,
        "last_probe_summary": t.last_probe_summary or "",
        "detected_metric_families_count": t.detected_metric_families_count or 0,
    }


def serialize_telemetry_profile(p: TelemetryProfile) -> Dict[str, Any]:
    return {
        "id": p.id,
        "code": p.code,
        "name": p.name,
        "description": p.description or "",
        "icon_key": p.icon_key or "analytics",
        "is_builtin": bool(p.is_builtin),
        "auto_match_exporter_types": list(p.auto_match_exporter_types or []),
        "assigned_asset_ids": list(p.assigned_asset_ids or []),
        "assigned_host_group_ids": list(p.assigned_host_group_ids or []),
        "kpi_badges": list(p.kpi_badges or []),
        "panels": list(p.panels or []),
        "panels_count": len(p.panels or []),
    }


def serialize_custom_chart(c: AssetCustomChart) -> Dict[str, Any]:
    return {
        "id": c.id,
        "asset_id": c.asset_id,
        "title": c.title,
        "unit": c.unit or "",
        "chart_type": c.chart_type or "line",
        "promql_a": c.promql_a,
        "label_a": c.label_a or "Serie A",
        "color_a": c.color_a or "#3B82F6",
        "promql_b": c.promql_b or "",
        "label_b": c.label_b or "",
        "color_b": c.color_b or "#A855F7",
        "legend_label": c.legend_label or "",
        "warn_threshold": c.warn_threshold,
        "crit_threshold": c.crit_threshold,
        "sort_order": c.sort_order or 0,
        "enabled": bool(c.enabled),
    }


def _detect_exporter_signature(metrics_text: str) -> Tuple[str, str, str, List[str]]:
    """
    Analiza la exposición texto Prometheus / OpenMetrics para autodetectar el agente:
    devuelve (exporter_type, suggested_profile_code, summary_detail, metric_names).
    """
    names_ordered: List[str] = []
    seen_names: Set[str] = set()
    oratui_meta = ""

    metric_line_re = re.compile(r"^([a-zA-Z_:][a-zA-Z0-9_:]*)(\{([^}]*)\})?\s+")
    help_line_re = re.compile(r"^#\s*HELP\s+([a-zA-Z_:][a-zA-Z0-9_:]*)")

    for raw_line in metrics_text.splitlines():
        line = raw_line.strip()
        if not line:
            continue
        if line.startswith("#"):
            hm = help_line_re.match(line)
            if hm:
                mname = hm.group(1)
                if mname not in seen_names:
                    seen_names.add(mname)
                    names_ordered.append(mname)
            continue

        mm = metric_line_re.match(line)
        if not mm:
            continue
        mname = mm.group(1)
        if mname not in seen_names:
            seen_names.add(mname)
            names_ordered.append(mname)

        if mname == "oratui_info" and mm.group(3) and not oratui_meta:
            lbl_str = mm.group(3)
            ver = re.search(r'version="([^"]+)"', lbl_str)
            topo = re.search(r'topology="([^"]+)"', lbl_str)
            ora_v = re.search(r'oracle_version="([^"]+)"', lbl_str)
            parts = []
            if ver:
                parts.append(f"ORA-TUI {ver.group(1)}")
            if topo:
                parts.append(topo.group(1))
            if ora_v and ora_v.group(1):
                parts.append(f"Oracle {ora_v.group(1)}")
            oratui_meta = " • ".join(parts)

    if "oratui_info" in seen_names or any(n.startswith("oratui_") for n in seen_names):
        det = oratui_meta or "Agente ORA-TUI Oracle & Linux SAN"
        return "oratui_oracle", "oratui_oracle", det, names_ordered
    if "node_uname_info" in seen_names or "node_cpu_seconds_total" in seen_names:
        return "node_exporter", "system_base", "Linux Prometheus Node Exporter", names_ordered
    if "windows_cs_hostname" in seen_names or "windows_cpu_time_total" in seen_names:
        return "windows_exporter", "system_base", "Windows Prometheus Exporter", names_ordered
    if any(n.startswith("otelcol_") or n.startswith("system_cpu_utilization") for n in seen_names):
        return "otel_collector", "otel_collector", "OpenTelemetry Collector Exporter", names_ordered
    if "pg_up" in seen_names or any(n.startswith("pg_stat_database_") for n in seen_names):
        return "postgres_exporter", "postgres_db", "PostgreSQL Exporter", names_ordered
    if "nginx_up" in seen_names or "nginx_http_requests_total" in seen_names:
        return "nginx_exporter", "system_base", "Nginx Prometheus Exporter", names_ordered
    if "haproxy_up" in seen_names or any(n.startswith("haproxy_frontend_") for n in seen_names):
        return "haproxy_stats", "system_base", "HAProxy Prometheus Stats", names_ordered
    if any(n.startswith("container_cpu_") or n.startswith("engine_daemon_") for n in seen_names):
        return "docker_engine", "system_base", "Docker / cAdvisor Exporter", names_ordered

    return "custom_prometheus", "system_base", "Endpoint Prometheus / OpenMetrics personalizado", names_ordered


def probe_telemetry_endpoint(
    db: Session,
    target_host: str = "",
    port: Optional[int] = None,
    metrics_path: Optional[str] = None,
    scheme: Optional[str] = None,
    bearer_token: Optional[str] = None,
    asset_id: Optional[int] = None,
    target_id: Optional[int] = None,
    timeout_sec: float = 3.0,
) -> Dict[str, Any]:
    """
    Conecta en vivo con un endpoint HTTP/HTTPS de métricas (en cualquier puerto/ruta),
    verifica respuesta válida, mide latencia y autodetecta la firma del agente (ej. ORA-TUI).
    """
    ensure_telemetry_profiles_seeded(db)

    tgt_row: Optional[AssetTelemetryTarget] = None
    if target_id:
        tgt_row = db.query(AssetTelemetryTarget).filter(AssetTelemetryTarget.id == target_id).first()

    eff_asset_id = asset_id or (tgt_row.asset_id if tgt_row else None)
    asset: Optional[CmdbAsset] = None
    if eff_asset_id:
        asset = (
            db.query(CmdbAsset)
            .options(joinedload(CmdbAsset.ip_addresses))
            .filter(CmdbAsset.id == eff_asset_id)
            .first()
        )

    eff_host = (target_host or (tgt_row.target_host if tgt_row else "") or "").strip()
    if not eff_host and asset is not None:
        eff_host = _resolve_asset_primary_ip(asset)
    if not eff_host:
        raise ValueError("Indica una dirección IP o hostname para probar el endpoint.")

    eff_scheme = ((scheme if scheme is not None else (tgt_row.scheme if tgt_row else "http")) or "http").lower().strip()
    if eff_scheme not in ("http", "https"):
        raise ValueError("El esquema debe ser 'http' o 'https'.")

    eff_port = int(port if port is not None else (tgt_row.port if tgt_row else 9100))
    if eff_port < 1 or eff_port > 65535:
        raise ValueError("El puerto debe estar entre 1 y 65535.")

    raw_path = ((metrics_path if metrics_path is not None else (tgt_row.metrics_path if tgt_row else "/metrics")) or "/metrics").strip()
    eff_path = raw_path if raw_path.startswith("/") else f"/{raw_path}"

    token_plain = (bearer_token or "").strip()
    if not token_plain and tgt_row and tgt_row.bearer_token_encrypted:
        try:
            token_plain = decrypt_vault_secret(tgt_row.bearer_token_encrypted)
        except ValueError:
            token_plain = ""

    url = f"{eff_scheme}://{eff_host}:{eff_port}{eff_path}"
    headers = {"User-Agent": "RackDoc-TelemetryProbe/1.4", "Accept": "text/plain,*/*"}
    if token_plain:
        headers["Authorization"] = f"Bearer {token_plain}"

    ctx = None
    if eff_scheme == "https":
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE

    t0 = time.monotonic()
    now_dt = utcnow()
    try:
        req = urllib.request.Request(url, method="GET", headers=headers)
        with urllib.request.urlopen(req, timeout=max(0.5, min(timeout_sec, 8.0)), context=ctx) as resp:
            latency_ms = round((time.monotonic() - t0) * 1000.0, 1)
            raw_bytes = resp.read(524_288)
            text = raw_bytes.decode("utf-8", errors="replace")
            det_type, det_profile, sig_detail, metric_names = _detect_exporter_signature(text)
            fam_count = len(metric_names)

            ok = resp.status == 200 and fam_count > 0
            summary = (
                f"HTTP {resp.status} ({latency_ms} ms) • {fam_count} familias • {sig_detail}"
                if fam_count > 0
                else f"HTTP {resp.status} ({latency_ms} ms), pero no se detectaron métricas formato Prometheus en {eff_path}"
            )
            if tgt_row is not None:
                tgt_row.last_probe_status = "ok" if ok else "error"
                tgt_row.last_probe_at = now_dt
                tgt_row.last_probe_summary = summary
                tgt_row.detected_metric_families_count = fam_count
                db.commit()

            return {
                "ok": ok,
                "url": url,
                "status_code": resp.status,
                "latency_ms": latency_ms,
                "detected_exporter_type": det_type,
                "suggested_profile_code": det_profile,
                "signature_detail": sig_detail,
                "families_count": fam_count,
                "sample_metrics": metric_names[:120],
                "summary": summary,
            }
    except Exception as exc:
        latency_ms = round((time.monotonic() - t0) * 1000.0, 1)
        err_msg = f"Fallo al conectar con {url} ({latency_ms} ms): {exc}"
        if tgt_row is not None:
            tgt_row.last_probe_status = "error"
            tgt_row.last_probe_at = now_dt
            tgt_row.last_probe_summary = err_msg[:400]
            db.commit()
        return {
            "ok": False,
            "url": url,
            "status_code": 0,
            "latency_ms": latency_ms,
            "detected_exporter_type": None,
            "suggested_profile_code": None,
            "signature_detail": "",
            "families_count": 0,
            "sample_metrics": [],
            "summary": err_msg,
        }


def list_asset_available_metrics(db: Session, asset_id: int) -> Dict[str, Any]:
    """
    Devuelve la lista real de métricas y etiquetas disponibles en Prometheus para un servidor,
    combinando TSDB (`/api/v1/series`) y fallback directo contra sus targets Pull activos
    si la máquina se acaba de registrar hace menos de 15s.
    """
    asset = (
        db.query(CmdbAsset)
        .options(joinedload(CmdbAsset.ip_addresses))
        .filter(CmdbAsset.id == asset_id)
        .first()
    )
    if not asset:
        raise ValueError("Activo no encontrado.")

    hb_ip = _resolve_asset_primary_ip(asset)
    metrics_map: Dict[str, Set[str]] = {}
    source = "none"

    now_ts = int(time.time())
    start_ts = now_ts - 7200
    matchers = [f'{{asset_code="{asset.code}"}}']
    if hb_ip:
        matchers.append(f'{{instance=~"{re.escape(hb_ip)}:.*"}}')

    try:
        params = [("start", str(start_ts)), ("end", str(now_ts))]
        for m in matchers:
            params.append(("match[]", m))
        qs = urllib.parse.urlencode(params)
        url = f"{PROMETHEUS_URL}/api/v1/series?{qs}"
        req = urllib.request.Request(url, method="GET")
        with urllib.request.urlopen(req, timeout=2.0) as resp:
            if resp.status == 200:
                body = json.loads(resp.read().decode("utf-8"))
                for series_lbls in body.get("data") or []:
                    mname = series_lbls.get("__name__")
                    if not mname:
                        continue
                    lbl_set = metrics_map.setdefault(mname, set())
                    for k in series_lbls.keys():
                        if k not in ("__name__", "job", "managed_by"):
                            lbl_set.add(k)
                if metrics_map:
                    source = "prometheus_tsdb"
    except Exception:
        logger.debug("No se pudo consultar /api/v1/series en Prometheus.", exc_info=True)

    # Si Prometheus aún no raspó el target recién creado, leemos nombres directamente del target Pull
    targets = (
        db.query(AssetTelemetryTarget)
        .filter(
            AssetTelemetryTarget.asset_id == asset.id,
            AssetTelemetryTarget.enabled == True,  # noqa: E712
            AssetTelemetryTarget.mode == "pull",
        )
        .all()
    )
    if not metrics_map and targets:
        for t in targets[:3]:
            pr = probe_telemetry_endpoint(db=db, target_id=t.id, asset_id=asset.id, timeout_sec=1.5)
            for mname in pr.get("sample_metrics") or []:
                metrics_map.setdefault(mname, {"asset_code"})
        if metrics_map:
            source = "live_target_scrape"

    items = [
        {
            "name": name,
            "labels": sorted(lbls),
            "suggested_promql": f'{name}{{asset_code="{{{{asset_code}}}}"}}',
        }
        for name, lbls in sorted(metrics_map.items())
    ]

    return {
        "asset_id": asset.id,
        "asset_code": asset.code,
        "source": source,
        "count": len(items),
        "metrics": items,
        "template_variables": [
            {"token": "{{asset_code}}", "example": asset.code, "description": "Código único del activo en RackDoc"},
            {"token": "{{hostname}}", "example": asset.hostname or asset.code.lower(), "description": "Hostname del servidor"},
            {"token": "{{ip}}", "example": hb_ip, "description": "IP primaria / Heartbeat"},
            {"token": "{{instance_regex}}", "example": f"{hb_ip}:.*" if hb_ip else f"{asset.code}.*", "description": "Regex de instancia IP:puerto"},
        ],
    }


def resolve_profiles_for_asset(
    db: Session,
    asset: CmdbAsset,
    targets: List[AssetTelemetryTarget],
    checks: List[MonitoredServiceCheck],
) -> List[TelemetryProfile]:
    """
    Determina qué plantillas reutilizables aplican a un activo:
    1. Siempre 'system_base' primero.
    2. Cualquier plantilla cuyo `auto_match_exporter_types` coincida con un target o chequeo activo del servidor.
    3. Cualquier plantilla asignada explícitamente al `asset.id` o a alguno de sus `HostGroup.id`.
    """
    ensure_telemetry_profiles_seeded(db)
    all_profiles = db.query(TelemetryProfile).order_by(TelemetryProfile.id).all()

    active_exporter_types: Set[str] = set()
    for t in targets:
        if t.enabled:
            active_exporter_types.add((t.exporter_type or "").lower().strip())
    for c in checks:
        if c.enabled:
            active_exporter_types.add((c.check_type or "").lower().strip())

    member_group_ids: Set[int] = set()
    for hg in db.query(HostGroup).all():
        if asset.id in (hg.member_asset_ids or []):
            member_group_ids.add(hg.id)

    matched: List[TelemetryProfile] = []
    seen_ids: Set[int] = set()

    for p in all_profiles:
        is_sys = p.code == "system_base"
        auto_types = {str(x).lower().strip() for x in (p.auto_match_exporter_types or [])}
        assigned_assets = {int(x) for x in (p.assigned_asset_ids or []) if str(x).isdigit() or isinstance(x, int)}
        assigned_groups = {int(x) for x in (p.assigned_host_group_ids or []) if str(x).isdigit() or isinstance(x, int)}

        if (
            is_sys
            or bool(auto_types & active_exporter_types)
            or (asset.id in assigned_assets)
            or bool(assigned_groups & member_group_ids)
        ):
            if p.id not in seen_ids:
                seen_ids.add(p.id)
                matched.append(p)

    # Ordenar garantizando system_base primero, seguido de packs auto-detectados (ej. ORA-TUI) y plantillas custom
    matched.sort(key=lambda pr: (0 if pr.code == "system_base" else (1 if pr.is_builtin else 2), pr.id))
    return matched


def build_rich_telemetry_payload_for_asset(
    db: Session,
    asset: CmdbAsset,
    start_ts: int,
    end_ts: int,
    step_sec: int,
    points_count: int,
) -> Tuple[bool, Dict[str, Any]]:
    """
    Construye el bloque enriquecido de targets multipuerto, perfiles evaluados (ej. ORA-TUI)
    y gráficas individuales del servidor para `get_asset_telemetry_timeseries`.
    """
    ensure_telemetry_profiles_seeded(db)

    targets = (
        db.query(AssetTelemetryTarget)
        .filter(AssetTelemetryTarget.asset_id == asset.id)
        .order_by(AssetTelemetryTarget.id)
        .all()
    )
    checks = (
        db.query(MonitoredServiceCheck)
        .filter(MonitoredServiceCheck.asset_id == asset.id)
        .all()
    )
    custom_charts = (
        db.query(AssetCustomChart)
        .filter(AssetCustomChart.asset_id == asset.id, AssetCustomChart.enabled == True)  # noqa: E712
        .order_by(AssetCustomChart.sort_order, AssetCustomChart.id)
        .all()
    )
    all_profiles = db.query(TelemetryProfile).order_by(TelemetryProfile.id).all()
    matched_profiles = resolve_profiles_for_asset(db, asset, targets, checks)

    any_prom_ok = False
    evaluated_profiles: List[Dict[str, Any]] = []
    for prof in matched_profiles:
        eval_kpis = [evaluate_kpi_badge(b, asset) for b in (prof.kpi_badges or [])]
        eval_panels: List[Dict[str, Any]] = []
        for pdef in prof.panels or []:
            p_ok, p_eval = evaluate_panel_definition(
                panel=pdef,
                asset=asset,
                start_ts=start_ts,
                end_ts=end_ts,
                step_sec=step_sec,
                points_count=points_count,
            )
            if p_ok:
                any_prom_ok = True
            eval_panels.append(p_eval)

        evaluated_profiles.append(
            {
                "id": prof.id,
                "code": prof.code,
                "name": prof.name,
                "description": prof.description or "",
                "icon_key": prof.icon_key or "analytics",
                "is_builtin": bool(prof.is_builtin),
                "explicitly_assigned": asset.id in (prof.assigned_asset_ids or []),
                "evaluated_kpis": eval_kpis,
                "evaluated_panels": eval_panels,
            }
        )

    evaluated_custom_charts: List[Dict[str, Any]] = []
    for cc in custom_charts:
        queries_list: List[Dict[str, Any]] = [
            {
                "label": cc.label_a or "Serie A",
                "promql": cc.promql_a,
                "color_hex": cc.color_a or "#3B82F6",
            }
        ]
        if (cc.promql_b or "").strip():
            queries_list.append(
                {
                    "label": cc.label_b or "Serie B",
                    "promql": cc.promql_b,
                    "color_hex": cc.color_b or "#A855F7",
                }
            )
        c_ok, c_eval = evaluate_panel_definition(
            panel={
                "id": f"custom_{cc.id}",
                "title": cc.title,
                "unit": cc.unit or "",
                "chart_type": cc.chart_type or "line",
                "warn_threshold": cc.warn_threshold,
                "crit_threshold": cc.crit_threshold,
                "legend_label": cc.legend_label or "",
                "queries": queries_list,
            },
            asset=asset,
            start_ts=start_ts,
            end_ts=end_ts,
            step_sec=step_sec,
            points_count=points_count,
        )
        if c_ok:
            any_prom_ok = True
        c_eval["custom_chart_id"] = cc.id
        c_eval["raw_config"] = serialize_custom_chart(cc)
        evaluated_custom_charts.append(c_eval)

    return any_prom_ok, {
        "exporter_presets": EXPORTER_PRESETS,
        "telemetry_targets": [serialize_telemetry_target(t, asset) for t in targets],
        "active_profiles": evaluated_profiles,
        "custom_charts": evaluated_custom_charts,
        "all_profiles_catalog": [serialize_telemetry_profile(p) for p in all_profiles],
    }


def upsert_telemetry_target_for_asset(
    db: Session,
    asset: CmdbAsset,
    data: Dict[str, Any],
    target_id: Optional[int] = None,
) -> AssetTelemetryTarget:
    """Crea o actualiza un `AssetTelemetryTarget` validando puerto, ruta, esquema y token cifrado."""
    if target_id is not None:
        tgt = (
            db.query(AssetTelemetryTarget)
            .filter(AssetTelemetryTarget.id == target_id)
            .first()
        )
        if not tgt:
            raise ValueError("Target de telemetría no encontrado.")
    else:
        tgt = AssetTelemetryTarget(asset_id=asset.id)
        db.add(tgt)

    exp_type = str(data.get("exporter_type") or "node_exporter").strip().lower()
    mode = str(data.get("mode") or ("push_otlp" if exp_type == "otlp_push" else "pull")).strip().lower()
    if mode not in ("pull", "push_otlp"):
        raise ValueError("El modo del target debe ser 'pull' o 'push_otlp'.")

    scheme = str(data.get("scheme") or "http").strip().lower()
    if scheme not in ("http", "https"):
        raise ValueError("El esquema debe ser 'http' o 'https'.")

    port = int(data.get("port") or 9100)
    if port < 1 or port > 65535:
        raise ValueError("El puerto debe estar entre 1 y 65535.")

    raw_path = str(data.get("metrics_path") or "/metrics").strip()
    metrics_path = raw_path if raw_path.startswith("/") else f"/{raw_path}"

    raw_interval = str(data.get("scrape_interval") or "15s").strip()
    if not re.match(r"^\d+(ms|s|m|h)$", raw_interval):
        raw_interval = "15s"

    tgt.name = str(data.get("name") or f"Target {exp_type} (:{port})").strip()
    tgt.exporter_type = exp_type
    tgt.mode = mode
    tgt.target_host = str(data.get("target_host") or "").strip()
    tgt.port = port
    tgt.metrics_path = metrics_path
    tgt.scheme = scheme
    tgt.scrape_interval = raw_interval
    tgt.enabled = bool(data.get("enabled", True))

    clean_labels: Dict[str, str] = {}
    for k, v in (data.get("extra_labels") or {}).items():
        ks = re.sub(r"[^a-zA-Z0-9_]", "_", str(k).strip())
        if ks and not ks.startswith("__"):
            clean_labels[ks] = str(v).strip()
    tgt.extra_labels = clean_labels

    if data.get("clear_bearer_token"):
        tgt.bearer_token_encrypted = ""
    elif data.get("bearer_token"):
        tgt.bearer_token_encrypted = encrypt_vault_secret(str(data["bearer_token"]))

    db.commit()
    db.refresh(tgt)
    return tgt
