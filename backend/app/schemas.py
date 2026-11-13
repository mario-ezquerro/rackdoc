"""
Esquemas Pydantic v2 de validación de entrada y serialización de salida para la API `/api/v1`.
"""

from datetime import datetime
from typing import List, Optional, Dict, Any
from pydantic import BaseModel, ConfigDict, model_validator
from pydantic_core import PydanticUndefined


class _ORMBaseSchema(BaseModel):
    """Clase base para esquemas ORM (`from_attributes=True`) tolerante a columnas `NULL` en SQLite."""

    model_config = ConfigDict(from_attributes=True)

    @model_validator(mode="before")
    @classmethod
    def _coerce_null_orm_fields(cls, data: Any) -> Any:
        if data is None:
            return data
        out: Dict[str, Any] = {}
        is_mapping = isinstance(data, dict)
        for name, field in cls.model_fields.items():
            val = (
                data.get(name, PydanticUndefined)
                if is_mapping
                else getattr(data, name, PydanticUndefined)
            )
            if val is PydanticUndefined:
                continue
            if val is None and not field.is_required():
                if field.default is not None and field.default is not PydanticUndefined:
                    default_val = field.default
                    if isinstance(default_val, list):
                        val = list(default_val)
                    elif isinstance(default_val, dict):
                        val = dict(default_val)
                    else:
                        val = default_val
                elif field.default_factory is not None:
                    val = field.default_factory()
            out[name] = val
        return out


class ManagementLinkSchema(BaseModel):
    """Esquema serializado de transferencia (`ManagementLinkSchema`)."""
    protocol: str  # ssh | telnet | https | http | rdp | ipmi
    port: int = 22
    username: str = "admin"
    label: str = ""
    path: str = ""


class PortSchema(_ORMBaseSchema):
    """Esquema serializado de transferencia (`PortSchema`)."""

    id: int
    rack_device_id: int
    port_number: str = ""
    label: str = ""
    face: str = "front"
    port_type: str = "rj45"
    row_index: int = 0
    col_index: int = 0
    rel_x: float = 0.5
    rel_y: float = 0.5
    mac_or_ip: str = ""
    vlan: Optional[int] = None


class DeviceTemplateSchema(_ORMBaseSchema):
    """Esquema serializado de transferencia (`DeviceTemplateSchema`)."""

    id: int
    library_group: str = "Network"
    category: str = "server"
    manufacturer: str = "Generic"
    model_name: str = ""
    u_height: int = 1
    is_full_depth: bool = False
    default_color: str = "#F8FAFC"
    layout_spec: Dict[str, Any] = {}


class DeviceTemplateCreate(BaseModel):
    """Payload de creación para `DeviceTemplate`."""
    library_group: str = "Network"
    category: str
    manufacturer: str = "Generic"
    model_name: str
    u_height: int = 1
    is_full_depth: bool = False
    default_color: str = "#F8FAFC"
    layout_spec: Dict[str, Any] = {}


class DeviceTemplateUpdate(BaseModel):
    """Payload de actualización parcial para `DeviceTemplate`."""
    library_group: Optional[str] = None
    category: Optional[str] = None
    manufacturer: Optional[str] = None
    model_name: Optional[str] = None
    u_height: Optional[int] = None
    is_full_depth: Optional[bool] = None
    default_color: Optional[str] = None
    layout_spec: Optional[Dict[str, Any]] = None
    photo_url: Optional[str] = None


class DeviceLibraryImportRequest(BaseModel):
    """Petición de operación (`DeviceLibraryImportRequest`)."""
    library_group: Optional[str] = None
    templates: List[Dict[str, Any]] = []


class ExternalOutletCreate(BaseModel):
    """Payload de creación para `ExternalOutlet`."""
    code: str = "FEED-C"
    name: str = "Línea Eléctrica C (Schuko)"
    feed_type: str = "power"  # "power" | "fiber"
    color_hex: str = "#EA580C"
    socket_count: int = 4
    start_u: int = 28


class ExternalOutletUpdate(BaseModel):
    """Payload de actualización parcial para `ExternalOutlet`."""
    code: Optional[str] = None
    name: Optional[str] = None
    feed_type: Optional[str] = None
    color_hex: Optional[str] = None
    socket_count: Optional[int] = None
    start_u: Optional[int] = None


