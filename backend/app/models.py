"""
Modelos ORM SQLAlchemy 2.0 de RackDoc DCIM (31 tablas relacionales).

Cubre autenticación/AD, jerarquía geográfica (Location -> Floor -> Room -> Aisle -> Rack),
catálogo hardware, cableado punto a punto, CMDB Multi-IP, Stacks 2D, Nagios/SNMP, Alarmas SRE y CertScope.
"""

from sqlalchemy import (
    Column,
    Integer,
    String,
    Float,
    Boolean,
    ForeignKey,
    DateTime,
    JSON,
    Text,
)
from sqlalchemy.orm import relationship
from .database import Base
from .time_utils import utcnow


class ADServer(Base):
    """Configuración de controlador de dominio Active Directory / LDAP para bind y búsqueda."""
    __tablename__ = "ad_servers"

    id = Column(Integer, primary_key=True, index=True)
    name = Column(String(120), nullable=False)  # Ej: "AD Corporativo Central", "AD EMEA"
    ldap_url = Column(String(255), nullable=False)  # Ej: "ldap://dc01.corp.local:389"
    domain = Column(String(120), default="")  # Ej: "corp.local"
    base_dn = Column(String(255), default="")  # Ej: "DC=corp,DC=local"
    bind_dn = Column(String(255), default="")  # Ej: "CN=svc_rackdoc,OU=Users,DC=corp,DC=local"
    bind_password = Column(String(255), default="")
    user_filter = Column(String(255), default="(&(objectClass=user)(sAMAccountName={username}))")
    default_role = Column(String(30), default="viewer")  # admin | editor | operator | viewer
    group_role_mapping = Column(JSON, default=list)  # Lista de {"group_name": str, "group_dn": str, "role": str}
    enabled = Column(Boolean, default=True)
    created_at = Column(DateTime, default=utcnow)

    users = relationship("User", back_populates="ad_server")


class User(Base):
    """Cuenta de usuario de RackDoc (local bcrypt o aprovisionada vía Active Directory) con rol RBAC."""
    __tablename__ = "users"

    id = Column(Integer, primary_key=True, index=True)
    username = Column(String(80), unique=True, index=True, nullable=False, default="admin")
    email = Column(String(120), index=True, nullable=False, default="")
    full_name = Column(String(120), nullable=False, default="")
    password_hash = Column(String(255), nullable=False, default="")
    # Roles permitidos:
    # - 'admin': Control total (Usuarios, AD, Editar todo, SSH/Web/Ping)
    # - 'editor': Editar todo (Locations, Plantas, Racks, Equipos, Cables) + SSH/Web/Ping
    # - 'operator': Solo Ver + Interactuar/Conectarse (SSH, Telnet, Web UI, Ping)
    # - 'viewer': Solo Ver estricto (sin edición ni lanzamiento de conexiones remotas)
    role = Column(String(30), default="viewer", nullable=False)
    auth_source = Column(String(30), default="local")  # 'local' | 'ad'
    ad_server_id = Column(Integer, ForeignKey("ad_servers.id", ondelete="SET NULL"), nullable=True)
    ad_dn = Column(String(255), default="")
    is_active = Column(Boolean, default=True)
    created_at = Column(DateTime, default=utcnow)

    ad_server = relationship("ADServer", back_populates="users")


class Location(Base):
    """Sede geográfica o centro de datos (CPD) posicionable sobre OpenStreetMap o plano."""
    __tablename__ = "locations"

    id = Column(Integer, primary_key=True, index=True)
    code = Column(String(32), unique=True, index=True, nullable=False)
    name = Column(String(120), nullable=False)
    latitude = Column(Float, default=40.4168)
    longitude = Column(Float, default=-3.7038)
    address = Column(String(255), default="")
    description = Column(Text, default="")
    map_image_url = Column(String(500), default="")
    plan_pos_x = Column(Float, default=0.30)
    plan_pos_y = Column(Float, default=0.40)
    plan_width = Column(Float, default=140.0)
    plan_height = Column(Float, default=80.0)
    map_scale = Column(Float, default=1.0)

    floors = relationship("Floor", back_populates="location", cascade="all, delete-orphan")


class Floor(Base):
    """Planta arquitectónica de una sede con plano 2D opcional y escala."""
    __tablename__ = "floors"

    id = Column(Integer, primary_key=True, index=True)
    location_id = Column(Integer, ForeignKey("locations.id", ondelete="CASCADE"), nullable=False)
    name = Column(String(100), nullable=False)
    level_number = Column(Integer, default=0)
    map_image_url = Column(String(500), default="")
    map_scale = Column(Float, default=1.0)

    location = relationship("Location", back_populates="floors")
    rooms = relationship("Room", back_populates="floor", cascade="all, delete-orphan")
    floor_devices = relationship("FloorDevice", back_populates="floor", cascade="all, delete-orphan")


class Room(Base):
    """Sala técnica o cuarto de comunicaciones dentro de una planta."""
    __tablename__ = "rooms"

    id = Column(Integer, primary_key=True, index=True)
    floor_id = Column(Integer, ForeignKey("floors.id", ondelete="CASCADE"), nullable=False)
    name = Column(String(100), nullable=False)
    width_m = Column(Float, default=12.0)
    depth_m = Column(Float, default=8.0)
    notes = Column(Text, default="")
    map_image_url = Column(String(500), default="")

    floor = relationship("Floor", back_populates="rooms")
    aisles = relationship("Aisle", back_populates="room", cascade="all, delete-orphan")
    racks = relationship("Rack", back_populates="room", cascade="all, delete-orphan")


class Aisle(Base):
    """Pasillo frío, caliente o estándar que agrupa armarios Rack dentro de una sala."""
    __tablename__ = "aisles"

    id = Column(Integer, primary_key=True, index=True)
    room_id = Column(Integer, ForeignKey("rooms.id", ondelete="CASCADE"), nullable=False)
    code = Column(String(32), nullable=False)
    name = Column(String(100), nullable=False)
    aisle_type = Column(String(32), default="cold")  # cold | hot | standard

    room = relationship("Room", back_populates="aisles")
    racks = relationship("Rack", back_populates="aisle")


