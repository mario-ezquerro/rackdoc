from datetime import datetime
from typing import List, Optional, Dict, Any
from pydantic import BaseModel, ConfigDict


class ManagementLinkSchema(BaseModel):
    protocol: str  # ssh | telnet | https | http | rdp | ipmi
    port: int = 22
    username: str = "admin"
    label: str = ""
    path: str = ""


class PortSchema(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    rack_device_id: int
    port_number: str
    label: str
    face: str
    port_type: str
    row_index: int
    col_index: int
    rel_x: float
    rel_y: float
    mac_or_ip: str = ""
    vlan: Optional[int] = None


class DeviceTemplateSchema(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    library_group: str = "Network"
    category: str
    manufacturer: str
    model_name: str
    u_height: int
    is_full_depth: bool
    default_color: str
    layout_spec: Dict[str, Any]


class DeviceTemplateCreate(BaseModel):
    library_group: str = "Network"
    category: str
    manufacturer: str = "Generic"
    model_name: str
    u_height: int = 1
    is_full_depth: bool = False
    default_color: str = "#F8FAFC"
    layout_spec: Dict[str, Any] = {}


class DeviceLibraryImportRequest(BaseModel):
    library_group: Optional[str] = None
    templates: List[Dict[str, Any]] = []


class ExternalOutletCreate(BaseModel):
    code: str = "FEED-C"
    name: str = "Línea Eléctrica C (Schuko)"
    feed_type: str = "power"  # "power" | "fiber"
    color_hex: str = "#EA580C"
    socket_count: int = 4
    start_u: int = 28


class ExternalOutletUpdate(BaseModel):
    code: Optional[str] = None
    name: Optional[str] = None
    feed_type: Optional[str] = None
    color_hex: Optional[str] = None
    socket_count: Optional[int] = None
    start_u: Optional[int] = None


class LoginRequest(BaseModel):
    username: str
    password: str
    ad_server_id: Optional[int] = None


class UserSchema(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    username: str
    email: str = ""
    full_name: str = ""
    role: str  # admin | editor | operator | viewer
    auth_source: str = "local"
    ad_server_id: Optional[int] = None
    ad_dn: str = ""
    is_active: bool = True


class UserCreate(BaseModel):
    username: str
    password: str = "changeme"
    email: str = ""
    full_name: str = ""
    role: str = "viewer"  # admin | editor | operator | viewer
    auth_source: str = "local"
    ad_server_id: Optional[int] = None
    ad_dn: str = ""
    is_active: bool = True


class UserUpdate(BaseModel):
    username: Optional[str] = None
    password: Optional[str] = None
    email: Optional[str] = None
    full_name: Optional[str] = None
    role: Optional[str] = None
    is_active: Optional[bool] = None
    ad_server_id: Optional[int] = None


class ADServerSchema(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    name: str
    ldap_url: str
    domain: str
    base_dn: str
    bind_dn: str
    user_filter: str
    default_role: str
    group_role_mapping: List[Dict[str, Any]] = []
    enabled: bool


class ADServerCreate(BaseModel):
    name: str
    ldap_url: str
    domain: str = ""
    base_dn: str = ""
    bind_dn: str = ""
    bind_password: str = ""
    user_filter: str = "(&(objectClass=user)(sAMAccountName={username}))"
    default_role: str = "viewer"
    group_role_mapping: List[Dict[str, Any]] = []
    enabled: bool = True


class ADServerUpdate(BaseModel):
    name: Optional[str] = None
    ldap_url: Optional[str] = None
    domain: Optional[str] = None
    base_dn: Optional[str] = None
    bind_dn: Optional[str] = None
    bind_password: Optional[str] = None
    user_filter: Optional[str] = None
    default_role: Optional[str] = None
    group_role_mapping: Optional[List[Dict[str, Any]]] = None
    enabled: Optional[bool] = None


class ADUserSearchRequest(BaseModel):
    query: str = ""


class ADUserImportItem(BaseModel):
    username: str
    full_name: str = ""
    email: str = ""
    ad_dn: str = ""
    role: str = "viewer"


class ADUserImportRequest(BaseModel):
    users: List[ADUserImportItem]


class RackDeviceSchema(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    rack_id: int
    template_id: int
    code: str
    name: str
    hostname: str
    fqdn: str
    start_u: int
    mounted_face: str
    ip_address: str
    subnet_mask: str
    gateway: str
    mac_address: str
    vlan_mgmt: Optional[int] = None
    management_links: List[Dict[str, Any]] = []
    monitoring_enabled: bool
    monitor_method: str
    monitor_port: int
    status: str
    last_ping_ms: Optional[float] = None
    last_checked_at: Optional[datetime] = None
    serial_number: str
    custom_fields: Dict[str, Any] = {}
    notes: str
    template: DeviceTemplateSchema
    ports: List[PortSchema] = []


class RackDeviceCreate(BaseModel):
    template_id: int
    code: str
    name: str
    hostname: str = ""
    fqdn: str = ""
    start_u: int
    mounted_face: str = "front"
    ip_address: str = ""
    subnet_mask: str = "255.255.255.0"
    gateway: str = ""
    mac_address: str = ""
    vlan_mgmt: Optional[int] = None
    management_links: List[Dict[str, Any]] = []
    monitoring_enabled: bool = False
    monitor_method: str = "icmp"
    monitor_port: int = 22
    serial_number: str = ""
    custom_fields: Dict[str, Any] = {}
    notes: str = ""


class RackDeviceUpdate(BaseModel):
    code: Optional[str] = None
    name: Optional[str] = None
    hostname: Optional[str] = None
    fqdn: Optional[str] = None
    start_u: Optional[int] = None
    mounted_face: Optional[str] = None
    ip_address: Optional[str] = None
    subnet_mask: Optional[str] = None
    gateway: Optional[str] = None
    mac_address: Optional[str] = None
    vlan_mgmt: Optional[int] = None
    management_links: Optional[List[Dict[str, Any]]] = None
    monitoring_enabled: Optional[bool] = None
    monitor_method: Optional[str] = None
    monitor_port: Optional[int] = None
    serial_number: Optional[str] = None
    custom_fields: Optional[Dict[str, Any]] = None
    notes: Optional[str] = None


class ConnectionEndpointInfo(BaseModel):
    port_id: int
    port_number: str
    port_type: str
    face: str
    device_id: int
    device_code: str
    device_name: str
    rack_id: int
    rack_code: str
    rack_name: str
    start_u: int


class ConnectionSchema(BaseModel):
    id: int
    source_port_id: int
    target_port_id: int
    cable_type: str
    color_hex: str
    routing_channel: str
    label: str
    vlan: Optional[int] = None
    length_m: float
    notes: str
    source_info: ConnectionEndpointInfo
    target_info: ConnectionEndpointInfo


class ConnectionCreate(BaseModel):
    source_port_id: int
    target_port_id: int
    cable_type: str = "utp_cat6"
    color_hex: str = "#2563EB"
    routing_channel: str = "auto"
    label: str = ""
    vlan: Optional[int] = None
    length_m: float = 1.5
    notes: str = ""


class ConnectionUpdate(BaseModel):
    cable_type: Optional[str] = None
    color_hex: Optional[str] = None
    routing_channel: Optional[str] = None
    label: Optional[str] = None
    vlan: Optional[int] = None
    length_m: Optional[float] = None
    notes: Optional[str] = None


class RackUpdate(BaseModel):
    code: Optional[str] = None
    name: Optional[str] = None
    total_units: Optional[int] = None
    manufacturer: Optional[str] = None
    model_name: Optional[str] = None
    serial_number: Optional[str] = None
    responsible_person: Optional[str] = None
    purchase_date: Optional[str] = None
    operation_start: Optional[str] = None
    aisle_id: Optional[int] = None
    pos_x: Optional[float] = None
    pos_y: Optional[float] = None
    width_px: Optional[float] = None
    depth_px: Optional[float] = None
    rotation_deg: Optional[int] = None
    notes: Optional[str] = None


class LocationUpdate(BaseModel):
    code: Optional[str] = None
    name: Optional[str] = None
    latitude: Optional[float] = None
    longitude: Optional[float] = None
    address: Optional[str] = None
    plan_pos_x: Optional[float] = None
    plan_pos_y: Optional[float] = None
    plan_width: Optional[float] = None
    plan_height: Optional[float] = None
    map_scale: Optional[float] = None


class FloorUpdate(BaseModel):
    name: Optional[str] = None
    level_number: Optional[int] = None
    map_scale: Optional[float] = None


class RackCreate(BaseModel):
    room_id: int
    aisle_id: Optional[int] = None
    code: str
    name: str
    total_units: int = 42
    manufacturer: str = "Rittal"
    model_name: str = "TS IT 42U"
    serial_number: str = ""
    responsible_person: str = "Alex Geng"
    purchase_date: str = "2026-04-01"
    operation_start: str = "2026-05-01"
    notes: str = ""


class LocationCreate(BaseModel):
    code: str
    name: str
    latitude: float
    longitude: float
    address: str = ""
    description: str = ""


class FloorCreate(BaseModel):
    location_id: int
    name: str
    level_number: int = 1


class RoomCreate(BaseModel):
    floor_id: int
    name: str
    width_m: float = 12.0
    depth_m: float = 8.0
    notes: str = ""


class AisleCreate(BaseModel):
    room_id: int
    code: str
    name: str
    aisle_type: str = "cold"
