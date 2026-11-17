"""
Fase 3 — Motor de Esquemas Visuales de Red según Análisis IA (`AiNetworkSchema`),
Auditoría FinOps / Capacidad con Prometheus TSDB y Publicación `Human-in-the-Loop`
hacia `4. Red & Host (Stacks Tecnológicos 2D)`.
"""

from __future__ import annotations

import os
import re
import secrets
from typing import Any, Dict, List, Optional, Tuple

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
    """
    Cruza las métricas instantáneas de Prometheus y `MonitoredServiceCheck.metrics_snapshot`
    con los recursos asignados en CMDB (`cpu_cores`, `ram_gb`, `storage_gb`) para detectar
    saturación (>85%) o sobredimensionamiento FinOps (<10% en máquinas grandes).
    """
    telemetry_by_code: Dict[str, Dict[str, float]] = {}

    # 1. Fallback local desde snapshots de chequeos Nagios/Prometheus ya almacenados
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

    # 2. Lectura en vivo no intrusiva contra Prometheus TSDB si está levantado
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
# 2. GENERADOR DE ESQUEMA VISUAL 2D DE RED SEGÚN ANÁLISIS (5 CAPAS + ENLACES RO)
# ==============================================================================

LAYER_DEFINITIONS: List[Tuple[str, str, str, str]] = [
    (
        "wan_perimetro",
        "CAPA 1 • SUBREDES IPAM, GATEWAYS, FIREWALLS Y PERÍMETRO / VIPs",
        "Perímetro, enrutamiento y balanceo de entrada",
        "#DC2626",
    ),
    (
        "switching_racks",
        "CAPA 2 • CONMUTACIÓN FÍSICA, BASTIDORES RACK Y TRONCALES SNMP / LLDP",
        "Switches Core/ToR, Patching y distribución en sala",
        "#0284C7",
    ),
    (
        "hipervisores_hierro",
        "CAPA 3 • HIPERVISORES FÍSICOS (ESXi / PROXMOX / KVM) Y SERVIDORES BAREMETAL",
        "Cómputo físico montado en Rack",
        "#2563EB",
    ),
    (
        "apps_vms_contenedores",
        "CAPA 4 • MÁQUINAS VIRTUALES, PROXIES WEB Y CONTENEDORES DESCUBIERTOS",
        "Carga de trabajo de aplicación y middleware",
        "#7C3AED",
    ),
    (
        "datos_almacenamiento",
        "CAPA 5 • BASES DE DATOS, CACHÉ Y ALMACENAMIENTO SAN / NAS",
        "Persistencia crítica y backends de datos",
        "#0D9488",
    ),
]


def _classify_asset_layer(asset_data: Dict[str, Any], listening_ports: List[int]) -> str:
    aclass = str(asset_data.get("asset_class") or "").lower()
    name_low = f"{asset_data.get('code', '')} {asset_data.get('name', '')} {asset_data.get('os_or_firmware', '')}".lower()

    if aclass == "cluster_vip" or any(k in name_low for k in ("firewall", "forti", "paloalto", "pfsense", "router", "wan", "vip", "haproxy")):
        return "wan_perimetro"
    if aclass == "network_security" or any(k in name_low for k in ("switch", "catalyst", "nexus", "aruba", "mikrotik", "tor")):
        return "switching_racks"
    if aclass == "storage_san_nas" or any(
        k in name_low for k in ("postgres", "mysql", "mariadb", "oracle", "mssql", "sql", "redis", "mongo", "san", "nas", "truenas", "netapp")
    ) or any(p in listening_ports for p in (5432, 3306, 1433, 6379, 27017, 2049)):
        return "datos_almacenamiento"
    if aclass == "physical_server" or any(k in name_low for k in ("esxi", "proxmox", "pve", "hypervisor", "hyper-v", "kvm", "poweredge", "proliant")):
        return "hipervisores_hierro"
    return "apps_vms_contenedores"