class Rack(Base):
    """Bastidor de 19 pulgadas (42U–48U) con coordenadas 2D en planta, rotación y metadatos."""
    __tablename__ = "racks"

    id = Column(Integer, primary_key=True, index=True)
    room_id = Column(Integer, ForeignKey("rooms.id", ondelete="CASCADE"), nullable=False)
    aisle_id = Column(Integer, ForeignKey("aisles.id", ondelete="SET NULL"), nullable=True)
    code = Column(String(50), index=True, nullable=False)
    name = Column(String(120), nullable=False)
    total_units = Column(Integer, default=42)
    manufacturer = Column(String(100), default="Rittal")
    model_name = Column(String(100), default="TS IT 42U 800x1000")
    serial_number = Column(String(100), default="")
    responsible_person = Column(String(120), default="Alex Geng")
    purchase_date = Column(String(30), default="2026-04-01")
    operation_start = Column(String(30), default="2026-05-01")
    pos_x = Column(Float, default=0.25)
    pos_y = Column(Float, default=0.35)
    width_px = Column(Float, default=96.0)
    depth_px = Column(Float, default=116.0)
    rotation_deg = Column(Integer, default=0)
    notes = Column(Text, default="")

    room = relationship("Room", back_populates="racks")
    aisle = relationship("Aisle", back_populates="racks")
    devices = relationship("RackDevice", back_populates="rack", cascade="all, delete-orphan")


class DeviceTemplate(Base):
    """Plantilla de catálogo hardware con altura en U, profundidad y geometría de puertos Front/Back."""
    __tablename__ = "device_templates"

    id = Column(Integer, primary_key=True, index=True)
    library_group = Column(String(80), index=True, default="Network", nullable=False)
    # Grupos de librería: Network | Power | Host - HP | Host - Dell | Patching & Passive | (o cualquier grupo creado/importado)
    category = Column(String(50), index=True, nullable=False)
    # Categorías: cable_manager | firewall | gateway | miscellaneous | patch_panel | patchbox | rack_tray | rack_tray_device | router | server | switch | ups | pdu | schuko | external_power_feed
    manufacturer = Column(String(100), default="Generic")
    model_name = Column(String(120), nullable=False)
    u_height = Column(Integer, default=1)
    is_full_depth = Column(Boolean, default=False)
    default_color = Column(String(20), default="#F8FAFC")
    layout_spec = Column(JSON, default=dict)
    # layout_spec define los bloques de puertos por cara ('front' y 'back')

    instances = relationship("RackDevice", back_populates="template")


class RackDevice(Base):
    """Equipo físico o toma exterior montado en un Rack con su red, estado Heartbeat y campos extra."""
    __tablename__ = "rack_devices"

    id = Column(Integer, primary_key=True, index=True)
    rack_id = Column(Integer, ForeignKey("racks.id", ondelete="CASCADE"), nullable=False)
    template_id = Column(Integer, ForeignKey("device_templates.id"), nullable=False)

    code = Column(String(40), nullable=False)  # Ej: SW01, PBX01, SRV01
    name = Column(String(120), nullable=False)
    hostname = Column(String(120), default="")
    fqdn = Column(String(255), default="")

    start_u = Column(Integer, nullable=False)  # Unidad U inferior (1..42)
    mounted_face = Column(String(16), default="front")  # front | back

    # Configuración de Red y Gestión
    ip_address = Column(String(64), default="")
    subnet_mask = Column(String(64), default="255.255.255.0")
    gateway = Column(String(64), default="")
    mac_address = Column(String(64), default="")
    vlan_mgmt = Column(Integer, nullable=True)
    management_links = Column(JSON, default=list)
    # Ej: [{"protocol": "ssh", "port": 22, "username": "admin"}, {"protocol": "https", "port": 443, "label": "Web UI"}]

    # Monitorización (Ping / TCP Check)
    monitoring_enabled = Column(Boolean, default=False)
    monitor_method = Column(String(32), default="icmp")  # icmp | tcp
    monitor_port = Column(Integer, default=22)
    status = Column(String(32), default="unmonitored")  # online | offline | warning | unmonitored
    last_ping_ms = Column(Float, nullable=True)
    last_checked_at = Column(DateTime, nullable=True)

    # Inventario y Variables Dinámicas
    serial_number = Column(String(100), default="")
    custom_fields = Column(JSON, default=dict)
    notes = Column(Text, default="")

    rack = relationship("Rack", back_populates="devices")
    template = relationship("DeviceTemplate", back_populates="instances")
    ports = relationship("Port", back_populates="device", cascade="all, delete-orphan")


class Port(Base):
    """Boca física (RJ45, SFP+, fibra LC/SC o toma eléctrica) perteneciente a un equipo enracado."""
    __tablename__ = "ports"

    id = Column(Integer, primary_key=True, index=True)
    rack_device_id = Column(Integer, ForeignKey("rack_devices.id", ondelete="CASCADE"), nullable=False)
    port_number = Column(String(32), nullable=False)  # Ej: "1", "24", "SFP1", "PSU1"
    label = Column(String(64), default="")
    face = Column(String(16), default="front")  # front | back
    port_type = Column(String(32), default="rj45")
    # rj45 | fiber_lc | fiber_sc | sfp_plus | power_c13 | power_c14 | power_schuko | passthrough
    row_index = Column(Integer, default=0)
    col_index = Column(Integer, default=0)
    rel_x = Column(Float, default=0.5)
    rel_y = Column(Float, default=0.5)
    mac_or_ip = Column(String(64), default="")
    vlan = Column(Integer, nullable=True)

    device = relationship("RackDevice", back_populates="ports")


class Connection(Base):
    """Latiguillo o acometida punto a punto entre dos puertos físicos (intra-rack o inter-rack)."""
    __tablename__ = "connections"

    id = Column(Integer, primary_key=True, index=True)
    source_port_id = Column(Integer, ForeignKey("ports.id", ondelete="CASCADE"), nullable=False)
    target_port_id = Column(Integer, ForeignKey("ports.id", ondelete="CASCADE"), nullable=False)

    cable_type = Column(String(32), default="utp_cat6")
    # utp_cat6 | utp_cat6a | fiber_om4 | fiber_os2 | power_ac
    color_hex = Column(String(20), default="#2563EB")
    routing_channel = Column(String(16), default="auto")  # left | right | auto
    label = Column(String(120), default="")
    vlan = Column(Integer, nullable=True)
    length_m = Column(Float, default=1.5)
    notes = Column(Text, default="")

    source_port = relationship("Port", foreign_keys=[source_port_id])
    target_port = relationship("Port", foreign_keys=[target_port_id])