class LoginRequest(BaseModel):
    """Petición de operación (`LoginRequest`)."""
    username: str
    password: str
    ad_server_id: Optional[int] = None


class UserSchema(_ORMBaseSchema):
    """Esquema serializado de transferencia (`UserSchema`)."""

    id: int
    username: str
    email: str = ""
    full_name: str = ""
    role: str = "viewer"  # admin | editor | operator | viewer
    auth_source: str = "local"
    ad_server_id: Optional[int] = None
    ad_dn: str = ""
    is_active: bool = True


class UserCreate(BaseModel):
    """Payload de creación para `User`."""
    username: str
    password: str
    email: str = ""
    full_name: str = ""
    role: str = "viewer"  # admin | editor | operator | viewer
    auth_source: str = "local"
    ad_server_id: Optional[int] = None
    ad_dn: str = ""
    is_active: bool = True


class UserUpdate(BaseModel):
    """Payload de actualización parcial para `User`."""
    username: Optional[str] = None
    password: Optional[str] = None
    email: Optional[str] = None
    full_name: Optional[str] = None
    role: Optional[str] = None
    is_active: Optional[bool] = None
    ad_server_id: Optional[int] = None


class ADServerSchema(_ORMBaseSchema):
    """Esquema serializado de transferencia (`ADServerSchema`)."""

    id: int
    name: str = ""
    ldap_url: str = ""
    domain: str = ""
    base_dn: str = ""
    bind_dn: str = ""
    user_filter: str = "(&(objectClass=user)(sAMAccountName={username}))"
    default_role: str = "viewer"
    group_role_mapping: List[Dict[str, Any]] = []
    enabled: bool = True


class ADServerCreate(BaseModel):
    """Payload de creación para `ADServer`."""
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
    """Payload de actualización parcial para `ADServer`."""
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
    """Petición de operación (`ADUserSearchRequest`)."""
    query: str = ""


class ADUserImportItem(BaseModel):
    """Esquema serializado de transferencia (`ADUserImportItem`)."""
    username: str
    full_name: str = ""
    email: str = ""
    ad_dn: str = ""
    role: str = "viewer"
    initial_password: str = ""


class ADUserImportRequest(BaseModel):
    """Petición de operación (`ADUserImportRequest`)."""
    users: List[ADUserImportItem]


class RackDeviceSchema(_ORMBaseSchema):
    """Esquema serializado de transferencia (`RackDeviceSchema`)."""

    id: int
    rack_id: int
    template_id: int
    code: str = ""
    name: str = ""
    hostname: str = ""
    fqdn: str = ""
    start_u: int = 1
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
    status: str = "unmonitored"
    last_ping_ms: Optional[float] = None
    last_checked_at: Optional[datetime] = None
    serial_number: str = ""
    custom_fields: Dict[str, Any] = {}
    notes: str = ""
    template: DeviceTemplateSchema
    ports: List[PortSchema] = []


class RackDeviceCreate(BaseModel):
    """Payload de creación para `RackDevice`."""
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
    certscope_enabled: Optional[bool] = False
    certscope_port: int = 443
    certscope_renewal_type: str = "manual"
    certscope_sni: str = ""


class RackDeviceUpdate(BaseModel):
    """Payload de actualización parcial para `RackDevice`."""
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
    certscope_enabled: Optional[bool] = None
    certscope_port: Optional[int] = None
    certscope_renewal_type: Optional[str] = None
    certscope_sni: Optional[str] = None


class ConnectionEndpointInfo(BaseModel):
    """Esquema serializado de transferencia (`ConnectionEndpointInfo`)."""
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
    """Esquema serializado de transferencia (`ConnectionSchema`)."""
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
    """Payload de creación para `Connection`."""
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
    """Payload de actualización parcial para `Connection`."""
    cable_type: Optional[str] = None
    color_hex: Optional[str] = None
    routing_channel: Optional[str] = None
    label: Optional[str] = None
    vlan: Optional[int] = None
    length_m: Optional[float] = None
    notes: Optional[str] = None


