"""
Generador del libro Excel de demostración:
`Demo_3_Racks_22_Switches_Red_23.xlsx`

Escenario:
- Sede de demostración `DEMO-SW` ("CPD Demo Campus Switching (/23)")
- 3 Racks de 42U (`RK-DEMO-01`, `RK-DEMO-02`, `RK-DEMO-03`)
- 2 Switches Core/Agregación de 48 puertos (`SW48-CORE-01`, `SW48-CORE-02`)
- 20 Switches de Acceso de 24 puertos (`SW24-ACC-01` .. `SW24-ACC-20`)
- 59 conexiones físicas (Trunk HA LACP Core, 40 Uplinks Dual-Homed Intra/Inter-Rack
  y 17 cascadas SFP+ locales Intra-Rack)
- Rango IP único `10.200.0.0/23` (máscara `255.255.254.0`, gateway `10.200.0.1`,
  repartiendo switches tanto en `10.200.0.x` como en `10.200.1.x`).
"""

from pathlib import Path
from openpyxl import Workbook
from openpyxl.styles import Alignment, Border, Font, PatternFill, Side
from openpyxl.utils import get_column_letter


OUTPUT_XLSX = Path(__file__).resolve().parent / "Demo_3_Racks_22_Switches_Red_23.xlsx"


def _style_sheet(ws) -> None:
    """Aplica cabeceras corporativas oscuras, bordes finos y autoajuste de columnas."""
    header_fill = PatternFill(start_color="0F172A", end_color="0F172A", fill_type="solid")
    zebra_fill = PatternFill(start_color="F8FAFC", end_color="F8FAFC", fill_type="solid")
    header_font = Font(name="Calibri", size=11, bold=True, color="FFFFFF")
    cell_font = Font(name="Calibri", size=10, color="0F172A")
    thin = Side(border_style="thin", color="CBD5E1")
    border = Border(left=thin, right=thin, top=thin, bottom=thin)

    ws.freeze_panes = "A2"
    for row_idx, row in enumerate(ws.iter_rows(), start=1):
        for cell in row:
            cell.border = border
            if row_idx == 1:
                cell.fill = header_fill
                cell.font = header_font
                cell.alignment = Alignment(horizontal="center", vertical="center")
            else:
                if row_idx % 2 == 0:
                    cell.fill = zebra_fill
                cell.font = cell_font
                cell.alignment = Alignment(vertical="center")
        ws.row_dimensions[row_idx].height = 24 if row_idx == 1 else 20

    for col_idx, col_cells in enumerate(ws.columns, start=1):
        max_len = max((len(str(c.value or "")) for c in col_cells), default=12)
        ws.column_dimensions[get_column_letter(col_idx)].width = min(48, max(14, max_len + 4))


