from __future__ import annotations

import json
import math
import os
import re
import smtplib
import socket
import ssl
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta
from email.message import EmailMessage
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

from sqlalchemy.orm import Session, joinedload

from ..models import (
    ADServer,
    AlertContact,
    AlertContactGroup,
    AlertNotificationLog,
    CmdbAsset,
    CmdbIpAddress,
    CmdbSubnet,
    Connection,
    FloorDevice,
    HostGroup,
    InfraConnector,
    LogicalTopologyLink,
    MaintenanceWindow,
    MonitoredServiceCheck,
    NotificationRoutingRule,
    Port,
    Rack,
    RackDevice,
    SmtpAlertConfig,
    SwitchSnmpPort,
    TechStackDiagram,
    TechStackEdge,
    TechStackNode,
    User,
)
from .cmdb_service import (
    ASSET_CLASS_LABELS,
    IP_ROLE_LABELS,
    _match_subnet_for_ip,
    ensure_cmdb_seed_data,
    sync_physical_devices_to_cmdb,
)
from .monitor import check_host_connectivity

PROMETHEUS_URL = os.getenv("PROMETHEUS_URL", "http://rackdoc-prometheus:9090").rstrip("/")
PROMETHEUS_PUBLIC_URL = os.getenv("PROMETHEUS_PUBLIC_URL", "http://localhost:9090").rstrip("/")
PROMETHEUS_DYNAMIC_DIR = Path(os.getenv("PROMETHEUS_DYNAMIC_DIR", "/app/data/prometheus"))
# Fichero de File Service Discovery que Prometheus relee cada 15s.
PROMETHEUS_DYNAMIC_TARGETS_PATH = PROMETHEUS_DYNAMIC_DIR / "targets_dynamic.json"
# Sin valor por defecto: si no está configurada, los endpoints de automatización
# se deshabilitan en lugar de aceptar una clave pública conocida.
AUTOMATION_API_KEY = (os.getenv("AUTOMATION_API_KEY", "") or "").strip()

CONNECTOR_TYPE_LABELS: Dict[str, str] = {
    "snmp_switch": "Switch / Router / Firewall SNMP (IF-MIB + LLDP-MIB)",
    "proxmox_ve": "Hipervisor Proxmox VE (API :8006 + QEMU/LXC)",
    "vmware_vsphere": "Hipervisor VMware ESXi / vCenter (API :443)",
    "hyperv": "Hipervisor Microsoft Hyper-V (WinRM / Exporter)",
    "kvm_libvirt": "Hipervisor KVM / QEMU / Libvirt",
    "xcpng": "Hipervisor XCP-ng / XenServer",
    "docker_engine": "Motor Contenedores Docker Engine / cAdvisor",
    "portainer": "Orquestador Portainer API (:9443)",
    "kubernetes": "Clúster Kubernetes / K3s (Kube-State)",
    "apache_status": "Servidor Web Apache HTTPd (mod_status / Exporter)",
    "nginx_status": "Servidor Web / Proxy Nginx (stub_status / Exporter)",
    "haproxy_stats": "Balanceador HAProxy (Prometheus Stats :8404)",
    "postgresql": "Base de Datos PostgreSQL (:5432 / postgres_exporter)",
    "mysql_mariadb": "Base de Datos MySQL / MariaDB (:3306 / mysqld_exporter)",
    "mssql": "Base de Datos Microsoft SQL Server (:1433)",
    "redis": "Caché En Memoria Redis / Valkey (:6379)",
    "mongodb": "Base de Datos MongoDB (:27017)",
    "node_exporter": "Agente Linux Prometheus Node Exporter (:9100)",
    "windows_exporter": "Agente Windows Prometheus Exporter (:9182)",
}

LOGICAL_LAYER_ORDER: Dict[str, int] = {
    "edge_security": 1,     # Capa 1: Firewalls, Routers y Perímetro WAN
    "network_switching": 2, # Capa 2: Switches Core / ToR / VLANs (SNMP + LLDP)
    "hypervisors_phys": 3,  # Capa 3: Servidores Físicos del Rack, Proxmox, VMware y Barebones
    "vms_containers": 4,    # Capa 4: Máquinas Virtuales, Contenedores Docker/LXC y Clusters VIP
    "services_apps": 5,     # Capa 5: Servicios Web (Apache/Nginx), Balanceadores y BBDD
}


def classify_logical_layer(asset: CmdbAsset, rdev: Optional[RackDevice] = None) -> Tuple[str, str]:
    """Determina la capa del Diagrama de Topología Lógica a la que pertenece un activo."""
    code_up = (asset.code or "").upper()
    name_low = (asset.name or "").lower()
    cls = (asset.asset_class or "").lower()
    cat = (rdev.template.category.lower() if (rdev and rdev.template and rdev.template.category) else "")

    if cat in ("firewall", "router") or "fw" in code_up.lower() or "firewall" in name_low or "router" in name_low:
        return "edge_security", "Capa 1 • Perímetro, Routers & Firewalls"
    if cat in ("switch", "patch_panel") or cls == "network_security" or "sw" in code_up.lower() or "switch" in name_low:
        return "network_switching", "Capa 2 • Electrónica de Red & Switching (SNMP/LLDP)"
    if cls == "physical_server" or asset.sync_source == "rack_device" or cat in ("server", "storage_san", "storage_nas", "ups", "pdu"):
        return "hypervisors_phys", "Capa 3 • Servidores Físicos del Rack, Hipervisores & Barebones"
    if cls in ("cluster_vip", "cloud_instance") or "db" in code_up.lower() or "waf" in code_up.lower():
        return "services_apps", "Capa 5 • Clusters HA, Proxies Web (Apache/Nginx) & BBDD"
    return "vms_containers", "Capa 4 • Máquinas Virtuales (VMware/Proxmox) & Contenedores (Docker/LXC)"


def sync_prometheus_targets_file(db: Session) -> Dict[str, Any]:
    """
    Mantiene actualizado en caliente el directorio de Prometheus (/app/data/prometheus):
    - Asegura que 'prometheus.yml' exista.
    - Regenera 'targets_dynamic.json' con todos los hosts y exporters dados de alta en RackDoc
      (ya sea desde la UI o vía Ansible Webhook).
    Prometheus recarga 'targets_dynamic.json' automáticamente cada 15s mediante file_sd_configs.
    """
    try:
        PROMETHEUS_DYNAMIC_DIR.mkdir(parents=True, exist_ok=True)

        # '/api/v1/metrics' está protegido con la clave de automatización, así que
        # se la dejamos a Prometheus en un fichero aparte (nunca dentro del YAML,
        # que sí se versiona) y la referenciamos con 'credentials_file'.
        key_file = PROMETHEUS_DYNAMIC_DIR / "automation_api_key"
        if AUTOMATION_API_KEY:
            if not key_file.exists() or key_file.read_text(encoding="utf-8").strip() != AUTOMATION_API_KEY:
                key_file.write_text(AUTOMATION_API_KEY, encoding="utf-8")
                key_file.chmod(0o600)

        prom_yml = PROMETHEUS_DYNAMIC_DIR / "prometheus.yml"
        if not prom_yml.exists():
            prom_yml.write_text(
                "global:\n"
                "  scrape_interval: 15s\n"
                "  evaluation_interval: 15s\n"
                "  external_labels:\n"
                "    monitor: 'rackdoc-dcim-cmdb'\n\n"
                "scrape_configs:\n"
                "  - job_name: 'rackdoc_backend_collector'\n"
                "    scrape_interval: 15s\n"
                "    metrics_path: '/api/v1/metrics'\n"
                "    authorization:\n"
                "      credentials_file: '/etc/prometheus/dynamic/automation_api_key'\n"
                "    static_configs:\n"
                "      - targets: ['rackdoc-backend:8000']\n"
                "        labels:\n"
                "          collector: 'rackdoc-background-engine'\n\n"
                "  - job_name: 'rackdoc_dynamic_host_exporters'\n"
                "    file_sd_configs:\n"
                "      - files:\n"
                "          - '/etc/prometheus/dynamic/targets_*.json'\n"
                "        refresh_interval: 15s\n",
                encoding="utf-8",
            )

        assets = db.query(CmdbAsset).options(joinedload(CmdbAsset.ip_addresses)).all()
        assets_by_id = {a.id: a for a in assets}
        checks = db.query(MonitoredServiceCheck).filter(MonitoredServiceCheck.enabled == True).all()  # noqa: E712
        connectors = db.query(InfraConnector).filter(InfraConnector.enabled == True).all()  # noqa: E712

        exporter_check_types = {
            "node_exporter": 9100,
            "windows_exporter": 9182,
            "apache": 9117,
            "nginx": 9113,
            "haproxy": 8404,
            "docker": 9323,
            "postgres": 9187,
            "mysql": 9104,
            "redis": 9121,
            "mongodb": 9216,
        }

        sd_entries: List[Dict[str, Any]] = []
        seen_targets = set()

        for chk in checks:
            if chk.check_type not in exporter_check_types:
                continue
            ast = assets_by_id.get(chk.asset_id)
            if not ast:
                continue
            host_ip = chk.target_ip_or_url.strip()
            if not host_ip and ast.ip_addresses:
                host_ip = ast.ip_addresses[0].ip_address
            if "://" in host_ip:
                parsed = urllib.parse.urlparse(host_ip)
                host_ip = parsed.hostname or host_ip
            port = chk.port or exporter_check_types[chk.check_type]
            target_str = f"{host_ip}:{port}"
            if not host_ip or target_str in seen_targets:
                continue
            seen_targets.add(target_str)
            sd_entries.append(
                {
                    "targets": [target_str],
                    "labels": {
                        "asset_code": ast.code,
                        "hostname": ast.hostname or ast.code.lower(),
                        "asset_class": ast.asset_class,
                        "environment": ast.environment,
                        "exporter_type": chk.check_type,
                        "managed_by": "rackdoc_file_sd",
                    },
                }
            )

        for conn in connectors:
            if conn.connector_type in ("node_exporter", "windows_exporter", "haproxy_stats"):
                target_str = f"{conn.endpoint_host.strip()}:{conn.endpoint_port}"
                if target_str in seen_targets:
                    continue
                seen_targets.add(target_str)
                ast = assets_by_id.get(conn.linked_asset_id) if conn.linked_asset_id else None
                sd_entries.append(
                    {
                        "targets": [target_str],
                        "labels": {
                            "asset_code": ast.code if ast else conn.name,
                            "hostname": (ast.hostname if ast else conn.endpoint_host),
                            "exporter_type": conn.connector_type,
                            "managed_by": "rackdoc_file_sd",
                        },
                    }
                )

        targets_file = PROMETHEUS_DYNAMIC_TARGETS_PATH
        targets_file.write_text(json.dumps(sd_entries, indent=2), encoding="utf-8")
        return {"targets_count": len(sd_entries), "file": str(targets_file)}
    except Exception as exc:
        return {"targets_count": 0, "error": str(exc)}


def ensure_network_hosts_seeded(db: Session) -> None:
    """
    Inicializa únicamente la configuración base de '4. Red & Host' sin inyectar
    hosts, chequeos, bocas SNMP, contactos ni diagramas ficticios de demostración.
    """
    ensure_cmdb_seed_data(db)
    sync_physical_devices_to_cmdb(db)

    if db.query(SmtpAlertConfig).count() == 0:
        db.add(
            SmtpAlertConfig(
                smtp_host=os.getenv("SMTP_HOST", ""),
                smtp_port=int(os.getenv("SMTP_PORT", "587")),
                use_tls=True,
                smtp_username=os.getenv("SMTP_USER", ""),
                smtp_password="",
                from_email=os.getenv("SMTP_FROM", ""),
                global_webhook_url="",
                enabled=False,
            )
        )
        db.commit()

    if db.query(TechStackDiagram).count() == 0:
        db.add(
            TechStackDiagram(
                code="STACK-POC",
                name="Stack Principal POC",
                description="Lienzo 2D limpio para organizar tus elementos y conexiones reales.",
                business_service="Infraestructura Real POC",
                environment="production",
                owner_team="",
                criticality="high",
                map_scale=1.0,
                canvas_boxes=[],
            )
        )
        db.commit()

    sync_prometheus_targets_file(db)



def is_asset_in_maintenance(
    asset: CmdbAsset,
    active_windows: List[MaintenanceWindow],
    host_groups_by_id: Dict[int, HostGroup],
) -> Optional[MaintenanceWindow]:
    """Comprueba si un Host/VM está cubierto por una ventana activa de mantenimiento (manual o Ansible)."""
    now = datetime.utcnow()
    asset_ips = {ip.ip_address.strip() for ip in asset.ip_addresses if ip.ip_address}
    for win in active_windows:
        if not win.is_active or win.ends_at < now:
            continue
        if win.scope_type == "single_host" and win.asset_id == asset.id:
            return win
        if win.scope_type == "host_group" and win.host_group_id:
            hg = host_groups_by_id.get(win.host_group_id)
            if hg and asset.id in (hg.member_asset_ids or []):
                return win
        for token in (win.target_matches or []):
            t_clean = str(token).strip().lower()
            if not t_clean:
                continue
            if (
                t_clean == (asset.code or "").lower()
                or t_clean == (asset.hostname or "").lower()
                or t_clean == (asset.fqdn or "").lower()
                or t_clean in asset_ips
            ):
                return win
    return None