class RackUpdate(BaseModel):
    """Payload de actualización parcial para `Rack`."""
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
    """Payload de actualización parcial para `Location`."""
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
    """Payload de actualización parcial para `Floor`."""
    name: Optional[str] = None
    level_number: Optional[int] = None
    map_scale: Optional[float] = None


class RackCreate(BaseModel):
    """Payload de creación para `Rack`."""
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
    """Payload de creación para `Location`."""
    code: str
    name: str
    latitude: float
    longitude: float
    address: str = ""
    description: str = ""


class FloorCreate(BaseModel):
    """Payload de creación para `Floor`."""
    location_id: int
    name: str
    level_number: int = 1


class RoomCreate(BaseModel):
    """Payload de creación para `Room`."""
    floor_id: int
    name: str
    width_m: float = 12.0
    depth_m: float = 8.0
    notes: str = ""


class AisleCreate(BaseModel):
    """Payload de creación para `Aisle`."""
    room_id: int
    code: str
    name: str
    aisle_type: str = "cold"


class FloorDeviceCreate(BaseModel):
    """Payload de creación para `FloorDevice`."""
    room_id: Optional[int] = None
    room_code: str = "GOA"
    device_type: str  # camera | access_control | access_point | desktop | laptop | phone | printer | 3d_printer | isp_uplink | microphone | ndi_box | screen | speaker | telecom_outlet
    code: str
    name: str
    pos_x: float = 0.50
    pos_y: float = 0.50
    fqdn: str = ""
    ip_address: str = ""
    mac_address: str = ""
    vlan: Optional[int] = None
    monitoring_enabled: bool = False
    monitor_method: str = "icmp"
    monitor_port: int = 22
    status: str = "unmonitored"
    custom_fields: Dict[str, Any] = {}
    linked_rack_id: Optional[int] = None
    linked_rack_device_code: str = ""
    linked_outlet_id: Optional[int] = None
    cmdb_asset_id: Optional[int] = None
    responsible_person: str = "Alex Geng"
    contact_first_name: str = ""
    contact_last_name: str = ""
    contact_email: str = ""
    contact_phone: str = ""
    contact_job_title: str = ""
    contact_department: str = ""
    notes: str = ""
    certscope_enabled: Optional[bool] = False
    certscope_port: int = 443
    certscope_renewal_type: str = "manual"
    certscope_sni: str = ""


class FloorDeviceUpdate(BaseModel):
    """Payload de actualización parcial para `FloorDevice`."""
    room_id: Optional[int] = None
    room_code: Optional[str] = None
    device_type: Optional[str] = None
    code: Optional[str] = None
    name: Optional[str] = None
    pos_x: Optional[float] = None
    pos_y: Optional[float] = None
    fqdn: Optional[str] = None
    ip_address: Optional[str] = None
    mac_address: Optional[str] = None
    vlan: Optional[int] = None
    monitoring_enabled: Optional[bool] = None
    monitor_method: Optional[str] = None
    monitor_port: Optional[int] = None
    status: Optional[str] = None
    custom_fields: Optional[Dict[str, Any]] = None
    linked_rack_id: Optional[int] = None
    linked_rack_device_code: Optional[str] = None
    linked_outlet_id: Optional[int] = None
    cmdb_asset_id: Optional[int] = None
    responsible_person: Optional[str] = None
    contact_first_name: Optional[str] = None
    contact_last_name: Optional[str] = None
    contact_email: Optional[str] = None
    contact_phone: Optional[str] = None
    contact_job_title: Optional[str] = None
    contact_department: Optional[str] = None
    notes: Optional[str] = None
    certscope_enabled: Optional[bool] = None
    certscope_port: Optional[int] = None
    certscope_renewal_type: Optional[str] = None
    certscope_sni: Optional[str] = None


class FloorDeviceCustomTypeCreate(BaseModel):
    """Payload de creación para `FloorDeviceCustomType`."""
    category_key: Optional[str] = None
    group_name: str = "Industrial / A Medida"
    label: str
    prefix: str = "DEV"
    icon_key: str = "memory"
    pin_color_hex: str = "#7C3AED"
    default_port_hint: str = "SW01:Gi1/0/1"
    is_sensor: bool = False


class MonitoringSettingsUpdate(BaseModel):
    """Payload de actualización parcial para `MonitoringSettings`."""
    interval_seconds: Optional[int] = None
    interval_minutes: Optional[int] = None
    background_enabled: Optional[bool] = None