def build_demo_workbook() -> Path:
    """Construye y guarda el archivo Excel `.xlsx` de demostración en `examples/`."""
    wb = Workbook()

    # =========================================================================
    # HOJA 1: 1_Racks_y_Sedes (3 Racks de 42U)
    # =========================================================================
    ws_racks = wb.active
    ws_racks.title = "1_Racks_y_Sedes"
    ws_racks.append([
        "Sede (Código)",
        "Sede (Nombre)",
        "Planta",
        "Sala",
        "Pasillo",
        "Código Rack",
        "Nombre Rack",
        "U Totales",
        "Fabricante",
        "Modelo",
        "Responsable",
        "Notas",
    ])

    racks_rows = [
        (
            "DEMO-SW",
            "CPD Demo Campus Switching (/23)",
            "Planta 1 - Telecomunicaciones",
            "Sala MDF / IDF Campus",
            "Fila A - Conmutación",
            "RK-DEMO-01",
            "Rack 01 - Cabecera Core 48p HA & Acceso A",
            42,
            "Rittal",
            "VX IT 42U",
            "Equipo Redes SRE",
            "Aloja pareja HA Core/Agregación de 48p (SW48-CORE-01/02) + 6 switches de acceso 24p",
        ),
        (
            "DEMO-SW",
            "CPD Demo Campus Switching (/23)",
            "Planta 1 - Telecomunicaciones",
            "Sala MDF / IDF Campus",
            "Fila A - Conmutación",
            "RK-DEMO-02",
            "Rack 02 - Distribución Acceso Bloque B",
            42,
            "Rittal",
            "VX IT 42U",
            "Equipo Redes SRE",
            "Aloja 7 switches de acceso 24p (SW24-ACC-07..13) con doble uplink a RK-DEMO-01",
        ),
        (
            "DEMO-SW",
            "CPD Demo Campus Switching (/23)",
            "Planta 1 - Telecomunicaciones",
            "Sala MDF / IDF Campus",
            "Fila A - Conmutación",
            "RK-DEMO-03",
            "Rack 03 - Distribución Acceso Bloque C",
            42,
            "Schneider APC",
            "NetShelter SX 42U",
            "Equipo Redes SRE",
            "Aloja 7 switches de acceso 24p (SW24-ACC-14..20, mitad alta 10.200.1.x del /23)",
        ),
    ]
    for r in racks_rows:
        ws_racks.append(list(r))
    _style_sheet(ws_racks)

    # =========================================================================
    # HOJA 2: 2_Equipos_y_Hosts (2 Switches 48p + 20 Switches 24p en 10.200.0.0/23)
    # =========================================================================
    ws_devs = wb.create_sheet(title="2_Equipos_y_Hosts")
    ws_devs.append([
        "Código Rack",
        "Unidad U Inicial",
        "Altura (U)",
        "Cara Montaje",
        "Código Equipo",
        "Nombre Dispositivo",
        "Librería",
        "Fabricante",
        "Modelo",
        "Hostname",
        "FQDN",
        "Dirección IP",
        "Máscara de Subred",
        "Gateway",
        "VLAN Gestión",
        "Heartbeat Activo",
        "Método Heartbeat",
        "Puerto Heartbeat",
        "URL Extra Heartbeat",
        "Usuario SSH",
        "Nº Serie",
        "Notas",
    ])

    model_48p = "Catalyst 9300-48P PoE+ (48x RJ45 + 4x SFP+)"
    model_24p = "Catalyst 9300-24T + 4xSFP+"
    subnet_mask = "255.255.254.0"  # /23 (10.200.0.0 - 10.200.1.255)
    gateway = "10.200.0.1"
    vlan_mgmt = 200

    devs_rows = [
        # 2 Switches Core/Agregación de 48 puertos en RK-DEMO-01
        (
            "RK-DEMO-01",
            40,
            1,
            "FRONT",
            "SW48-CORE-01",
            "Switch Core/Agregación 48p Activo A",
            "Network",
            "Cisco",
            model_48p,
            "sw48-core-01",
            "sw48-core-01.demo.rackdoc.local",
            "10.200.0.11",
            subnet_mask,
            gateway,
            vlan_mgmt,
            "NO",
            "ssh",
            22,
            "",
            "netadmin",
            "FCW2648C001",
            "Core HA Primario 48p — Recibe uplinks primarios SFP1 de los 20 switches 24p",
        ),
        (
            "RK-DEMO-01",
            38,
            1,
            "FRONT",
            "SW48-CORE-02",
            "Switch Core/Agregación 48p Activo B",
            "Network",
            "Cisco",
            model_48p,
            "sw48-core-02",
            "sw48-core-02.demo.rackdoc.local",
            "10.200.0.12",
            subnet_mask,
            gateway,
            vlan_mgmt,
            "NO",
            "ssh",
            22,
            "",
            "netadmin",
            "FCW2648C002",
            "Core HA Secundario 48p — Recibe uplinks redundantes SFP2 de los 20 switches 24p",
        ),
    ]

    # 20 Switches de Acceso de 24 puertos repartidos en los 3 Racks
    # RK-DEMO-01: SW24-ACC-01..06 (U34, 32, 30, 28, 26, 24) -> 10.200.0.21..26
    # RK-DEMO-02: SW24-ACC-07..13 (U38, 35, 32, 29, 26, 23, 20) -> 10.200.0.27..33
    # RK-DEMO-03: SW24-ACC-14..20 (U38, 35, 32, 29, 26, 23, 20) -> 10.200.1.14..20 (mitad alta del /23)
    for idx in range(1, 21):
        code = f"SW24-ACC-{idx:02d}"
        hostname = code.lower()
        fqdn = f"{hostname}.demo.rackdoc.local"
        serial = f"FCW2624A{idx:03d}"

        if idx <= 6:
            rack_code = "RK-DEMO-01"
            start_u = 34 - (idx - 1) * 2
            ip_addr = f"10.200.0.{20 + idx}"
            bloque = "Bloque A (Cabecera)"
        elif idx <= 13:
            rack_code = "RK-DEMO-02"
            start_u = 38 - (idx - 7) * 3
            ip_addr = f"10.200.0.{20 + idx}"
            bloque = "Bloque B (Planta Norte)"
        else:
            rack_code = "RK-DEMO-03"
            start_u = 38 - (idx - 14) * 3
            ip_addr = f"10.200.1.{idx}"
            bloque = "Bloque C (Planta Sur - segundo /24 dentro del /23)"

        devs_rows.append(
            (
                rack_code,
                start_u,
                1,
                "FRONT",
                code,
                f"Switch Acceso 24p #{idx:02d} — {bloque.split(' (')[0]}",
                "Network",
                "Cisco",
                model_24p,
                hostname,
                fqdn,
                ip_addr,
                subnet_mask,
                gateway,
                vlan_mgmt,
                "NO",
                "ssh",
                22,
                "",
                "netadmin",
                serial,
                f"Switch 24p {bloque} con doble uplink a SW48-CORE-01/02 ({ip_addr}/23)",
            )
        )

    for d in devs_rows:
        ws_devs.append(list(d))
    _style_sheet(ws_devs)

    # =========================================================================
    # HOJA 3: 3_Conexiones_y_Fibras (59 conexiones físicas sin colisión de bocas)
    # =========================================================================
    ws_conns = wb.create_sheet(title="3_Conexiones_y_Fibras")
    ws_conns.append([
        "Rack Origen",
        "Equipo Origen",
        "Boca Origen",
        "Rack Destino",
        "Equipo Destino",
        "Boca Destino",
        "Tipo de Cable",
        "Color Hex",
        "Etiqueta / Circuito",
        "VLAN",
        "Longitud (m)",
    ])

    conns_rows = [
        # 1) LACP Stack / Trunk 10G entre los dos Switches Core de 48p
        (
            "RK-DEMO-01",
            "SW48-CORE-01",
            "SFP1",
            "RK-DEMO-01",
            "SW48-CORE-02",
            "SFP1",
            "fiber_om4",
            "#7C3AED",
            "LACP Po1 Miembro 1 (10GbE Core HA)",
            200,
            1.0,
        ),
        (
            "RK-DEMO-01",
            "SW48-CORE-01",
            "SFP2",
            "RK-DEMO-01",
            "SW48-CORE-02",
            "SFP2",
            "fiber_om4",
            "#7C3AED",
            "LACP Po1 Miembro 2 (10GbE Core HA)",
            200,
            1.0,
        ),
    ]

    # 2) 40 Uplinks Dual-Homed (cada uno de los 20 switches 24p conecta SFP1 -> CORE-01:idx y SFP2 -> CORE-02:idx)
    for idx in range(1, 21):
        sw_code = f"SW24-ACC-{idx:02d}"
        if idx <= 6:
            src_rack = "RK-DEMO-01"
            cable_t = "utp_cat6a"
            dist_m = 2.0
        elif idx <= 13:
            src_rack = "RK-DEMO-02"
            cable_t = "fiber_om4"
            dist_m = 8.0
        else:
            src_rack = "RK-DEMO-03"
            cable_t = "fiber_os2"
            dist_m = 14.0

        # Uplink primario hacia SW48-CORE-01 boca `idx`
        conns_rows.append(
            (
                src_rack,
                sw_code,
                "SFP1",
                "RK-DEMO-01",
                "SW48-CORE-01",
                str(idx),
                cable_t,
                "#0284C7",
                f"Uplink A {sw_code}:SFP1 -> SW48-CORE-01:{idx}",
                200,
                dist_m,
            )
        )
        # Uplink secundario redundante hacia SW48-CORE-02 boca `idx`
        conns_rows.append(
            (
                src_rack,
                sw_code,
                "SFP2",
                "RK-DEMO-01",
                "SW48-CORE-02",
                str(idx),
                cable_t,
                "#10B981",
                f"Uplink B {sw_code}:SFP2 -> SW48-CORE-02:{idx}",
                200,
                dist_m,
            )
        )

    # 3) Cascada Óptica Local Intra-Rack (SFP3 -> SFP4) dentro de cada Rack
    rack_groups = [
        ("RK-DEMO-01", range(1, 7)),
        ("RK-DEMO-02", range(7, 14)),
        ("RK-DEMO-03", range(14, 21)),
    ]
    for rk_code, sw_indices in rack_groups:
        idx_list = list(sw_indices)
        for a, b in zip(idx_list[:-1], idx_list[1:]):
            sw_a = f"SW24-ACC-{a:02d}"
            sw_b = f"SW24-ACC-{b:02d}"
            conns_rows.append(
                (
                    rk_code,
                    sw_a,
                    "SFP3",
                    rk_code,
                    sw_b,
                    "SFP4",
                    "fiber_om4",
                    "#F59E0B",
                    f"Cascada SFP+ Local {sw_a}:SFP3 -> {sw_b}:SFP4",
                    200,
                    0.5,
                )
            )

    for c in conns_rows:
        ws_conns.append(list(c))
    _style_sheet(ws_conns)

    # =========================================================================
    # HOJA 4: 4_Subredes_IPAM (Rango /23 = 510 IPs útiles)
    # =========================================================================
    ws_sub = wb.create_sheet(title="4_Subredes_IPAM")
    ws_sub.append([
        "CIDR",
        "Nombre Subred",
        "VLAN",
        "Gateway",
        "Máscara",
        "DNS",
        "Entorno",
        "Sede (Código)",
        "Notas",
    ])
    ws_sub.append([
        "10.200.0.0/23",
        "VLAN 200 - Gestión Campus Switching (/23 — 510 hosts)",
        200,
        "10.200.0.1",
        "255.255.254.0",
        "10.200.0.2, 1.1.1.1",
        "production",
        "DEMO-SW",
        "Superred /23 demostrativa (10.200.0.1 a 10.200.1.254) para los 3 Racks y 22 Switches.",
    ])
    _style_sheet(ws_sub)

    OUTPUT_XLSX.parent.mkdir(parents=True, exist_ok=True)
    wb.save(OUTPUT_XLSX)
    return OUTPUT_XLSX


if __name__ == "__main__":
    path = build_demo_workbook()
    print(f"Excel generado en: {path} ({path.stat().st_size} bytes)")