class FloorDevice(Base):
    """Dispositivo o sensor situado en el plano 2D de planta (cámara, AP Wi-Fi, SAI, roseta, sonda)."""
    __tablename__ = "floor_devices"

    id = Column(Integer, primary_key=True, index=True)
    floor_id = Column(Integer, ForeignKey("floors.id", ondelete="CASCADE"), nullable=False, index=True)
    room_id = Column(Integer, ForeignKey("rooms.id", ondelete="SET NULL"), nullable=True)
    room_code = Column(String(64), default="SALA-01")
    device_type = Column(String(40), nullable=False, index=True)
    # 3d_printer | access_control | access_point | camera | desktop | isp_uplink |
    # laptop | microphone | ndi_box | phone | printer | screen | speaker | telecom_outlet
    code = Column(String(50), nullable=False)
    name = Column(String(120), nullable=False)
    pos_x = Column(Float, default=0.50)
    pos_y = Column(Float, default=0.50)
    fqdn = Column(String(255), default="")
    ip_address = Column(String(64), default="")
    mac_address = Column(String(64), default="")
    vlan = Column(Integer, nullable=True)
    monitoring_enabled = Column(Boolean, default=False)
    monitor_method = Column(String(32), default="icmp")
    monitor_port = Column(Integer, default=22)
    status = Column(String(32), default="unmonitored")  # online | offline | warning | unmonitored
    last_ping_ms = Column(Float, nullable=True)
    last_checked_at = Column(DateTime, nullable=True)
    custom_fields = Column(JSON, default=dict)

    # Enlaces en el plano de planta (Rack -> Roseta/AP/CAM y Roseta -> Equipo final)
    linked_rack_id = Column(Integer, ForeignKey("racks.id", ondelete="SET NULL"), nullable=True)
    linked_rack_device_code = Column(String(80), default="")
    linked_outlet_id = Column(Integer, ForeignKey("floor_devices.id", ondelete="SET NULL"), nullable=True)

    # Persona responsable y de contacto (Settings Panel de Planta)
    responsible_person = Column(String(120), default="Alex Geng")
    contact_first_name = Column(String(80), default="")
    contact_last_name = Column(String(80), default="")
    contact_email = Column(String(120), default="")
    contact_phone = Column(String(60), default="")
    contact_job_title = Column(String(80), default="")
    contact_department = Column(String(80), default="")
    notes = Column(Text, default="")

    floor = relationship("Floor", back_populates="floor_devices")


class FloorDeviceCustomType(Base):
    """Tipo personalizado de dispositivo de planta definido por el usuario."""
    __tablename__ = "floor_device_custom_types"

    id = Column(Integer, primary_key=True, index=True)
    category_key = Column(String(64), unique=True, nullable=False, index=True)
    group_name = Column(String(80), default="Industrial / A Medida")
    label = Column(String(120), nullable=False)
    prefix = Column(String(24), default="DEV")
    icon_key = Column(String(50), default="memory")
    pin_color_hex = Column(String(20), default="#7C3AED")
    default_port_hint = Column(String(100), default="SW01:Gi1/0/1")
    is_sensor = Column(Boolean, default=False)


class CmdbSubnet(Base):
    """Subred CIDR / VLAN registrada en el módulo IPAM de la CMDB y vinculable a una sede."""
    __tablename__ = "cmdb_subnets"

    id = Column(Integer, primary_key=True, index=True)
    cidr = Column(String(64), unique=True, index=True, nullable=False)  # Ej: "10.20.1.0/24"
    name = Column(String(120), nullable=False)  # Ej: "VLAN 10 - Gestión & Heartbeat CPD"
    vlan_id = Column(Integer, nullable=True)
    gateway = Column(String(64), default="")
    subnet_mask = Column(String(64), default="255.255.255.0")
    dns_servers = Column(String(255), default="")
    environment = Column(String(40), default="production")  # production | preprod | dev | mgmt | dmz | storage | cloud
    location_id = Column(Integer, ForeignKey("locations.id", ondelete="SET NULL"), nullable=True)
    notes = Column(Text, default="")
    created_at = Column(DateTime, default=utcnow)

    ip_addresses = relationship("CmdbIpAddress", back_populates="subnet")


