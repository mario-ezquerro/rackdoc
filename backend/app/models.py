from datetime import datetime
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


class ADServer(Base):
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
    enabled = Column(Boolean, default=True)
    created_at = Column(DateTime, default=datetime.utcnow)

    users = relationship("User", back_populates="ad_server")


class User(Base):
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
    created_at = Column(DateTime, default=datetime.utcnow)

    ad_server = relationship("ADServer", back_populates="users")


class Location(Base):
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
    __tablename__ = "floors"

    id = Column(Integer, primary_key=True, index=True)
    location_id = Column(Integer, ForeignKey("locations.id", ondelete="CASCADE"), nullable=False)
    name = Column(String(100), nullable=False)
    level_number = Column(Integer, default=0)
    map_image_url = Column(String(500), default="")
    map_scale = Column(Float, default=1.0)

    location = relationship("Location", back_populates="floors")
    rooms = relationship("Room", back_populates="floor", cascade="all, delete-orphan")


class Room(Base):
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
    __tablename__ = "aisles"

    id = Column(Integer, primary_key=True, index=True)
    room_id = Column(Integer, ForeignKey("rooms.id", ondelete="CASCADE"), nullable=False)
    code = Column(String(32), nullable=False)
    name = Column(String(100), nullable=False)
    aisle_type = Column(String(32), default="cold")  # cold | hot | standard

    room = relationship("Room", back_populates="aisles")
    racks = relationship("Rack", back_populates="aisle")


class Rack(Base):
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
    status = Column(String(32), default="unknown")  # online | offline | warning | unknown
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