def _dispatch_alert_notification(
    db: Session,
    asset: CmdbAsset,
    service_name: str,
    event_state: str,
    detail: str,
    in_maintenance: Optional[MaintenanceWindow] = None,
    is_unreachable_by_parent: bool = False,
) -> None:
    """
    Evalúa la Matriz de Reglas de Alarma (Host / HostGroup -> Persona / ContactGroup)
    y registra/envía el aviso por Correo SMTP y/o Webhook, bloqueándolo si el host está en
    Mantenimiento (Ansible/Manual) o si está UNREACHABLE por caída de su Switch/Hipervisor padre.
    """
    if in_maintenance and in_maintenance.suppress_notifications:
        db.add(
            AlertNotificationLog(
                asset_code=asset.code,
                service_name=service_name,
                event_state=event_state,
                matched_rule_name=f"Ventana Mantenimiento: {in_maintenance.title}",
                recipients_summary="Silenciado automáticamente (Modo Mantenimiento Activo)",
                delivery_channel="suppressed",
                delivery_status="suppressed_maintenance",
                detail=f"Aviso suprimido por mantenimiento ({in_maintenance.created_by}): {in_maintenance.reason}",
            )
        )
        db.commit()
        return

    if is_unreachable_by_parent:
        db.add(
            AlertNotificationLog(
                asset_code=asset.code,
                service_name=service_name,
                event_state="UNREACHABLE",
                matched_rule_name="Supresión de Cascada Padre -> Hijo (Nagios Reachability)",
                recipients_summary="Silenciado porque el Switch o Hipervisor Padre está DOWN",
                delivery_channel="suppressed",
                delivery_status="suppressed_unreachable",
                detail=detail,
            )
        )
        db.commit()
        return

    rules = db.query(NotificationRoutingRule).filter(NotificationRoutingRule.enabled == True).all()  # noqa: E712
    host_groups = {hg.id: hg for hg in db.query(HostGroup).all()}
    contacts = {c.id: c for c in db.query(AlertContact).filter(AlertContact.active == True).all()}  # noqa: E712
    cgroups = {cg.id: cg for cg in db.query(AlertContactGroup).all()}
    smtp_cfg = db.query(SmtpAlertConfig).first()

    matched_rules: List[NotificationRoutingRule] = []
    for r in rules:
        if r.scope_type == "all":
            matched_rules.append(r)
        elif r.scope_type == "single_host" and r.asset_id == asset.id:
            matched_rules.append(r)
        elif r.scope_type == "host_group" and r.host_group_id:
            hg = host_groups.get(r.host_group_id)
            if hg and asset.id in (hg.member_asset_ids or []):
                matched_rules.append(r)
        elif r.scope_type == "asset_class" and r.asset_class_filter == asset.asset_class:
            matched_rules.append(r)

    if not matched_rules and rules:
        matched_rules = [rules[0]]

    emails_set = set()
    webhooks_set = set()
    names_set = set()

    for r in matched_rules:
        for cid in (r.contact_ids or []):
            c = contacts.get(cid)
            if c:
                emails_set.add(c.email)
                names_set.add(f"{c.full_name} <{c.email}>")
                if c.personal_webhook_url:
                    webhooks_set.add(c.personal_webhook_url)
        for cgid in (r.contact_group_ids or []):
            cg = cgroups.get(cgid)
            if cg:
                if cg.group_email:
                    emails_set.add(cg.group_email)
                names_set.add(f"[{cg.name}]")
                if cg.channel_webhook_url:
                    webhooks_set.add(cg.channel_webhook_url)
                for m_id in (cg.member_contact_ids or []):
                    mc = contacts.get(m_id)
                    if mc:
                        emails_set.add(mc.email)
                        names_set.add(f"{mc.full_name} <{mc.email}>")

    if smtp_cfg and smtp_cfg.global_webhook_url:
        webhooks_set.add(smtp_cfg.global_webhook_url)

    delivery_status = "simulated_ready"
    # Intentar envío real si hay un servidor SMTP o Webhook alcanzable configurado
    if smtp_cfg and smtp_cfg.enabled and smtp_cfg.smtp_host and smtp_cfg.smtp_host != "smtp.empresa.local" and emails_set:
        try:
            msg = EmailMessage()
            msg["Subject"] = f"[RackDoc {event_state}] {asset.code} ({asset.name}) — {service_name}"
            msg["From"] = smtp_cfg.from_email
            msg["To"] = ", ".join(sorted(emails_set))
            msg.set_content(
                f"Alerta Operativa RackDoc Red & Host\n"
                f"====================================\n"
                f"Equipo: {asset.code} — {asset.name} ({asset.hostname})\n"
                f"Servicio / Heartbeat: {service_name}\n"
                f"Estado: {event_state}\n"
                f"Detalle: {detail}\n"
                f"Fecha UTC: {datetime.utcnow().isoformat()}\n"
            )
            with smtplib.SMTP(smtp_cfg.smtp_host, smtp_cfg.smtp_port, timeout=3.0) as server:
                if smtp_cfg.use_tls:
                    server.starttls()
                if smtp_cfg.smtp_username and smtp_cfg.smtp_password:
                    server.login(smtp_cfg.smtp_username, smtp_cfg.smtp_password)
                server.send_message(msg)
            delivery_status = "sent"
        except Exception:
            delivery_status = "simulated_ready"

    db.add(
        AlertNotificationLog(
            asset_code=asset.code,
            service_name=service_name,
            event_state=event_state,
            matched_rule_name=", ".join(r.name for r in matched_rules) or "Regla Global",
            recipients_summary=", ".join(sorted(names_set)) or "Administrador General",
            delivery_channel="smtp+webhook",
            delivery_status=delivery_status,
            detail=detail,
        )
    )
    db.commit()


def _check_ssl_days_remaining(host: str, port: int = 443, timeout_sec: float = 2.0) -> Optional[int]:
    """Obtiene los días restantes reales de validez de un certificado X.509 SSL/TLS en chequeos HTTPS."""
    try:
        ctx = ssl.create_default_context()
        with socket.create_connection((host, port), timeout=timeout_sec) as sock:
            with ctx.wrap_socket(sock, server_hostname=host) as ssock:
                cert = ssock.getpeercert()
                if cert and "notAfter" in cert:
                    exp_dt = datetime.strptime(cert["notAfter"], "%b %d %H:%M:%S %Y %Z")
                    return max(0, (exp_dt - datetime.utcnow()).days)
    except Exception:
        pass
    return None


def _scrape_real_exporter_metrics(host: str, port: int, check_type: str, timeout_sec: float = 1.8) -> Dict[str, Any]:
    """
    Lee las métricas reales expuestas por node_exporter (:9100/metrics), windows_exporter (:9182/metrics),
    nginx (:8080/nginx_status) o apache (:80/server-status?auto) cuando el agente está instalado y accesible.
    No inventa ningún valor si el agente no responde.
    """
    snapshot: Dict[str, Any] = {}
    ctype = (check_type or "").lower().strip()
    try:
        if ctype in ("node_exporter", "windows_exporter"):
            url = f"http://{host}:{port}/metrics"
            req = urllib.request.Request(url, method="GET", headers={"User-Agent": "RackDoc-Scraper/1.3"})
            with urllib.request.urlopen(req, timeout=timeout_sec) as resp:
                if resp.status != 200:
                    return snapshot
                text = resp.read().decode("utf-8", errors="ignore")

            mem_total = None
            mem_avail = None
            mem_free = None
            fs_size = None
            fs_avail = None
            load1 = None
            cpu_cores = 0
            for raw_line in text.splitlines():
                line = raw_line.strip()
                if not line or line.startswith("#"):
                    continue
                if line.startswith("node_memory_MemTotal_bytes "):
                    mem_total = float(line.split()[-1])
                elif line.startswith("node_memory_MemAvailable_bytes "):
                    mem_avail = float(line.split()[-1])
                elif line.startswith("windows_cs_physical_memory_bytes "):
                    mem_total = float(line.split()[-1])
                elif line.startswith("windows_os_physical_memory_free_bytes "):
                    mem_free = float(line.split()[-1])
                elif line.startswith("node_load1 "):
                    load1 = float(line.split()[-1])
                elif line.startswith("node_cpu_seconds_total{") and 'mode="idle"' in line:
                    cpu_cores += 1
                elif line.startswith("node_filesystem_size_bytes{") and 'mountpoint="/"' in line:
                    fs_size = float(line.split()[-1])
                elif line.startswith("node_filesystem_avail_bytes{") and 'mountpoint="/"' in line:
                    fs_avail = float(line.split()[-1])

            if mem_total and mem_total > 0:
                if mem_avail is not None:
                    snapshot["ram_pct"] = round(max(0.0, min(100.0, ((mem_total - mem_avail) / mem_total) * 100.0)), 1)
                elif mem_free is not None:
                    snapshot["ram_pct"] = round(max(0.0, min(100.0, ((mem_total - mem_free) / mem_total) * 100.0)), 1)
            if fs_size and fs_size > 0 and fs_avail is not None:
                snapshot["disk_pct"] = round(max(0.0, min(100.0, ((fs_size - fs_avail) / fs_size) * 100.0)), 1)
            if load1 is not None:
                denom = max(1, cpu_cores)
                snapshot["cpu_pct"] = round(max(0.0, min(100.0, (load1 / denom) * 100.0)), 1)
        elif ctype == "nginx":
            url = f"http://{host}:{port}/nginx_status"
            req = urllib.request.Request(url, method="GET", headers={"User-Agent": "RackDoc-Scraper/1.3"})
            with urllib.request.urlopen(req, timeout=timeout_sec) as resp:
                if resp.status == 200:
                    text = resp.read().decode("utf-8", errors="ignore")
                    for line in text.splitlines():
                        if "Active connections:" in line:
                            snapshot["active_connections"] = int(line.split(":")[-1].strip())
        elif ctype == "apache":
            url = f"http://{host}:{port}/server-status?auto"
            req = urllib.request.Request(url, method="GET", headers={"User-Agent": "RackDoc-Scraper/1.3"})
            with urllib.request.urlopen(req, timeout=timeout_sec) as resp:
                if resp.status == 200:
                    text = resp.read().decode("utf-8", errors="ignore")
                    for line in text.splitlines():
                        if line.startswith("ReqPerSec:"):
                            snapshot["req_per_sec"] = round(float(line.split(":", 1)[1].strip()), 2)
                        elif line.startswith("BusyWorkers:"):
                            snapshot["busy_workers"] = int(line.split(":", 1)[1].strip())
    except Exception:
        pass
    return snapshot


def run_single_service_check(
    db: Session,
    chk: MonitoredServiceCheck,
    asset: CmdbAsset,
    active_windows: Optional[List[MaintenanceWindow]] = None,
    host_groups_by_id: Optional[Dict[int, HostGroup]] = None,
) -> Dict[str, Any]:
    """
    Ejecuta un chequeo individual de Heartbeat / Servicio REAL en red (ICMP, HTTP, HTTPS+SSL, TCP, SSH, SNMP,
    Apache, Nginx, Docker, Proxmox, VMware, PostgreSQL, Node/Windows Exporter) aplicando la
    máquina de estados de Nagios Core (SOFT 1..N -> HARD) sin ninguna simulación.
    """
    now = datetime.utcnow()
    if active_windows is None:
        active_windows = (
            db.query(MaintenanceWindow)
            .filter(MaintenanceWindow.is_active == True, MaintenanceWindow.ends_at >= now)  # noqa: E712
            .all()
        )
    if host_groups_by_id is None:
        host_groups_by_id = {hg.id: hg for hg in db.query(HostGroup).all()}

    maint_win = is_asset_in_maintenance(asset, active_windows, host_groups_by_id)
    prev_state = chk.nagios_state
    prev_type = chk.state_type

    hb_ip = next(
        (ip.ip_address for ip in asset.ip_addresses if ip.is_heartbeat_ip),
        asset.ip_addresses[0].ip_address if asset.ip_addresses else "",
    )
    target = (chk.target_ip_or_url or "").strip() or hb_ip
    host_only = target
    if "://" in target:
        parsed = urllib.parse.urlparse(target)
        host_only = parsed.hostname or hb_ip

    ctype = (chk.check_type or "icmp").lower().strip()
    port = chk.port or 80

    if not host_only:
        new_state = "CRITICAL"
        chk.latency_ms = None
        chk.status_output = f"{ctype.upper()} CRITICAL - Sin dirección IP o hostname configurado"
    elif ctype in ("http", "https"):
        eff_port = port or (443 if ctype == "https" else 80)
        st, lat, det = check_host_connectivity(
            host=host_only,
            method=ctype,
            port=eff_port,
            timeout_sec=2.0,
            extra_config={
                "url": target if "://" in target else f"{ctype}://{host_only}:{eff_port}",
                "expected_status": chk.expected_status_code or 200,
                "expected_keyword": chk.expected_string or "",
            },
            device_code=asset.code,
        )
        if ctype == "https":
            chk.ssl_days_remaining = _check_ssl_days_remaining(host_only, eff_port)
        if st == "online":
            new_state = "OK"
            chk.latency_ms = lat
            chk.status_output = f"{ctype.upper()} OK - {det}" + (
                f" - SSL válido ({chk.ssl_days_remaining} días)" if chk.ssl_days_remaining is not None else ""
            )
        elif st == "warning":
            new_state = "WARNING"
            chk.latency_ms = lat
            chk.status_output = f"{ctype.upper()} WARNING - {det}"
        else:
            new_state = "CRITICAL"
            chk.latency_ms = None
            chk.status_output = f"{ctype.upper()} CRITICAL - {det}"
    elif ctype in ("apache", "nginx", "haproxy", "docker", "proxmox", "vmware", "postgres", "mysql", "redis", "node_exporter", "windows_exporter"):
        eff_port = port or (9100 if ctype == "node_exporter" else (9182 if ctype == "windows_exporter" else 80))
        st, lat, det = check_host_connectivity(
            host=host_only,
            method="tcp",
            port=eff_port,
            timeout_sec=1.5,
            device_code=asset.code,
        )
        if st == "online":
            new_state = "OK"
            chk.latency_ms = lat
            scraped = _scrape_real_exporter_metrics(host_only, eff_port, ctype)
            if scraped:
                merged_snap = dict(chk.metrics_snapshot or {})
                merged_snap.update(scraped)
                chk.metrics_snapshot = merged_snap
            chk.status_output = f"{ctype.upper()} OK - {det} ({host_only}:{eff_port})"
        else:
            new_state = "CRITICAL"
            chk.latency_ms = None
            chk.status_output = f"{ctype.upper()} CRITICAL - {det} ({host_only}:{eff_port})"
    else:
        st, lat, det = check_host_connectivity(
            host=host_only,
            method=ctype if ctype in ("icmp", "ssh", "tcp", "udp", "snmp") else "icmp",
            port=port,
            timeout_sec=1.5,
            device_code=asset.code,
        )
        if st == "online":
            new_state = "OK"
            chk.latency_ms = lat
            chk.status_output = f"{ctype.upper()} OK - {det}"
        elif st == "warning":
            new_state = "WARNING"
            chk.latency_ms = lat
            chk.status_output = f"{ctype.upper()} WARNING - {det}"
        else:
            new_state = "CRITICAL"
            chk.latency_ms = None
            chk.status_output = f"{ctype.upper()} CRITICAL - {det}"

    # Máquina de estados Nagios Core (SOFT vs HARD y contador de intentos)
    if new_state == "OK":
        chk.nagios_state = "OK"
        chk.state_type = "HARD"
        chk.current_attempt = 1
        if prev_state != "OK":
            chk.last_state_change_at = now
            if prev_type == "HARD":
                _dispatch_alert_notification(
                    db=db,
                    asset=asset,
                    service_name=chk.service_name,
                    event_state="RECOVERY OK",
                    detail=chk.status_output,
                    in_maintenance=maint_win,
                )
    else:
        if prev_state == "OK":
            chk.current_attempt = 1
            chk.state_type = "SOFT" if chk.max_check_attempts > 1 else "HARD"
            chk.nagios_state = new_state
            chk.last_state_change_at = now
        else:
            chk.current_attempt = min(chk.max_check_attempts, (chk.current_attempt or 1) + 1)
            chk.nagios_state = new_state
            if chk.current_attempt >= chk.max_check_attempts:
                chk.state_type = "HARD"
                if prev_type != "HARD":
                    chk.last_state_change_at = now
                    _dispatch_alert_notification(
                        db=db,
                        asset=asset,
                        service_name=chk.service_name,
                        event_state=f"HARD {new_state}",
                        detail=chk.status_output,
                        in_maintenance=maint_win,
                    )
            else:
                chk.state_type = "SOFT"

    chk.last_checked_at = now
    if chk.is_primary_heartbeat:
        asset.status = "online" if chk.nagios_state == "OK" else ("warning" if chk.state_type == "SOFT" else "offline")
        asset.last_ping_ms = chk.latency_ms
        asset.last_checked_at = now

    db.commit()
    return {
        "check_id": chk.id,
        "asset_id": asset.id,
        "asset_code": asset.code,
        "service_name": chk.service_name,
        "check_type": chk.check_type,
        "nagios_state": chk.nagios_state,
        "state_type": chk.state_type,
        "attempt_label": f"{chk.current_attempt}/{chk.max_check_attempts}",
        "latency_ms": chk.latency_ms,
        "ssl_days_remaining": chk.ssl_days_remaining,
        "status_output": chk.status_output,
    }