class CmdbSubnetCreate(BaseModel):
    """Payload de creación para `CmdbSubnet`."""
    cidr: str
    name: str
    vlan_id: Optional[int] = None
    gateway: str = ""
    subnet_mask: str = "255.255.255.0"
    dns_servers: str = ""
    environment: str = "production"
    location_id: Optional[int] = None
    notes: str = ""


class CmdbSubnetUpdate(BaseModel):
    """Payload de actualización parcial para `CmdbSubnet`."""
    cidr: Optional[str] = None
    name: Optional[str] = None
    vlan_id: Optional[int] = None
    gateway: Optional[str] = None
    subnet_mask: Optional[str] = None
    dns_servers: Optional[str] = None
    environment: Optional[str] = None
    location_id: Optional[int] = None
    notes: Optional[str] = None


class CmdbIpAddressInput(BaseModel):
    """Datos de entrada validados para `CmdbIpAddress`."""
    id: Optional[int] = None
    subnet_id: Optional[int] = None
    ip_address: str
    subnet_mask: str = "255.255.255.0"
    gateway: str = ""
    vlan_id: Optional[int] = None
    ip_role: str = "primary_service"
    interface_name: str = "eth0"
    mac_address: str = ""
    fqdn: str = ""
    is_heartbeat_ip: bool = False
    allocation_status: str = "assigned"
    notes: str = ""


class CmdbAssetCreate(BaseModel):
    """Payload de creación para `CmdbAsset`."""
    code: str
    name: str
    hostname: str = ""
    fqdn: str = ""
    asset_class: str = "virtual_machine"
    environment: str = "production"
    criticality: str = "high"
    lifecycle_status: str = "active"
    os_or_firmware: str = ""
    cpu_cores: int = 0
    ram_gb: float = 0.0
    storage_gb: float = 0.0
    hypervisor_or_platform: str = ""
    model_name: str = ""
    serial_or_uuid: str = ""
    owner_team: str = "Sistemas & Infraestructura"
    responsible_person: str = "Alex Geng"
    host_rack_device_id: Optional[int] = None
    parent_asset_id: Optional[int] = None
    floor_id: Optional[int] = None
    floor_device_type: Optional[str] = None
    linked_rack_id: Optional[int] = None
    room_code: Optional[str] = None
    monitoring_enabled: bool = False
    monitor_method: str = "icmp"
    monitor_port: int = 22
    management_links: List[Dict[str, Any]] = []
    custom_fields: Dict[str, Any] = {}
    notes: str = ""
    ip_addresses: List[CmdbIpAddressInput] = []
    certscope_enabled: Optional[bool] = False
    certscope_port: int = 443
    certscope_renewal_type: str = "manual"
    certscope_sni: str = ""


class CmdbAssetUpdate(BaseModel):
    """Payload de actualización parcial para `CmdbAsset`."""
    code: Optional[str] = None
    name: Optional[str] = None
    hostname: Optional[str] = None
    fqdn: Optional[str] = None
    asset_class: Optional[str] = None
    environment: Optional[str] = None
    criticality: Optional[str] = None
    lifecycle_status: Optional[str] = None
    os_or_firmware: Optional[str] = None
    cpu_cores: Optional[int] = None
    ram_gb: Optional[float] = None
    storage_gb: Optional[float] = None
    hypervisor_or_platform: Optional[str] = None
    model_name: Optional[str] = None
    serial_or_uuid: Optional[str] = None
    owner_team: Optional[str] = None
    responsible_person: Optional[str] = None
    host_rack_device_id: Optional[int] = None
    parent_asset_id: Optional[int] = None
    floor_id: Optional[int] = None
    floor_device_type: Optional[str] = None
    linked_rack_id: Optional[int] = None
    room_code: Optional[str] = None
    monitoring_enabled: Optional[bool] = None
    monitor_method: Optional[str] = None
    monitor_port: Optional[int] = None
    management_links: Optional[List[Dict[str, Any]]] = None
    custom_fields: Optional[Dict[str, Any]] = None
    notes: Optional[str] = None
    ip_addresses: Optional[List[CmdbIpAddressInput]] = None
    certscope_enabled: Optional[bool] = None
    certscope_port: Optional[int] = None
    certscope_renewal_type: Optional[str] = None
    certscope_sni: Optional[str] = None