class CmdbAsset(Base):
    """Elemento de configuración (CI) maestro en la CMDB (físico, VM, contenedor, VIP o servicio cloud)."""
    __tablename__ = "cmdb_assets"

    id = Column(Integer, primary_key=True, index=True)
    code = Column(String(64), unique=True, index=True, nullable=False)  # Ej: VM-ERP-01, CLU-DB-01, CI-SRV01
    name = Column(String(160), nullable=False)
    hostname = Column(String(120), default="")
    fqdn = Column(String(255), default="")

    # Clasificación CMDB (físicos, virtuales, contenedores, clusters, cloud, otros)
    asset_class = Column(String(50), index=True, default="virtual_machine", nullable=False)
    # virtual_machine | container_lxc | physical_server | cluster_vip | virtual_appliance |
    # cloud_instance | network_security | storage_san_nas | floor_endpoint | other_machine
    environment = Column(String(40), default="production")  # production | preprod | dev | mgmt | dr
    criticality = Column(String(32), default="high")  # critical | high | medium | low
    lifecycle_status = Column(String(40), default="active")  # active | maintenance | planned | decommissioned

    # Especificaciones técnicas de la máquina (física o virtual)
    os_or_firmware = Column(String(120), default="")
    cpu_cores = Column(Integer, default=0)
    ram_gb = Column(Float, default=0.0)
    storage_gb = Column(Float, default=0.0)
    hypervisor_or_platform = Column(String(120), default="")  # Ej: VMware vSphere 8, Proxmox VE, Baremetal, AWS, K8s
    serial_or_uuid = Column(String(120), default="")

    # Propiedad y Gobierno
    owner_team = Column(String(120), default="Sistemas & Infraestructura")
    responsible_person = Column(String(120), default="Alex Geng")

    # Origen y Relaciones con Racks, Plantas e Hipervisores Padres
    sync_source = Column(String(32), default="cmdb")  # cmdb | rack_device | floor_device
    rack_device_id = Column(Integer, ForeignKey("rack_devices.id", ondelete="SET NULL"), nullable=True, index=True)
    floor_device_id = Column(Integer, ForeignKey("floor_devices.id", ondelete="SET NULL"), nullable=True, index=True)
    host_rack_device_id = Column(Integer, ForeignKey("rack_devices.id", ondelete="SET NULL"), nullable=True, index=True)
    parent_asset_id = Column(Integer, ForeignKey("cmdb_assets.id", ondelete="SET NULL"), nullable=True)

    # Monitorización (Heartbeat sobre su IP de Gestión) y Accesos Remotos
    monitoring_enabled = Column(Boolean, default=False)
    monitor_method = Column(String(32), default="icmp")  # icmp | ssh | http | https | tcp | udp | snmp
    monitor_port = Column(Integer, default=22)
    status = Column(String(32), default="unmonitored")  # online | offline | warning | unmonitored
    last_ping_ms = Column(Float, nullable=True)
    last_checked_at = Column(DateTime, nullable=True)
    management_links = Column(JSON, default=list)
    custom_fields = Column(JSON, default=dict)
    notes = Column(Text, default="")
    created_at = Column(DateTime, default=utcnow)
    updated_at = Column(DateTime, default=utcnow)

    # Equipo de rack que hospeda este CI (por ejemplo, el host físico de una VM).
    # CmdbAsset tiene DOS claves ajenas hacia rack_devices (rack_device_id y
    # host_rack_device_id), así que 'foreign_keys' es obligatorio para que
    # SQLAlchemy sepa cuál de las dos usar.
    host_rack_device = relationship(
        "RackDevice",
        foreign_keys=[host_rack_device_id],
    )

    ip_addresses = relationship(
        "CmdbIpAddress",
        back_populates="asset",
        cascade="all, delete-orphan",
        order_by="CmdbIpAddress.id",
    )


class CmdbIpAddress(Base):
    """Dirección IP asociada a una interfaz de un activo CMDB con su rol operativo y máscara."""
    __tablename__ = "cmdb_ip_addresses"

    id = Column(Integer, primary_key=True, index=True)
    asset_id = Column(Integer, ForeignKey("cmdb_assets.id", ondelete="CASCADE"), nullable=True, index=True)
    subnet_id = Column(Integer, ForeignKey("cmdb_subnets.id", ondelete="SET NULL"), nullable=True, index=True)

    ip_address = Column(String(64), index=True, nullable=False)
    subnet_mask = Column(String(64), default="255.255.255.0")
    gateway = Column(String(64), default="")
    vlan_id = Column(Integer, nullable=True)

    # Rol de la IP dentro de la máquina:
    # mgmt_heartbeat | ilo_idrac | primary_service | secondary_service | vip_cluster |
    # storage | backup | vmotion_replication | public_wan | reserved
    ip_role = Column(String(40), default="primary_service", nullable=False)
    interface_name = Column(String(64), default="eth0")  # Ej: mgmt0, eno1, ens192, bond0.20, vip0, iDRAC
    mac_address = Column(String(64), default="")
    fqdn = Column(String(255), default="")
    is_heartbeat_ip = Column(Boolean, default=False)

    # Estado administrativo y de verificación manual contra la red real
    allocation_status = Column(String(32), default="assigned")  # assigned | reserved | dhcp | conflict | deprecated
    last_verification_status = Column(String(40), default="unverified")
    # free_confirmed | active_in_network | no_response | conflict_unregistered | unverified
    last_verified_at = Column(DateTime, nullable=True)
    last_verification_detail = Column(Text, default="")
    notes = Column(Text, default="")

    asset = relationship("CmdbAsset", back_populates="ip_addresses")
    subnet = relationship("CmdbSubnet", back_populates="ip_addresses")


# ==============================================================================
# MÓDULO 4: RED & HOST (Topología Lógica, Autodescubrimiento SNMP/LLDP,
# Conectores Hipervisores/Docker/Web/BBDD, Estados Nagios, Prometheus y Avisos)
# ==============================================================================

class HostGroup(Base):
    """Agrupación lógica de activos para monitorización y enrutamiento de avisos SRE."""
    __tablename__ = "network_host_groups"

    id = Column(Integer, primary_key=True, index=True)
    code = Column(String(64), unique=True, index=True, nullable=False)  # Ej: HG-SWITCHES-CORE, HG-PROXMOX-PROD
    name = Column(String(160), nullable=False)
    category = Column(String(48), default="infrastructure")  # network | virtualization | web_middleware | database | containers | custom
    environment = Column(String(32), default="production")
    color_hex = Column(String(16), default="#1E3A8A")
    member_asset_ids = Column(JSON, default=list)  # Lista de CmdbAsset.id pertenecientes al grupo
    description = Column(Text, default="")
    created_at = Column(DateTime, default=utcnow)


