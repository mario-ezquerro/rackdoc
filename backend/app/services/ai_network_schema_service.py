"""
Motor Topológico v2 de Esquemas Visuales de Red según Análisis IA (`AiNetworkSchema`),
Auditoría FinOps / Capacidad con Prometheus TSDB y Publicación `Human-in-the-Loop`
hacia `4. Red & Host (Stacks Tecnológicos 2D)`.

Mejoras clave de ingeniería topológica (v2):
1. **Fusión canónica 1:1 (`RackDevice` ⇄ `CmdbAsset`)**: elimina duplicidades cuando un equipo
   de rack (`SW48-CORE-01`) tiene además ficha sincronizada en CMDB (`RK-DEMO-01-SW48-CORE-01`)
   o múltiples entradas descubiertas sobre el mismo `rack_device_id`.
2. **Exclusión de elementos no-red**: filtra tomas eléctricas (`TOMA-A/B`, `schuko`), pasivos
   y cajas auxiliares (`PLANTA-DC`, `FIBRA-EXT-*`), así como acometidas `power_ac`.
3. **Jerarquía Norte -> Sur real en 5 niveles de red**:
   `1. Perímetro, Gateways & Subredes L3` -> `2. Core / Distribución` ->
   `3. Switching de Acceso (agrupado por Rack)` -> `4. Servidores, VMs & BBDD` ->
   `5. Endpoints de Planta, Wi-Fi & Equipos IP`.
4. **Agregación de enlaces paralelos (LACP / Dual-Homed)** y **enrutamiento automático L3 por CIDR**
   (`ipaddress.ip_network`) para que ningún host ni subred quede huérfano en el plano.
"""

from __future__ import annotations

import ipaddress
import os
import re
import secrets
from typing import Any, Dict, List, Optional, Set, Tuple

import httpx
from sqlalchemy.orm import Session, joinedload

from ..models import (
    AiPassiveDiscoverySnapshot,
    CmdbAsset,
    CmdbSubnet,
    Connection,
    Location,
    LogicalTopologyLink,
    MonitoredServiceCheck,
    Port,
    Rack,
    RackDevice,
    TechStackDiagram,
    TechStackEdge,
    TechStackNode,
)
from .ai_agent_service import ALLOWED_SCOPES, build_federated_readonly_snapshot, sanitize_context_payload

PROMETHEUS_INTERNAL_URL = (
    os.getenv("PROMETHEUS_URL", "http://rackdoc-prometheus:9090") or "http://rackdoc-prometheus:9090"
).rstrip("/")

# Categorías y códigos sintéticos del editor de Rack que NO son nodos L2/L3 de topología IP
NON_NETWORK_CATEGORIES = frozenset({
    "cable_manager",
    "patch_panel",
    "patchbox",
    "rack_tray",
    "pdu",
    "schuko",
    "external_power_feed",
})
SYNTHETIC_RACK_CODES = ("PLANTA-DC", "FIBRA-EXT", "TOMA-A", "TOMA-B")


def is_auxiliary_rack_item(code: str, category: str) -> bool:
    cu = (code or "").upper().strip()
    cat = (category or "").lower().strip()
    if cat in NON_NETWORK_CATEGORIES:
        return True
    return any(cu == p or cu.startswith(p + "-") or cu.endswith("-" + p) for p in SYNTHETIC_RACK_CODES)


# ==============================================================================
# 1. TELEMETRÍA FINOPS Y CAPACIDAD DESDE PROMETHEUS (100% SOLO-LECTURA)
# ==============================================================================


def _query_prom_metric_by_code(client: httpx.Client, metric_name: str) -> Dict[str, float]:
    out: Dict[str, float] = {}
    try:
        resp = client.get(
            f"{PROMETHEUS_INTERNAL_URL}/api/v1/query",
            params={"query": metric_name},
        )
        if resp.status_code != 200:
            return out
        results = ((resp.json().get("data") or {}).get("result") or [])
        for row in results:
            labels = row.get("metric") or {}
            code = str(labels.get("code") or labels.get("host_code") or labels.get("instance") or "").strip()
            val_pair = row.get("value") or []
            if code and len(val_pair) >= 2:
                try:
                    out[code] = round(float(val_pair[1]), 1)
                except (TypeError, ValueError):
                    pass
    except Exception:
        pass
    return out