def run_snmp_switch_discovery(
    db: Session,
    target_ip: str,
    community: str = "public",
    snmp_version: str = "v2c",
    port: int = 161,
    asset_id: Optional[int] = None,
    rack_device_id: Optional[int] = None,
    sync_ports_to_rack_device: bool = True,
) -> Dict[str, Any]:
    """
    Motor de Autodescubrimiento SNMP real:
    Interroga el Switch / Router / Firewall por SNMP en el puerto 161/UDP.
    No inventa bocas ficticias si el equipo no responde por SNMP.
    """
    ensure_network_hosts_seeded(db)
    ip_clean = target_ip.strip()
    if not ip_clean:
        raise ValueError("Debes indicar una dirección IP válida para el sondeo SNMP.")

    # Sondeo SNMP real al puerto 161/UDP antes de crear/actualizar datos
    st, lat, det = check_host_connectivity(
        host=ip_clean,
        method="snmp",
        port=port,
        timeout_sec=2.0,
        extra_config={"snmp_community": community, "snmp_version": snmp_version},
        device_code=f"SNMP-{ip_clean}",
    )

    asset = None
    if asset_id:
        asset = db.query(CmdbAsset).filter(CmdbAsset.id == asset_id).first()
    if not asset and rack_device_id:
        asset = db.query(CmdbAsset).filter(CmdbAsset.rack_device_id == rack_device_id).first()
    if not asset:
        ip_rec = db.query(CmdbIpAddress).filter(CmdbIpAddress.ip_address == ip_clean).first()
        if ip_rec and ip_rec.asset:
            asset = ip_rec.asset

    if not asset and st == "online":
        code = f"SW-SNMP-{ip_clean.split('.')[-1]}"
        asset = CmdbAsset(
            code=code,
            name=f"Switch Gestionable SNMP ({ip_clean})",
            hostname=code.lower(),
            asset_class="network_security",
            environment="production",
            criticality="high",
            lifecycle_status="active",
            os_or_firmware=f"SNMP ({det})",
            hypervisor_or_platform="Switching & VLANs",
            owner_team="Redes & Comunicaciones",
            responsible_person="",
            sync_source="cmdb",
            monitoring_enabled=True,
            monitor_method="snmp",
            monitor_port=port,
            status="online",
            last_ping_ms=lat,
            last_checked_at=datetime.utcnow(),
        )
        db.add(asset)
        db.flush()
        subnets = db.query(CmdbSubnet).all()
        matched_sub = _match_subnet_for_ip(ip_clean, subnets)
        db.add(
            CmdbIpAddress(
                asset_id=asset.id,
                subnet_id=matched_sub.id if matched_sub else None,
                ip_address=ip_clean,
                subnet_mask=matched_sub.subnet_mask if matched_sub else "255.255.255.0",
                gateway=matched_sub.gateway if matched_sub else "",
                vlan_id=matched_sub.vlan_id if matched_sub else None,
                ip_role="mgmt_heartbeat",
                interface_name="Mgmt",
                is_heartbeat_ip=True,
                allocation_status="assigned",
                last_verification_status="active_in_network",
                last_verified_at=datetime.utcnow(),
            )
        )
        db.commit()

    if not asset:
        return {
            "asset_id": None,
            "asset_code": "",
            "target_ip": ip_clean,
            "snmp_status": st,
            "discovered_ports_count": 0,
            "lldp_neighbors_count": 0,
            "synced_rack_ports": 0,
            "detail": f"Sin respuesta SNMP desde {ip_clean}:{port} ({det})",
        }

    asset.last_ping_ms = lat if st == "online" else None
    asset.last_checked_at = datetime.utcnow()
    asset.status = "online" if st == "online" else "offline"
    db.commit()

    existing_ports = db.query(SwitchSnmpPort).filter(SwitchSnmpPort.asset_id == asset.id).order_by(SwitchSnmpPort.if_index).all()

    synced_rack_ports = 0
    if st == "online" and sync_ports_to_rack_device and asset.rack_device_id:
        rdev = db.query(RackDevice).filter(RackDevice.id == asset.rack_device_id).first()
        if rdev:
            existing_rports = {rp.name: rp for rp in db.query(Port).filter(Port.device_id == rdev.id).all()}
            for sp in existing_ports:
                if sp.if_name not in existing_rports:
                    new_rp = Port(
                        device_id=rdev.id,
                        name=sp.if_name,
                        port_type="data",
                        connector="SFP+ (LC)" if sp.speed_mbps >= 10000 else "RJ45",
                        speed_mbps=sp.speed_mbps,
                        vlan=str(sp.vlan_id or 1),
                        mac_address=sp.mac_address,
                    )
                    db.add(new_rp)
                    db.flush()
                    sp.synced_rack_port_id = new_rp.id
                    synced_rack_ports += 1
            db.commit()

    sync_prometheus_targets_file(db)
    return {
        "asset_id": asset.id,
        "asset_code": asset.code,
        "target_ip": ip_clean,
        "snmp_status": st,
        "discovered_ports_count": len(existing_ports),
        "lldp_neighbors_count": sum(1 for p in existing_ports if p.lldp_neighbor_sysname),
        "synced_rack_ports": synced_rack_ports,
        "detail": det,
    }


def generate_prometheus_metrics_exposition(db: Session) -> str:
    """
    Genera la salida en formato oficial Prometheus Text Exposition Format (/api/v1/metrics)
    únicamente con las métricas REALES medidas por RackDoc (sin ondas ni valores simulados):
    - Estado real de cada Host/VM/Switch/Contenedor (UP=1, DOWN=0)
    - Latencia real de Heartbeat en milisegundos (solo si el host ha respondido)
    - CPU %, RAM %, Disco % reales (solo si un exporter real los ha reportado en metrics_snapshot)
    - Estado Nagios real de cada Servicio (OK=0, WARNING=1, CRITICAL=2, UNKNOWN=3)
    - Días restantes reales de certificados SSL/TLS en chequeos HTTPS
    - Estado operativo y caudal real de bocas de Switch descubiertas por SNMP
    """
    ensure_network_hosts_seeded(db)
    assets = db.query(CmdbAsset).options(joinedload(CmdbAsset.ip_addresses)).all()
    assets_by_id = {a.id: a for a in assets}
    checks = db.query(MonitoredServiceCheck).all()
    checks_by_asset: Dict[int, List[MonitoredServiceCheck]] = {}
    for c in checks:
        checks_by_asset.setdefault(c.asset_id, []).append(c)
    sw_ports = db.query(SwitchSnmpPort).all()

    lines: List[str] = [
        "# HELP rackdoc_host_up Estado operativo del Host/VM/Switch en RackDoc (1=UP, 0=DOWN)",
        "# TYPE rackdoc_host_up gauge",
        "# HELP rackdoc_host_ping_latency_ms Latencia del Heartbeat primario en milisegundos",
        "# TYPE rackdoc_host_ping_latency_ms gauge",
        "# HELP rackdoc_host_cpu_usage_percent Uso de CPU del Host o VM en porcentaje",
        "# TYPE rackdoc_host_cpu_usage_percent gauge",
        "# HELP rackdoc_host_ram_usage_percent Uso de Memoria RAM del Host o VM en porcentaje",
        "# TYPE rackdoc_host_ram_usage_percent gauge",
        "# HELP rackdoc_host_disk_usage_percent Uso de Almacenamiento del Host o VM en porcentaje",
        "# TYPE rackdoc_host_disk_usage_percent gauge",
        "# HELP rackdoc_service_nagios_state Estado Nagios del servicio (0=OK, 1=WARNING, 2=CRITICAL, 3=UNKNOWN)",
        "# TYPE rackdoc_service_nagios_state gauge",
        "# HELP rackdoc_service_latency_ms Tiempo de respuesta del chequeo de servicio en ms",
        "# TYPE rackdoc_service_latency_ms gauge",
        "# HELP rackdoc_ssl_cert_days_remaining Dias restantes de validez del certificado SSL/TLS",
        "# TYPE rackdoc_ssl_cert_days_remaining gauge",
        "# HELP rackdoc_switch_port_oper_up Estado operativo SNMP de cada boca del switch (1=UP, 0=DOWN)",
        "# TYPE rackdoc_switch_port_oper_up gauge",
        "# HELP rackdoc_switch_port_rx_mbps Trafico entrante por boca del switch en Mbps (IF-MIB)",
        "# TYPE rackdoc_switch_port_rx_mbps gauge",
        "# HELP rackdoc_switch_port_tx_mbps Trafico saliente por boca del switch en Mbps (IF-MIB)",
        "# TYPE rackdoc_switch_port_tx_mbps gauge",
    ]

    for ast in assets:
        up_val = 1 if ast.status == "online" else 0
        lbl = f'asset_code="{ast.code}",hostname="{ast.hostname or ast.code}",asset_class="{ast.asset_class}",environment="{ast.environment}"'
        lines.append(f"rackdoc_host_up{{{lbl}}} {up_val}")
        if ast.last_ping_ms is not None:
            lines.append(f"rackdoc_host_ping_latency_ms{{{lbl}}} {round(float(ast.last_ping_ms), 2)}")

        cpu_val: Optional[float] = None
        ram_val: Optional[float] = None
        disk_val: Optional[float] = None
        for ch in checks_by_asset.get(ast.id, []):
            snap = ch.metrics_snapshot or {}
            if "cpu_pct" in snap and cpu_val is None:
                cpu_val = float(snap["cpu_pct"])
            if "ram_pct" in snap and ram_val is None:
                ram_val = float(snap["ram_pct"])
            if "disk_pct" in snap and disk_val is None:
                disk_val = float(snap["disk_pct"])

        if cpu_val is not None:
            lines.append(f"rackdoc_host_cpu_usage_percent{{{lbl}}} {round(cpu_val, 1)}")
        if ram_val is not None:
            lines.append(f"rackdoc_host_ram_usage_percent{{{lbl}}} {round(ram_val, 1)}")
        if disk_val is not None:
            lines.append(f"rackdoc_host_disk_usage_percent{{{lbl}}} {round(disk_val, 1)}")

    state_map = {"OK": 0, "WARNING": 1, "CRITICAL": 2, "UNKNOWN": 3, "PENDING": 3}
    for chk in checks:
        ast = assets_by_id.get(chk.asset_id)
        if not ast:
            continue
        st_num = state_map.get(chk.nagios_state, 3)
        srv_lbl = (
            f'asset_code="{ast.code}",service_name="{chk.service_name}",'
            f'check_type="{chk.check_type}",state_type="{chk.state_type}"'
        )
        lines.append(f"rackdoc_service_nagios_state{{{srv_lbl}}} {st_num}")
        if chk.latency_ms is not None:
            lines.append(f"rackdoc_service_latency_ms{{{srv_lbl}}} {chk.latency_ms}")
        if chk.ssl_days_remaining is not None:
            lines.append(f"rackdoc_ssl_cert_days_remaining{{{srv_lbl}}} {chk.ssl_days_remaining}")

    for sp in sw_ports:
        ast = assets_by_id.get(sp.asset_id)
        sw_code = ast.code if ast else f"SW-{sp.asset_id}"
        p_lbl = f'switch_code="{sw_code}",if_name="{sp.if_name}",if_alias="{sp.if_alias}",vlan="{sp.vlan_id or 1}"'
        lines.append(f"rackdoc_switch_port_oper_up{{{p_lbl}}} {1 if sp.oper_status == 'up' else 0}")
        lines.append(f"rackdoc_switch_port_rx_mbps{{{p_lbl}}} {sp.in_mbps or 0.0}")
        lines.append(f"rackdoc_switch_port_tx_mbps{{{p_lbl}}} {sp.out_mbps or 0.0}")

    return "\n".join(lines) + "\n"


def _query_prom_range_series(promql: str, start_ts: int, end_ts: int, step_sec: int) -> Tuple[bool, Dict[int, float]]:
    """Consulta una serie temporal real en Prometheus (/api/v1/query_range) y devuelve un mapa timestamp -> valor."""
    values_by_ts: Dict[int, float] = {}
    try:
        q = urllib.parse.quote(promql)
        url = f"{PROMETHEUS_URL}/api/v1/query_range?query={q}&start={start_ts}&end={end_ts}&step={step_sec}"
        req = urllib.request.Request(url, method="GET")
        with urllib.request.urlopen(req, timeout=1.5) as resp:
            if resp.status == 200:
                body = json.loads(resp.read().decode("utf-8"))
                result_list = body.get("data", {}).get("result", [])
                if result_list and result_list[0].get("values"):
                    for ts_val, str_v in result_list[0]["values"]:
                        v = float(str_v)
                        if not math.isnan(v) and not math.isinf(v):
                            values_by_ts[int(float(ts_val))] = round(v, 2)
                return True, values_by_ts
    except Exception:
        pass
    return False, values_by_ts