def build_analyzed_network_schema(
    db: Session,
    scope_type: str = "global_cpd",
    scope_target_id: Optional[int] = None,
) -> Dict[str, Any]:
    """
    Construye el grafo geométrico completo en 2D (`zones`, `nodes`, `edges`) a partir del
    análisis combinado de Fase 1 (Racks, Cableado, CMDB, Topología, SPOFs, CertScope) y
    Fase 2 (Descubrimiento Pasivo SSH/WinRM + SNMP IF-MIB/LLDP-MIB).
    """
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

    # Mapear descubrimiento pasivo reciente por asset_code o target_host
    ro_rows = (
        db.query(AiPassiveDiscoverySnapshot)
        .options(joinedload(AiPassiveDiscoverySnapshot.asset))
        .filter(AiPassiveDiscoverySnapshot.status == "completed")
        .order_by(AiPassiveDiscoverySnapshot.id.desc())
        .limit(60)
        .all()
    )
    ro_by_code: Dict[str, AiPassiveDiscoverySnapshot] = {}
    for rs in ro_rows:
        if rs.asset and rs.asset.code not in ro_by_code:
            ro_by_code[rs.asset.code] = rs
        if rs.target_host and rs.target_host not in ro_by_code:
            ro_by_code[rs.target_host] = rs

    # Recopilar nodos candidatos (Subredes clave + Equipos de Rack sin CI + Activos CMDB)
    raw_nodes_by_layer: Dict[str, List[Dict[str, Any]]] = {k[0]: [] for k in LAYER_DEFINITIONS}
    node_id_by_code: Dict[str, str] = {}
    asset_id_by_node_id: Dict[str, int] = {}

    # Subredes IPAM como nodos de contexto en Capa 1 (máx 4 para no saturar el esquema)
    for idx, sub in enumerate((base_snap.get("subnets") or [])[:4]):
        nid = f"SUB_{idx + 1}"
        cidr = str(sub.get("cidr") or "")
        raw_nodes_by_layer["wan_perimetro"].append(
            {
                "id": nid,
                "asset_id": None,
                "rack_id": None,
                "rack_device_id": None,
                "code": f"VLAN-{sub.get('vlan_id') or idx + 1}",
                "name": str(sub.get("name") or cidr),
                "ip": cidr,
                "subtitle": f"GW {sub.get('gateway') or '—'} · {sub.get('environment') or 'prod'}",
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

    # Activos CMDB dentro del alcance analizado
    all_db_assets = {
        a.id: a
        for a in db.query(CmdbAsset).options(joinedload(CmdbAsset.host_rack_device)).all()
    }
    rack_by_code = {r["code"]: r for r in (base_snap.get("racks") or [])}

    for a_sum in (base_snap.get("assets") or [])[:42]:
        code = str(a_sum["code"])
        ro_snap = ro_by_code.get(code) or (
            ro_by_code.get(a_sum["ips"][0]) if a_sum.get("ips") else None
        )
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

        layer_key = _classify_asset_layer(a_sum, listen_ports)
        layer_color = next(c for k, _t, _s, c in LAYER_DEFINITIONS if k == layer_key)
        node_risks = risks_by_code.get(code, [])
        if any(r["severity"] in ("critical", "high") for r in node_risks):
            border_hex = "#DC2626"
        elif node_risks:
            border_hex = "#D97706"
        else:
            border_hex = layer_color

        tel = telemetry_map.get(code, {})
        rk_code = str(a_sum.get("rack_code") or "")
        rk_info = rack_by_code.get(rk_code)
        orm_asset = all_db_assets.get(int(a_sum["id"]))

        nid = f"CI_{a_sum['id']}"
        node_id_by_code[code] = nid
        asset_id_by_node_id[nid] = int(a_sum["id"])

        subtitle_parts = []
        if rk_code:
            subtitle_parts.append(f"Rack {rk_code}")
        if listen_ports:
            subtitle_parts.append(f"RO :{',:'.join(str(p) for p in listen_ports[:4])}")
        elif a_sum.get("cpu_cores"):
            subtitle_parts.append(f"{a_sum['cpu_cores']}vCPU/{a_sum['ram_gb']}GB")

        raw_nodes_by_layer[layer_key].append(
            {
                "id": nid,
                "asset_id": int(a_sum["id"]),
                "rack_id": rk_info["id"] if rk_info else None,
                "rack_device_id": orm_asset.rack_device_id if orm_asset else None,
                "code": code,
                "name": str(a_sum["name"]),
                "ip": a_sum["ips"][0] if a_sum.get("ips") else "",
                "subtitle": " • ".join(subtitle_parts) or str(a_sum["asset_class"]),
                "model_name": str(a_sum.get("os_or_firmware") or ""),
                "serial_number": "",
                "status": str(a_sum.get("status") or "online"),
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

    # Añadir equipos físicos relevantes de Rack que aún no tuvieran ficha CMDB propia
    for rk in (base_snap.get("racks") or [])[:10]:
        for dv in (rk.get("devices") or []):
            dv_code = str(dv["code"])
            if dv_code in node_id_by_code:
                continue
            cat = str(dv.get("category") or "").lower()
            if cat in ("cable_manager", "patch_panel", "patchbox", "rack_tray"):
                continue
            if cat in ("firewall", "router", "gateway"):
                lkey = "wan_perimetro"
            elif cat in ("switch", "pdu", "ups", "external_power_feed", "schuko"):
                lkey = "switching_racks"
            elif cat == "storage":
                lkey = "datos_almacenamiento"
            else:
                lkey = "hipervisores_hierro"

            nid = f"RD_{dv['id']}"
            node_id_by_code[dv_code] = nid
            raw_nodes_by_layer[lkey].append(
                {
                    "id": nid,
                    "asset_id": None,
                    "rack_id": int(rk["id"]),
                    "rack_device_id": int(dv["id"]),
                    "code": dv_code,
                    "name": str(dv["name"]),
                    "ip": str(dv.get("ip_address") or ""),
                    "subtitle": f"Rack {rk['code']} ({dv['u_range']})",
                    "model_name": str(dv.get("model") or cat),
                    "serial_number": "",
                    "status": str(dv.get("status") or "online"),
                    "color_hex": "#0284C7" if lkey == "switching_racks" else "#2563EB",
                    "listening_ports": [],
                    "containers": [],
                    "snmp_ports_up": 0,
                    "cpu_pct": None,
                    "ram_pct": None,
                    "disk_pct": None,
                    "risk_badges": risks_by_code.get(rk["code"], [])[:2],
                }
            )

    # --- Cálculo geométrico de Zonas (Swimlanes) y Nodos (Grid limpio sin solapamientos) ---
    canvas_width = 1480.0
    margin_x = 28.0
    zone_width = canvas_width - (margin_x * 2)
    node_w = 236.0
    node_h = 88.0
    gap_x = 24.0
    gap_y = 20.0
    cols_per_row = 5

    zones_out: List[Dict[str, Any]] = []
    nodes_out: List[Dict[str, Any]] = []
    cursor_y = 24.0

    for layer_key, layer_title, layer_sub, layer_hex in LAYER_DEFINITIONS:
        items = raw_nodes_by_layer.get(layer_key, [])
        if not items:
            continue
        rows_count = max(1, (len(items) + cols_per_row - 1) // cols_per_row)
        zone_h = 52.0 + rows_count * node_h + (rows_count - 1) * gap_y + 22.0

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
            items_in_this_row = min(cols_per_row, len(items) - r_idx * cols_per_row)
            total_row_w = items_in_this_row * node_w + (items_in_this_row - 1) * gap_x
            start_x = margin_x + max(24.0, (zone_width - total_row_w) / 2.0)

            nx = round(start_x + c_idx * (node_w + gap_x), 1)
            ny = round(cursor_y + 46.0 + r_idx * (node_h + gap_y), 1)
            nodes_out.append(
                {
                    **item,
                    "layer_key": layer_key,
                    "x": nx,
                    "y": ny,
                    "width": node_w,
                    "height": node_h,
                }
            )

        cursor_y += zone_h + 22.0

    canvas_height = max(780.0, cursor_y + 16.0)

    # --- Construcción de Aristas Multi-Fuente ---
    edges_out: List[Dict[str, Any]] = []
    seen_edges = set()

    def _add_edge(
        src_nid: Optional[str],
        dst_nid: Optional[str],
        edge_kind: str,
        label: str,
        detail: str,
        color_hex: str,
        dashed: bool = False,
    ) -> None:
        if not src_nid or not dst_nid or src_nid == dst_nid:
            return
        pair_key = (src_nid, dst_nid, edge_kind, label)
        if pair_key in seen_edges:
            return
        seen_edges.add(pair_key)
        edges_out.append(
            {
                "id": f"E_{len(edges_out) + 1}",
                "source_id": src_nid,
                "target_id": dst_nid,
                "edge_kind": edge_kind,
                "label": label[:40],
                "detail": detail[:120],
                "color_hex": color_hex,
                "dashed": dashed,
            }
        )

    # A) Cableado estructurado físico (`Connection`)
    for cab in (base_snap.get("cabling_sample") or []):
        s_nid = node_id_by_code.get(str(cab.get("source_device") or ""))
        t_nid = node_id_by_code.get(str(cab.get("target_device") or ""))
        ctype = str(cab.get("cable_type") or "utp_cat6")
        is_fiber = "fiber" in ctype
        is_power = "power" in ctype
        col = "#D97706" if is_power else ("#0284C7" if is_fiber else "#2563EB")
        lbl = f"{cab.get('source_port') or ''}⇄{cab.get('target_port') or ''}"
        _add_edge(
            s_nid,
            t_nid,
            "physical_cabling",
            lbl,
            f"Cable físico {ctype}",
            col,
            dashed=False,
        )

    # B) Relación Hipervisor Físico -> VM Huésped
    rack_dev_code_by_id = {
        d.id: d.code for d in db.query(RackDevice).all()
    }
    for a_sum in (base_snap.get("assets") or []):
        orm_a = all_db_assets.get(int(a_sum["id"]))
        if not orm_a:
            continue
        vm_nid = node_id_by_code.get(orm_a.code)
        if orm_a.host_rack_device_id and orm_a.host_rack_device_id in rack_dev_code_by_id:
            hyp_code = rack_dev_code_by_id[orm_a.host_rack_device_id]
            # Buscar primero si el hipervisor tiene CI propio o nodo RD_
            hyp_nid = node_id_by_code.get(hyp_code)
            if not hyp_nid:
                for cand_a in all_db_assets.values():
                    if cand_a.rack_device_id == orm_a.host_rack_device_id:
                        hyp_nid = node_id_by_code.get(cand_a.code)
                        break
            _add_edge(
                hyp_nid,
                vm_nid,
                "hosting_parent",
                "Host VM",
                f"Alojada en hipervisor {hyp_code}",
                "#4F46E5",
                dashed=False,
            )

    # C) Enlaces Lógicos Confirmados (`LogicalTopologyLink`)
    for lk in db.query(LogicalTopologyLink).all():
        s_a = all_db_assets.get(lk.source_asset_id)
        t_a = all_db_assets.get(lk.target_asset_id)
        if s_a and t_a:
            _add_edge(
                node_id_by_code.get(s_a.code),
                node_id_by_code.get(t_a.code),
                "logical_confirmed",
                str(lk.protocol_label or lk.link_type),
                f"Enlace lógico ({lk.link_type})",
                "#16A34A",
                dashed=False,
            )

    # D) Enlaces Descubiertos Pasivamente en Fase 2 (`inferred_dependencies` RO: TCP sockets & LLDP)
    for rs in ro_rows:
        for dep in (rs.inferred_dependencies or []):
            s_code = str(dep.get("source_code") or "")
            t_code = str(dep.get("target_code") or "")
            _add_edge(
                node_id_by_code.get(s_code),
                node_id_by_code.get(t_code),
                "passive_ro_discovered",
                f"RO {dep.get('protocol_label') or 'TCP'}",
                f"Descubierto pasivamente ({rs.collector_type})",
                "#06B6D4",
                dashed=True,
            )

    return sanitize_context_payload(
        {
            "scope_type": scope_type,
            "scope_target_id": scope_target_id,
            "title": f"Esquema Analítico de Red — {base_snap['scope_label']}",
            "subtitle": "Topología en 5 capas fusionando Cableado Rack, CMDB, Riesgos SPOF y Descubrimiento Pasivo RO",
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
                "edges_passive_ro": sum(1 for e in edges_out if e["edge_kind"] == "passive_ro_discovered"),
                "nodes_with_risks": sum(1 for n in nodes_out if n.get("risk_badges")),
            },
            "finops_findings": finops_findings,
        }
    )


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
    """
    Convierte el esquema de red analizado por el Agente IA en un `TechStackDiagram`
    editable dentro de `4. Red & Host`, creando sus zonas (`canvas_boxes`), nodos CMDB
    y flechas de flujo.
    """
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
        description=f"Generado a partir del análisis solo-lectura de RackDoc AI por {published_by}.",
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