class CmdbVerifyIpRequest(BaseModel):
    """Petición de operación (`CmdbVerifyIpRequest`)."""
    target_ip: str = ""
    subnet_id: Optional[int] = None
    ports: List[int] = [22, 80, 443, 3389, 445, 8006, 902, 161]
    timeout_sec: float = 0.6
    count_limit: int = 254
    only_suggest_free: bool = False


class CmdbDiscoveredHostItem(BaseModel):
    """Esquema serializado de transferencia (`CmdbDiscoveredHostItem`)."""
    ip_address: str
    subnet_mask: str = ""
    hostname: str = ""
    fqdn: str = ""
    mac_address: str = ""
    asset_class: str = "other_machine"
    environment: str = "production"
    location_id: Optional[int] = None
    open_ports: List[int] = []
    notes: str = ""


class CmdbImportDiscoveredRequest(BaseModel):
    """Petición de operación (`CmdbImportDiscoveredRequest`)."""
    register_subnet_cidr: Optional[str] = None
    subnet_name: Optional[str] = None
    vlan_id: Optional[int] = None
    location_id: Optional[int] = None
    items: List[CmdbDiscoveredHostItem] = []


# ==============================================================================
# ESQUEMAS DE '4. RED & HOST', CONECTORES, ALERTAS MATRICIALES Y WEBHOOKS ANSIBLE
# ==============================================================================

class HostGroupInput(BaseModel):
    """Datos de entrada validados para `HostGroup`."""
    code: str
    name: str
    category: str = "infrastructure"
    environment: str = "production"
    color_hex: str = "#1E3A8A"
    member_asset_ids: List[int] = []
    description: str = ""


class ServiceCheckInput(BaseModel):
    """Datos de entrada validados para `ServiceCheck`."""
    asset_id: int
    service_name: str
    check_type: str = "https"  # icmp | http | https | tcp | udp | ssh | dns | snmp | apache | nginx | haproxy | docker | proxmox | vmware | postgres | mysql | redis | node_exporter | windows_exporter
    target_ip_or_url: str = ""
    port: int = 443
    expected_status_code: int = 200
    expected_string: str = ""
    max_check_attempts: int = 3
    is_primary_heartbeat: bool = False
    enabled: bool = True
    check_config: Dict[str, Any] = {}


class LogicalLinkInput(BaseModel):
    """Datos de entrada validados para `LogicalLink`."""
    source_asset_id: int
    target_asset_id: int
    link_type: str = "custom_logical"
    source_interface: str = ""
    target_interface: str = ""
    protocol_label: str = "TCP/IP"
    vlan_id: Optional[int] = None
    bandwidth_mbps: float = 0.0
    notes: str = ""


class InfraConnectorInput(BaseModel):
    """Datos de entrada validados para `InfraConnector`."""
    name: str
    connector_type: str  # snmp_switch | proxmox_ve | vmware_vsphere | hyperv | kvm_libvirt | xcpng | docker_engine | portainer | kubernetes | apache_status | nginx_status | haproxy_stats | postgresql | mysql_mariadb | redis | node_exporter | windows_exporter
    endpoint_host: str
    endpoint_port: int = 161
    auth_username_or_community: str = "public"
    auth_secret: str = ""
    linked_asset_id: Optional[int] = None
    linked_rack_device_id: Optional[int] = None
    extra_settings: Dict[str, Any] = {}
    enabled: bool = True


class SnmpWalkDiscoveryRequest(BaseModel):
    """Petición de operación (`SnmpWalkDiscoveryRequest`)."""
    target_ip: str
    community: str = "public"
    snmp_version: str = "v2c"
    port: int = 161
    asset_id: Optional[int] = None
    rack_device_id: Optional[int] = None
    sync_ports_to_rack_device: bool = True


class AlertContactInput(BaseModel):
    """Datos de entrada validados para `AlertContact`."""
    code: str
    full_name: str
    role_title: str = "Ingeniero de Sistemas"
    email: str
    phone_or_telegram: str = ""
    personal_webhook_url: str = ""
    schedule_period: str = "24x7"
    notify_on_down: bool = True
    notify_on_critical: bool = True
    notify_on_warning: bool = True
    notify_on_unreachable: bool = False
    notify_on_recovery: bool = True
    active: bool = True
    notes: str = ""