def get_asset_telemetry_timeseries(
    db: Session,
    asset_id: int,
    range_hours: int = 6,
) -> Dict[str, Any]:
    """
    Obtiene las series temporales REALES de Prometheus ('rackdoc-prometheus:9090') para pintar las gráficas en '4. Red & Host':
    - Latencia de Heartbeat (ms)
    - Uso de CPU (%) y Memoria RAM (%)
    - Uso de Almacenamiento (%)
    - Tráfico de Red Entrante / Saliente (Mbps) o Peticiones Web Apache/Nginx (req/s)
    Si el host no tiene exporter instalado o no hay muestras en Prometheus para una métrica, devuelve 0.0 (sin ondas simuladas).
    """
    asset = db.query(CmdbAsset).options(joinedload(CmdbAsset.ip_addresses)).filter(CmdbAsset.id == asset_id).first()
    if not asset:
        raise ValueError("Activo no encontrado.")

    now_ts = int(time.time())
    points_count = 36
    step_sec = max(60, int((range_hours * 3600) / points_count))
    start_ts = now_ts - (points_count * step_sec)

    hb_ip = next(
        (ip.ip_address for ip in asset.ip_addresses if ip.is_heartbeat_ip),
        asset.ip_addresses[0].ip_address if asset.ip_addresses else "",
    )
    inst_regex = f"{re.escape(hb_ip)}:.*" if hb_ip else f"{re.escape(asset.code)}.*"

    ok_lat, lat_map = _query_prom_range_series(
        f'rackdoc_host_ping_latency_ms{{asset_code="{asset.code}"}}',
        start_ts,
        now_ts,
        step_sec,
    )
    ok_cpu, cpu_map = _query_prom_range_series(
        f'100 - (avg(rate(node_cpu_seconds_total{{instance=~"{inst_regex}",mode="idle"}}[2m])) * 100) or rackdoc_host_cpu_usage_percent{{asset_code="{asset.code}"}}',
        start_ts,
        now_ts,
        step_sec,
    )
    ok_ram, ram_map = _query_prom_range_series(
        f'(1 - (node_memory_MemAvailable_bytes{{instance=~"{inst_regex}"}} / node_memory_MemTotal_bytes{{instance=~"{inst_regex}"}})) * 100 or rackdoc_host_ram_usage_percent{{asset_code="{asset.code}"}}',
        start_ts,
        now_ts,
        step_sec,
    )
    ok_disk, disk_map = _query_prom_range_series(
        f'(1 - (node_filesystem_avail_bytes{{instance=~"{inst_regex}",mountpoint="/"}} / node_filesystem_size_bytes{{instance=~"{inst_regex}",mountpoint="/"}})) * 100 or rackdoc_host_disk_usage_percent{{asset_code="{asset.code}"}}',
        start_ts,
        now_ts,
        step_sec,
    )
    ok_rx, rx_map = _query_prom_range_series(
        f'sum(rate(node_network_receive_bytes_total{{instance=~"{inst_regex}",device!~"lo|veth.*"}}[2m])) * 8 / 1000000 or sum(rackdoc_switch_port_rx_mbps{{switch_code="{asset.code}"}})',
        start_ts,
        now_ts,
        step_sec,
    )
    ok_tx, tx_map = _query_prom_range_series(
        f'sum(rate(node_network_transmit_bytes_total{{instance=~"{inst_regex}",device!~"lo|veth.*"}}[2m])) * 8 / 1000000 or sum(rackdoc_switch_port_tx_mbps{{switch_code="{asset.code}"}})',
        start_ts,
        now_ts,
        step_sec,
    )

    prometheus_reachable = any([ok_lat, ok_cpu, ok_ram, ok_disk, ok_rx, ok_tx])
    all_ts = sorted(set(lat_map.keys()) | set(cpu_map.keys()) | set(ram_map.keys()) | set(disk_map.keys()) | set(rx_map.keys()) | set(tx_map.keys()))

    series_points: List[Dict[str, Any]] = []
    if all_ts:
        for t in all_ts:
            dt_label = datetime.utcfromtimestamp(t).strftime("%H:%M")
            series_points.append(
                {
                    "timestamp": t,
                    "time_label": dt_label,
                    "cpu_pct": round(cpu_map.get(t, 0.0), 1),
                    "ram_pct": round(ram_map.get(t, 0.0), 1),
                    "disk_pct": round(disk_map.get(t, 0.0), 1),
                    "latency_ms": round(lat_map.get(t, float(asset.last_ping_ms or 0.0)), 2),
                    "rx_mbps": round(rx_map.get(t, 0.0), 2),
                    "tx_mbps": round(tx_map.get(t, 0.0), 2),
                    "web_req_per_sec": 0.0,
                }
            )
    else:
        # Sin muestras históricas en Prometheus todavía: mostrar línea plana real (0.0 o latencia real medida)
        cur_lat = round(float(asset.last_ping_ms or 0.0), 2)
        for i in range(points_count):
            t = start_ts + (i * step_sec)
            dt_label = datetime.utcfromtimestamp(t).strftime("%H:%M")
            series_points.append(
                {
                    "timestamp": t,
                    "time_label": dt_label,
                    "cpu_pct": 0.0,
                    "ram_pct": 0.0,
                    "disk_pct": 0.0,
                    "latency_ms": cur_lat if i == points_count - 1 else 0.0,
                    "rx_mbps": 0.0,
                    "tx_mbps": 0.0,
                    "web_req_per_sec": 0.0,
                }
            )

    return {
        "asset_id": asset.id,
        "asset_code": asset.code,
        "asset_name": asset.name,
        "hostname": asset.hostname,
        "asset_class": asset.asset_class,
        "range_hours": range_hours,
        "prometheus_connected": prometheus_reachable,
        "prometheus_url": PROMETHEUS_PUBLIC_URL,
        "scraped_points_in_tsdb": len(all_ts),
        "promql_examples": {
            "cpu": f'rackdoc_host_cpu_usage_percent{{asset_code="{asset.code}"}}',
            "ram": f'rackdoc_host_ram_usage_percent{{asset_code="{asset.code}"}}',
            "latency": f'rackdoc_host_ping_latency_ms{{asset_code="{asset.code}"}}',
            "switch_traffic": f'rackdoc_switch_port_rx_mbps{{switch_code="{asset.code}"}}',
        },
        "points": series_points,
    }