class MonitoredServiceCheck(Base):
    """Chequeo de servicio estilo Nagios Core (ICMP/TCP/UDP/SSH/HTTP/SNMP) con estados SOFT/HARD."""
    __tablename__ = "network_service_checks"

    id = Column(Integer, primary_key=True, index=True)
    asset_id = Column(Integer, ForeignKey("cmdb_assets.id", ondelete="CASCADE"), nullable=False, index=True)

    service_name = Column(String(140), nullable=False)  # Ej: "PING Heartbeat", "HTTPS Portal SSL", "Apache mod_status"
    # check_type:
    # icmp | http | https | tcp | udp | ssh | dns | snmp |
    # apache | nginx | haproxy | docker | portainer | kubernetes |
    # proxmox | vmware | hyperv | kvm |
    # postgres | mysql | mssql | redis | mongodb |
    # node_exporter | windows_exporter
    check_type = Column(String(40), default="icmp", nullable=False)
    target_ip_or_url = Column(String(255), default="")  # IP, FQDN o URL completa (ej. https://portal.hq.local/health)
    port = Column(Integer, default=0)
    expected_status_code = Column(Integer, default=200)
    expected_string = Column(String(160), default="")
    check_config = Column(JSON, default=dict)  # Comunidad SNMP, path status, credenciales API, umbrales warning/critical

    # Máquina de Estados estilo Nagios Core (OK / WARNING / CRITICAL / UNKNOWN + SOFT / HARD)
    nagios_state = Column(String(24), default="OK")  # OK | WARNING | CRITICAL | UNKNOWN | PENDING
    state_type = Column(String(16), default="HARD")  # HARD | SOFT
    current_attempt = Column(Integer, default=1)
    max_check_attempts = Column(Integer, default=3)

    latency_ms = Column(Float, nullable=True)
    ssl_days_remaining = Column(Integer, nullable=True)  # Calculado automáticamente en chequeos HTTPS
    metrics_snapshot = Column(JSON, default=dict)  # Últimas métricas recolectadas (CPU%, RAM%, req/s, bocas UP, etc.)
    status_output = Column(Text, default="")  # Salida estilo plugin Nagios
    enabled = Column(Boolean, default=True)
    is_primary_heartbeat = Column(Boolean, default=False)
    last_checked_at = Column(DateTime, nullable=True)
    last_state_change_at = Column(DateTime, default=utcnow)


class SwitchSnmpPort(Base):
    """Registro de boca de switch descubierta por SNMP (IF-MIB / LLDP-MIB)."""
    __tablename__ = "network_switch_snmp_ports"

    id = Column(Integer, primary_key=True, index=True)
    asset_id = Column(Integer, ForeignKey("cmdb_assets.id", ondelete="CASCADE"), nullable=False, index=True)
    rack_device_id = Column(Integer, ForeignKey("rack_devices.id", ondelete="SET NULL"), nullable=True, index=True)

    if_index = Column(Integer, default=1)
    if_name = Column(String(64), nullable=False)  # Ej: Gi1/0/1, Te1/1/1, eth0, Vlan20
    if_alias = Column(String(160), default="")  # Descripción SNMP configurada en la boca del switch
    if_type = Column(String(64), default="ethernetCsmacd")
    admin_status = Column(String(16), default="up")  # up | down
    oper_status = Column(String(16), default="up")  # up | down | dormant
    speed_mbps = Column(Integer, default=1000)
    mac_address = Column(String(64), default="")
    vlan_id = Column(Integer, nullable=True)
    vlan_mode = Column(String(24), default="access")  # access | trunk | routed

    in_mbps = Column(Float, default=0.0)
    out_mbps = Column(Float, default=0.0)
    in_errors = Column(Integer, default=0)
    out_errors = Column(Integer, default=0)

    # Descubrimiento de Vecinos LLDP-MIB / CDP-MIB en esta boca
    lldp_neighbor_sysname = Column(String(140), default="")
    lldp_neighbor_port = Column(String(64), default="")
    lldp_neighbor_ip = Column(String(64), default="")
    lldp_neighbor_asset_id = Column(Integer, ForeignKey("cmdb_assets.id", ondelete="SET NULL"), nullable=True)
    synced_rack_port_id = Column(Integer, ForeignKey("ports.id", ondelete="SET NULL"), nullable=True)
    last_polled_at = Column(DateTime, default=utcnow)


class LogicalTopologyLink(Base):
    """Enlace lógico documentado entre dos activos dentro del mapa de 5 capas de Red & Host."""
    __tablename__ = "network_logical_links"

    id = Column(Integer, primary_key=True, index=True)
    source_asset_id = Column(Integer, ForeignKey("cmdb_assets.id", ondelete="CASCADE"), nullable=False, index=True)
    target_asset_id = Column(Integer, ForeignKey("cmdb_assets.id", ondelete="CASCADE"), nullable=False, index=True)

    # link_type:
    # lldp_trunk | switch_uplink | hypervisor_vm | docker_host |
    # reverse_proxy_upstream | app_to_db | storage_san_nfs | ha_cluster_sync | custom_logical
    link_type = Column(String(48), default="custom_logical")
    source_interface = Column(String(64), default="")
    target_interface = Column(String(64), default="")
    protocol_label = Column(String(80), default="TCP/IP")  # Ej: "10GbE Trunk LLDP", "HTTPS Upstream :8443", "PostgreSQL :5432"
    vlan_id = Column(Integer, nullable=True)
    bandwidth_mbps = Column(Float, default=0.0)
    status = Column(String(24), default="UP")  # UP | WARNING | DOWN | MAINTENANCE
    auto_discovered = Column(Boolean, default=False)
    notes = Column(Text, default="")
    created_at = Column(DateTime, default=utcnow)


class InfraConnector(Base):
    """Conector de integración con switches SNMP, hipervisores o exporters de Prometheus."""
    __tablename__ = "network_infra_connectors"

    id = Column(Integer, primary_key=True, index=True)
    name = Column(String(160), nullable=False)
    # connector_type:
    # snmp_switch | proxmox_ve | vmware_vsphere | hyperv | kvm_libvirt | xcpng |
    # docker_engine | portainer | kubernetes |
    # apache_status | nginx_status | haproxy_stats |
    # postgresql | mysql_mariadb | mssql | redis | mongodb |
    # node_exporter | windows_exporter
    connector_type = Column(String(48), nullable=False)
    endpoint_host = Column(String(255), nullable=False)
    endpoint_port = Column(Integer, default=161)
    auth_username_or_community = Column(String(160), default="public")
    auth_secret = Column(String(255), default="")
    linked_asset_id = Column(Integer, ForeignKey("cmdb_assets.id", ondelete="SET NULL"), nullable=True)
    linked_rack_device_id = Column(Integer, ForeignKey("rack_devices.id", ondelete="SET NULL"), nullable=True)
    extra_settings = Column(JSON, default=dict)
    enabled = Column(Boolean, default=True)
    # "never" = no se ha contactado con el sistema remoto. Es el estado de partida:
    # dar de alta un conector no comprueba nada. Default de Python, sin
    # server_default, así que cambiarlo no necesita migración.
    last_sync_status = Column(String(32), default="never")  # ok | warning | error | never
    last_sync_at = Column(DateTime, nullable=True)
    last_sync_summary = Column(Text, default="")
    discovered_items_count = Column(Integer, default=0)
    created_at = Column(DateTime, default=utcnow)