class AlertContactGroupInput(BaseModel):
    """Datos de entrada validados para `AlertContactGroup`."""
    code: str
    name: str
    description: str = ""
    group_email: str = ""
    channel_webhook_url: str = ""
    member_contact_ids: List[int] = []


class NotificationRoutingRuleInput(BaseModel):
    """Datos de entrada validados para `NotificationRoutingRule`."""
    name: str
    description: str = ""
    enabled: bool = True
    scope_type: str = "host_group"  # all | host_group | single_host | asset_class | service_type
    host_group_id: Optional[int] = None
    asset_id: Optional[int] = None
    asset_class_filter: str = ""
    service_type_filter: str = ""
    contact_group_ids: List[int] = []
    contact_ids: List[int] = []
    send_email: bool = True
    send_webhook: bool = True
    only_on_hard_state: bool = True


class MaintenanceWindowInput(BaseModel):
    """Datos de entrada validados para `MaintenanceWindow`."""
    title: str
    reason: str = "Mantenimiento programado"
    created_by: str = "admin"
    scope_type: str = "single_host"  # single_host | host_group | ip_or_hostname_list
    asset_id: Optional[int] = None
    host_group_id: Optional[int] = None
    target_matches: List[str] = []
    duration_minutes: int = 60
    suppress_notifications: bool = True


class SmtpAlertConfigInput(BaseModel):
    """Datos de entrada validados para `SmtpAlertConfig`."""
    smtp_host: str = "smtp.empresa.local"
    smtp_port: int = 587
    use_tls: bool = True
    smtp_username: str = "alertas-rackdoc@empresa.local"
    smtp_password: str = ""
    from_email: str = "RackDoc Monitor & CMDB <alertas-rackdoc@empresa.local>"
    global_webhook_url: str = ""
    enabled: bool = True


# Webhooks Idempotentes para Ansible y Agentes IA (y Alta/Edición Avanzada Web de Hosts y VMs)
class AnsibleHostUpsertWebhook(BaseModel):
    """Payload de webhook de automatización (`AnsibleHostUpsertWebhook`)."""
    asset_id: Optional[int] = None
    code: Optional[str] = None
    name: Optional[str] = None
    hostname: str
    fqdn: str = ""
    asset_class: str = "virtual_machine"  # physical_server | virtual_machine | container_lxc | network_security | storage_san_nas | cluster_vip | custom
    custom_asset_class_label: str = ""
    environment: str = "production"
    criticality: str = "high"
    os_or_firmware: str = ""
    cpu_cores: int = 0
    ram_gb: float = 0.0
    storage_gb: float = 0.0
    # Modo de alojamiento: 'cluster_pool' (VMware/Proxmox/Hyper-V sin máquina fija) | 'physical_rack_server' (Máquina concreta) | 'standalone' (Independiente)
    hosting_mode: str = "cluster_pool"
    cluster_or_pool_name: str = ""
    hypervisor_or_platform: str = ""
    host_rack_device_code: Optional[str] = None
    parent_asset_code: Optional[str] = None
    owner_team: str = "Sistemas & DevOps"
    responsible_person: str = "Alex Geng"
    serial_or_uuid: str = ""
    floor_id: Optional[int] = None
    floor_device_type: Optional[str] = None
    room_code: Optional[str] = None
    linked_rack_id: Optional[int] = None
    primary_ip: str
    primary_subnet_mask: str = "255.255.255.0"
    primary_gateway: str = ""
    primary_vlan_id: Optional[int] = None
    primary_mac_address: str = ""
    additional_ips: List[Dict[str, Any]] = []
    host_groups: List[str] = []  # Lista de códigos de HostGroup (se crean si no existen)
    # Sección 1: Healthchecks, Monitorización en Background & Prometheus (Activable / Desactivable)
    monitoring_enabled: bool = True
    enable_icmp_ping: bool = True
    replace_checks: bool = False
    heartbeat_config: Optional[Dict[str, Any]] = None
    exporters: List[Dict[str, Any]] = []  # Ej: [{"type": "node_exporter", "port": 9100}, {"type": "custom_exporter", "name": "JVM Metrics", "port": 9404, "url": "http://.../metrics"}]
    heartbeats: List[Dict[str, Any]] = []  # Ej: [{"name": "HTTPS Web", "type": "https", "url": "https://...", "port": 443}]
    # Sección 2: Conectar desde el Frontend (SSH / HTTP / HTTPS — Activable / Desactivable)
    connect_enabled: bool = True
    ssh_enabled: bool = True
    ssh_user: str = "root"
    ssh_port: int = 22
    ssh_host: str = ""
    web_http_enabled: bool = False
    web_http_url: str = ""
    web_https_enabled: bool = False
    web_https_url: str = ""
    connect_config: Optional[Dict[str, Any]] = None
    # Sección 3: CertScope — Auditoría y Caducidad de Certificados SSL/TLS
    certscope_enabled: Optional[bool] = False
    certscope_port: int = 443
    certscope_sni: str = ""
    certscope_renewal_type: str = "manual"
    certscope_contact_group_ids: List[int] = []
    certscope_contact_ids: List[int] = []
    certscope_notify_emails: str = ""
    notes: str = "Registrado/actualizado en Red & Host y CMDB"