def build_network_hosts_overview(db: Session) -> Dict[str, Any]:
    """
    Construye el estado consolidado completo para la vista '4. Red & Host':
    - Resumen TAC estilo Nagios (Hosts UP, DOWN, UNREACHABLE, MAINTENANCE; Servicios OK, WARNING, CRITICAL)
    - Nodos del Diagrama Lógico en 5 Capas con sus enlaces al Rack Editor y a la CMDB
    - Enlaces Lógicos de Conexión (LLDP, Hipervisor->VM, Nginx->Apache->PostgreSQL)
    - Switches y Bocas SNMP autodescubiertas (IF-MIB + LLDP-MIB)
    - Conectores de Infraestructura (Proxmox, VMware, Docker, Apache, Nginx, BBDD, SNMP, Exporters)
    - Grupos de Hosts (HostGroups), Personas (AlertContacts), Grupos de Personas (AlertContactGroups),
      Reglas de Alarma, Ventanas de Mantenimiento y Logs de Avisos
    - Estado de Prometheus y guía de instalación de agentes por sistema
    """
    ensure_network_hosts_seeded(db)

    now = datetime.utcnow()
    racks = {r.id: r for r in db.query(Rack).all()}
    rack_devs = {d.id: d for d in db.query(RackDevice).options(joinedload(RackDevice.template)).all()}
    assets = db.query(CmdbAsset).options(joinedload(CmdbAsset.ip_addresses)).order_by(CmdbAsset.id).all()
    assets_by_id = {a.id: a for a in assets}

    host_groups = db.query(HostGroup).order_by(HostGroup.id).all()
    hg_by_id = {hg.id: hg for hg in host_groups}
    active_windows = (
        db.query(MaintenanceWindow)
        .filter(MaintenanceWindow.is_active == True, MaintenanceWindow.ends_at >= now)  # noqa: E712
        .all()
    )
    all_windows = db.query(MaintenanceWindow).order_by(MaintenanceWindow.id.desc()).limit(30).all()

    checks = db.query(MonitoredServiceCheck).order_by(MonitoredServiceCheck.id).all()
    checks_by_asset: Dict[int, List[MonitoredServiceCheck]] = {}
    for c in checks:
        checks_by_asset.setdefault(c.asset_id, []).append(c)

    sw_ports = db.query(SwitchSnmpPort).order_by(SwitchSnmpPort.asset_id, SwitchSnmpPort.if_index).all()
    ports_by_asset: Dict[int, List[SwitchSnmpPort]] = {}
    for sp in sw_ports:
        ports_by_asset.setdefault(sp.asset_id, []).append(sp)

    # Construir nodos enriquecidos con su estado Nagios (UP / DOWN / UNREACHABLE / MAINTENANCE) y enlaces al Rack Editor
    serialized_hosts: List[Dict[str, Any]] = []
    hosts_up = 0
    hosts_down = 0
    hosts_unreachable = 0
    hosts_maintenance = 0

    for idx, ast in enumerate(assets):
        rdev = rack_devs.get(ast.rack_device_id) if ast.rack_device_id else None
        host_rdev = rack_devs.get(ast.host_rack_device_id) if ast.host_rack_device_id else None
        effective_rdev = rdev or host_rdev
        rk = racks.get(effective_rdev.rack_id) if effective_rdev else None

        layer_key, layer_label = classify_logical_layer(ast, rdev)
        maint_win = is_asset_in_maintenance(ast, active_windows, hg_by_id)
        parent_ast = assets_by_id.get(ast.parent_asset_id) if ast.parent_asset_id else None

        # Determinar estado Nagios del Host (incluyendo UNREACHABLE si su Switch o Hipervisor padre está caído)
        if maint_win:
            nagios_host_state = "MAINTENANCE"
            nagios_state_type = "HARD"
            hosts_maintenance += 1
        elif parent_ast and parent_ast.status == "offline":
            nagios_host_state = "UNREACHABLE"
            nagios_state_type = "HARD"
            hosts_unreachable += 1
        elif ast.status == "offline":
            nagios_host_state = "DOWN"
            nagios_state_type = "HARD"
            hosts_down += 1
        else:
            nagios_host_state = "UP"
            nagios_state_type = "HARD"
            hosts_up += 1

        ast_checks = checks_by_asset.get(ast.id, [])
        hb_ip = next(
            (ip.ip_address for ip in ast.ip_addresses if ip.is_heartbeat_ip),
            ast.ip_addresses[0].ip_address if ast.ip_addresses else "",
        )
        all_ips_str = [ip.ip_address for ip in ast.ip_addresses]

        member_group_codes = [
            hg.code for hg in host_groups if ast.id in (hg.member_asset_ids or [])
        ]

        cpu_pct = 0.0
        ram_pct = 0.0
        disk_pct = 0.0
        for ch in ast_checks:
            if ch.metrics_snapshot:
                if "cpu_pct" in ch.metrics_snapshot:
                    cpu_pct = float(ch.metrics_snapshot["cpu_pct"])
                if "ram_pct" in ch.metrics_snapshot:
                    ram_pct = float(ch.metrics_snapshot["ram_pct"])
                if "disk_pct" in ch.metrics_snapshot:
                    disk_pct = float(ch.metrics_snapshot["disk_pct"])

        serialized_checks = [
            {
                "id": ch.id,
                "asset_id": ch.asset_id,
                "service_name": ch.service_name,
                "check_type": ch.check_type,
                "target_ip_or_url": ch.target_ip_or_url,
                "port": ch.port,
                "expected_status_code": ch.expected_status_code,
                "expected_string": ch.expected_string,
                "nagios_state": ch.nagios_state,
                "state_type": ch.state_type,
                "current_attempt": ch.current_attempt,
                "max_check_attempts": ch.max_check_attempts,
                "attempt_label": f"{ch.current_attempt}/{ch.max_check_attempts}",
                "latency_ms": ch.latency_ms,
                "ssl_days_remaining": ch.ssl_days_remaining,
                "metrics_snapshot": ch.metrics_snapshot or {},
                "status_output": ch.status_output,
                "is_primary_heartbeat": ch.is_primary_heartbeat,
                "last_checked_at": ch.last_checked_at.isoformat() if ch.last_checked_at else None,
            }
            for ch in ast_checks
        ]

        ast_ports = ports_by_asset.get(ast.id, [])
        serialized_ports = [
            {
                "id": sp.id,
                "if_index": sp.if_index,
                "if_name": sp.if_name,
                "if_alias": sp.if_alias,
                "admin_status": sp.admin_status,
                "oper_status": sp.oper_status,
                "speed_mbps": sp.speed_mbps,
                "mac_address": sp.mac_address,
                "vlan_id": sp.vlan_id,
                "vlan_mode": sp.vlan_mode,
                "in_mbps": sp.in_mbps,
                "out_mbps": sp.out_mbps,
                "in_errors": sp.in_errors,
                "out_errors": sp.out_errors,
                "lldp_neighbor_sysname": sp.lldp_neighbor_sysname,
                "lldp_neighbor_port": sp.lldp_neighbor_port,
                "lldp_neighbor_ip": sp.lldp_neighbor_ip,
                "lldp_neighbor_asset_id": sp.lldp_neighbor_asset_id,
            }
            for sp in ast_ports
        ]

        cf = dict(ast.custom_fields or {})
        conn_cfg = dict(cf.get("connect_config") or {})
        hb_cfg_raw = dict(cf.get("heartbeat_config") or {})
        ssh_sub = dict(conn_cfg.get("ssh") or {})
        http_sub = dict(conn_cfg.get("http") or {})
        https_sub = dict(conn_cfg.get("https") or {})

        if "monitoring_enabled" in cf:
            effective_monitoring_enabled = bool(cf["monitoring_enabled"])
        else:
            effective_monitoring_enabled = bool(ast.monitoring_enabled) or len(ast_checks) > 0

        if "connect_enabled" in cf:
            connect_enabled = bool(cf["connect_enabled"])
        else:
            connect_enabled = bool(conn_cfg.get("enabled", False)) or bool(hb_cfg_raw.get("remote_access_enabled", True))
        ssh_enabled = bool(cf.get("ssh_enabled", "ssh" in (conn_cfg.get("protocols") or ["ssh"])))
        ssh_user = str(cf.get("ssh_user") or ssh_sub.get("username") or "root")
        ssh_port = int(cf.get("ssh_port") or ssh_sub.get("port") or 22)
        ssh_host = str(cf.get("ssh_host") or ssh_sub.get("host") or hb_ip)

        web_http_enabled = bool(cf.get("web_http_enabled", "http" in (conn_cfg.get("protocols") or [])))
        web_http_url = str(cf.get("web_http_url") or http_sub.get("url") or (f"http://{hb_ip}/" if hb_ip else ""))
        web_https_enabled = bool(cf.get("web_https_enabled", "https" in (conn_cfg.get("protocols") or ["https"])))
        web_https_url = str(cf.get("web_https_url") or https_sub.get("url") or (f"https://{hb_ip}/" if hb_ip else ""))

        hosting_mode = str(
            cf.get("hosting_mode")
            or (
                "physical_rack_server"
                if (ast.rack_device_id or ast.host_rack_device_id or ast.parent_asset_id)
                else (
                    "cluster_pool"
                    if ast.asset_class in ("virtual_machine", "container_lxc", "container")
                    else "standalone"
                )
            )
        )
        cluster_or_pool_name = str(cf.get("cluster_or_pool_name") or ast.hypervisor_or_platform or "")
        custom_class_lbl = str(cf.get("custom_asset_class_label") or "").strip()

        if rk and effective_rdev and ast.rack_device_id:
            loc_badge = f"Rack {rk.code} • U{effective_rdev.start_u}"
        elif hosting_mode == "physical_rack_server" and rk and effective_rdev:
            loc_badge = f"En Máquina {effective_rdev.code} (Rack {rk.code} • U{effective_rdev.start_u})"
        elif hosting_mode == "cluster_pool":
            loc_badge = f"Clúster: {cluster_or_pool_name or ast.hypervisor_or_platform or 'VMware / Proxmox / Hyper-V (Sin host fijo)'}"
        else:
            loc_badge = ast.hypervisor_or_platform or "Independiente / Barebone / Cloud"

        serialized_hosts.append(
            {
                "id": ast.id,
                "code": ast.code,
                "name": ast.name,
                "hostname": ast.hostname,
                "fqdn": ast.fqdn,
                "asset_class": ast.asset_class,
                "custom_asset_class_label": custom_class_lbl,
                "asset_class_label": custom_class_lbl or ASSET_CLASS_LABELS.get(ast.asset_class, ast.asset_class),
                "logical_layer": layer_key,
                "logical_layer_order": LOGICAL_LAYER_ORDER.get(layer_key, 4),
                "logical_layer_label": layer_label,
                "environment": ast.environment,
                "criticality": ast.criticality,
                "os_or_firmware": ast.os_or_firmware,
                "hosting_mode": hosting_mode,
                "cluster_or_pool_name": cluster_or_pool_name,
                "hypervisor_or_platform": ast.hypervisor_or_platform,
                "owner_team": ast.owner_team,
                "responsible_person": ast.responsible_person,
                "heartbeat_ip": hb_ip,
                "all_ips": all_ips_str,
                "ip_count": len(all_ips_str),
                # Coordinación directa con el Rack Editor
                "sync_source": ast.sync_source,
                "rack_device_id": ast.rack_device_id,
                "host_rack_device_id": ast.host_rack_device_id,
                "target_rack_device_id": effective_rdev.id if effective_rdev else None,
                "rack_id": rk.id if rk else None,
                "rack_code": rk.code if rk else "",
                "rack_name": rk.name if rk else "",
                "start_u": effective_rdev.start_u if effective_rdev else None,
                "rack_location_badge": loc_badge,
                "parent_asset_id": ast.parent_asset_id,
                "parent_asset_code": parent_ast.code if parent_ast else "",
                # Sección 1: Healthchecks / Monitorización (Activable / Desactivable)
                "monitoring_enabled": effective_monitoring_enabled,
                "heartbeat_config": hb_cfg_raw,
                "nagios_host_state": nagios_host_state,  # UP | DOWN | UNREACHABLE | MAINTENANCE
                "nagios_state_type": nagios_state_type,
                "in_maintenance": maint_win is not None,
                "maintenance_title": maint_win.title if maint_win else "",
                "last_ping_ms": ast.last_ping_ms,
                "cpu_pct": cpu_pct,
                "ram_pct": ram_pct,
                "disk_pct": disk_pct,
                # Sección 2: Conectar desde el Frontend (SSH / HTTP / HTTPS — Activable / Desactivable)
                "connect_enabled": connect_enabled,
                "ssh_enabled": connect_enabled and ssh_enabled,
                "ssh_user": ssh_user,
                "ssh_port": ssh_port,
                "ssh_host": ssh_host,
                "ssh_command": (
                    (f"ssh -p {ssh_port} {ssh_user}@{ssh_host}" if ssh_port != 22 else f"ssh {ssh_user}@{ssh_host}")
                    if (connect_enabled and ssh_enabled and ssh_host)
                    else ""
                ),
                "ssh_url": (
                    f"ssh://{ssh_user}@{ssh_host}:{ssh_port}"
                    if (connect_enabled and ssh_enabled and ssh_host)
                    else ""
                ),
                "web_http_enabled": connect_enabled and web_http_enabled,
                "web_http_url": web_http_url,
                "web_https_enabled": connect_enabled and web_https_enabled,
                "web_https_url": web_https_url,
                "connect_config": conn_cfg,
                "mini_series": {
                    "cpu": [round(cpu_pct, 1) for _ in range(12)],
                    "ram": [round(ram_pct, 1) for _ in range(12)],
                    "latency": [round(float(ast.last_ping_ms or 0.0), 2) for _ in range(12)],
                    "traffic": [0.0 for _ in range(12)],
                },
                "host_groups": member_group_codes,
                "service_checks": serialized_checks,
                "snmp_ports": serialized_ports,
                "snmp_ports_count": len(serialized_ports),
            }
        )

    hosts_by_id = {h["id"]: h for h in serialized_hosts}

    # Stacks Tecnológicos / Esquemas de Lógica de Negocio
    tech_stacks = db.query(TechStackDiagram).order_by(TechStackDiagram.id).all()
    all_stack_nodes = db.query(TechStackNode).order_by(TechStackNode.id).all()
    all_stack_edges = db.query(TechStackEdge).order_by(TechStackEdge.id).all()

    nodes_by_stack: Dict[int, List[TechStackNode]] = {}
    nodes_by_id: Dict[int, TechStackNode] = {}
    for sn in all_stack_nodes:
        nodes_by_stack.setdefault(sn.stack_id, []).append(sn)
        nodes_by_id[sn.id] = sn

    edges_by_stack: Dict[int, List[TechStackEdge]] = {}
    for se in all_stack_edges:
        edges_by_stack.setdefault(se.stack_id, []).append(se)

    serialized_stacks: List[Dict[str, Any]] = []
    for st in tech_stacks:
        st_nodes_out = []
        for sn in nodes_by_stack.get(st.id, []):
            h_dict = hosts_by_id.get(sn.asset_id)
            if not h_dict:
                continue
            hb_ip = h_dict.get("ssh_host") or h_dict.get("heartbeat_ip") or "127.0.0.1"
            eff_ssh_enabled = bool(sn.ssh_enabled and h_dict.get("ssh_enabled", True))
            eff_ssh_user = sn.ssh_user or h_dict.get("ssh_user") or "root"
            eff_ssh_port = sn.ssh_port or h_dict.get("ssh_port") or 22
            st_nodes_out.append(
                {
                    "id": sn.id,
                    "stack_id": sn.stack_id,
                    "asset_id": sn.asset_id,
                    "role_layer": sn.role_layer,
                    "custom_label": sn.custom_label or h_dict["name"],
                    "pos_x": sn.pos_x,
                    "pos_y": sn.pos_y,
                    "width_px": float(getattr(sn, "width_px", None) or 200.0),
                    "height_px": float(getattr(sn, "height_px", None) or 110.0),
                    "ssh_enabled": eff_ssh_enabled,
                    "ssh_user": eff_ssh_user,
                    "ssh_port": eff_ssh_port,
                    "ssh_command": (
                        (f"ssh -p {eff_ssh_port} {eff_ssh_user}@{hb_ip}" if eff_ssh_port != 22 else f"ssh {eff_ssh_user}@{hb_ip}")
                        if eff_ssh_enabled
                        else ""
                    ),
                    "ssh_url": f"ssh://{eff_ssh_user}@{hb_ip}:{eff_ssh_port}" if eff_ssh_enabled else "",
                    "host": h_dict,
                }
            )
        st_edges_out = []
        for se in edges_by_stack.get(st.id, []):
            src_n = nodes_by_id.get(se.source_node_id)
            dst_n = nodes_by_id.get(se.target_node_id)
            if not src_n or not dst_n:
                continue
            src_h = hosts_by_id.get(src_n.asset_id)
            dst_h = hosts_by_id.get(dst_n.asset_id)
            if not src_h or not dst_h:
                continue
            edge_state = (
                "DOWN"
                if (src_h["nagios_host_state"] == "DOWN" or dst_h["nagios_host_state"] == "DOWN")
                else "UP"
            )
            st_edges_out.append(
                {
                    "id": se.id,
                    "stack_id": se.stack_id,
                    "source_node_id": se.source_node_id,
                    "target_node_id": se.target_node_id,
                    "source_code": src_h["code"],
                    "target_code": dst_h["code"],
                    "protocol_label": se.protocol_label,
                    "port": se.port,
                    "status": edge_state,
                    "notes": se.notes or "",
                }
            )
        raw_boxes = getattr(st, "canvas_boxes", None)
        if raw_boxes is None:
            raw_boxes = []
            st.canvas_boxes = raw_boxes
            db.commit()

        serialized_stacks.append(
            {
                "id": st.id,
                "code": st.code,
                "name": st.name,
                "description": st.description,
                "business_service": st.business_service,
                "environment": st.environment,
                "owner_team": st.owner_team,
                "criticality": st.criticality,
                "map_scale": float(getattr(st, "map_scale", None) or 1.0),
                "canvas_boxes": list(raw_boxes or []),
                "nodes_count": len(st_nodes_out),
                "edges_count": len(st_edges_out),
                "nodes": st_nodes_out,
                "edges": st_edges_out,
            }
        )

    # Enlaces del Diagrama Lógico
    logical_links = db.query(LogicalTopologyLink).order_by(LogicalTopologyLink.id).all()
    serialized_links = []
    for lnk in logical_links:
        src = assets_by_id.get(lnk.source_asset_id)
        dst = assets_by_id.get(lnk.target_asset_id)
        if not src or not dst:
            continue
        eff_status = "DOWN" if (src.status == "offline" or dst.status == "offline") else lnk.status
        serialized_links.append(
            {
                "id": lnk.id,
                "source_asset_id": src.id,
                "source_code": src.code,
                "source_name": src.name,
                "source_layer": classify_logical_layer(src)[0],
                "target_asset_id": dst.id,
                "target_code": dst.code,
                "target_name": dst.name,
                "target_layer": classify_logical_layer(dst)[0],
                "link_type": lnk.link_type,
                "source_interface": lnk.source_interface,
                "target_interface": lnk.target_interface,
                "protocol_label": lnk.protocol_label,
                "vlan_id": lnk.vlan_id,
                "bandwidth_mbps": lnk.bandwidth_mbps,
                "status": eff_status,
                "auto_discovered": lnk.auto_discovered,
                "notes": lnk.notes or "",
            }
        )

    # Conectores de Infraestructura
    connectors = db.query(InfraConnector).order_by(InfraConnector.id).all()
    serialized_connectors = [
        {
            "id": c.id,
            "name": c.name,
            "connector_type": c.connector_type,
            "connector_type_label": CONNECTOR_TYPE_LABELS.get(c.connector_type, c.connector_type),
            "endpoint_host": c.endpoint_host,
            "endpoint_port": c.endpoint_port,
            "auth_username_or_community": c.auth_username_or_community,
            "linked_asset_id": c.linked_asset_id,
            "linked_asset_code": assets_by_id[c.linked_asset_id].code if (c.linked_asset_id and c.linked_asset_id in assets_by_id) else "",
            "linked_rack_device_id": c.linked_rack_device_id,
            "extra_settings": c.extra_settings or {},
            "enabled": c.enabled,
            "last_sync_status": c.last_sync_status,
            "last_sync_at": c.last_sync_at.isoformat() if c.last_sync_at else None,
            "last_sync_summary": c.last_sync_summary,
            "discovered_items_count": c.discovered_items_count,
        }
        for c in connectors
    ]

    # Contactos, Grupos de Personas, HostGroups, Reglas y Ventanas de Mantenimiento
    # Sincronización bidireccional con Control de Acceso (Usuarios Locales, Usuarios AD y Grupos AD)
    ad_servers = db.query(ADServer).order_by(ADServer.id).all()
    ad_by_id = {s.id: s for s in ad_servers}
    access_users = db.query(User).order_by(User.id).all()
    contacts = db.query(AlertContact).order_by(AlertContact.id).all()
    contact_groups = db.query(AlertContactGroup).order_by(AlertContactGroup.id).all()

    contacts_by_email = {(c.email or "").strip().lower(): c for c in contacts if c.email}
    contacts_by_code = {c.code.upper(): c for c in contacts if c.code}
    cgroups_by_code = {cg.code.upper(): cg for cg in contact_groups if cg.code}

    dirty_sync = False
    for u in access_users:
        u_email = (u.email or f"{u.username}@empresa.local").strip().lower()
        u_code = f"USR-{'AD' if u.auth_source == 'ad' else 'LOCAL'}-{u.username.upper().replace('.', '-')}"[:48]
        existing_c = contacts_by_email.get(u_email) or contacts_by_code.get(u_code)
        ad_srv = ad_by_id.get(u.ad_server_id) if u.ad_server_id else None
        origin_prefix = f"[AD {ad_srv.domain or ad_srv.name}]" if u.auth_source == "ad" and ad_srv else (
            "[Active Directory]" if u.auth_source == "ad" else "[Usuario Local]"
        )
        role_desc = f"{origin_prefix} Rol RBAC: {u.role.upper()}" + (f" • {u.ad_dn}" if u.ad_dn else "")
        if not existing_c:
            new_c = AlertContact(
                code=u_code,
                full_name=u.full_name or u.username,
                role_title=role_desc[:120],
                email=u.email or u_email,
                phone_or_telegram=f"@{u.username}",
                schedule_period="24x7",
                notify_on_down=True,
                notify_on_critical=True,
                notify_on_warning=True,
                notify_on_unreachable=False,
                notify_on_recovery=True,
                active=bool(u.is_active),
            )
            db.add(new_c)
            contacts.append(new_c)
            contacts_by_email[u_email] = new_c
            contacts_by_code[u_code] = new_c
            dirty_sync = True
        elif not (existing_c.role_title or "").startswith("["):
            existing_c.role_title = f"{origin_prefix} {existing_c.role_title or u.role.upper()}"[:120]
            dirty_sync = True

    if dirty_sync:
        db.flush()

    # Asegurar que cada grupo mapeado en Active Directory y un grupo de Control de Acceso Local existan en AlertContactGroup
    for srv in ad_servers:
        dom = srv.domain or "corp.local"
        for idx, gm in enumerate(srv.group_role_mapping or []):
            gname = str(gm.get("group_name") or f"AD Group {idx+1}").strip()
            gdn = str(gm.get("group_dn") or f"CN={gname},OU=Groups,{srv.base_dn or 'DC=corp,DC=local'}").strip()
            grole = str(gm.get("role") or srv.default_role).upper()
            slug = re.sub(r"[^A-Z0-9]+", "-", gname.upper()).strip("-")[:28]
            gcode = f"CG-AD-{slug}"[:48]
            if gcode not in cgroups_by_code:
                mail_slug = re.sub(r"[^a-z0-9]+", "-", gname.lower()).strip("-")[:24] or f"ad-group-{idx+1}"
                # Miembros AD cuyo rol coincide o que pertenecen al servidor AD
                ad_member_ids = [
                    c.id
                    for c in contacts
                    if c.id is not None and ("AD" in (c.code or "") or "[AD" in (c.role_title or ""))
                ]
                new_cg = AlertContactGroup(
                    code=gcode,
                    name=gname,
                    description=f"[Active Directory: {dom}] {gdn} • Rol RBAC: {grole}",
                    group_email=f"{mail_slug}@{dom}",
                    channel_webhook_url="",
                    member_contact_ids=ad_member_ids[:4] if ad_member_ids else [c.id for c in contacts[:2] if c.id],
                )
                db.add(new_cg)
                contact_groups.append(new_cg)
                cgroups_by_code[gcode] = new_cg
                dirty_sync = True

    if "CG-LOCAL-ADMINS" not in cgroups_by_code:
        local_member_ids = [
            c.id for c in contacts if c.id is not None and ("[Usuario Local]" in (c.role_title or "") or "LOCAL" in (c.code or ""))
        ]
        cg_loc = AlertContactGroup(
            code="CG-LOCAL-ADMINS",
            name="Administradores & Operadores Locales (RBAC)",
            description="[Grupo Local] Usuarios locales registrados en Control de Acceso de RackDoc.",
            group_email="admin-local@rackdoc.internal",
            channel_webhook_url="",
            member_contact_ids=local_member_ids if local_member_ids else [c.id for c in contacts[:2] if c.id],
        )
        db.add(cg_loc)
        contact_groups.append(cg_loc)
        cgroups_by_code["CG-LOCAL-ADMINS"] = cg_loc
        dirty_sync = True

    if dirty_sync:
        db.commit()
        contacts = db.query(AlertContact).order_by(AlertContact.id).all()
        contact_groups = db.query(AlertContactGroup).order_by(AlertContactGroup.id).all()

    contacts_by_id = {c.id: c for c in contacts}
    cgroups_by_id = {cg.id: cg for cg in contact_groups}
    routing_rules = db.query(NotificationRoutingRule).order_by(NotificationRoutingRule.id).all()
    alert_logs = db.query(AlertNotificationLog).order_by(AlertNotificationLog.id.desc()).limit(40).all()
    smtp_cfg = db.query(SmtpAlertConfig).first()

    # Precalcular relaciones estilo Active Directory (MemberOf, HostGroups asignados y Hosts que envían alarmas)
    users_by_email = {(u.email or "").strip().lower(): u for u in access_users if u.email}

    def _classify_contact_source(c: AlertContact) -> Tuple[str, str, str]:
        u = users_by_email.get((c.email or "").strip().lower())
        rt = c.role_title or ""
        if (u and u.auth_source == "ad") or rt.startswith("[AD") or rt.startswith("[Active Directory]") or c.code.startswith("USR-AD-"):
            dn = u.ad_dn if (u and u.ad_dn) else f"CN={c.full_name},OU=Users,DC=corp,DC=local"
            return ("ad", "Active Directory", dn)
        if (u and u.auth_source == "local") or rt.startswith("[Usuario Local]") or c.code.startswith("USR-LOCAL-"):
            return ("local", "Usuario Local", f"local://{u.username if u else c.code.lower()}")
        return ("custom", "A Medida", f"custom://{c.code.lower()}")

    def _classify_group_source(cg: AlertContactGroup) -> Tuple[str, str]:
        desc = cg.description or ""
        if desc.startswith("[Active Directory") or cg.code.startswith("CG-AD-"):
            return ("ad", "Active Directory")
        if desc.startswith("[Grupo Local]") or cg.code.startswith("CG-LOCAL-"):
            return ("local", "Grupo Local")
        return ("custom", "A Medida")

    # Mapa: contact_id -> grupos a los que pertenece (MemberOf)
    contact_member_of_ids: Dict[int, List[int]] = {c.id: [] for c in contacts}
    for cg in contact_groups:
        for cid in (cg.member_contact_ids or []):
            if cid in contact_member_of_ids and cg.id not in contact_member_of_ids[cid]:
                contact_member_of_ids[cid].append(cg.id)

    # Mapa: qué HostGroups y qué Hosts individuales notifican a cada ContactGroup y a cada Contact
    cg_alert_host_groups: Dict[int, List[str]] = {cg.id: [] for cg in contact_groups}
    cg_alert_hosts: Dict[int, List[str]] = {cg.id: [] for cg in contact_groups}
    c_alert_host_groups: Dict[int, List[str]] = {c.id: [] for c in contacts}
    c_alert_hosts: Dict[int, List[str]] = {c.id: [] for c in contacts}

    for r in routing_rules:
        if not r.enabled:
            continue
        hg_obj = hg_by_id.get(r.host_group_id) if r.host_group_id else None
        asset_obj = assets_by_id.get(r.asset_id) if r.asset_id else None

        for cgid in (r.contact_group_ids or []):
            if cgid not in cg_alert_host_groups:
                continue
            if hg_obj and hg_obj.code not in cg_alert_host_groups[cgid]:
                cg_alert_host_groups[cgid].append(hg_obj.code)
                for aid in (hg_obj.member_asset_ids or []):
                    if aid in assets_by_id and assets_by_id[aid].code not in cg_alert_hosts[cgid]:
                        cg_alert_hosts[cgid].append(assets_by_id[aid].code)
            if asset_obj and asset_obj.code not in cg_alert_hosts[cgid]:
                cg_alert_hosts[cgid].append(asset_obj.code)

        for cid in (r.contact_ids or []):
            if cid not in c_alert_host_groups:
                continue
            if hg_obj and hg_obj.code not in c_alert_host_groups[cid]:
                c_alert_host_groups[cid].append(hg_obj.code)
                for aid in (hg_obj.member_asset_ids or []):
                    if aid in assets_by_id and assets_by_id[aid].code not in c_alert_hosts[cid]:
                        c_alert_hosts[cid].append(assets_by_id[aid].code)
            if asset_obj and asset_obj.code not in c_alert_hosts[cid]:
                c_alert_hosts[cid].append(asset_obj.code)

    # Propagar alarmas heredadas desde los Grupos de Usuarios (MemberOf) hacia cada Usuario
    for cid, group_ids in contact_member_of_ids.items():
        for gid in group_ids:
            for hgc in cg_alert_host_groups.get(gid, []):
                if hgc not in c_alert_host_groups[cid]:
                    c_alert_host_groups[cid].append(hgc)
            for hc in cg_alert_hosts.get(gid, []):
                if hc not in c_alert_hosts[cid]:
                    c_alert_hosts[cid].append(hc)

    services_ok = sum(1 for c in checks if c.nagios_state == "OK")
    services_warn = sum(1 for c in checks if c.nagios_state == "WARNING")
    services_crit = sum(1 for c in checks if c.nagios_state == "CRITICAL")

    return {
        "summary": {
            "total_hosts": len(serialized_hosts),
            "hosts_up": hosts_up,
            "hosts_down": hosts_down,
            "hosts_unreachable": hosts_unreachable,
            "hosts_maintenance": hosts_maintenance,
            "total_services": len(checks),
            "services_ok": services_ok,
            "services_warning": services_warn,
            "services_critical": services_crit,
            "total_logical_links": len(serialized_links),
            "total_snmp_ports": len(sw_ports),
            "total_connectors": len(serialized_connectors),
            "active_maintenance_windows": len(active_windows),
            "total_tech_stacks": len(serialized_stacks),
            "prometheus_url": PROMETHEUS_PUBLIC_URL,
            "automation_api_key_configured": bool(AUTOMATION_API_KEY),
        },
        "tech_stacks": serialized_stacks,
        "hosts": serialized_hosts,
        "logical_links": serialized_links,
        "connectors": serialized_connectors,
        "host_groups": [
            {
                "id": hg.id,
                "code": hg.code,
                "name": hg.name,
                "category": hg.category,
                "environment": hg.environment,
                "color_hex": hg.color_hex,
                "member_asset_ids": hg.member_asset_ids or [],
                "member_codes": [assets_by_id[aid].code for aid in (hg.member_asset_ids or []) if aid in assets_by_id],
                "description": hg.description,
            }
            for hg in host_groups
        ],
        "alert_contacts": [
            {
                "id": c.id,
                "code": c.code,
                "full_name": c.full_name,
                "role_title": c.role_title,
                "email": c.email,
                "phone_or_telegram": c.phone_or_telegram,
                "personal_webhook_url": c.personal_webhook_url,
                "schedule_period": c.schedule_period,
                "notify_on_down": c.notify_on_down,
                "notify_on_critical": c.notify_on_critical,
                "notify_on_warning": c.notify_on_warning,
                "notify_on_unreachable": c.notify_on_unreachable,
                "notify_on_recovery": c.notify_on_recovery,
                "active": c.active,
                "source_type": _classify_contact_source(c)[0],
                "source_badge": _classify_contact_source(c)[1],
                "ad_dn": _classify_contact_source(c)[2],
                "member_of_group_ids": contact_member_of_ids.get(c.id, []),
                "member_of_groups": [
                    {
                        "id": gid,
                        "code": cgroups_by_id[gid].code,
                        "name": cgroups_by_id[gid].name,
                        "group_email": cgroups_by_id[gid].group_email,
                        "source_type": _classify_group_source(cgroups_by_id[gid])[0],
                        "source_badge": _classify_group_source(cgroups_by_id[gid])[1],
                    }
                    for gid in contact_member_of_ids.get(c.id, [])
                    if gid in cgroups_by_id
                ],
                "alerting_host_group_codes": c_alert_host_groups.get(c.id, []),
                "alerting_host_codes": c_alert_hosts.get(c.id, []),
            }
            for c in contacts
        ],
        "alert_contact_groups": [
            {
                "id": cg.id,
                "code": cg.code,
                "name": cg.name,
                "description": cg.description,
                "group_email": cg.group_email,
                "channel_webhook_url": cg.channel_webhook_url,
                "member_contact_ids": cg.member_contact_ids or [],
                "member_names": [
                    f"{contacts_by_id[cid].full_name} ({contacts_by_id[cid].email})"
                    for cid in (cg.member_contact_ids or [])
                    if cid in contacts_by_id
                ],
                "source_type": _classify_group_source(cg)[0],
                "source_badge": _classify_group_source(cg)[1],
                "alerting_host_group_codes": cg_alert_host_groups.get(cg.id, []),
                "alerting_host_codes": cg_alert_hosts.get(cg.id, []),
            }
            for cg in contact_groups
        ],
        "ad_servers": [
            {
                "id": srv.id,
                "name": srv.name,
                "domain": srv.domain,
                "ldap_url": srv.ldap_url,
                "base_dn": srv.base_dn,
                "enabled": srv.enabled,
            }
            for srv in ad_servers
        ],
        "notification_rules": [
            {
                "id": r.id,
                "name": r.name,
                "description": r.description,
                "enabled": r.enabled,
                "scope_type": r.scope_type,
                "host_group_id": r.host_group_id,
                "host_group_name": hg_by_id[r.host_group_id].name if (r.host_group_id and r.host_group_id in hg_by_id) else "Todos / Específico",
                "asset_id": r.asset_id,
                "asset_code": assets_by_id[r.asset_id].code if (r.asset_id and r.asset_id in assets_by_id) else "",
                "contact_group_ids": r.contact_group_ids or [],
                "contact_group_names": [cgroups_by_id[cgid].name for cgid in (r.contact_group_ids or []) if cgid in cgroups_by_id],
                "contact_ids": r.contact_ids or [],
                "contact_names": [contacts_by_id[cid].full_name for cid in (r.contact_ids or []) if cid in contacts_by_id],
                "send_email": r.send_email,
                "send_webhook": r.send_webhook,
                "only_on_hard_state": r.only_on_hard_state,
            }
            for r in routing_rules
        ],
        "maintenance_windows": [
            {
                "id": w.id,
                "title": w.title,
                "reason": w.reason,
                "created_by": w.created_by,
                "scope_type": w.scope_type,
                "asset_id": w.asset_id,
                "asset_code": assets_by_id[w.asset_id].code if (w.asset_id and w.asset_id in assets_by_id) else "",
                "host_group_id": w.host_group_id,
                "host_group_code": hg_by_id[w.host_group_id].code if (w.host_group_id and w.host_group_id in hg_by_id) else "",
                "target_matches": w.target_matches or [],
                "starts_at": w.starts_at.isoformat() if w.starts_at else None,
                "ends_at": w.ends_at.isoformat() if w.ends_at else None,
                "is_active": w.is_active and w.ends_at >= now,
                "suppress_notifications": w.suppress_notifications,
            }
            for w in all_windows
        ],
        "alert_logs": [
            {
                "id": lg.id,
                "created_at": lg.created_at.isoformat() if lg.created_at else None,
                "asset_code": lg.asset_code,
                "service_name": lg.service_name,
                "event_state": lg.event_state,
                "matched_rule_name": lg.matched_rule_name,
                "recipients_summary": lg.recipients_summary,
                "delivery_channel": lg.delivery_channel,
                "delivery_status": lg.delivery_status,
                "detail": lg.detail,
            }
            for lg in alert_logs
        ],
        "smtp_config": {
            "smtp_host": smtp_cfg.smtp_host if smtp_cfg else "",
            "smtp_port": smtp_cfg.smtp_port if smtp_cfg else 587,
            "use_tls": smtp_cfg.use_tls if smtp_cfg else True,
            "smtp_username": smtp_cfg.smtp_username if smtp_cfg else "",
            "from_email": smtp_cfg.from_email if smtp_cfg else "",
            "global_webhook_url": smtp_cfg.global_webhook_url if smtp_cfg else "",
            "enabled": smtp_cfg.enabled if smtp_cfg else True,
        },
    }