class AlertContact(Base):
    """Contacto destinatario de avisos de guardia SRE y caducidad de certificados."""
    __tablename__ = "network_alert_contacts"

    id = Column(Integer, primary_key=True, index=True)
    code = Column(String(64), unique=True, index=True, nullable=False)
    full_name = Column(String(140), nullable=False)
    role_title = Column(String(120), default="Ingeniero de Sistemas")
    email = Column(String(180), nullable=False)
    phone_or_telegram = Column(String(80), default="")
    personal_webhook_url = Column(String(255), default="")
    schedule_period = Column(String(32), default="24x7")  # 24x7 | workhours | oncall
    notify_on_down = Column(Boolean, default=True)
    notify_on_critical = Column(Boolean, default=True)
    notify_on_warning = Column(Boolean, default=True)
    notify_on_unreachable = Column(Boolean, default=False)
    notify_on_recovery = Column(Boolean, default=True)
    active = Column(Boolean, default=True)
    notes = Column(Text, default="")


class AlertContactGroup(Base):
    """Grupo o turno de guardia que agrupa múltiples contactos SRE y canal de aviso."""
    __tablename__ = "network_alert_contact_groups"

    id = Column(Integer, primary_key=True, index=True)
    code = Column(String(64), unique=True, index=True, nullable=False)
    name = Column(String(160), nullable=False)
    description = Column(Text, default="")
    group_email = Column(String(180), default="")
    channel_webhook_url = Column(String(255), default="")  # Teams / Slack / Telegram / Discord
    member_contact_ids = Column(JSON, default=list)  # Lista de AlertContact.id


class NotificationRoutingRule(Base):
    """Regla de enrutamiento que vincula grupos de hosts con grupos/contactos según severidad."""
    __tablename__ = "network_notification_rules"

    id = Column(Integer, primary_key=True, index=True)
    name = Column(String(160), nullable=False)
    description = Column(Text, default="")
    enabled = Column(Boolean, default=True)

    # Qué ámbito de máquinas dispara la regla:
    # all | host_group | single_host | asset_class | service_type
    scope_type = Column(String(32), default="host_group")
    host_group_id = Column(Integer, ForeignKey("network_host_groups.id", ondelete="SET NULL"), nullable=True)
    asset_id = Column(Integer, ForeignKey("cmdb_assets.id", ondelete="SET NULL"), nullable=True)
    asset_class_filter = Column(String(48), default="")
    service_type_filter = Column(String(48), default="")

    # A quién se avisa (Personas y/o Grupos de Personas):
    contact_group_ids = Column(JSON, default=list)
    contact_ids = Column(JSON, default=list)
    send_email = Column(Boolean, default=True)
    send_webhook = Column(Boolean, default=True)
    only_on_hard_state = Column(Boolean, default=True)


class MaintenanceWindow(Base):
    """Ventana de mantenimiento programada que silencia el disparo de alertas sobre activos afectados."""
    __tablename__ = "network_maintenance_windows"

    id = Column(Integer, primary_key=True, index=True)
    title = Column(String(160), nullable=False)
    reason = Column(Text, default="")
    created_by = Column(String(80), default="admin")  # Ej: "ansible-playbook" o "admin"
    # scope_type: single_host | host_group | ip_or_hostname_list
    scope_type = Column(String(32), default="single_host")
    asset_id = Column(Integer, ForeignKey("cmdb_assets.id", ondelete="SET NULL"), nullable=True)
    host_group_id = Column(Integer, ForeignKey("network_host_groups.id", ondelete="SET NULL"), nullable=True)
    target_matches = Column(JSON, default=list)  # Lista de códigos, hostnames o IPs incluidos en mantenimiento
    starts_at = Column(DateTime, default=utcnow)
    ends_at = Column(DateTime, nullable=False)
    is_active = Column(Boolean, default=True)
    suppress_notifications = Column(Boolean, default=True)


class AlertNotificationLog(Base):
    """Registro histórico auditable de cada alerta evaluada o enviada por SMTP/webhook."""
    __tablename__ = "network_alert_logs"

    id = Column(Integer, primary_key=True, index=True)
    created_at = Column(DateTime, default=utcnow, index=True)
    asset_code = Column(String(80), default="")
    service_name = Column(String(120), default="")
    event_state = Column(String(40), default="HARD CRITICAL")
    matched_rule_name = Column(String(160), default="")
    recipients_summary = Column(Text, default="")
    delivery_channel = Column(String(48), default="smtp+webhook")
    # sent / sent_smtp / sent_webhook : entregado de verdad por ese transporte
    # not_configured                  : no se intentó enviar (sin SMTP ni destinatarios)
    # error                           : se intentó y falló; el detalle lleva el motivo
    # suppressed_maintenance          : silenciado por ventana de mantenimiento
    # suppressed_unreachable          : silenciado porque el padre estaba caído
    delivery_status = Column(String(32), default="sent")
    detail = Column(Text, default="")


class SmtpAlertConfig(Base):
    """Configuración global del servidor de correo SMTP y webhook para despacho de alarmas."""
    __tablename__ = "network_smtp_config"

    id = Column(Integer, primary_key=True, index=True)
    smtp_host = Column(String(180), default="smtp.empresa.local")
    smtp_port = Column(Integer, default=587)
    use_tls = Column(Boolean, default=True)
    smtp_username = Column(String(160), default="alertas-rackdoc@empresa.local")
    smtp_password = Column(String(255), default="")
    from_email = Column(String(180), default="RackDoc Monitor & CMDB <alertas-rackdoc@empresa.local>")
    global_webhook_url = Column(String(255), default="")
    enabled = Column(Boolean, default=True)