class AnsibleHostDecommissionWebhook(BaseModel):
    """Payload de webhook de automatización (`AnsibleHostDecommissionWebhook`)."""
    code: Optional[str] = None
    hostname: Optional[str] = None
    ip_address: Optional[str] = None
    delete_permanently: bool = False
    reason: str = "Baja ejecutada desde Playbook Ansible"


class AnsibleMaintenanceWebhook(BaseModel):
    """Payload de webhook de automatización (`AnsibleMaintenanceWebhook`)."""
    action: str = "start"  # start | stop
    title: str = "Mantenimiento Automático Ansible"
    reason: str = "Despliegue / Parcheo automatizado con Ansible"
    created_by: str = "ansible-playbook"
    duration_minutes: int = 45
    host_group_code: Optional[str] = None
    targets: List[str] = []  # Hostnames, códigos CMDB o direcciones IP


class AnsibleContactsRoutingWebhook(BaseModel):
    """Payload de webhook de automatización (`AnsibleContactsRoutingWebhook`)."""
    contacts: List[AlertContactInput] = []
    contact_groups: List[Dict[str, Any]] = []
    host_groups: List[Dict[str, Any]] = []
    routing_rules: List[Dict[str, Any]] = []


class TechStackDiagramInput(BaseModel):
    """Datos de entrada validados para `TechStackDiagram`."""
    code: str
    name: str
    description: str = ""
    business_service: str = "Plataforma Digital & Negocio"
    environment: str = "production"
    owner_team: str = "DevOps & Arquitectura"
    criticality: str = "critical"
    map_scale: float = 1.0
    canvas_boxes: Optional[List[Dict[str, Any]]] = None


class TechStackDiagramUpdateInput(BaseModel):
    """Payload de actualización parcial para `TechStackDiagram`."""
    name: Optional[str] = None
    description: Optional[str] = None
    business_service: Optional[str] = None
    environment: Optional[str] = None
    owner_team: Optional[str] = None
    criticality: Optional[str] = None
    map_scale: Optional[float] = None
    canvas_boxes: Optional[List[Dict[str, Any]]] = None


class TechStackNodeInput(BaseModel):
    """Datos de entrada validados para `TechStackNode`."""
    stack_id: int
    asset_id: int
    role_layer: str = "general"
    custom_label: str = ""
    pos_x: float = 0.25
    pos_y: float = 0.35
    width_px: float = 200.0
    height_px: float = 110.0
    ssh_enabled: bool = True
    ssh_user: str = "root"
    ssh_port: int = 22


class TechStackNodeMoveInput(BaseModel):
    """Datos de entrada validados para `TechStackNodeMove`."""
    pos_x: Optional[float] = None
    pos_y: Optional[float] = None
    width_px: Optional[float] = None
    height_px: Optional[float] = None
    role_layer: Optional[str] = None
    custom_label: Optional[str] = None
    ssh_enabled: Optional[bool] = None
    ssh_user: Optional[str] = None
    ssh_port: Optional[int] = None