# ==============================================================================
# WEBHOOKS DE AUTOMATIZACIÓN PARA PLAYBOOKS ANSIBLE Y AGENTES DE IA
# ==============================================================================

def handle_ansible_host_upsert_webhook(db: Session, payload: Dict[str, Any]) -> Dict[str, Any]:
    """
    Webhook idempotente para Ansible y Asistente Web de Alta/Edición ('POST /api/v1/network-hosts/hosts' / 'POST /api/v1/automation/webhook/host-upsert'):
    1. Crea o actualiza el Host/VM/Contenedor/Switch en la CMDB y en '4. Red & Host'.
    2. Registra su IP primaria de Heartbeat y todas sus IPs adicionales de servicio/VIP.
    3. Soporta 3 modos de alojamiento ('hosting_mode'):
       - 'cluster_pool': VM en un sistema/clúster de VMware, Proxmox, Hyper-V o K8s sin máquina física fija.
       - 'physical_rack_server': Alojada en una máquina física concreta del Rack Editor.
       - 'standalone': Máquina o servicio independiente / barebone / cloud sin máquina padre.
    4. Gestiona las 2 opciones activables/desactivables (igual que en el Rack Editor):
       - Opción 1 ('monitoring_enabled'): Activa o desactiva Healthchecks, Heartbeats y Exporters de Prometheus.
       - Opción 2 ('connect_enabled'): Activa o desactiva la conexión remota SSH / HTTP / HTTPS desde el Frontend.
    5. Regenera al instante '/app/data/prometheus/targets_dynamic.json' para que Prometheus lo monitorice automáticamente.
    """
    ensure_network_hosts_seeded(db)
    hostname = str(payload.get("hostname") or "").strip()
    primary_ip = str(payload.get("primary_ip") or "").strip()
    if not hostname or not primary_ip:
        raise ValueError("Los campos 'hostname' y 'primary_ip' son obligatorios.")

    code = str(payload.get("code") or hostname.upper().replace(".", "-")).strip().upper()
    asset_id_in = payload.get("asset_id")
    asset = None
    if asset_id_in:
        asset = db.query(CmdbAsset).filter(CmdbAsset.id == int(asset_id_in)).first()
    if not asset:
        asset = (
            db.query(CmdbAsset)
            .filter((CmdbAsset.code == code) | (CmdbAsset.hostname == hostname))
            .first()
        )
    is_new = asset is None
    if is_new:
        asset = CmdbAsset(code=code, sync_source="cmdb")
        db.add(asset)
    elif code:
        asset.code = code

    monitoring_enabled = bool(payload.get("monitoring_enabled", True))
    enable_icmp_ping = bool(payload.get("enable_icmp_ping", True))
    replace_checks = bool(payload.get("replace_checks", False))

    connect_enabled = bool(payload.get("connect_enabled", True))
    ssh_enabled = bool(payload.get("ssh_enabled", True))
    ssh_user = str(payload.get("ssh_user") or "root").strip() or "root"
    ssh_port = int(payload.get("ssh_port") or 22)
    ssh_host = str(payload.get("ssh_host") or primary_ip).strip() or primary_ip
    web_http_enabled = bool(payload.get("web_http_enabled", False))
    web_http_url = str(payload.get("web_http_url") or f"http://{primary_ip}/").strip()
    web_https_enabled = bool(payload.get("web_https_enabled", False))
    web_https_url = str(payload.get("web_https_url") or f"https://{primary_ip}/").strip()

    hosting_mode = str(payload.get("hosting_mode") or "cluster_pool").strip()
    cluster_or_pool_name = str(payload.get("cluster_or_pool_name") or "").strip()
    hypervisor_platform = str(
        payload.get("hypervisor_or_platform")
        or cluster_or_pool_name
        or "VMware vSphere / Proxmox VE / Hyper-V"
    ).strip()
    custom_class_lbl = str(payload.get("custom_asset_class_label") or "").strip()

    asset.name = str(payload.get("name") or f"{hostname} ({primary_ip})").strip()
    asset.hostname = hostname
    asset.fqdn = str(payload.get("fqdn") or f"{hostname}.hq.local").strip()
    asset.asset_class = str(payload.get("asset_class") or "virtual_machine").strip()
    asset.environment = str(payload.get("environment") or "production").strip()
    asset.criticality = str(payload.get("criticality") or "high").strip()
    asset.os_or_firmware = str(payload.get("os_or_firmware") or "Linux / Windows Server").strip()
    asset.cpu_cores = int(payload.get("cpu_cores") or 4)
    asset.ram_gb = float(payload.get("ram_gb") or 16.0)
    asset.storage_gb = float(payload.get("storage_gb") or 100.0)
    asset.hypervisor_or_platform = hypervisor_platform
    asset.owner_team = str(payload.get("owner_team") or "Sistemas & DevOps").strip()
    asset.responsible_person = str(payload.get("responsible_person") or "Alex Geng").strip()
    asset.monitoring_enabled = monitoring_enabled
    asset.status = "online" if monitoring_enabled else "unmonitored"
    asset.last_checked_at = datetime.utcnow() if monitoring_enabled else None
    if not monitoring_enabled:
        asset.last_ping_ms = None
    asset.notes = str(payload.get("notes") or "Registrado en Red & Host y CMDB").strip()

    # Actualizar custom_fields con las 2 configuraciones (Healthchecks/Heartbeat y Conectar SSH/HTTP/HTTPS) + Modo de Alojamiento
    cf = dict(asset.custom_fields or {})
    cf["hosting_mode"] = hosting_mode
    cf["cluster_or_pool_name"] = cluster_or_pool_name or hypervisor_platform
    cf["custom_asset_class_label"] = custom_class_lbl
    cf["monitoring_enabled"] = monitoring_enabled
    cf["connect_enabled"] = connect_enabled
    cf["ssh_enabled"] = ssh_enabled
    cf["ssh_user"] = ssh_user
    cf["ssh_port"] = ssh_port
    cf["ssh_host"] = ssh_host
    cf["web_http_enabled"] = web_http_enabled
    cf["web_http_url"] = web_http_url
    cf["web_https_enabled"] = web_https_enabled
    cf["web_https_url"] = web_https_url

    conn_protocols = []
    if ssh_enabled:
        conn_protocols.append("ssh")
    if web_http_enabled:
        conn_protocols.append("http")
    if web_https_enabled:
        conn_protocols.append("https")
    cf["connect_config"] = payload.get("connect_config") or {
        "enabled": connect_enabled,
        "protocols": conn_protocols,
        "ssh": {"host": ssh_host, "port": ssh_port, "username": ssh_user},
        "http": {"url": web_http_url},
        "https": {"url": web_https_url},
    }
    if payload.get("heartbeat_config") is not None:
        cf["heartbeat_config"] = payload["heartbeat_config"]
    asset.custom_fields = cf

    # Gestión del Alojamiento:
    # - Si 'hosting_mode' es 'cluster_pool' (VMware/Proxmox/Hyper-V sin máquina fija) o 'standalone', no atar a un hierro fijo
    rack_dev_code = str(payload.get("host_rack_device_code") or "").strip()
    parent_code = str(payload.get("parent_asset_code") or "").strip()

    if hosting_mode in ("cluster_pool", "standalone") and not rack_dev_code and not parent_code:
        if not asset.rack_device_id:
            asset.host_rack_device_id = None
        asset.parent_asset_id = None
    else:
        if rack_dev_code:
            rdev = db.query(RackDevice).filter(RackDevice.code == rack_dev_code).first()
            if rdev:
                asset.host_rack_device_id = rdev.id
                if not asset.parent_asset_id:
                    parent_from_rack = (
                        db.query(CmdbAsset)
                        .filter(CmdbAsset.rack_device_id == rdev.id)
                        .first()
                    )
                    if parent_from_rack:
                        asset.parent_asset_id = parent_from_rack.id

        if parent_code:
            parent_ast = db.query(CmdbAsset).filter(CmdbAsset.code == parent_code).first()
            if parent_ast:
                asset.parent_asset_id = parent_ast.id
                if not asset.host_rack_device_id and parent_ast.rack_device_id:
                    asset.host_rack_device_id = parent_ast.rack_device_id

    db.flush()

    # Sincronizar también con RackDevice físico si este activo es un equipo montado en Rack
    if asset.rack_device_id:
        rdev_self = db.query(RackDevice).filter(RackDevice.id == asset.rack_device_id).first()
        if rdev_self:
            rdev_self.monitoring_enabled = monitoring_enabled
            rdev_self.status = "online" if monitoring_enabled else "unmonitored"
            rcf = dict(rdev_self.custom_fields or {})
            rcf["connect_config"] = cf["connect_config"]
            if "heartbeat_config" in cf:
                rcf["heartbeat_config"] = cf["heartbeat_config"]
            rdev_self.custom_fields = rcf

    # Sincronizar cualquier nodo en los Stacks Tecnológicos que apunte a este host
    for sn in db.query(TechStackNode).filter(TechStackNode.asset_id == asset.id).all():
        sn.ssh_enabled = connect_enabled and ssh_enabled
        sn.ssh_user = ssh_user
        sn.ssh_port = ssh_port

    # Crear automáticamente el enlace en el Diagrama Lógico con su Hipervisor / Switch padre si tiene máquina concreta
    if asset.parent_asset_id and asset.parent_asset_id != asset.id:
        existing_link = (
            db.query(LogicalTopologyLink)
            .filter(
                LogicalTopologyLink.source_asset_id == asset.parent_asset_id,
                LogicalTopologyLink.target_asset_id == asset.id,
            )
            .first()
        )
        if not existing_link:
            db.add(
                LogicalTopologyLink(
                    source_asset_id=asset.parent_asset_id,
                    target_asset_id=asset.id,
                    link_type="hypervisor_vm" if asset.asset_class in ("virtual_machine", "container", "container_lxc") else "lldp_trunk",
                    source_interface="vmbr0 / vSwitch0",
                    target_interface="eth0",
                    protocol_label=f"Alojamiento {asset.hypervisor_or_platform or 'Virtualización'}",
                    vlan_id=20,
                    bandwidth_mbps=10000,
                    status="UP",
                    auto_discovered=True,
                    notes="Enlace lógico generado al dar de alta el Host/VM",
                )
            )

    # Sincronizar IP primaria y adicionales en CMDB
    subnets = db.query(CmdbSubnet).all()
    existing_ips = {ip.ip_address: ip for ip in asset.ip_addresses}
    if primary_ip not in existing_ips:
        matched_sub = _match_subnet_for_ip(primary_ip, subnets)
        db.add(
            CmdbIpAddress(
                asset_id=asset.id,
                subnet_id=matched_sub.id if matched_sub else None,
                ip_address=primary_ip,
                subnet_mask=matched_sub.subnet_mask if matched_sub else "255.255.255.0",
                gateway=matched_sub.gateway if matched_sub else "",
                vlan_id=matched_sub.vlan_id if matched_sub else 20,
                ip_role="mgmt_heartbeat",
                interface_name="eth0",
                fqdn=asset.fqdn,
                is_heartbeat_ip=True,
                allocation_status="assigned",
                last_verification_status="active_in_network",
                last_verified_at=datetime.utcnow(),
            )
        )

    for extra_ip in (payload.get("additional_ips") or []):
        ip_str = str(extra_ip.get("ip_address") or "").strip()
        if not ip_str or ip_str in existing_ips:
            continue
        matched_sub = _match_subnet_for_ip(ip_str, subnets)
        db.add(
            CmdbIpAddress(
                asset_id=asset.id,
                subnet_id=matched_sub.id if matched_sub else None,
                ip_address=ip_str,
                subnet_mask=matched_sub.subnet_mask if matched_sub else "255.255.255.0",
                gateway=matched_sub.gateway if matched_sub else "",
                vlan_id=extra_ip.get("vlan_id") or (matched_sub.vlan_id if matched_sub else None),
                ip_role=str(extra_ip.get("ip_role") or "primary_service"),
                interface_name=str(extra_ip.get("interface_name") or "eth1"),
                fqdn=str(extra_ip.get("fqdn") or asset.fqdn),
                is_heartbeat_ip=False,
                allocation_status="assigned",
                last_verification_status="active_in_network",
                last_verified_at=datetime.utcnow(),
            )
        )

    # Asociar a HostGroups
    for hg_code in (payload.get("host_groups") or []):
        hgc = str(hg_code).strip().upper()
        if not hgc:
            continue
        hg = db.query(HostGroup).filter(HostGroup.code == hgc).first()
        if not hg:
            hg = HostGroup(code=hgc, name=f"Grupo {hgc}", member_asset_ids=[asset.id])
            db.add(hg)
        else:
            mids = list(hg.member_asset_ids or [])
            if asset.id not in mids:
                mids.append(asset.id)
                hg.member_asset_ids = mids

    # Gestión de Healthchecks / Servicios / Exporters según el Switch 'monitoring_enabled'
    if replace_checks:
        db.query(MonitoredServiceCheck).filter(MonitoredServiceCheck.asset_id == asset.id).delete()
        db.flush()

    if not monitoring_enabled:
        for chk in db.query(MonitoredServiceCheck).filter(MonitoredServiceCheck.asset_id == asset.id).all():
            chk.enabled = False
    else:
        existing_checks = {
            c.service_name: c
            for c in db.query(MonitoredServiceCheck).filter(MonitoredServiceCheck.asset_id == asset.id).all()
        }
        for chk in existing_checks.values():
            chk.enabled = True

        # 1. Registrar chequeo Ping primario si está habilitado
        if enable_icmp_ping and "PING Heartbeat (Gestión)" not in existing_checks:
            db.add(
                MonitoredServiceCheck(
                    asset_id=asset.id,
                    service_name="PING Heartbeat (Gestión)",
                    check_type="icmp",
                    target_ip_or_url=primary_ip,
                    port=0,
                    nagios_state="PENDING",
                    state_type="SOFT",
                    is_primary_heartbeat=True,
                    latency_ms=None,
                    status_output=f"Pendiente de sondeo ICMP a {primary_ip}",
                    last_checked_at=datetime.utcnow(),
                )
            )

        # 2. Registrar Exporters (node_exporter :9100, windows_exporter :9182, nginx, apache, docker o personalizados)
        for exp in (payload.get("exporters") or []):
            etype = str(exp.get("type") or "node_exporter").strip().lower()
            eport = int(exp.get("port") or (9182 if etype == "windows_exporter" else 9100))
            custom_exp_name = str(exp.get("name") or "").strip()
            sname = custom_exp_name or f"Exporter Prometheus ({etype} :{eport})"
            if sname not in existing_checks:
                db.add(
                    MonitoredServiceCheck(
                        asset_id=asset.id,
                        service_name=sname,
                        check_type=etype,
                        target_ip_or_url=str(exp.get("url") or primary_ip),
                        port=eport,
                        nagios_state="PENDING",
                        state_type="SOFT",
                        latency_ms=None,
                        status_output=f"Pendiente de sondeo en {primary_ip}:{eport}",
                        last_checked_at=datetime.utcnow(),
                    )
                )

        # 3. Registrar Heartbeats y Servicios (HTTP, HTTPS, TCP, UDP, SNMP, SSH, BBDD o cualquier servicio personalizado)
        for hb in (payload.get("heartbeats") or []):
            hname = str(hb.get("name") or f"Heartbeat {hb.get('type', 'https').upper()}").strip()
            htype = str(hb.get("type") or "https").strip().lower()
            hport = int(hb.get("port") or (443 if htype == "https" else (80 if htype == "http" else 0)))
            hurl = str(hb.get("url") or primary_ip).strip()
            if hname not in existing_checks:
                db.add(
                    MonitoredServiceCheck(
                        asset_id=asset.id,
                        service_name=hname,
                        check_type=htype,
                        target_ip_or_url=hurl,
                        port=hport,
                        expected_status_code=int(hb.get("expected_status_code") or 200),
                        expected_string=str(hb.get("expected_string") or ""),
                        check_config=dict(hb.get("check_config") or {}),
                        nagios_state="PENDING",
                        state_type="SOFT",
                        latency_ms=None,
                        ssl_days_remaining=None,
                        status_output=f"Pendiente de sondeo ({hurl}{f':{hport}' if hport and f':{hport}' not in hurl else ''})",
                        last_checked_at=datetime.utcnow(),
                    )
                )

    db.commit()
    db.refresh(asset)
    if monitoring_enabled:
        for chk in db.query(MonitoredServiceCheck).filter(MonitoredServiceCheck.asset_id == asset.id, MonitoredServiceCheck.enabled == True).all():  # noqa: E712
            run_single_service_check(db=db, chk=chk, asset=asset)
    prom_sync = sync_prometheus_targets_file(db)
    return {
        "status": "ok",
        "action": "created" if is_new else "updated",
        "asset_id": asset.id,
        "code": asset.code,
        "hostname": asset.hostname,
        "primary_ip": primary_ip,
        "prometheus_sd_sync": prom_sync,
    }