class TechStackDiagram(Base):
    """
    Esquema visual de Lógica de Negocio / Stack Tecnológico (ej. 'Stack Portal Ecommerce & ERP',
    'Stack Clúster Microservicios & Pagos', 'Stack Identidad & Correo').
    Permite tener múltiples esquemas independientes donde se dibujan cajas/zonas delimitadoras
    con texto en la esquina superior y elementos/nodos libres en 2D con enlaces a medida,
    ventana flotante de datos técnicos + gráficas Prometheus y acceso SSH directo.
    """
    __tablename__ = "tech_stack_diagrams"

    id = Column(Integer, primary_key=True, index=True)
    code = Column(String(80), unique=True, index=True, nullable=False)
    name = Column(String(180), nullable=False)
    description = Column(Text, default="")
    business_service = Column(String(140), default="Plataforma Digital & Negocio")
    environment = Column(String(32), default="production")
    owner_team = Column(String(120), default="DevOps & Arquitectura")
    criticality = Column(String(24), default="critical")
    map_scale = Column(Float, default=1.0)
    canvas_boxes = Column(JSON, default=list)  # Cajas/Zonas libres con texto/datos en esquina superior [{id, title, corner_data, pos_x, pos_y, width_px, height_px, color_hex}]
    created_at = Column(DateTime, default=utcnow)


class TechStackNode(Base):
    """
    Nodo posicionado libremente dentro del lienzo 2D de un Stack Tecnológico, vinculado a un Host/VM/VIP/BBDD
    real de Red & Host / CMDB / Prometheus.
    """
    __tablename__ = "tech_stack_nodes"

    id = Column(Integer, primary_key=True, index=True)
    stack_id = Column(Integer, ForeignKey("tech_stack_diagrams.id", ondelete="CASCADE"), nullable=False, index=True)
    asset_id = Column(Integer, ForeignKey("cmdb_assets.id", ondelete="CASCADE"), nullable=False, index=True)
    role_layer = Column(String(48), default="general")
    custom_label = Column(String(140), default="")
    pos_x = Column(Float, default=0.25)  # Coordenada normalizada X (0.01 .. 0.96) en el lienzo
    pos_y = Column(Float, default=0.35)  # Coordenada normalizada Y (0.01 .. 0.95) en el lienzo
    width_px = Column(Float, default=200.0)
    height_px = Column(Float, default=110.0)
    ssh_enabled = Column(Boolean, default=True)
    ssh_user = Column(String(64), default="root")
    ssh_port = Column(Integer, default=22)


class TechStackEdge(Base):
    """
    Flecha / conexión de flujo de lógica de negocio entre dos nodos de un Stack Tecnológico
    (ej. Balanceador VIP -> Frontal Web Nginx 01 -> App ERP -> PostgreSQL Master).
    """
    __tablename__ = "tech_stack_edges"

    id = Column(Integer, primary_key=True, index=True)
    stack_id = Column(Integer, ForeignKey("tech_stack_diagrams.id", ondelete="CASCADE"), nullable=False, index=True)
    source_node_id = Column(Integer, ForeignKey("tech_stack_nodes.id", ondelete="CASCADE"), nullable=False)
    target_node_id = Column(Integer, ForeignKey("tech_stack_nodes.id", ondelete="CASCADE"), nullable=False)
    protocol_label = Column(String(120), default="HTTPS :443")
    port = Column(Integer, default=443)
    notes = Column(Text, default="")


class TlsCertificate(Base):
    """
    CertScope — Auditoría y Control de Caducidad de Certificados SSL/TLS (Automáticos por Red HTTPS y Manuales/Offline).
    Vinculado opcionalmente a activos de CMDB, equipos de Rack 42U, dispositivos de Planta y Sedes (Locations),
    con alertas preventivas a Personas y Grupos de Personas antes de su vencimiento.
    """
    __tablename__ = "certscope_certificates"

    id = Column(Integer, primary_key=True, index=True)
    code = Column(String(80), unique=True, index=True, nullable=False)  # Ej: CERT-ROU01-443, CERT-ERP-WEB, CERT-MAN-01
    name = Column(String(180), nullable=False)
    # check_mode: 'https_live' (sonda TLS automática a host:port) | 'manual' (fecha manual o certificado PEM pegado sin acceso directo)
    check_mode = Column(String(32), default="https_live")
    # renewal_type: 'manual' (renovación manual por operario: avisar antes de caducar) | 'auto_acme' (Let's Encrypt / ACME / Auto-enrollment)
    renewal_type = Column(String(32), default="manual")

    target_host = Column(String(255), default="")  # IP, Hostname o Dominio FQDN (ej. 192.168.2.1 o portal.empresa.com)
    port = Column(Integer, default=443)  # 443, 8443, 8006, 9443, 636, etc.
    sni_hostname = Column(String(255), default="")  # SNI opcional si target_host es una IP
    environment = Column(String(32), default="production")  # production | staging | development | dr

    # Vínculos directos para navegar con 1 clic al Rack, Planta, Máquina CMDB o Sede
    asset_id = Column(Integer, ForeignKey("cmdb_assets.id", ondelete="SET NULL"), nullable=True, index=True)
    rack_device_id = Column(Integer, ForeignKey("rack_devices.id", ondelete="SET NULL"), nullable=True, index=True)
    floor_device_id = Column(Integer, ForeignKey("floor_devices.id", ondelete="SET NULL"), nullable=True, index=True)
    location_id = Column(Integer, ForeignKey("locations.id", ondelete="SET NULL"), nullable=True, index=True)

    # Atributos X.509 extraídos por TLS/PEM o cumplimentados manualmente
    common_name = Column(String(255), default="")
    issuer_cn = Column(String(255), default="")
    issuer_org = Column(String(255), default="")
    san_domains = Column(JSON, default=list)
    serial_number = Column(String(160), default="")
    fingerprint_sha256 = Column(String(180), default="")
    tls_version = Column(String(64), default="")
    cipher_suite = Column(String(128), default="")
    is_self_signed = Column(Boolean, default=False)
    valid_from = Column(DateTime, nullable=True)
    valid_until = Column(DateTime, nullable=True)
    days_remaining = Column(Integer, nullable=True)
    pem_certificate = Column(Text, default="")

    # Semáforo y Avisos a Personas / Grupos
    # status: 'valid' (>warn_days_before) | 'expiring_soon' (<=warn_days_before) | 'critical' (<=critical_days_before) | 'expired' (<=0d) | 'unreachable' | 'unknown'
    status = Column(String(32), default="unknown")
    warn_days_before = Column(Integer, default=30)
    critical_days_before = Column(Integer, default=7)
    auto_probe_enabled = Column(Boolean, default=True)
    notify_enabled = Column(Boolean, default=True)
    owner_team = Column(String(140), default="Seguridad & Sistemas")
    responsible_person = Column(String(140), default="Alex Geng")
    notify_emails = Column(String(500), default="")
    contact_group_ids = Column(JSON, default=list)
    contact_ids = Column(JSON, default=list)

    last_checked_at = Column(DateTime, nullable=True)
    last_probe_error = Column(Text, default="")
    last_notified_at = Column(DateTime, nullable=True)
    last_notified_severity = Column(String(32), default="")
    renewal_notes = Column(Text, default="")
    notes = Column(Text, default="")
    created_at = Column(DateTime, default=utcnow)
    updated_at = Column(DateTime, default=utcnow, onupdate=utcnow)

    asset = relationship("CmdbAsset")
    rack_device = relationship("RackDevice")
    floor_device = relationship("FloorDevice")
    location = relationship("Location")