class TechStackEdgeInput(BaseModel):
    """Datos de entrada validados para `TechStackEdge`."""
    stack_id: int
    source_node_id: int
    target_node_id: int
    protocol_label: str = "HTTPS :443"
    port: int = 443
    notes: str = ""


class TechStackEdgeUpdateInput(BaseModel):
    """Payload de actualización parcial para `TechStackEdge`."""
    protocol_label: Optional[str] = None
    port: Optional[int] = None
    notes: Optional[str] = None


class HostSshCommandInput(BaseModel):
    """Datos de entrada validados para `HostSshCommand`."""
    asset_id: int
    command: str = "uptime && df -h / && free -m"
    ssh_user: str = "root"
    ssh_port: int = 22


# ==============================================================================
# ESQUEMAS DE '7. CERTSCOPE — AUDITORÍA Y CADUCIDAD DE CERTIFICADOS SSL/TLS'
# ==============================================================================

class TlsCertificateProbeRequest(BaseModel):
    """Petición de operación (`TlsCertificateProbeRequest`)."""
    target_host: str = ""
    port: int = 443
    sni_hostname: str = ""
    pem_text: str = ""
    timeout_sec: float = 4.0


class TlsCertificateCreate(BaseModel):
    """Payload de creación para `TlsCertificate`."""
    code: Optional[str] = None
    name: str
    check_mode: str = "https_live"  # https_live | manual
    target_host: str = ""
    port: int = 443
    sni_hostname: str = ""
    environment: str = "production"
    # Campos manuales u obtenidos tras verificación / PEM
    common_name: str = ""
    issuer_cn: str = ""
    issuer_org: str = ""
    san_domains: List[str] = []
    serial_number: str = ""
    fingerprint_sha256: str = ""
    valid_from: Optional[str] = None
    valid_until: Optional[str] = None
    pem_text: str = ""
    # Renovación y Alertas
    renewal_type: str = "manual"  # manual | auto_acme
    warn_days_before: int = 30
    critical_days_before: int = 7
    auto_probe_enabled: bool = True
    notify_enabled: bool = True
    contact_group_ids: List[int] = []
    contact_ids: List[int] = []
    notify_emails: str = ""
    owner_team: str = "Seguridad & Sistemas"
    responsible_person: str = "Alex Geng"
    # Enlaces cruzados con CMDB, Rack Editor, Datacenter Planta y Sede
    asset_id: Optional[int] = None
    rack_device_id: Optional[int] = None
    floor_device_id: Optional[int] = None
    location_id: Optional[int] = None
    renewal_notes: str = ""
    notes: str = ""


class TlsCertificateUpdate(BaseModel):
    """Payload de actualización parcial para `TlsCertificate`."""
    code: Optional[str] = None
    name: Optional[str] = None
    check_mode: Optional[str] = None
    target_host: Optional[str] = None
    port: Optional[int] = None
    sni_hostname: Optional[str] = None
    environment: Optional[str] = None
    common_name: Optional[str] = None
    issuer_cn: Optional[str] = None
    issuer_org: Optional[str] = None
    san_domains: Optional[List[str]] = None
    serial_number: Optional[str] = None
    fingerprint_sha256: Optional[str] = None
    valid_from: Optional[str] = None
    valid_until: Optional[str] = None
    pem_text: Optional[str] = None
    renewal_type: Optional[str] = None
    warn_days_before: Optional[int] = None
    critical_days_before: Optional[int] = None
    auto_probe_enabled: Optional[bool] = None
    notify_enabled: Optional[bool] = None
    contact_group_ids: Optional[List[int]] = None
    contact_ids: Optional[List[int]] = None
    notify_emails: Optional[str] = None
    owner_team: Optional[str] = None
    responsible_person: Optional[str] = None
    asset_id: Optional[int] = None
    rack_device_id: Optional[int] = None
    floor_device_id: Optional[int] = None
    location_id: Optional[int] = None
    renewal_notes: Optional[str] = None
    notes: Optional[str] = None


class TlsCertificateNotifyRequest(BaseModel):
    """Petición de operación (`TlsCertificateNotifyRequest`)."""
    custom_message: str = ""
    force_send: bool = True