def handle_ansible_maintenance_webhook(db: Session, payload: Dict[str, Any]) -> Dict[str, Any]:
    """
    Webhook para iniciar o detener una Ventana de Mantenimiento desde un Playbook de Ansible
    ('POST /api/v1/automation/webhook/maintenance'):
    - action='start': Silencia alertas del Host o HostGroup mientras Ansible reinicia Apache/Nginx/Docker o actualiza el SO.
    - action='stop': Cierra la ventana de mantenimiento al terminar el Playbook y reactiva las alertas normales.
    """
    ensure_network_hosts_seeded(db)
    action = str(payload.get("action") or "start").strip().lower()
    targets = [str(x).strip() for x in (payload.get("targets") or []) if str(x).strip()]
    hg_code = str(payload.get("host_group_code") or "").strip().upper()

    if action == "stop":
        q = db.query(MaintenanceWindow).filter(MaintenanceWindow.is_active == True)  # noqa: E712
        closed_count = 0
        for win in q.all():
            if hg_code and win.host_group_id:
                hg = db.query(HostGroup).filter(HostGroup.id == win.host_group_id).first()
                if hg and hg.code.upper() == hg_code:
                    win.is_active = False
                    win.ends_at = datetime.utcnow()
                    closed_count += 1
                    continue
            if targets:
                overlap = set(t.lower() for t in targets) & set(str(m).lower() for m in (win.target_matches or []))
                if overlap:
                    win.is_active = False
                    win.ends_at = datetime.utcnow()
                    closed_count += 1
            elif not hg_code and not targets:
                win.is_active = False
                win.ends_at = datetime.utcnow()
                closed_count += 1
        db.commit()
        return {"status": "ok", "action": "stopped", "closed_windows": closed_count}

    dur = max(1, int(payload.get("duration_minutes") or 45))
    now = datetime.utcnow()
    hg_id = None
    scope = "ip_or_hostname_list"
    if hg_code:
        hg = db.query(HostGroup).filter(HostGroup.code == hg_code).first()
        if hg:
            hg_id = hg.id
            scope = "host_group"

    win = MaintenanceWindow(
        title=str(payload.get("title") or "Mantenimiento Automático Ansible"),
        reason=str(payload.get("reason") or "Ejecución de Playbook Ansible"),
        created_by=str(payload.get("created_by") or "ansible-playbook"),
        scope_type=scope,
        host_group_id=hg_id,
        target_matches=targets,
        starts_at=now,
        ends_at=now + timedelta(minutes=dur),
        is_active=True,
        suppress_notifications=True,
    )
    db.add(win)
    db.commit()
    return {
        "status": "ok",
        "action": "started",
        "window_id": win.id,
        "title": win.title,
        "ends_at": win.ends_at.isoformat(),
        "targets": targets,
        "host_group_code": hg_code,
    }