class ProvisioningCredential(Base):
    """
    Credencial reutilizable cifrada en reposo (Fernet AES-128-CBC + HMAC-SHA256) para
    aprovisionamiento Ansible sobre servidores Linux (SSH) y Windows (WinRM).
    """
    __tablename__ = "provisioning_credentials"

    id = Column(Integer, primary_key=True, index=True)
    name = Column(String(160), unique=True, nullable=False)
    # credential_type: 'ssh_key' | 'ssh_password' | 'winrm'
    credential_type = Column(String(32), default="ssh_key", nullable=False)
    # os_family: 'linux' | 'windows'
    os_family = Column(String(24), default="linux", nullable=False)
    username = Column(String(120), default="root", nullable=False)
    port = Column(Integer, default=22)

    # Secretos cifrados con Fernet (jamás se exponen en claro en endpoints GET)
    secret_ciphertext = Column(Text, default="")
    passphrase_ciphertext = Column(Text, default="")
    become_password_ciphertext = Column(Text, default="")

    # Ajustes específicos WinRM (Windows Server)
    winrm_transport = Column(String(32), default="ntlm")  # ntlm | basic
    winrm_use_ssl = Column(Boolean, default=False)
    winrm_validate_certs = Column(Boolean, default=False)

    # Metadatos no sensibles visibles en el baúl
    key_fingerprint = Column(String(180), default="")
    notes = Column(Text, default="")
    created_by = Column(String(120), default="admin")
    created_at = Column(DateTime, default=utcnow)
    updated_at = Column(DateTime, default=utcnow, onupdate=utcnow)


class ProvisioningJob(Base):
    """
    Trabajo asíncrono de verificación previa, auditoría hardware CMDB y despliegue
    condicional de Exporters nativos (`node_exporter` / `windows_exporter`) y/o
    OpenTelemetry Collector (`otelcol`) mediante Ansible.
    """
    __tablename__ = "provisioning_jobs"

    id = Column(Integer, primary_key=True, index=True)
    job_code = Column(String(64), unique=True, index=True, nullable=False)
    title = Column(String(200), nullable=False)
    # os_family: 'linux' | 'windows'
    os_family = Column(String(24), default="linux", nullable=False)
    # action_profile: 'verify_and_propose' | 'ensure_native_exporter' | 'ensure_otel_collector' | 'ensure_both'
    action_profile = Column(String(48), default="verify_and_propose", nullable=False)
    targets = Column(JSON, default=list)  # Lista de IPs o FQDNs objetivo

    credential_id = Column(
        Integer,
        ForeignKey("provisioning_credentials.id", ondelete="SET NULL"),
        nullable=True,
        index=True,
    )
    credential_mode = Column(String(24), default="vault")  # vault | ephemeral
    target_location_id = Column(
        Integer,
        ForeignKey("locations.id", ondelete="SET NULL"),
        nullable=True,
        index=True,
    )
    host_groups = Column(JSON, default=list)
    otel_endpoint_url = Column(String(255), default="")
    use_local_cache = Column(Boolean, default=True)

    # status: 'queued' | 'running' | 'completed' | 'partial' | 'failed'
    status = Column(String(32), default="queued", index=True)
    host_results = Column(JSON, default=dict)
    console_log = Column(Text, default="")
    created_by = Column(String(120), default="admin")
    started_at = Column(DateTime, nullable=True)
    finished_at = Column(DateTime, nullable=True)
    created_at = Column(DateTime, default=utcnow)

    credential = relationship("ProvisioningCredential")
    target_location = relationship("Location")


class ProvisioningToken(Base):
    """
    Token acotado de auto-alta sin SSH/WinRM entrante para scripts one-liner
    (`.sh` en Linux / cloud-init y `.ps1` en Windows / GPO) y reenvío OTLP en DMZ.
    """
    __tablename__ = "provisioning_tokens"

    id = Column(Integer, primary_key=True, index=True)
    name = Column(String(160), nullable=False)
    token_hash = Column(String(128), unique=True, index=True, nullable=False)
    token_prefix = Column(String(24), default="")
    # os_family: 'linux' | 'windows' | 'any'
    os_family = Column(String(24), default="any")
    # action_profile: 'verify_and_propose' | 'ensure_native_exporter' | 'ensure_otel_collector' | 'ensure_both'
    action_profile = Column(String(48), default="ensure_native_exporter")
    target_location_id = Column(
        Integer,
        ForeignKey("locations.id", ondelete="SET NULL"),
        nullable=True,
        index=True,
    )
    host_groups = Column(JSON, default=list)
    reusable = Column(Boolean, default=True)
    uses_count = Column(Integer, default=0)
    max_uses = Column(Integer, default=0)  # 0 = ilimitado mientras no expire o se revoque
    expires_at = Column(DateTime, nullable=True)
    revoked = Column(Boolean, default=False)
    created_by = Column(String(120), default="admin")
    last_used_at = Column(DateTime, nullable=True)
    notes = Column(Text, default="")
    created_at = Column(DateTime, default=utcnow)

    target_location = relationship("Location")