def collect_finops_telemetry_and_findings(db: Session) -> Tuple[Dict[str, Dict[str, float]], List[Dict[str, Any]]]:
    telemetry_by_code: Dict[str, Dict[str, float]] = {}

    checks = db.query(MonitoredServiceCheck).all()
    assets = db.query(CmdbAsset).filter(CmdbAsset.lifecycle_status != "decommissioned").all()
    asset_by_id = {a.id: a for a in assets}

    for chk in checks:
        a_obj = asset_by_id.get(chk.asset_id)
        if not a_obj or not isinstance(chk.metrics_snapshot, dict):
            continue
        ms = chk.metrics_snapshot
        entry = telemetry_by_code.setdefault(a_obj.code, {})
        for k_src, k_dst in (
            ("cpu_percent", "cpu_pct"),
            ("cpu_usage_percent", "cpu_pct"),
            ("ram_percent", "ram_pct"),
            ("memory_usage_percent", "ram_pct"),
            ("disk_percent", "disk_pct"),
            ("disk_usage_percent", "disk_pct"),
        ):
            if ms.get(k_src) is not None:
                try:
                    entry[k_dst] = round(float(ms[k_src]), 1)
                except (TypeError, ValueError):
                    pass

    try:
        with httpx.Client(timeout=2.2) as client:
            cpu_map = _query_prom_metric_by_code(client, "rackdoc_host_cpu_usage_percent")
            ram_map = _query_prom_metric_by_code(client, "rackdoc_host_ram_usage_percent")
            disk_map = _query_prom_metric_by_code(client, "rackdoc_host_disk_usage_percent")
            for c, val in cpu_map.items():
                telemetry_by_code.setdefault(c, {})["cpu_pct"] = val
            for c, val in ram_map.items():
                telemetry_by_code.setdefault(c, {})["ram_pct"] = val
            for c, val in disk_map.items():
                telemetry_by_code.setdefault(c, {})["disk_pct"] = val
    except Exception:
        pass

    finops_findings: List[Dict[str, Any]] = []
    for a in assets:
        tel = telemetry_by_code.get(a.code)
        if not tel:
            continue
        cpu = tel.get("cpu_pct")
        ram = tel.get("ram_pct")
        disk = tel.get("disk_pct")

        if (cpu is not None and cpu >= 85.0) or (ram is not None and ram >= 88.0) or (disk is not None and disk >= 85.0):
            finops_findings.append(
                {
                    "severity": "high",
                    "category": "Capacidad / Saturación",
                    "target_code": a.code,
                    "title": f"Riesgo de saturación en '{a.code}' (CPU {cpu or 0}% · RAM {ram or 0}% · Disco {disk or 0}%)",
                    "detail": (
                        f"El activo '{a.name}' presenta consumo elevado frente a su dotación CMDB "
                        f"({a.cpu_cores} vCPU, {a.ram_gb} GB RAM, {a.storage_gb} GB Disco)."
                    ),
                }
            )
        elif (
            (a.cpu_cores >= 8 or a.ram_gb >= 32.0)
            and cpu is not None
            and ram is not None
            and cpu <= 10.0
            and ram <= 18.0
        ):
            finops_findings.append(
                {
                    "severity": "info",
                    "category": "FinOps / Sobredimensionamiento",
                    "target_code": a.code,
                    "title": f"Activo '{a.code}' sobredimensionado ({a.cpu_cores} vCPU / {a.ram_gb} GB RAM con uso < 10%)",
                    "detail": (
                        f"Uso medido: CPU {cpu}%, RAM {ram}%. Candidato a ajuste de recursos (right-sizing) "
                        "en mantenimiento programado."
                    ),
                }
            )

    return telemetry_by_code, finops_findings


# ==============================================================================
# 2. GENERADOR DE ESQUEMA TOPOLÓGICO 2D (FUSIÓN 1:1 + 5 NIVELES NORTE-SUR)
# ==============================================================================

LAYER_DEFINITIONS: List[Tuple[str, str, str, str]] = [
    (
        "wan_perimetro",
        "NIVEL 1 • PERÍMETRO, ROUTERS / GATEWAYS Y SEGMENTOS DE SUBRED L3 (IPAM)",
        "Enrutamiento principal, cortafuegos y pasarelas VLAN",
        "#DC2626",
    ),
    (
        "core_distribution",
        "NIVEL 2 • CONMUTACIÓN CORE / AGREGACIÓN ALTA DISPONIBILIDAD (LACP / FIBRA)",
        "Switches troncales de distribución entre bastidores",
        "#0284C7",
    ),
    (
        "access_switching",
        "NIVEL 3 • CONMUTACIÓN DE ACCESO POR BASTIDOR RACK (ToR / ACCESO)",
        "Switches de acceso ordenados por Rack físico",
        "#2563EB",
    ),
    (
        "compute_and_services",
        "NIVEL 4 • SERVIDORES, HIPERVISORES, MÁQUINAS VIRTUALES, APPS Y DATOS",
        "Cómputo físico/virtual, contenedores, bases de datos y SAI gestionado",
        "#7C3AED",
    ),
    (
        "endpoints_and_iot",
        "NIVEL 5 • DISPOSITIVOS DE PLANTA, APs WI-FI, IMPRESORAS Y HOSTS DESCUBIERTOS",
        "Equipos finales e IPs activas en subredes de usuario/planta",
        "#0D9488",
    ),
]


def _classify_canonical_layer(
    code: str,
    name: str,
    asset_class: str,
    rack_category: str,
    ips: List[str],
    gateway_ips: Set[str],
    switch_peer_degree: int,
    listening_ports: List[int],
) -> str:
    text = f"{code} {name}".lower()
    aclass = (asset_class or "").lower()
    rcat = (rack_category or "").lower()

    # SAIs / UPS nunca son Firewalls aunque su código empiece por FIR*
    if rcat == "ups" or any(w in text for w in ("sai", "ups ", "ups/", "apc ")):
        return "compute_and_services"

    # Nivel 1: Routers, Gateways reales de subred, Firewalls y VIPs
    if (
        rcat in ("router", "firewall", "gateway")
        or aclass == "cluster_vip"
        or any(ip in gateway_ips for ip in ips)
        or any(w in text for w in ("mikrotik", "router", "ccr", "forti", "paloalto", "pfsense", "wan", "haproxy"))
    ):
        return "wan_perimetro"

    # Nivel 2 vs Nivel 3: Switches Core/Agregación frente a Switches de Acceso
    is_switch = (
        rcat == "switch"
        or any(w in text for w in ("switch", "sw48", "sw24", "catalyst", "nexus", "aruba"))
    )
    if is_switch:
        is_explicit_access = any(w in text for w in ("acc", "acceso", "tor"))
        if not is_explicit_access and (
            any(w in text for w in ("core", "agreg", "dist", "spine"))
            or switch_peer_degree >= 6
        ):
            return "core_distribution"
        return "access_switching"

    # Nivel 5: Dispositivos finales de planta, APs, impresoras o nodos autodescubiertos DISC-*
    is_auto_disc = code.upper().startswith("DISC-")
    if (
        aclass in ("floor_endpoint", "other_machine")
        or any(
            w in text
            for w in (
                "printer",
                "impresora",
                "iphone",
                "android",
                "pixel",
                "samsung",
                "ipad",
                "tab-",
                "google-home",
                "u6-",
                "unifi",
                "desktop",
                "macbook",
                "mcbook",
                "equipo detectado",
            )
        )
        or (is_auto_disc and aclass == "virtual_machine" and not listening_ports)
    ):
        return "endpoints_and_iot"

    return "compute_and_services"