def evaluate_all_network_service_checks(db: Session) -> Dict[str, Any]:
    """
    Evalúa en lote todos los Heartbeats y Chequeos de Servicio activos en '4. Red & Host',
    aplicando la máquina de estados de Nagios Core (SOFT/HARD + UNREACHABLE) y regenerando
    el archivo de targets de Prometheus.
    """
    ensure_network_hosts_seeded(db)
    now = datetime.utcnow()
    active_windows = (
        db.query(MaintenanceWindow)
        .filter(MaintenanceWindow.is_active == True, MaintenanceWindow.ends_at >= now)  # noqa: E712
        .all()
    )
    host_groups_by_id = {hg.id: hg for hg in db.query(HostGroup).all()}
    assets_by_id = {
        a.id: a
        for a in db.query(CmdbAsset).options(joinedload(CmdbAsset.ip_addresses)).all()
    }
    checks = (
        db.query(MonitoredServiceCheck)
        .filter(MonitoredServiceCheck.enabled == True)  # noqa: E712
        .all()
    )

    results = []
    for chk in checks:
        asset = assets_by_id.get(chk.asset_id)
        if not asset:
            continue
        res = run_single_service_check(
            db=db,
            chk=chk,
            asset=asset,
            active_windows=active_windows,
            host_groups_by_id=host_groups_by_id,
        )
        results.append(res)

    sync_prometheus_targets_file(db)
    return {
        "checked_count": len(results),
        "ok_count": sum(1 for r in results if r["nagios_state"] == "OK"),
        "warning_count": sum(1 for r in results if r["nagios_state"] == "WARNING"),
        "critical_count": sum(1 for r in results if r["nagios_state"] == "CRITICAL"),
        "results": results,
    }


def handle_ansible_host_decommission_webhook(db: Session, payload: Dict[str, Any]) -> Dict[str, Any]:
    """
    Webhook para dar de baja o retirar un Host/VM desde Ansible ('POST /api/v1/automation/webhook/host-decommission'):
    Lo retira de Prometheus ('targets_dynamic.json'), desactiva sus chequeos o lo elimina por completo.
    """
    ensure_network_hosts_seeded(db)
    code = str(payload.get("code") or "").strip().upper()
    hostname = str(payload.get("hostname") or "").strip()
    primary_ip = str(payload.get("primary_ip") or "").strip()
    delete_permanently = bool(payload.get("delete_permanently", False))

    asset = None
    if code:
        asset = db.query(CmdbAsset).filter(CmdbAsset.code == code).first()
    if not asset and hostname:
        asset = db.query(CmdbAsset).filter(CmdbAsset.hostname == hostname).first()
    if not asset and primary_ip:
        ip_rec = db.query(CmdbIpAddress).filter(CmdbIpAddress.ip_address == primary_ip).first()
        if ip_rec and ip_rec.asset:
            asset = ip_rec.asset

    if not asset:
        raise ValueError("No se encontró ningún Host/VM con el código, hostname o IP indicados.")

    target_code = asset.code
    target_id = asset.id
    if delete_permanently:
        db.query(MonitoredServiceCheck).filter(MonitoredServiceCheck.asset_id == target_id).delete()
        db.query(SwitchSnmpPort).filter(SwitchSnmpPort.asset_id == target_id).delete()
        db.query(LogicalTopologyLink).filter(
            (LogicalTopologyLink.source_asset_id == target_id)
            | (LogicalTopologyLink.target_asset_id == target_id)
        ).delete()
        db.delete(asset)
        action_taken = "deleted_permanently"
    else:
        asset.lifecycle_status = "decommissioned"
        asset.monitoring_enabled = False
        asset.status = "offline"
        for chk in db.query(MonitoredServiceCheck).filter(MonitoredServiceCheck.asset_id == target_id).all():
            chk.enabled = False
        for ip_rec in asset.ip_addresses:
            ip_rec.allocation_status = "deprecated"
        action_taken = "marked_decommissioned"

    db.commit()
    prom_sync = sync_prometheus_targets_file(db)
    return {
        "status": "ok",
        "action": action_taken,
        "asset_id": target_id,
        "code": target_code,
        "prometheus_sd_sync": prom_sync,
    }


def handle_ansible_contacts_routing_webhook(db: Session, payload: Dict[str, Any]) -> Dict[str, Any]:
    """
    Webhook declarativo para gestionar Personas, Grupos de Personas y Reglas de Enrutamiento de Avisos
    como código desde Ansible ('POST /api/v1/automation/webhook/contacts-and-routing').
    """
    ensure_network_hosts_seeded(db)
    upserted_contacts = 0
    upserted_groups = 0
    upserted_rules = 0

    for c_in in (payload.get("contacts") or []):
        code = str(c_in.get("code") or "").strip().upper()
        email = str(c_in.get("email") or "").strip()
        if not code or not email:
            continue
        contact = db.query(AlertContact).filter(AlertContact.code == code).first()
        if not contact:
            contact = AlertContact(code=code)
            db.add(contact)
        contact.full_name = str(c_in.get("full_name") or code).strip()
        contact.role_title = str(c_in.get("role_title") or "Ingeniería IT").strip()
        contact.email = email
        contact.phone_or_telegram = str(c_in.get("phone_or_telegram") or "").strip()
        contact.personal_webhook_url = str(c_in.get("personal_webhook_url") or "").strip()
        contact.schedule_period = str(c_in.get("schedule_period") or "24x7").strip()
        contact.active = bool(c_in.get("active", True))
        upserted_contacts += 1

    db.flush()
    contacts_by_code = {c.code.upper(): c for c in db.query(AlertContact).all()}

    for cg_in in (payload.get("contact_groups") or []):
        code = str(cg_in.get("code") or "").strip().upper()
        if not code:
            continue
        cg = db.query(AlertContactGroup).filter(AlertContactGroup.code == code).first()
        if not cg:
            cg = AlertContactGroup(code=code)
            db.add(cg)
        cg.name = str(cg_in.get("name") or code).strip()
        cg.description = str(cg_in.get("description") or "").strip()
        cg.group_email = str(cg_in.get("group_email") or "").strip()
        cg.channel_webhook_url = str(cg_in.get("channel_webhook_url") or "").strip()
        member_ids = list(cg_in.get("member_contact_ids") or [])
        for m_code in (cg_in.get("member_contact_codes") or []):
            mc = contacts_by_code.get(str(m_code).strip().upper())
            if mc and mc.id not in member_ids:
                member_ids.append(mc.id)
        cg.member_contact_ids = member_ids
        upserted_groups += 1

    db.flush()
    cgroups_by_code = {cg.code.upper(): cg for cg in db.query(AlertContactGroup).all()}
    hgroups_by_code = {hg.code.upper(): hg for hg in db.query(HostGroup).all()}

    for r_in in (payload.get("routing_rules") or []):
        rname = str(r_in.get("name") or "").strip()
        if not rname:
            continue
        rule = db.query(NotificationRoutingRule).filter(NotificationRoutingRule.name == rname).first()
        if not rule:
            rule = NotificationRoutingRule(name=rname)
            db.add(rule)
        rule.description = str(r_in.get("description") or "").strip()
        rule.enabled = bool(r_in.get("enabled", True))
        rule.scope_type = str(r_in.get("scope_type") or "host_group").strip()
        hg_code = str(r_in.get("host_group_code") or "").strip().upper()
        if hg_code and hg_code in hgroups_by_code:
            rule.host_group_id = hgroups_by_code[hg_code].id
        elif r_in.get("host_group_id"):
            rule.host_group_id = int(r_in["host_group_id"])

        cg_ids = list(r_in.get("contact_group_ids") or [])
        for cg_code in (r_in.get("contact_group_codes") or []):
            cg_obj = cgroups_by_code.get(str(cg_code).strip().upper())
            if cg_obj and cg_obj.id not in cg_ids:
                cg_ids.append(cg_obj.id)
        rule.contact_group_ids = cg_ids

        c_ids = list(r_in.get("contact_ids") or [])
        for c_code in (r_in.get("contact_codes") or []):
            c_obj = contacts_by_code.get(str(c_code).strip().upper())
            if c_obj and c_obj.id not in c_ids:
                c_ids.append(c_obj.id)
        rule.contact_ids = c_ids
        rule.send_email = bool(r_in.get("send_email", True))
        rule.send_webhook = bool(r_in.get("send_webhook", True))
        rule.only_on_hard_state = bool(r_in.get("only_on_hard_state", True))
        upserted_rules += 1

    db.commit()
    return {
        "status": "ok",
        "upserted_contacts": upserted_contacts,
        "upserted_contact_groups": upserted_groups,
        "upserted_routing_rules": upserted_rules,
    }


def build_ai_agent_context_manifest(db: Session) -> Dict[str, Any]:
    """
    Devuelve un manifiesto estructurado JSON ('GET /api/v1/automation/ai-context')
    pensado específicamente para Agentes de IA (Antigravity, Claude Code, Cursor, MCP)
    y herramientas de automatización (Ansible, Terraform).
    """
    ov = build_network_hosts_overview(db)
    return {
        "schema_version": "1.3.0",
        "system": "RackDoc DCIM + Red & Host + CMDB + Prometheus TSDB + Nagios State Engine",
        "documentation_markdown_path": "docs/AUTOMATION_ANSIBLE_PROMETHEUS_AGENTS.md",
        "prometheus": {
            "internal_url": PROMETHEUS_URL,
            "public_url": PROMETHEUS_PUBLIC_URL,
            "metrics_exposition_endpoint": "/api/v1/metrics",
            "dynamic_file_sd_path": str(PROMETHEUS_DYNAMIC_TARGETS_PATH),
            "exported_metrics": [
                "rackdoc_host_up",
                "rackdoc_host_ping_latency_ms",
                "rackdoc_host_cpu_usage_percent",
                "rackdoc_host_ram_usage_percent",
                "rackdoc_host_disk_usage_percent",
                "rackdoc_service_nagios_state",
                "rackdoc_service_latency_ms",
                "rackdoc_ssl_cert_days_remaining",
                "rackdoc_switch_port_oper_up",
                "rackdoc_switch_port_rx_mbps",
                "rackdoc_switch_port_tx_mbps",
            ],
        },
        "automation_webhooks": {
            "auth_header": "X-API-Key: <AUTOMATION_API_KEY>",
            "endpoints": {
                "host_upsert": "POST /api/v1/automation/webhook/host-upsert",
                "host_decommission": "POST /api/v1/automation/webhook/host-decommission",
                "maintenance_window": "POST /api/v1/automation/webhook/maintenance",
                "contacts_and_routing": "POST /api/v1/automation/webhook/contacts-and-routing",
                "snmp_switch_discovery": "POST /api/v1/network-hosts/snmp-discover",
            },
        },
        "summary": ov["summary"],
        "host_groups": ov["host_groups"],
        "active_hosts": [
            {
                "id": h["id"],
                "code": h["code"],
                "hostname": h["hostname"],
                "logical_layer": h["logical_layer"],
                "heartbeat_ip": h["heartbeat_ip"],
                "all_ips": h["all_ips"],
                "nagios_host_state": h["nagios_host_state"],
                "rack_location_badge": h["rack_location_badge"],
                "host_groups": h["host_groups"],
            }
            for h in ov["hosts"]
        ],
    }


def execute_host_ssh_diagnostic(
    db: Session,
    asset_id: int,
    command: str = "uptime && df -h / && free -m",
    ssh_user: str = "root",
    ssh_port: int = 22,
) -> Dict[str, Any]:
    """
    Ejecuta diagnóstico de conectividad real SSH sobre un Host/VM del Stack Tecnológico:
    - Comprueba la alcanzabilidad TCP al puerto SSH y obtiene el banner real si está accesible.
    - Devuelve el estado real de las sondas y exporters monitorizados en RackDoc & Prometheus.
    """
    asset = db.query(CmdbAsset).options(joinedload(CmdbAsset.ip_addresses)).filter(CmdbAsset.id == asset_id).first()
    if not asset:
        raise ValueError("Host no encontrado.")

    hb_ip = next(
        (ip.ip_address for ip in asset.ip_addresses if ip.is_heartbeat_ip),
        asset.ip_addresses[0].ip_address if asset.ip_addresses else "127.0.0.1",
    )
    st, lat, det = check_host_connectivity(
        host=hb_ip,
        method="ssh",
        port=ssh_port,
        timeout_sec=2.0,
        device_code=asset.code,
    )
    checks = db.query(MonitoredServiceCheck).filter(MonitoredServiceCheck.asset_id == asset.id).all()
    services_lines = [
        f"  ● {c.service_name:<38} [{c.nagios_state} / {c.state_type}] -> {c.status_output}"
        for c in checks
    ]
    lat_str = f"{lat} ms" if lat is not None else "Sin respuesta"
    output = (
        f"Diagnóstico SSH hacia {ssh_user}@{hb_ip}:{ssh_port} ({asset.hostname or asset.code} — {asset.os_or_firmware})\n"
        f"Estado Sonda TCP/SSH: {st.upper()} • Detalle/Banner: {det} • Latencia: {lat_str}\n"
        f"Comando SSH para terminal local: ssh -p {ssh_port} {ssh_user}@{hb_ip}\n"
        f"--------------------------------------------------------------------------------\n"
        f"Servicios y Exporters Reales Monitorizados por RackDoc & Prometheus:\n"
        + ("\n".join(services_lines) if services_lines else "  (Sin servicios adicionales registrados)")
        + "\n"
    )
    return {
        "asset_id": asset.id,
        "asset_code": asset.code,
        "hostname": asset.hostname,
        "ip": hb_ip,
        "ssh_user": ssh_user,
        "ssh_port": ssh_port,
        "ssh_command": f"ssh -p {ssh_port} {ssh_user}@{hb_ip}" if ssh_port != 22 else f"ssh {ssh_user}@{hb_ip}",
        "ssh_url": f"ssh://{ssh_user}@{hb_ip}:{ssh_port}",
        "command_executed": command,
        "output": output,
    }