def build_analyzed_network_schema(
    db: Session,
    scope_type: str = "global_cpd",
    scope_target_id: Optional[int] = None,
) -> Dict[str, Any]:
    if scope_type not in ALLOWED_SCOPES:
        scope_type = "global_cpd"

    base_snap = build_federated_readonly_snapshot(
        db=db,
        scope_type=scope_type,
        scope_target_id=scope_target_id,
    )
    telemetry_map, finops_findings = collect_finops_telemetry_and_findings(db)

    all_findings = list(base_snap.get("findings") or []) + finops_findings
    risks_by_code: Dict[str, List[Dict[str, str]]] = {}
    for f in all_findings:
        tcode = str(f.get("target_code") or "").strip()
        if tcode:
            risks_by_code.setdefault(tcode, []).append(
                {
                    "severity": str(f.get("severity") or "info"),
                    "category": str(f.get("category") or ""),
                    "title": str(f.get("title") or ""),
                }
            )

    # Cargar inventario completo desde SQLAlchemy (sin recortes [:40] que partan uplinks)
    locations = db.query(Location).options(joinedload(Location.floors)).all()
    floor_to_loc_id = {fl.id: loc.id for loc in locations for fl in loc.floors}

    racks = (
        db.query(Rack)
        .options(
            joinedload(Rack.room),
            joinedload(Rack.devices).joinedload(RackDevice.template),
        )
        .order_by(Rack.code.asc())
        .all()
    )
    connections = (
        db.query(Connection)
        .options(
            joinedload(Connection.source_port).joinedload(Port.device),
            joinedload(Connection.target_port).joinedload(Port.device),
        )
        .all()
    )
    assets = (
        db.query(CmdbAsset)
        .options(joinedload(CmdbAsset.ip_addresses))
        .filter(CmdbAsset.lifecycle_status != "decommissioned")
        .order_by(CmdbAsset.id.asc())
        .all()
    )
    subnets = db.query(CmdbSubnet).order_by(CmdbSubnet.id.asc()).all()
    logical_links = db.query(LogicalTopologyLink).all()
    ro_rows = (
        db.query(AiPassiveDiscoverySnapshot)
        .options(joinedload(AiPassiveDiscoverySnapshot.asset))
        .filter(AiPassiveDiscoverySnapshot.status == "completed")
        .order_by(AiPassiveDiscoverySnapshot.id.desc())
        .limit(80)
        .all()
    )

    # Filtrado de Racks/Activos según el alcance solicitado
    allowed_rack_ids: Optional[Set[int]] = None
    allowed_asset_ids: Optional[Set[int]] = None
    if scope_type == "location" and scope_target_id is not None:
        allowed_rack_ids = {
            rk.id
            for rk in racks
            if rk.room and floor_to_loc_id.get(rk.room.floor_id) == scope_target_id
        }
    elif scope_type == "rack" and scope_target_id is not None:
        allowed_rack_ids = {int(scope_target_id)}
    elif scope_type == "logical_stack" and scope_target_id is not None:
        st_asset_codes = {
            n["asset_code"]
            for s in (base_snap.get("tech_stacks") or [])
            for n in s.get("nodes", [])
            if n.get("asset_code")
        }
        allowed_asset_ids = {a.id for a in assets if a.code in st_asset_codes}
        allowed_rack_ids = set()
    elif scope_type == "host" and scope_target_id is not None:
        focus_id = int(scope_target_id)
        neighbor_ids = {focus_id}
        for lk in logical_links:
            if lk.source_asset_id == focus_id:
                neighbor_ids.add(lk.target_asset_id)
            elif lk.target_asset_id == focus_id:
                neighbor_ids.add(lk.source_asset_id)
        allowed_asset_ids = neighbor_ids
        allowed_rack_ids = set()

    rack_by_id: Dict[int, Rack] = {rk.id: rk for rk in racks}
    rack_dev_by_id: Dict[int, RackDevice] = {
        dv.id: dv for rk in racks for dv in rk.devices
    }

    # Calcular grado de interconexión física/lógica por equipo para distinguir Core vs Acceso
    rd_peer_set: Dict[int, Set[int]] = {}
    for conn in connections:
        sp, tp = conn.source_port, conn.target_port
        if not sp or not tp or not sp.device or not tp.device:
            continue
        if conn.cable_type == "power_ac" or "power" in (sp.port_type or "") or "power" in (tp.port_type or ""):
            continue
        d1, d2 = sp.device.id, tp.device.id
        if d1 != d2:
            rd_peer_set.setdefault(d1, set()).add(d2)
            rd_peer_set.setdefault(d2, set()).add(d1)

    asset_peer_set: Dict[int, Set[int]] = {}
    for lk in logical_links:
        if lk.source_asset_id != lk.target_asset_id:
            asset_peer_set.setdefault(lk.source_asset_id, set()).add(lk.target_asset_id)
            asset_peer_set.setdefault(lk.target_asset_id, set()).add(lk.source_asset_id)

    ro_by_key: Dict[str, AiPassiveDiscoverySnapshot] = {}
    for rs in ro_rows:
        if rs.asset and rs.asset.code not in ro_by_key:
            ro_by_key[rs.asset.code] = rs
        if rs.target_host and rs.target_host not in ro_by_key:
            ro_by_key[rs.target_host] = rs

    gateway_ips: Set[str] = {
        s.gateway.strip() for s in subnets if (s.gateway or "").strip()
    }

    # --- Agrupar activos CMDB que apuntan al mismo `rack_device_id` (evita duplicados 100%) ---
    assets_by_rd_id: Dict[int, List[CmdbAsset]] = {}
    standalone_assets: List[CmdbAsset] = []
    for a in assets:
        if allowed_asset_ids is not None and a.id not in allowed_asset_ids:
            continue
        if a.rack_device_id and a.rack_device_id in rack_dev_by_id:
            rd = rack_dev_by_id[a.rack_device_id]
            if allowed_rack_ids is not None and rd.rack_id not in allowed_rack_ids and allowed_asset_ids is None:
                continue
            assets_by_rd_id.setdefault(a.rack_device_id, []).append(a)
        else:
            if allowed_rack_ids is not None and allowed_asset_ids is None:
                if not (a.host_rack_device_id and a.host_rack_device_id in rack_dev_by_id and rack_dev_by_id[a.host_rack_device_id].rack_id in allowed_rack_ids):
                    continue
            standalone_assets.append(a)

    raw_nodes_by_layer: Dict[str, List[Dict[str, Any]]] = {k[0]: [] for k in LAYER_DEFINITIONS}
    node_id_by_asset_id: Dict[int, str] = {}
    node_id_by_rd_id: Dict[int, str] = {}
    node_id_by_code: Dict[str, str] = {}
    node_ips_map: Dict[str, List[str]] = {}
    node_layer_map: Dict[str, str] = {}

    # 1) Nodos físicos enracados (fusionando su(s) ficha(s) CMDB si existen)
    for rk in racks:
        if allowed_rack_ids is not None and rk.id not in allowed_rack_ids:
            continue
        for dv in sorted(rk.devices, key=lambda d: (-d.start_u, d.code)):
            cat = dv.template.category if dv.template else "miscellaneous"
            if is_auxiliary_rack_item(dv.code, cat):
                continue

            linked_cis = assets_by_rd_id.get(dv.id, [])
            # Elegir como CI primario el que tenga IP o no empiece por DISC-
            primary_ci: Optional[CmdbAsset] = None
            if linked_cis:
                linked_cis_sorted = sorted(
                    linked_cis,
                    key=lambda c: (0 if c.ip_addresses else 1, 1 if c.code.startswith("DISC-") else 0, c.id),
                )
                primary_ci = linked_cis_sorted[0]

            all_ips: List[str] = []
            if dv.ip_address and dv.ip_address.strip():
                all_ips.append(dv.ip_address.strip())
            for ci in linked_cis:
                for ip_row in ci.ip_addresses:
                    if ip_row.ip_address and ip_row.ip_address.strip() not in all_ips:
                        all_ips.append(ip_row.ip_address.strip())

            ro_snap = ro_by_key.get(dv.code)
            if not ro_snap and primary_ci:
                ro_snap = ro_by_key.get(primary_ci.code)
            if not ro_snap and all_ips:
                ro_snap = ro_by_key.get(all_ips[0])

            listen_ports = [
                int(p.get("port") or 0)
                for p in ((ro_snap.listening_ports if ro_snap else None) or [])
                if p.get("port")
            ]
            containers = [
                f"{c.get('name')} ({c.get('image')})"
                for c in ((ro_snap.containers if ro_snap else None) or [])[:6]
            ]
            snmp_up = sum(
                1
                for iface in ((ro_snap.snmp_interfaces if ro_snap else None) or [])
                if iface.get("oper_status") == "up"
            )

            deg = len(rd_peer_set.get(dv.id, set()))
            if primary_ci:
                deg = max(deg, len(asset_peer_set.get(primary_ci.id, set())))

            layer_key = _classify_canonical_layer(
                code=dv.code,
                name=dv.name,
                asset_class=primary_ci.asset_class if primary_ci else "network_security",
                rack_category=cat,
                ips=all_ips,
                gateway_ips=gateway_ips,
                switch_peer_degree=deg,
                listening_ports=listen_ports,
            )

            node_risks: List[Dict[str, str]] = list(risks_by_code.get(dv.code, []))
            for ci in linked_cis:
                for rk_badge in risks_by_code.get(ci.code, []):
                    if rk_badge not in node_risks:
                        node_risks.append(rk_badge)

            layer_color = next(c for k, _t, _s, c in LAYER_DEFINITIONS if k == layer_key)
            border_hex = (
                "#DC2626"
                if any(r["severity"] in ("critical", "high") for r in node_risks)
                else ("#D97706" if node_risks else layer_color)
            )

            nid = f"DEV_{dv.id}"
            node_id_by_rd_id[dv.id] = nid
            node_id_by_code[dv.code] = nid
            for ci in linked_cis:
                node_id_by_asset_id[ci.id] = nid
                node_id_by_code[ci.code] = nid

            tel = telemetry_map.get(primary_ci.code, {}) if primary_ci else {}
            uh = dv.template.u_height if dv.template else 1
            u_lbl = f"U{dv.start_u}-U{dv.start_u + uh - 1}" if uh > 1 else f"U{dv.start_u}"
            model_txt = (
                f"{dv.template.manufacturer} {dv.template.model_name}"
                if dv.template
                else (primary_ci.os_or_firmware if primary_ci else cat)
            )

            node_ips_map[nid] = all_ips
            node_layer_map[nid] = layer_key
            raw_nodes_by_layer[layer_key].append(
                {
                    "id": nid,
                    "asset_id": primary_ci.id if primary_ci else None,
                    "rack_id": rk.id,
                    "rack_device_id": dv.id,
                    "sort_group": f"{rk.code}_{dv.code}",
                    "code": dv.code,
                    "name": dv.name,
                    "ip": all_ips[0] if all_ips else "",
                    "subtitle": f"Rack {rk.code} ({u_lbl})"
                    + (f" · :{',:'.join(str(p) for p in listen_ports[:3])}" if listen_ports else ""),
                    "model_name": model_txt,
                    "serial_number": dv.serial_number or "",
                    "status": primary_ci.status if primary_ci else (dv.status or "online"),
                    "color_hex": border_hex,
                    "listening_ports": listen_ports[:12],
                    "containers": containers,
                    "snmp_ports_up": snmp_up,
                    "cpu_pct": tel.get("cpu_pct"),
                    "ram_pct": tel.get("ram_pct"),
                    "disk_pct": tel.get("disk_pct"),
                    "risk_badges": node_risks[:5],
                }
            )

    # 2) Activos lógicos / VMs / Endpoints sin `rack_device_id` directo
    ip_already_drawn = {ip for ips in node_ips_map.values() for ip in ips}
    for a in standalone_assets:
        a_ips = [ip.ip_address.strip() for ip in a.ip_addresses if (ip.ip_address or "").strip()]
        # Evitar duplicar un DISC-* cuya IP ya pertenece a un equipo enracado arriba
        if a.code.upper().startswith("DISC-") and a_ips and all(ip in ip_already_drawn for ip in a_ips):
            continue

        ro_snap = ro_by_key.get(a.code) or (ro_by_key.get(a_ips[0]) if a_ips else None)
        listen_ports = [
            int(p.get("port") or 0)
            for p in ((ro_snap.listening_ports if ro_snap else None) or [])
            if p.get("port")
        ]
        containers = [
            f"{c.get('name')} ({c.get('image')})"
            for c in ((ro_snap.containers if ro_snap else None) or [])[:6]
        ]

        layer_key = _classify_canonical_layer(
            code=a.code,
            name=a.name,
            asset_class=a.asset_class,
            rack_category="",
            ips=a_ips,
            gateway_ips=gateway_ips,
            switch_peer_degree=len(asset_peer_set.get(a.id, set())),
            listening_ports=listen_ports,
        )

        node_risks = list(risks_by_code.get(a.code, []))
        layer_color = next(c for k, _t, _s, c in LAYER_DEFINITIONS if k == layer_key)
        border_hex = (
            "#DC2626"
            if any(r["severity"] in ("critical", "high") for r in node_risks)
            else ("#D97706" if node_risks else layer_color)
        )

        host_rk_id: Optional[int] = None
        host_rk_code = ""
        if a.host_rack_device_id and a.host_rack_device_id in rack_dev_by_id:
            hrd = rack_dev_by_id[a.host_rack_device_id]
            host_rk_id = hrd.rack_id
            host_rk_code = rack_by_id[hrd.rack_id].code if hrd.rack_id in rack_by_id else ""

        nid = f"CI_{a.id}"
        node_id_by_asset_id[a.id] = nid
        node_id_by_code[a.code] = nid
        node_ips_map[nid] = a_ips
        node_layer_map[nid] = layer_key

        tel = telemetry_map.get(a.code, {})
        sub_parts = []
        if host_rk_code:
            sub_parts.append(f"Host en {host_rk_code}")
        if a.ip_addresses and a_ips and a_ips[0] in gateway_ips:
            sub_parts.append("Gateway L3")
        elif listen_ports:
            sub_parts.append(f"RO :{',:'.join(str(p) for p in listen_ports[:3])}")
        elif a.cpu_cores and layer_key == "compute_and_services":
            sub_parts.append(f"{a.cpu_cores}vCPU/{a.ram_gb}GB")
        else:
            sub_parts.append(a.asset_class)

        raw_nodes_by_layer[layer_key].append(
            {
                "id": nid,
                "asset_id": a.id,
                "rack_id": host_rk_id,
                "rack_device_id": None,
                "sort_group": f"{a_ips[0] if a_ips else '999'}_{a.code}",
                "code": a.code,
                "name": a.name,
                "ip": a_ips[0] if a_ips else "",
                "subtitle": " • ".join(sub_parts),
                "model_name": a.os_or_firmware or "",
                "serial_number": "",
                "status": a.status or "online",
                "color_hex": border_hex,
                "listening_ports": listen_ports[:12],
                "containers": containers,
                "snmp_ports_up": 0,
                "cpu_pct": tel.get("cpu_pct"),
                "ram_pct": tel.get("ram_pct"),
                "disk_pct": tel.get("disk_pct"),
                "risk_badges": node_risks[:5],
            }
        )

    # 3) Nodos de Subred L3 (`CmdbSubnet`) en Nivel 1 cuando existen equipos en su rango CIDR
    parsed_subnets: List[Tuple[str, CmdbSubnet, ipaddress.IPv4Network]] = []
    if scope_type in ("global_cpd", "location"):
        for sub in subnets:
            try:
                net_obj = ipaddress.ip_network(sub.cidr.strip(), strict=False)
                if not isinstance(net_obj, ipaddress.IPv4Network):
                    continue
            except ValueError:
                continue
            sub_nid = f"SUB_{sub.id}"
            parsed_subnets.append((sub_nid, sub, net_obj))
            vlan_lbl = f"VLAN-{sub.vlan_id}" if sub.vlan_id else f"NET-{sub.id}"
            raw_nodes_by_layer["wan_perimetro"].append(
                {
                    "id": sub_nid,
                    "asset_id": None,
                    "rack_id": None,
                    "rack_device_id": None,
                    "sort_group": f"ZZ_SUB_{sub.id}",
                    "code": vlan_lbl,
                    "name": sub.name,
                    "ip": sub.cidr,
                    "subtitle": f"GW {sub.gateway or '—'} · Segmento L3",
                    "model_name": "Subred IPAM",
                    "serial_number": "",
                    "status": "online",
                    "color_hex": "#DC2626",
                    "listening_ports": [],
                    "containers": [],
                    "snmp_ports_up": 0,
                    "cpu_pct": None,
                    "ram_pct": None,
                    "disk_pct": None,
                    "risk_badges": [],
                }
            )
            node_layer_map[sub_nid] = "wan_perimetro"

    # Ordenar dentro de cada nivel por `sort_group` (agrupa switches por Rack y endpoints por subred!)
    for lkey in raw_nodes_by_layer:
        raw_nodes_by_layer[lkey].sort(key=lambda x: str(x.get("sort_group") or x["code"]))

    # --- Posicionamiento Geométrico Norte -> Sur espaciado para curvas limpias ---
    cols_per_row = 6
    node_w = 232.0
    node_h = 84.0
    gap_x = 24.0
    gap_y = 26.0
    margin_x = 32.0
    canvas_width = margin_x * 2 + cols_per_row * node_w + (cols_per_row - 1) * gap_x + 48.0
    zone_width = canvas_width - margin_x * 2

    zones_out: List[Dict[str, Any]] = []
    nodes_out: List[Dict[str, Any]] = []
    cursor_y = 26.0

    for layer_key, layer_title, layer_sub, layer_hex in LAYER_DEFINITIONS:
        items = raw_nodes_by_layer.get(layer_key, [])
        if not items:
            continue
        rows_count = max(1, (len(items) + cols_per_row - 1) // cols_per_row)
        zone_h = 54.0 + rows_count * node_h + (rows_count - 1) * gap_y + 24.0

        zones_out.append(
            {
                "id": layer_key,
                "title": layer_title,
                "subtitle": f"{layer_sub} ({len(items)} nodos)",
                "x": margin_x,
                "y": cursor_y,
                "width": zone_width,
                "height": zone_h,
                "color_hex": layer_hex,
            }
        )

        for idx, item in enumerate(items):
            r_idx = idx // cols_per_row
            c_idx = idx % cols_per_row
            items_in_row = min(cols_per_row, len(items) - r_idx * cols_per_row)
            row_w = items_in_row * node_w + (items_in_row - 1) * gap_x
            start_x = margin_x + (zone_width - row_w) / 2.0
            nx = round(start_x + c_idx * (node_w + gap_x), 1)
            ny = round(cursor_y + 48.0 + r_idx * (node_h + gap_y), 1)

            clean_item = {k: v for k, v in item.items() if k != "sort_group"}
            nodes_out.append(
                {
                    **clean_item,
                    "layer_key": layer_key,
                    "x": nx,
                    "y": ny,
                    "width": node_w,
                    "height": node_h,
                }
            )

        cursor_y += zone_h + 44.0  # Canal amplio de 44px entre niveles para curvas Norte-Sur

    canvas_height = max(780.0, cursor_y + 20.0)
    visible_node_ids = {str(n["id"]) for n in nodes_out}
    layer_rank = {k[0]: idx for idx, k in enumerate(LAYER_DEFINITIONS)}

    # --- Consolidación de Aristas por Par de Nodos (evita líneas superpuestas en LACP / Dual Fibra) ---
    pair_bundles: Dict[Tuple[str, str], Dict[str, Any]] = {}
    connected_nodes: Set[str] = set()

    def _orient_north_south(u: str, v: str) -> Tuple[str, str]:
        ru = layer_rank.get(node_layer_map.get(u, ""), 99)
        rv = layer_rank.get(node_layer_map.get(v, ""), 99)
        if ru < rv:
            return (u, v)
        if rv < ru:
            return (v, u)
        return (u, v) if u < v else (v, u)

    def _register_link(
        u_opt: Optional[str],
        v_opt: Optional[str],
        edge_kind: str,
        label: str,
        detail: str,
        color_hex: str,
        dashed: bool = False,
    ) -> None:
        if not u_opt or not v_opt or u_opt == v_opt:
            return
        if u_opt not in visible_node_ids or v_opt not in visible_node_ids:
            return
        src, dst = _orient_north_south(u_opt, v_opt)
        connected_nodes.add(src)
        connected_nodes.add(dst)
        bkey = (src, dst)
        bundle = pair_bundles.get(bkey)
        if bundle is None:
            pair_bundles[bkey] = {
                "source_id": src,
                "target_id": dst,
                "edge_kind": edge_kind,
                "labels": [label] if label else [],
                "details": [detail] if detail else [],
                "color_hex": color_hex,
                "dashed": dashed,
                "count": 1,
            }
        else:
            bundle["count"] += 1
            if label and label not in bundle["labels"]:
                bundle["labels"].append(label)
            if detail and detail not in bundle["details"]:
                bundle["details"].append(detail)
            # Priorizar color de fibra / físico si coexiste con enlace lógico duplicado
            if edge_kind == "physical_cabling":
                bundle["edge_kind"] = "physical_cabling"
                bundle["color_hex"] = color_hex
                bundle["dashed"] = False
            elif edge_kind == "passive_ro_discovered" and bundle["edge_kind"] not in ("physical_cabling", "logical_confirmed"):
                bundle["dashed"] = True

    # A) Cableado físico de datos (`Connection`, excluyendo cables eléctricos `power_ac`)
    for conn in connections:
        sp, tp = conn.source_port, conn.target_port
        if not sp or not tp or not sp.device or not tp.device:
            continue
        ctype = str(conn.cable_type or "utp_cat6")
        if ctype == "power_ac" or "power" in (sp.port_type or "") or "power" in (tp.port_type or ""):
            continue
        u_nid = node_id_by_rd_id.get(sp.device.id)
        v_nid = node_id_by_rd_id.get(tp.device.id)
        col = "#0284C7" if "fiber" in ctype else "#2563EB"
        _register_link(
            u_nid,
            v_nid,
            "physical_cabling",
            f"{sp.port_number}⇄{tp.port_number}",
            f"Cable {ctype}",
            col,
            dashed=False,
        )

    # B) Alojamiento Hipervisor Físico -> VM Huésped
    for a in assets:
        vm_nid = node_id_by_asset_id.get(a.id)
        if a.host_rack_device_id:
            hyp_nid = node_id_by_rd_id.get(a.host_rack_device_id)
            _register_link(
                hyp_nid,
                vm_nid,
                "hosting_parent",
                "Host VM",
                "Alojamiento virtualización",
                "#4F46E5",
                dashed=False,
            )

    # C) Enlaces lógicos confirmados (`LogicalTopologyLink`)
    for lk in logical_links:
        u_nid = node_id_by_asset_id.get(lk.source_asset_id)
        v_nid = node_id_by_asset_id.get(lk.target_asset_id)
        short_lbl = str(lk.protocol_label or lk.link_type).split("(")[0].strip()[:26]
        _register_link(
            u_nid,
            v_nid,
            "logical_confirmed",
            short_lbl,
            f"Lógico ({lk.link_type})",
            "#16A34A",
            dashed=False,
        )

    # D) Descubrimiento Pasivo RO (Fase 2: conexiones TCP establecidas + vecinos LLDP)
    for rs in ro_rows:
        for dep in (rs.inferred_dependencies or []):
            s_nid = (
                node_id_by_asset_id.get(int(dep["source_asset_id"]))
                if dep.get("source_asset_id")
                else node_id_by_code.get(str(dep.get("source_code") or ""))
            )
            t_nid = (
                node_id_by_asset_id.get(int(dep["target_asset_id"]))
                if dep.get("target_asset_id")
                else node_id_by_code.get(str(dep.get("target_code") or ""))
            )
            _register_link(
                s_nid,
                t_nid,
                "passive_ro_discovered",
                f"RO {dep.get('protocol_label') or 'TCP'}",
                f"Descubierto RO ({rs.collector_type})",
                "#06B6D4",
                dashed=True,
            )

    # E) Topología IP L3 automática (`Gateway -> Subred` y `Subred -> Nodos sin enlace físico directo`)
    for sub_nid, sub, net_obj in parsed_subnets:
        gw_ip = (sub.gateway or "").strip()
        # 1. Conectar el Gateway o los Core Switches de esa subred con el nodo Subred
        gw_connected = False
        for nid, ips in node_ips_map.items():
            if gw_ip and gw_ip in ips:
                _register_link(
                    nid,
                    sub_nid,
                    "subnet_l3",
                    f"GW {gw_ip}",
                    f"Pasarela L3 de {sub.cidr}",
                    "#DC2626",
                    dashed=False,
                )
                gw_connected = True

        # Si no hay router con la IP exacta del gateway, enlazar la subred con los Core Switches presentes en ella
        for nid, ips in node_ips_map.items():
            if node_layer_map.get(nid) == "core_distribution":
                if any(
                    _ip_in_net(ip_s, net_obj)
                    for ip_s in ips
                ):
                    _register_link(
                        sub_nid,
                        nid,
                        "subnet_l3",
                        f"VLAN {sub.vlan_id or 'Mgmt'}",
                        f" Troncal L3 {sub.cidr}",
                        "#0284C7",
                        dashed=False,
                    )
                    gw_connected = True

        # 2. Enlazar cualquier host/servidor/endpoint cuya IP pertenezca a esta subred y aún esté sin cable L2
        for nid, ips in node_ips_map.items():
            if nid == sub_nid or nid in connected_nodes:
                continue
            if any(_ip_in_net(ip_s, net_obj) for ip_s in ips):
                _register_link(
                    sub_nid,
                    nid,
                    "subnet_l3",
                    "IP LAN",
                    f"Miembro L3 de {sub.cidr}",
                    "#64748B",
                    dashed=True,
                )

    edges_out: List[Dict[str, Any]] = []
    for idx, b in enumerate(pair_bundles.values(), start=1):
        cnt = int(b["count"])
        labels = b["labels"]
        if cnt >= 2:
            sample = ", ".join(labels[:2])
            agg_label = f"{cnt}x Enlaces ({sample})"[:36]
        else:
            agg_label = (labels[0] if labels else "Enlace")[:36]
        edges_out.append(
            {
                "id": f"E_{idx}",
                "source_id": b["source_id"],
                "target_id": b["target_id"],
                "edge_kind": b["edge_kind"],
                "label": agg_label,
                "detail": " | ".join(b["details"][:4])[:160],
                "color_hex": b["color_hex"],
                "dashed": bool(b["dashed"]),
                "bundle_count": cnt,
            }
        )

    return sanitize_context_payload(
        {
            "scope_type": scope_type,
            "scope_target_id": scope_target_id,
            "title": f"Esquema Topológico de Red — {base_snap['scope_label']}",
            "subtitle": "Jerarquía Norte-Sur deduplicada (Perímetro L3 ➔ Core HA ➔ Acceso por Rack ➔ Servidores ➔ Endpoints)",
            "canvas_width": canvas_width,
            "canvas_height": canvas_height,
            "zones": zones_out,
            "nodes": nodes_out,
            "edges": edges_out,
            "summary": {
                "zones_count": len(zones_out),
                "nodes_count": len(nodes_out),
                "edges_total": len(edges_out),
                "edges_physical": sum(1 for e in edges_out if e["edge_kind"] == "physical_cabling"),
                "edges_hosting": sum(1 for e in edges_out if e["edge_kind"] == "hosting_parent"),
                "edges_logical": sum(1 for e in edges_out if e["edge_kind"] == "logical_confirmed"),
                "edges_subnet_l3": sum(1 for e in edges_out if e["edge_kind"] == "subnet_l3"),
                "edges_passive_ro": sum(1 for e in edges_out if e["edge_kind"] == "passive_ro_discovered"),
                "nodes_with_risks": sum(1 for n in nodes_out if n.get("risk_badges")),
            },
            "finops_findings": finops_findings,
        }
    )


def _ip_in_net(ip_str: str, net_obj: ipaddress.IPv4Network) -> bool:
    try:
        addr = ipaddress.ip_address(ip_str.strip())
        return isinstance(addr, ipaddress.IPv4Address) and addr in net_obj
    except ValueError:
        return False


# ==============================================================================
# 3. PUBLICACIÓN HUMAN-IN-THE-LOOP HACIA `4. RED & HOST` (`TechStackDiagram`)
# ==============================================================================


def publish_analyzed_schema_to_tech_stack(
    db: Session,
    scope_type: str = "global_cpd",
    scope_target_id: Optional[int] = None,
    stack_name: str = "",
    include_passive_ro_edges: bool = True,
    published_by: str = "editor",
) -> Dict[str, Any]:
    schema = build_analyzed_network_schema(
        db=db,
        scope_type=scope_type,
        scope_target_id=scope_target_id,
    )
    cw = max(1200.0, float(schema["canvas_width"]))
    ch = max(750.0, float(schema["canvas_height"]))

    clean_title = (stack_name or "").strip() or f"[IA] {schema['title']}"
    stack_code = f"STACK-AI-{scope_type.upper()[:6]}-{secrets.token_hex(2).upper()}"

    canvas_boxes = [
        {
            "id": z["id"],
            "title": z["title"],
            "corner_data": z["subtitle"],
            "pos_x": round(min(0.95, max(0.01, float(z["x"]) / cw)), 4),
            "pos_y": round(min(0.95, max(0.01, float(z["y"]) / ch)), 4),
            "width_px": float(z["width"]),
            "height_px": float(z["height"]),
            "color_hex": z["color_hex"],
        }
        for z in schema["zones"]
    ]

    stack = TechStackDiagram(
        code=stack_code,
        name=clean_title[:180],
        description=f"Generado a partir del análisis topológico solo-lectura de RackDoc AI por {published_by}.",
        business_service=schema["title"][:140],
        environment="production",
        owner_team="Arquitectura & IA",
        criticality="critical",
        map_scale=1.0,
        canvas_boxes=canvas_boxes,
    )
    db.add(stack)
    db.flush()

    stack_node_by_schema_id: Dict[str, TechStackNode] = {}
    for n in schema["nodes"]:
        aid = n.get("asset_id")
        if not aid:
            continue
        ts_node = TechStackNode(
            stack_id=stack.id,
            asset_id=int(aid),
            role_layer=str(n.get("layer_key") or "general")[:48],
            custom_label=f"{n['code']} · {n['name']}"[:140],
            pos_x=round(min(0.92, max(0.02, float(n["x"]) / cw)), 4),
            pos_y=round(min(0.92, max(0.02, float(n["y"]) / ch)), 4),
            width_px=210.0,
            height_px=105.0,
        )
        db.add(ts_node)
        db.flush()
        stack_node_by_schema_id[str(n["id"])] = ts_node

    edges_created = 0
    for e in schema["edges"]:
        if e["edge_kind"] == "passive_ro_discovered" and not include_passive_ro_edges:
            continue
        sn = stack_node_by_schema_id.get(str(e["source_id"]))
        tn = stack_node_by_schema_id.get(str(e["target_id"]))
        if not sn or not tn or sn.id == tn.id:
            continue
        port_match = re.search(r":(\d{2,5})", str(e.get("label") or ""))
        port_num = int(port_match.group(1)) if port_match else 443
        db.add(
            TechStackEdge(
                stack_id=stack.id,
                source_node_id=sn.id,
                target_node_id=tn.id,
                protocol_label=str(e.get("label") or "TCP/IP")[:120],
                port=port_num,
                notes=str(e.get("detail") or ""),
            )
        )
        edges_created += 1

    db.commit()
    db.refresh(stack)
    return {
        "stack_id": stack.id,
        "stack_code": stack.code,
        "stack_name": stack.name,
        "nodes_created": len(stack_node_by_schema_id),
        "edges_created": edges_created,
    }
