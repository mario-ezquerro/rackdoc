"""Baseline: esquema inicial completo de RackDoc.

Generada con autogenerate a partir de los modelos. Las bases de datos que ya
existían (creadas con create_all + los ALTER TABLE manuales de versiones
anteriores) se marcan directamente en esta revisión al arrancar, sin reaplicarla.

Revision ID: 36d83056894d
Revises: 
Create Date: 2026-11-09 16:42:13.639356
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = '36d83056894d'
down_revision: Union[str, None] = None
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table('ad_servers',
    sa.Column('id', sa.Integer(), nullable=False),
    sa.Column('name', sa.String(length=120), nullable=False),
    sa.Column('ldap_url', sa.String(length=255), nullable=False),
    sa.Column('domain', sa.String(length=120), nullable=True),
    sa.Column('base_dn', sa.String(length=255), nullable=True),
    sa.Column('bind_dn', sa.String(length=255), nullable=True),
    sa.Column('bind_password', sa.String(length=255), nullable=True),
    sa.Column('user_filter', sa.String(length=255), nullable=True),
    sa.Column('default_role', sa.String(length=30), nullable=True),
    sa.Column('group_role_mapping', sa.JSON(), nullable=True),
    sa.Column('enabled', sa.Boolean(), nullable=True),
    sa.Column('created_at', sa.DateTime(), nullable=True),
    sa.PrimaryKeyConstraint('id')
    )
    with op.batch_alter_table('ad_servers', schema=None) as batch_op:
        batch_op.create_index(batch_op.f('ix_ad_servers_id'), ['id'], unique=False)

    op.create_table('device_templates',
    sa.Column('id', sa.Integer(), nullable=False),
    sa.Column('library_group', sa.String(length=80), nullable=False),
    sa.Column('category', sa.String(length=50), nullable=False),
    sa.Column('manufacturer', sa.String(length=100), nullable=True),
    sa.Column('model_name', sa.String(length=120), nullable=False),
    sa.Column('u_height', sa.Integer(), nullable=True),
    sa.Column('is_full_depth', sa.Boolean(), nullable=True),
    sa.Column('default_color', sa.String(length=20), nullable=True),
    sa.Column('layout_spec', sa.JSON(), nullable=True),
    sa.PrimaryKeyConstraint('id')
    )
    with op.batch_alter_table('device_templates', schema=None) as batch_op:
        batch_op.create_index(batch_op.f('ix_device_templates_category'), ['category'], unique=False)
        batch_op.create_index(batch_op.f('ix_device_templates_id'), ['id'], unique=False)
        batch_op.create_index(batch_op.f('ix_device_templates_library_group'), ['library_group'], unique=False)

    op.create_table('floor_device_custom_types',
    sa.Column('id', sa.Integer(), nullable=False),
    sa.Column('category_key', sa.String(length=64), nullable=False),
    sa.Column('group_name', sa.String(length=80), nullable=True),
    sa.Column('label', sa.String(length=120), nullable=False),
    sa.Column('prefix', sa.String(length=24), nullable=True),
    sa.Column('icon_key', sa.String(length=50), nullable=True),
    sa.Column('pin_color_hex', sa.String(length=20), nullable=True),
    sa.Column('default_port_hint', sa.String(length=100), nullable=True),
    sa.Column('is_sensor', sa.Boolean(), nullable=True),
    sa.PrimaryKeyConstraint('id')
    )
    with op.batch_alter_table('floor_device_custom_types', schema=None) as batch_op:
        batch_op.create_index(batch_op.f('ix_floor_device_custom_types_category_key'), ['category_key'], unique=True)
        batch_op.create_index(batch_op.f('ix_floor_device_custom_types_id'), ['id'], unique=False)

    op.create_table('locations',
    sa.Column('id', sa.Integer(), nullable=False),
    sa.Column('code', sa.String(length=32), nullable=False),
    sa.Column('name', sa.String(length=120), nullable=False),
    sa.Column('latitude', sa.Float(), nullable=True),
    sa.Column('longitude', sa.Float(), nullable=True),
    sa.Column('address', sa.String(length=255), nullable=True),
    sa.Column('description', sa.Text(), nullable=True),
    sa.Column('map_image_url', sa.String(length=500), nullable=True),
    sa.Column('plan_pos_x', sa.Float(), nullable=True),
    sa.Column('plan_pos_y', sa.Float(), nullable=True),
    sa.Column('plan_width', sa.Float(), nullable=True),
    sa.Column('plan_height', sa.Float(), nullable=True),
    sa.Column('map_scale', sa.Float(), nullable=True),
    sa.PrimaryKeyConstraint('id')
    )
    with op.batch_alter_table('locations', schema=None) as batch_op:
        batch_op.create_index(batch_op.f('ix_locations_code'), ['code'], unique=True)
        batch_op.create_index(batch_op.f('ix_locations_id'), ['id'], unique=False)

    op.create_table('network_alert_contact_groups',
    sa.Column('id', sa.Integer(), nullable=False),
    sa.Column('code', sa.String(length=64), nullable=False),
    sa.Column('name', sa.String(length=160), nullable=False),
    sa.Column('description', sa.Text(), nullable=True),
    sa.Column('group_email', sa.String(length=180), nullable=True),
    sa.Column('channel_webhook_url', sa.String(length=255), nullable=True),
    sa.Column('member_contact_ids', sa.JSON(), nullable=True),
    sa.PrimaryKeyConstraint('id')
    )
    with op.batch_alter_table('network_alert_contact_groups', schema=None) as batch_op:
        batch_op.create_index(batch_op.f('ix_network_alert_contact_groups_code'), ['code'], unique=True)
        batch_op.create_index(batch_op.f('ix_network_alert_contact_groups_id'), ['id'], unique=False)

    op.create_table('network_alert_contacts',
    sa.Column('id', sa.Integer(), nullable=False),
    sa.Column('code', sa.String(length=64), nullable=False),
    sa.Column('full_name', sa.String(length=140), nullable=False),
    sa.Column('role_title', sa.String(length=120), nullable=True),
    sa.Column('email', sa.String(length=180), nullable=False),
    sa.Column('phone_or_telegram', sa.String(length=80), nullable=True),
    sa.Column('personal_webhook_url', sa.String(length=255), nullable=True),
    sa.Column('schedule_period', sa.String(length=32), nullable=True),
    sa.Column('notify_on_down', sa.Boolean(), nullable=True),
    sa.Column('notify_on_critical', sa.Boolean(), nullable=True),
    sa.Column('notify_on_warning', sa.Boolean(), nullable=True),
    sa.Column('notify_on_unreachable', sa.Boolean(), nullable=True),
    sa.Column('notify_on_recovery', sa.Boolean(), nullable=True),
    sa.Column('active', sa.Boolean(), nullable=True),
    sa.Column('notes', sa.Text(), nullable=True),
    sa.PrimaryKeyConstraint('id')
    )
    with op.batch_alter_table('network_alert_contacts', schema=None) as batch_op:
        batch_op.create_index(batch_op.f('ix_network_alert_contacts_code'), ['code'], unique=True)
        batch_op.create_index(batch_op.f('ix_network_alert_contacts_id'), ['id'], unique=False)

    op.create_table('network_alert_logs',
    sa.Column('id', sa.Integer(), nullable=False),
    sa.Column('created_at', sa.DateTime(), nullable=True),
    sa.Column('asset_code', sa.String(length=80), nullable=True),
    sa.Column('service_name', sa.String(length=120), nullable=True),
    sa.Column('event_state', sa.String(length=40), nullable=True),
    sa.Column('matched_rule_name', sa.String(length=160), nullable=True),
    sa.Column('recipients_summary', sa.Text(), nullable=True),
    sa.Column('delivery_channel', sa.String(length=48), nullable=True),
    sa.Column('delivery_status', sa.String(length=32), nullable=True),
    sa.Column('detail', sa.Text(), nullable=True),
    sa.PrimaryKeyConstraint('id')
    )
    with op.batch_alter_table('network_alert_logs', schema=None) as batch_op:
        batch_op.create_index(batch_op.f('ix_network_alert_logs_created_at'), ['created_at'], unique=False)
        batch_op.create_index(batch_op.f('ix_network_alert_logs_id'), ['id'], unique=False)

    op.create_table('network_host_groups',
    sa.Column('id', sa.Integer(), nullable=False),
    sa.Column('code', sa.String(length=64), nullable=False),
    sa.Column('name', sa.String(length=160), nullable=False),
    sa.Column('category', sa.String(length=48), nullable=True),
    sa.Column('environment', sa.String(length=32), nullable=True),
    sa.Column('color_hex', sa.String(length=16), nullable=True),
    sa.Column('member_asset_ids', sa.JSON(), nullable=True),
    sa.Column('description', sa.Text(), nullable=True),
    sa.Column('created_at', sa.DateTime(), nullable=True),
    sa.PrimaryKeyConstraint('id')
    )
    with op.batch_alter_table('network_host_groups', schema=None) as batch_op:
        batch_op.create_index(batch_op.f('ix_network_host_groups_code'), ['code'], unique=True)
        batch_op.create_index(batch_op.f('ix_network_host_groups_id'), ['id'], unique=False)

    op.create_table('network_smtp_config',
    sa.Column('id', sa.Integer(), nullable=False),
    sa.Column('smtp_host', sa.String(length=180), nullable=True),
    sa.Column('smtp_port', sa.Integer(), nullable=True),
    sa.Column('use_tls', sa.Boolean(), nullable=True),
    sa.Column('smtp_username', sa.String(length=160), nullable=True),
    sa.Column('smtp_password', sa.String(length=255), nullable=True),
    sa.Column('from_email', sa.String(length=180), nullable=True),
    sa.Column('global_webhook_url', sa.String(length=255), nullable=True),
    sa.Column('enabled', sa.Boolean(), nullable=True),
    sa.PrimaryKeyConstraint('id')
    )
    with op.batch_alter_table('network_smtp_config', schema=None) as batch_op:
        batch_op.create_index(batch_op.f('ix_network_smtp_config_id'), ['id'], unique=False)

    op.create_table('tech_stack_diagrams',
    sa.Column('id', sa.Integer(), nullable=False),
    sa.Column('code', sa.String(length=80), nullable=False),
    sa.Column('name', sa.String(length=180), nullable=False),
    sa.Column('description', sa.Text(), nullable=True),
    sa.Column('business_service', sa.String(length=140), nullable=True),
    sa.Column('environment', sa.String(length=32), nullable=True),
    sa.Column('owner_team', sa.String(length=120), nullable=True),
    sa.Column('criticality', sa.String(length=24), nullable=True),
    sa.Column('map_scale', sa.Float(), nullable=True),
    sa.Column('canvas_boxes', sa.JSON(), nullable=True),
    sa.Column('created_at', sa.DateTime(), nullable=True),
    sa.PrimaryKeyConstraint('id')
    )
    with op.batch_alter_table('tech_stack_diagrams', schema=None) as batch_op:
        batch_op.create_index(batch_op.f('ix_tech_stack_diagrams_code'), ['code'], unique=True)
        batch_op.create_index(batch_op.f('ix_tech_stack_diagrams_id'), ['id'], unique=False)

    op.create_table('cmdb_subnets',
    sa.Column('id', sa.Integer(), nullable=False),
    sa.Column('cidr', sa.String(length=64), nullable=False),
    sa.Column('name', sa.String(length=120), nullable=False),
    sa.Column('vlan_id', sa.Integer(), nullable=True),
    sa.Column('gateway', sa.String(length=64), nullable=True),
    sa.Column('subnet_mask', sa.String(length=64), nullable=True),
    sa.Column('dns_servers', sa.String(length=255), nullable=True),
    sa.Column('environment', sa.String(length=40), nullable=True),
    sa.Column('location_id', sa.Integer(), nullable=True),
    sa.Column('notes', sa.Text(), nullable=True),
    sa.Column('created_at', sa.DateTime(), nullable=True),
    sa.ForeignKeyConstraint(['location_id'], ['locations.id'], ondelete='SET NULL'),
    sa.PrimaryKeyConstraint('id')
    )
    with op.batch_alter_table('cmdb_subnets', schema=None) as batch_op:
        batch_op.create_index(batch_op.f('ix_cmdb_subnets_cidr'), ['cidr'], unique=True)
        batch_op.create_index(batch_op.f('ix_cmdb_subnets_id'), ['id'], unique=False)

    op.create_table('floors',
    sa.Column('id', sa.Integer(), nullable=False),
    sa.Column('location_id', sa.Integer(), nullable=False),
    sa.Column('name', sa.String(length=100), nullable=False),
    sa.Column('level_number', sa.Integer(), nullable=True),
    sa.Column('map_image_url', sa.String(length=500), nullable=True),
    sa.Column('map_scale', sa.Float(), nullable=True),
    sa.ForeignKeyConstraint(['location_id'], ['locations.id'], ondelete='CASCADE'),
    sa.PrimaryKeyConstraint('id')
    )
    with op.batch_alter_table('floors', schema=None) as batch_op:
        batch_op.create_index(batch_op.f('ix_floors_id'), ['id'], unique=False)

    op.create_table('users',
    sa.Column('id', sa.Integer(), nullable=False),
    sa.Column('username', sa.String(length=80), nullable=False),
    sa.Column('email', sa.String(length=120), nullable=False),
    sa.Column('full_name', sa.String(length=120), nullable=False),
    sa.Column('password_hash', sa.String(length=255), nullable=False),
    sa.Column('role', sa.String(length=30), nullable=False),
    sa.Column('auth_source', sa.String(length=30), nullable=True),
    sa.Column('ad_server_id', sa.Integer(), nullable=True),
    sa.Column('ad_dn', sa.String(length=255), nullable=True),
    sa.Column('is_active', sa.Boolean(), nullable=True),
    sa.Column('created_at', sa.DateTime(), nullable=True),
    sa.ForeignKeyConstraint(['ad_server_id'], ['ad_servers.id'], ondelete='SET NULL'),
    sa.PrimaryKeyConstraint('id')
    )
    with op.batch_alter_table('users', schema=None) as batch_op:
        batch_op.create_index(batch_op.f('ix_users_email'), ['email'], unique=False)
        batch_op.create_index(batch_op.f('ix_users_id'), ['id'], unique=False)
        batch_op.create_index(batch_op.f('ix_users_username'), ['username'], unique=True)

    op.create_table('rooms',
    sa.Column('id', sa.Integer(), nullable=False),
    sa.Column('floor_id', sa.Integer(), nullable=False),
    sa.Column('name', sa.String(length=100), nullable=False),
    sa.Column('width_m', sa.Float(), nullable=True),
    sa.Column('depth_m', sa.Float(), nullable=True),
    sa.Column('notes', sa.Text(), nullable=True),
    sa.Column('map_image_url', sa.String(length=500), nullable=True),
    sa.ForeignKeyConstraint(['floor_id'], ['floors.id'], ondelete='CASCADE'),
    sa.PrimaryKeyConstraint('id')
    )
    with op.batch_alter_table('rooms', schema=None) as batch_op:
        batch_op.create_index(batch_op.f('ix_rooms_id'), ['id'], unique=False)

    op.create_table('aisles',
    sa.Column('id', sa.Integer(), nullable=False),
    sa.Column('room_id', sa.Integer(), nullable=False),
    sa.Column('code', sa.String(length=32), nullable=False),
    sa.Column('name', sa.String(length=100), nullable=False),
    sa.Column('aisle_type', sa.String(length=32), nullable=True),
    sa.ForeignKeyConstraint(['room_id'], ['rooms.id'], ondelete='CASCADE'),
    sa.PrimaryKeyConstraint('id')
    )
    with op.batch_alter_table('aisles', schema=None) as batch_op:
        batch_op.create_index(batch_op.f('ix_aisles_id'), ['id'], unique=False)

    op.create_table('racks',
    sa.Column('id', sa.Integer(), nullable=False),
    sa.Column('room_id', sa.Integer(), nullable=False),
    sa.Column('aisle_id', sa.Integer(), nullable=True),
    sa.Column('code', sa.String(length=50), nullable=False),
    sa.Column('name', sa.String(length=120), nullable=False),
    sa.Column('total_units', sa.Integer(), nullable=True),
    sa.Column('manufacturer', sa.String(length=100), nullable=True),
    sa.Column('model_name', sa.String(length=100), nullable=True),
    sa.Column('serial_number', sa.String(length=100), nullable=True),
    sa.Column('responsible_person', sa.String(length=120), nullable=True),
    sa.Column('purchase_date', sa.String(length=30), nullable=True),
    sa.Column('operation_start', sa.String(length=30), nullable=True),
    sa.Column('pos_x', sa.Float(), nullable=True),
    sa.Column('pos_y', sa.Float(), nullable=True),
    sa.Column('width_px', sa.Float(), nullable=True),
    sa.Column('depth_px', sa.Float(), nullable=True),
    sa.Column('rotation_deg', sa.Integer(), nullable=True),
    sa.Column('notes', sa.Text(), nullable=True),
    sa.ForeignKeyConstraint(['aisle_id'], ['aisles.id'], ondelete='SET NULL'),
    sa.ForeignKeyConstraint(['room_id'], ['rooms.id'], ondelete='CASCADE'),
    sa.PrimaryKeyConstraint('id')
    )
    with op.batch_alter_table('racks', schema=None) as batch_op:
        batch_op.create_index(batch_op.f('ix_racks_code'), ['code'], unique=False)
        batch_op.create_index(batch_op.f('ix_racks_id'), ['id'], unique=False)

    op.create_table('floor_devices',
    sa.Column('id', sa.Integer(), nullable=False),
    sa.Column('floor_id', sa.Integer(), nullable=False),
    sa.Column('room_id', sa.Integer(), nullable=True),
    sa.Column('room_code', sa.String(length=64), nullable=True),
    sa.Column('device_type', sa.String(length=40), nullable=False),
    sa.Column('code', sa.String(length=50), nullable=False),
    sa.Column('name', sa.String(length=120), nullable=False),
    sa.Column('pos_x', sa.Float(), nullable=True),
    sa.Column('pos_y', sa.Float(), nullable=True),
    sa.Column('fqdn', sa.String(length=255), nullable=True),
    sa.Column('ip_address', sa.String(length=64), nullable=True),
    sa.Column('mac_address', sa.String(length=64), nullable=True),
    sa.Column('vlan', sa.Integer(), nullable=True),
    sa.Column('monitoring_enabled', sa.Boolean(), nullable=True),
    sa.Column('monitor_method', sa.String(length=32), nullable=True),
    sa.Column('monitor_port', sa.Integer(), nullable=True),
    sa.Column('status', sa.String(length=32), nullable=True),
    sa.Column('last_ping_ms', sa.Float(), nullable=True),
    sa.Column('last_checked_at', sa.DateTime(), nullable=True),
    sa.Column('custom_fields', sa.JSON(), nullable=True),
    sa.Column('linked_rack_id', sa.Integer(), nullable=True),
    sa.Column('linked_rack_device_code', sa.String(length=80), nullable=True),
    sa.Column('linked_outlet_id', sa.Integer(), nullable=True),
    sa.Column('responsible_person', sa.String(length=120), nullable=True),
    sa.Column('contact_first_name', sa.String(length=80), nullable=True),
    sa.Column('contact_last_name', sa.String(length=80), nullable=True),
    sa.Column('contact_email', sa.String(length=120), nullable=True),
    sa.Column('contact_phone', sa.String(length=60), nullable=True),
    sa.Column('contact_job_title', sa.String(length=80), nullable=True),
    sa.Column('contact_department', sa.String(length=80), nullable=True),
    sa.Column('notes', sa.Text(), nullable=True),
    sa.ForeignKeyConstraint(['floor_id'], ['floors.id'], ondelete='CASCADE'),
    sa.ForeignKeyConstraint(['linked_outlet_id'], ['floor_devices.id'], ondelete='SET NULL'),
    sa.ForeignKeyConstraint(['linked_rack_id'], ['racks.id'], ondelete='SET NULL'),
    sa.ForeignKeyConstraint(['room_id'], ['rooms.id'], ondelete='SET NULL'),
    sa.PrimaryKeyConstraint('id')
    )
    with op.batch_alter_table('floor_devices', schema=None) as batch_op:
        batch_op.create_index(batch_op.f('ix_floor_devices_device_type'), ['device_type'], unique=False)
        batch_op.create_index(batch_op.f('ix_floor_devices_floor_id'), ['floor_id'], unique=False)
        batch_op.create_index(batch_op.f('ix_floor_devices_id'), ['id'], unique=False)

    op.create_table('rack_devices',
    sa.Column('id', sa.Integer(), nullable=False),
    sa.Column('rack_id', sa.Integer(), nullable=False),
    sa.Column('template_id', sa.Integer(), nullable=False),
    sa.Column('code', sa.String(length=40), nullable=False),
    sa.Column('name', sa.String(length=120), nullable=False),
    sa.Column('hostname', sa.String(length=120), nullable=True),
    sa.Column('fqdn', sa.String(length=255), nullable=True),
    sa.Column('start_u', sa.Integer(), nullable=False),
    sa.Column('mounted_face', sa.String(length=16), nullable=True),
    sa.Column('ip_address', sa.String(length=64), nullable=True),
    sa.Column('subnet_mask', sa.String(length=64), nullable=True),
    sa.Column('gateway', sa.String(length=64), nullable=True),
    sa.Column('mac_address', sa.String(length=64), nullable=True),
    sa.Column('vlan_mgmt', sa.Integer(), nullable=True),
    sa.Column('management_links', sa.JSON(), nullable=True),
    sa.Column('monitoring_enabled', sa.Boolean(), nullable=True),
    sa.Column('monitor_method', sa.String(length=32), nullable=True),
    sa.Column('monitor_port', sa.Integer(), nullable=True),
    sa.Column('status', sa.String(length=32), nullable=True),
    sa.Column('last_ping_ms', sa.Float(), nullable=True),
    sa.Column('last_checked_at', sa.DateTime(), nullable=True),
    sa.Column('serial_number', sa.String(length=100), nullable=True),
    sa.Column('custom_fields', sa.JSON(), nullable=True),
    sa.Column('notes', sa.Text(), nullable=True),
    sa.ForeignKeyConstraint(['rack_id'], ['racks.id'], ondelete='CASCADE'),
    sa.ForeignKeyConstraint(['template_id'], ['device_templates.id'], ),
    sa.PrimaryKeyConstraint('id')
    )
    with op.batch_alter_table('rack_devices', schema=None) as batch_op:
        batch_op.create_index(batch_op.f('ix_rack_devices_id'), ['id'], unique=False)

    op.create_table('cmdb_assets',
    sa.Column('id', sa.Integer(), nullable=False),
    sa.Column('code', sa.String(length=64), nullable=False),
    sa.Column('name', sa.String(length=160), nullable=False),
    sa.Column('hostname', sa.String(length=120), nullable=True),
    sa.Column('fqdn', sa.String(length=255), nullable=True),
    sa.Column('asset_class', sa.String(length=50), nullable=False),
    sa.Column('environment', sa.String(length=40), nullable=True),
    sa.Column('criticality', sa.String(length=32), nullable=True),
    sa.Column('lifecycle_status', sa.String(length=40), nullable=True),
    sa.Column('os_or_firmware', sa.String(length=120), nullable=True),
    sa.Column('cpu_cores', sa.Integer(), nullable=True),
    sa.Column('ram_gb', sa.Float(), nullable=True),
    sa.Column('storage_gb', sa.Float(), nullable=True),
    sa.Column('hypervisor_or_platform', sa.String(length=120), nullable=True),
    sa.Column('serial_or_uuid', sa.String(length=120), nullable=True),
    sa.Column('owner_team', sa.String(length=120), nullable=True),
    sa.Column('responsible_person', sa.String(length=120), nullable=True),
    sa.Column('sync_source', sa.String(length=32), nullable=True),
    sa.Column('rack_device_id', sa.Integer(), nullable=True),
    sa.Column('floor_device_id', sa.Integer(), nullable=True),
    sa.Column('host_rack_device_id', sa.Integer(), nullable=True),
    sa.Column('parent_asset_id', sa.Integer(), nullable=True),
    sa.Column('monitoring_enabled', sa.Boolean(), nullable=True),
    sa.Column('monitor_method', sa.String(length=32), nullable=True),
    sa.Column('monitor_port', sa.Integer(), nullable=True),
    sa.Column('status', sa.String(length=32), nullable=True),
    sa.Column('last_ping_ms', sa.Float(), nullable=True),
    sa.Column('last_checked_at', sa.DateTime(), nullable=True),
    sa.Column('management_links', sa.JSON(), nullable=True),
    sa.Column('custom_fields', sa.JSON(), nullable=True),
    sa.Column('notes', sa.Text(), nullable=True),
    sa.Column('created_at', sa.DateTime(), nullable=True),
    sa.Column('updated_at', sa.DateTime(), nullable=True),
    sa.ForeignKeyConstraint(['floor_device_id'], ['floor_devices.id'], ondelete='SET NULL'),
    sa.ForeignKeyConstraint(['host_rack_device_id'], ['rack_devices.id'], ondelete='SET NULL'),
    sa.ForeignKeyConstraint(['parent_asset_id'], ['cmdb_assets.id'], ondelete='SET NULL'),
    sa.ForeignKeyConstraint(['rack_device_id'], ['rack_devices.id'], ondelete='SET NULL'),
    sa.PrimaryKeyConstraint('id')
    )
    with op.batch_alter_table('cmdb_assets', schema=None) as batch_op:
        batch_op.create_index(batch_op.f('ix_cmdb_assets_asset_class'), ['asset_class'], unique=False)
        batch_op.create_index(batch_op.f('ix_cmdb_assets_code'), ['code'], unique=True)
        batch_op.create_index(batch_op.f('ix_cmdb_assets_floor_device_id'), ['floor_device_id'], unique=False)
        batch_op.create_index(batch_op.f('ix_cmdb_assets_host_rack_device_id'), ['host_rack_device_id'], unique=False)
        batch_op.create_index(batch_op.f('ix_cmdb_assets_id'), ['id'], unique=False)
        batch_op.create_index(batch_op.f('ix_cmdb_assets_rack_device_id'), ['rack_device_id'], unique=False)

    op.create_table('ports',
    sa.Column('id', sa.Integer(), nullable=False),
    sa.Column('rack_device_id', sa.Integer(), nullable=False),
    sa.Column('port_number', sa.String(length=32), nullable=False),
    sa.Column('label', sa.String(length=64), nullable=True),
    sa.Column('face', sa.String(length=16), nullable=True),
    sa.Column('port_type', sa.String(length=32), nullable=True),
    sa.Column('row_index', sa.Integer(), nullable=True),
    sa.Column('col_index', sa.Integer(), nullable=True),
    sa.Column('rel_x', sa.Float(), nullable=True),
    sa.Column('rel_y', sa.Float(), nullable=True),
    sa.Column('mac_or_ip', sa.String(length=64), nullable=True),
    sa.Column('vlan', sa.Integer(), nullable=True),
    sa.ForeignKeyConstraint(['rack_device_id'], ['rack_devices.id'], ondelete='CASCADE'),
    sa.PrimaryKeyConstraint('id')
    )
    with op.batch_alter_table('ports', schema=None) as batch_op:
        batch_op.create_index(batch_op.f('ix_ports_id'), ['id'], unique=False)

    op.create_table('cmdb_ip_addresses',
    sa.Column('id', sa.Integer(), nullable=False),
    sa.Column('asset_id', sa.Integer(), nullable=True),
    sa.Column('subnet_id', sa.Integer(), nullable=True),
    sa.Column('ip_address', sa.String(length=64), nullable=False),
    sa.Column('subnet_mask', sa.String(length=64), nullable=True),
    sa.Column('gateway', sa.String(length=64), nullable=True),
    sa.Column('vlan_id', sa.Integer(), nullable=True),
    sa.Column('ip_role', sa.String(length=40), nullable=False),
    sa.Column('interface_name', sa.String(length=64), nullable=True),
    sa.Column('mac_address', sa.String(length=64), nullable=True),
    sa.Column('fqdn', sa.String(length=255), nullable=True),
    sa.Column('is_heartbeat_ip', sa.Boolean(), nullable=True),
    sa.Column('allocation_status', sa.String(length=32), nullable=True),
    sa.Column('last_verification_status', sa.String(length=40), nullable=True),
    sa.Column('last_verified_at', sa.DateTime(), nullable=True),
    sa.Column('last_verification_detail', sa.Text(), nullable=True),
    sa.Column('notes', sa.Text(), nullable=True),
    sa.ForeignKeyConstraint(['asset_id'], ['cmdb_assets.id'], ondelete='CASCADE'),
    sa.ForeignKeyConstraint(['subnet_id'], ['cmdb_subnets.id'], ondelete='SET NULL'),
    sa.PrimaryKeyConstraint('id')
    )
    with op.batch_alter_table('cmdb_ip_addresses', schema=None) as batch_op:
        batch_op.create_index(batch_op.f('ix_cmdb_ip_addresses_asset_id'), ['asset_id'], unique=False)
        batch_op.create_index(batch_op.f('ix_cmdb_ip_addresses_id'), ['id'], unique=False)
        batch_op.create_index(batch_op.f('ix_cmdb_ip_addresses_ip_address'), ['ip_address'], unique=False)
        batch_op.create_index(batch_op.f('ix_cmdb_ip_addresses_subnet_id'), ['subnet_id'], unique=False)

    op.create_table('connections',
    sa.Column('id', sa.Integer(), nullable=False),
    sa.Column('source_port_id', sa.Integer(), nullable=False),
    sa.Column('target_port_id', sa.Integer(), nullable=False),
    sa.Column('cable_type', sa.String(length=32), nullable=True),
    sa.Column('color_hex', sa.String(length=20), nullable=True),
    sa.Column('routing_channel', sa.String(length=16), nullable=True),
    sa.Column('label', sa.String(length=120), nullable=True),
    sa.Column('vlan', sa.Integer(), nullable=True),
    sa.Column('length_m', sa.Float(), nullable=True),
    sa.Column('notes', sa.Text(), nullable=True),
    sa.ForeignKeyConstraint(['source_port_id'], ['ports.id'], ondelete='CASCADE'),
    sa.ForeignKeyConstraint(['target_port_id'], ['ports.id'], ondelete='CASCADE'),
    sa.PrimaryKeyConstraint('id')
    )
    with op.batch_alter_table('connections', schema=None) as batch_op:
        batch_op.create_index(batch_op.f('ix_connections_id'), ['id'], unique=False)

    op.create_table('network_infra_connectors',
    sa.Column('id', sa.Integer(), nullable=False),
    sa.Column('name', sa.String(length=160), nullable=False),
    sa.Column('connector_type', sa.String(length=48), nullable=False),
    sa.Column('endpoint_host', sa.String(length=255), nullable=False),
    sa.Column('endpoint_port', sa.Integer(), nullable=True),
    sa.Column('auth_username_or_community', sa.String(length=160), nullable=True),
    sa.Column('auth_secret', sa.String(length=255), nullable=True),
    sa.Column('linked_asset_id', sa.Integer(), nullable=True),
    sa.Column('linked_rack_device_id', sa.Integer(), nullable=True),
    sa.Column('extra_settings', sa.JSON(), nullable=True),
    sa.Column('enabled', sa.Boolean(), nullable=True),
    sa.Column('last_sync_status', sa.String(length=32), nullable=True),
    sa.Column('last_sync_at', sa.DateTime(), nullable=True),
    sa.Column('last_sync_summary', sa.Text(), nullable=True),
    sa.Column('discovered_items_count', sa.Integer(), nullable=True),
    sa.Column('created_at', sa.DateTime(), nullable=True),
    sa.ForeignKeyConstraint(['linked_asset_id'], ['cmdb_assets.id'], ondelete='SET NULL'),
    sa.ForeignKeyConstraint(['linked_rack_device_id'], ['rack_devices.id'], ondelete='SET NULL'),
    sa.PrimaryKeyConstraint('id')
    )
    with op.batch_alter_table('network_infra_connectors', schema=None) as batch_op:
        batch_op.create_index(batch_op.f('ix_network_infra_connectors_id'), ['id'], unique=False)

    op.create_table('network_logical_links',
    sa.Column('id', sa.Integer(), nullable=False),
    sa.Column('source_asset_id', sa.Integer(), nullable=False),
    sa.Column('target_asset_id', sa.Integer(), nullable=False),
    sa.Column('link_type', sa.String(length=48), nullable=True),
    sa.Column('source_interface', sa.String(length=64), nullable=True),
    sa.Column('target_interface', sa.String(length=64), nullable=True),
    sa.Column('protocol_label', sa.String(length=80), nullable=True),
    sa.Column('vlan_id', sa.Integer(), nullable=True),
    sa.Column('bandwidth_mbps', sa.Float(), nullable=True),
    sa.Column('status', sa.String(length=24), nullable=True),
    sa.Column('auto_discovered', sa.Boolean(), nullable=True),
    sa.Column('notes', sa.Text(), nullable=True),
    sa.Column('created_at', sa.DateTime(), nullable=True),
    sa.ForeignKeyConstraint(['source_asset_id'], ['cmdb_assets.id'], ondelete='CASCADE'),
    sa.ForeignKeyConstraint(['target_asset_id'], ['cmdb_assets.id'], ondelete='CASCADE'),
    sa.PrimaryKeyConstraint('id')
    )
    with op.batch_alter_table('network_logical_links', schema=None) as batch_op:
        batch_op.create_index(batch_op.f('ix_network_logical_links_id'), ['id'], unique=False)
        batch_op.create_index(batch_op.f('ix_network_logical_links_source_asset_id'), ['source_asset_id'], unique=False)
        batch_op.create_index(batch_op.f('ix_network_logical_links_target_asset_id'), ['target_asset_id'], unique=False)

    op.create_table('network_maintenance_windows',
    sa.Column('id', sa.Integer(), nullable=False),
    sa.Column('title', sa.String(length=160), nullable=False),
    sa.Column('reason', sa.Text(), nullable=True),
    sa.Column('created_by', sa.String(length=80), nullable=True),
    sa.Column('scope_type', sa.String(length=32), nullable=True),
    sa.Column('asset_id', sa.Integer(), nullable=True),
    sa.Column('host_group_id', sa.Integer(), nullable=True),
    sa.Column('target_matches', sa.JSON(), nullable=True),
    sa.Column('starts_at', sa.DateTime(), nullable=True),
    sa.Column('ends_at', sa.DateTime(), nullable=False),
    sa.Column('is_active', sa.Boolean(), nullable=True),
    sa.Column('suppress_notifications', sa.Boolean(), nullable=True),
    sa.ForeignKeyConstraint(['asset_id'], ['cmdb_assets.id'], ondelete='SET NULL'),
    sa.ForeignKeyConstraint(['host_group_id'], ['network_host_groups.id'], ondelete='SET NULL'),
    sa.PrimaryKeyConstraint('id')
    )
    with op.batch_alter_table('network_maintenance_windows', schema=None) as batch_op:
        batch_op.create_index(batch_op.f('ix_network_maintenance_windows_id'), ['id'], unique=False)

    op.create_table('network_notification_rules',
    sa.Column('id', sa.Integer(), nullable=False),
    sa.Column('name', sa.String(length=160), nullable=False),
    sa.Column('description', sa.Text(), nullable=True),
    sa.Column('enabled', sa.Boolean(), nullable=True),
    sa.Column('scope_type', sa.String(length=32), nullable=True),
    sa.Column('host_group_id', sa.Integer(), nullable=True),
    sa.Column('asset_id', sa.Integer(), nullable=True),
    sa.Column('asset_class_filter', sa.String(length=48), nullable=True),
    sa.Column('service_type_filter', sa.String(length=48), nullable=True),
    sa.Column('contact_group_ids', sa.JSON(), nullable=True),
    sa.Column('contact_ids', sa.JSON(), nullable=True),
    sa.Column('send_email', sa.Boolean(), nullable=True),
    sa.Column('send_webhook', sa.Boolean(), nullable=True),
    sa.Column('only_on_hard_state', sa.Boolean(), nullable=True),
    sa.ForeignKeyConstraint(['asset_id'], ['cmdb_assets.id'], ondelete='SET NULL'),
    sa.ForeignKeyConstraint(['host_group_id'], ['network_host_groups.id'], ondelete='SET NULL'),
    sa.PrimaryKeyConstraint('id')
    )
    with op.batch_alter_table('network_notification_rules', schema=None) as batch_op:
        batch_op.create_index(batch_op.f('ix_network_notification_rules_id'), ['id'], unique=False)

    op.create_table('network_service_checks',
    sa.Column('id', sa.Integer(), nullable=False),
    sa.Column('asset_id', sa.Integer(), nullable=False),
    sa.Column('service_name', sa.String(length=140), nullable=False),
    sa.Column('check_type', sa.String(length=40), nullable=False),
    sa.Column('target_ip_or_url', sa.String(length=255), nullable=True),
    sa.Column('port', sa.Integer(), nullable=True),
    sa.Column('expected_status_code', sa.Integer(), nullable=True),
    sa.Column('expected_string', sa.String(length=160), nullable=True),
    sa.Column('check_config', sa.JSON(), nullable=True),
    sa.Column('nagios_state', sa.String(length=24), nullable=True),
    sa.Column('state_type', sa.String(length=16), nullable=True),
    sa.Column('current_attempt', sa.Integer(), nullable=True),
    sa.Column('max_check_attempts', sa.Integer(), nullable=True),
    sa.Column('latency_ms', sa.Float(), nullable=True),
    sa.Column('ssl_days_remaining', sa.Integer(), nullable=True),
    sa.Column('metrics_snapshot', sa.JSON(), nullable=True),
    sa.Column('status_output', sa.Text(), nullable=True),
    sa.Column('enabled', sa.Boolean(), nullable=True),
    sa.Column('is_primary_heartbeat', sa.Boolean(), nullable=True),
    sa.Column('last_checked_at', sa.DateTime(), nullable=True),
    sa.Column('last_state_change_at', sa.DateTime(), nullable=True),
    sa.ForeignKeyConstraint(['asset_id'], ['cmdb_assets.id'], ondelete='CASCADE'),
    sa.PrimaryKeyConstraint('id')
    )
    with op.batch_alter_table('network_service_checks', schema=None) as batch_op:
        batch_op.create_index(batch_op.f('ix_network_service_checks_asset_id'), ['asset_id'], unique=False)
        batch_op.create_index(batch_op.f('ix_network_service_checks_id'), ['id'], unique=False)

    op.create_table('network_switch_snmp_ports',
    sa.Column('id', sa.Integer(), nullable=False),
    sa.Column('asset_id', sa.Integer(), nullable=False),
    sa.Column('rack_device_id', sa.Integer(), nullable=True),
    sa.Column('if_index', sa.Integer(), nullable=True),
    sa.Column('if_name', sa.String(length=64), nullable=False),
    sa.Column('if_alias', sa.String(length=160), nullable=True),
    sa.Column('if_type', sa.String(length=64), nullable=True),
    sa.Column('admin_status', sa.String(length=16), nullable=True),
    sa.Column('oper_status', sa.String(length=16), nullable=True),
    sa.Column('speed_mbps', sa.Integer(), nullable=True),
    sa.Column('mac_address', sa.String(length=64), nullable=True),
    sa.Column('vlan_id', sa.Integer(), nullable=True),
    sa.Column('vlan_mode', sa.String(length=24), nullable=True),
    sa.Column('in_mbps', sa.Float(), nullable=True),
    sa.Column('out_mbps', sa.Float(), nullable=True),
    sa.Column('in_errors', sa.Integer(), nullable=True),
    sa.Column('out_errors', sa.Integer(), nullable=True),
    sa.Column('lldp_neighbor_sysname', sa.String(length=140), nullable=True),
    sa.Column('lldp_neighbor_port', sa.String(length=64), nullable=True),
    sa.Column('lldp_neighbor_ip', sa.String(length=64), nullable=True),
    sa.Column('lldp_neighbor_asset_id', sa.Integer(), nullable=True),
    sa.Column('synced_rack_port_id', sa.Integer(), nullable=True),
    sa.Column('last_polled_at', sa.DateTime(), nullable=True),
    sa.ForeignKeyConstraint(['asset_id'], ['cmdb_assets.id'], ondelete='CASCADE'),
    sa.ForeignKeyConstraint(['lldp_neighbor_asset_id'], ['cmdb_assets.id'], ondelete='SET NULL'),
    sa.ForeignKeyConstraint(['rack_device_id'], ['rack_devices.id'], ondelete='SET NULL'),
    sa.ForeignKeyConstraint(['synced_rack_port_id'], ['ports.id'], ondelete='SET NULL'),
    sa.PrimaryKeyConstraint('id')
    )
    with op.batch_alter_table('network_switch_snmp_ports', schema=None) as batch_op:
        batch_op.create_index(batch_op.f('ix_network_switch_snmp_ports_asset_id'), ['asset_id'], unique=False)
        batch_op.create_index(batch_op.f('ix_network_switch_snmp_ports_id'), ['id'], unique=False)
        batch_op.create_index(batch_op.f('ix_network_switch_snmp_ports_rack_device_id'), ['rack_device_id'], unique=False)

    op.create_table('tech_stack_nodes',
    sa.Column('id', sa.Integer(), nullable=False),
    sa.Column('stack_id', sa.Integer(), nullable=False),
    sa.Column('asset_id', sa.Integer(), nullable=False),
    sa.Column('role_layer', sa.String(length=48), nullable=True),
    sa.Column('custom_label', sa.String(length=140), nullable=True),
    sa.Column('pos_x', sa.Float(), nullable=True),
    sa.Column('pos_y', sa.Float(), nullable=True),
    sa.Column('width_px', sa.Float(), nullable=True),
    sa.Column('height_px', sa.Float(), nullable=True),
    sa.Column('ssh_enabled', sa.Boolean(), nullable=True),
    sa.Column('ssh_user', sa.String(length=64), nullable=True),
    sa.Column('ssh_port', sa.Integer(), nullable=True),
    sa.ForeignKeyConstraint(['asset_id'], ['cmdb_assets.id'], ondelete='CASCADE'),
    sa.ForeignKeyConstraint(['stack_id'], ['tech_stack_diagrams.id'], ondelete='CASCADE'),
    sa.PrimaryKeyConstraint('id')
    )
    with op.batch_alter_table('tech_stack_nodes', schema=None) as batch_op:
        batch_op.create_index(batch_op.f('ix_tech_stack_nodes_asset_id'), ['asset_id'], unique=False)
        batch_op.create_index(batch_op.f('ix_tech_stack_nodes_id'), ['id'], unique=False)
        batch_op.create_index(batch_op.f('ix_tech_stack_nodes_stack_id'), ['stack_id'], unique=False)

    op.create_table('tech_stack_edges',
    sa.Column('id', sa.Integer(), nullable=False),
    sa.Column('stack_id', sa.Integer(), nullable=False),
    sa.Column('source_node_id', sa.Integer(), nullable=False),
    sa.Column('target_node_id', sa.Integer(), nullable=False),
    sa.Column('protocol_label', sa.String(length=120), nullable=True),
    sa.Column('port', sa.Integer(), nullable=True),
    sa.Column('notes', sa.Text(), nullable=True),
    sa.ForeignKeyConstraint(['source_node_id'], ['tech_stack_nodes.id'], ondelete='CASCADE'),
    sa.ForeignKeyConstraint(['stack_id'], ['tech_stack_diagrams.id'], ondelete='CASCADE'),
    sa.ForeignKeyConstraint(['target_node_id'], ['tech_stack_nodes.id'], ondelete='CASCADE'),
    sa.PrimaryKeyConstraint('id')
    )
    with op.batch_alter_table('tech_stack_edges', schema=None) as batch_op:
        batch_op.create_index(batch_op.f('ix_tech_stack_edges_id'), ['id'], unique=False)
        batch_op.create_index(batch_op.f('ix_tech_stack_edges_stack_id'), ['stack_id'], unique=False)



def downgrade() -> None:
    with op.batch_alter_table('tech_stack_edges', schema=None) as batch_op:
        batch_op.drop_index(batch_op.f('ix_tech_stack_edges_stack_id'))
        batch_op.drop_index(batch_op.f('ix_tech_stack_edges_id'))

    op.drop_table('tech_stack_edges')
    with op.batch_alter_table('tech_stack_nodes', schema=None) as batch_op:
        batch_op.drop_index(batch_op.f('ix_tech_stack_nodes_stack_id'))
        batch_op.drop_index(batch_op.f('ix_tech_stack_nodes_id'))
        batch_op.drop_index(batch_op.f('ix_tech_stack_nodes_asset_id'))

    op.drop_table('tech_stack_nodes')
    with op.batch_alter_table('network_switch_snmp_ports', schema=None) as batch_op:
        batch_op.drop_index(batch_op.f('ix_network_switch_snmp_ports_rack_device_id'))
        batch_op.drop_index(batch_op.f('ix_network_switch_snmp_ports_id'))
        batch_op.drop_index(batch_op.f('ix_network_switch_snmp_ports_asset_id'))

    op.drop_table('network_switch_snmp_ports')
    with op.batch_alter_table('network_service_checks', schema=None) as batch_op:
        batch_op.drop_index(batch_op.f('ix_network_service_checks_id'))
        batch_op.drop_index(batch_op.f('ix_network_service_checks_asset_id'))

    op.drop_table('network_service_checks')
    with op.batch_alter_table('network_notification_rules', schema=None) as batch_op:
        batch_op.drop_index(batch_op.f('ix_network_notification_rules_id'))

    op.drop_table('network_notification_rules')
    with op.batch_alter_table('network_maintenance_windows', schema=None) as batch_op:
        batch_op.drop_index(batch_op.f('ix_network_maintenance_windows_id'))

    op.drop_table('network_maintenance_windows')
    with op.batch_alter_table('network_logical_links', schema=None) as batch_op:
        batch_op.drop_index(batch_op.f('ix_network_logical_links_target_asset_id'))
        batch_op.drop_index(batch_op.f('ix_network_logical_links_source_asset_id'))
        batch_op.drop_index(batch_op.f('ix_network_logical_links_id'))

    op.drop_table('network_logical_links')
    with op.batch_alter_table('network_infra_connectors', schema=None) as batch_op:
        batch_op.drop_index(batch_op.f('ix_network_infra_connectors_id'))

    op.drop_table('network_infra_connectors')
    with op.batch_alter_table('connections', schema=None) as batch_op:
        batch_op.drop_index(batch_op.f('ix_connections_id'))

    op.drop_table('connections')
    with op.batch_alter_table('cmdb_ip_addresses', schema=None) as batch_op:
        batch_op.drop_index(batch_op.f('ix_cmdb_ip_addresses_subnet_id'))
        batch_op.drop_index(batch_op.f('ix_cmdb_ip_addresses_ip_address'))
        batch_op.drop_index(batch_op.f('ix_cmdb_ip_addresses_id'))
        batch_op.drop_index(batch_op.f('ix_cmdb_ip_addresses_asset_id'))

    op.drop_table('cmdb_ip_addresses')
    with op.batch_alter_table('ports', schema=None) as batch_op:
        batch_op.drop_index(batch_op.f('ix_ports_id'))

    op.drop_table('ports')
    with op.batch_alter_table('cmdb_assets', schema=None) as batch_op:
        batch_op.drop_index(batch_op.f('ix_cmdb_assets_rack_device_id'))
        batch_op.drop_index(batch_op.f('ix_cmdb_assets_id'))
        batch_op.drop_index(batch_op.f('ix_cmdb_assets_host_rack_device_id'))
        batch_op.drop_index(batch_op.f('ix_cmdb_assets_floor_device_id'))
        batch_op.drop_index(batch_op.f('ix_cmdb_assets_code'))
        batch_op.drop_index(batch_op.f('ix_cmdb_assets_asset_class'))

    op.drop_table('cmdb_assets')
    with op.batch_alter_table('rack_devices', schema=None) as batch_op:
        batch_op.drop_index(batch_op.f('ix_rack_devices_id'))

    op.drop_table('rack_devices')
    with op.batch_alter_table('floor_devices', schema=None) as batch_op:
        batch_op.drop_index(batch_op.f('ix_floor_devices_id'))
        batch_op.drop_index(batch_op.f('ix_floor_devices_floor_id'))
        batch_op.drop_index(batch_op.f('ix_floor_devices_device_type'))

    op.drop_table('floor_devices')
    with op.batch_alter_table('racks', schema=None) as batch_op:
        batch_op.drop_index(batch_op.f('ix_racks_id'))
        batch_op.drop_index(batch_op.f('ix_racks_code'))

    op.drop_table('racks')
    with op.batch_alter_table('aisles', schema=None) as batch_op:
        batch_op.drop_index(batch_op.f('ix_aisles_id'))

    op.drop_table('aisles')
    with op.batch_alter_table('rooms', schema=None) as batch_op:
        batch_op.drop_index(batch_op.f('ix_rooms_id'))

    op.drop_table('rooms')
    with op.batch_alter_table('users', schema=None) as batch_op:
        batch_op.drop_index(batch_op.f('ix_users_username'))
        batch_op.drop_index(batch_op.f('ix_users_id'))
        batch_op.drop_index(batch_op.f('ix_users_email'))

    op.drop_table('users')
    with op.batch_alter_table('floors', schema=None) as batch_op:
        batch_op.drop_index(batch_op.f('ix_floors_id'))

    op.drop_table('floors')
    with op.batch_alter_table('cmdb_subnets', schema=None) as batch_op:
        batch_op.drop_index(batch_op.f('ix_cmdb_subnets_id'))
        batch_op.drop_index(batch_op.f('ix_cmdb_subnets_cidr'))

    op.drop_table('cmdb_subnets')
    with op.batch_alter_table('tech_stack_diagrams', schema=None) as batch_op:
        batch_op.drop_index(batch_op.f('ix_tech_stack_diagrams_id'))
        batch_op.drop_index(batch_op.f('ix_tech_stack_diagrams_code'))

    op.drop_table('tech_stack_diagrams')
    with op.batch_alter_table('network_smtp_config', schema=None) as batch_op:
        batch_op.drop_index(batch_op.f('ix_network_smtp_config_id'))

    op.drop_table('network_smtp_config')
    with op.batch_alter_table('network_host_groups', schema=None) as batch_op:
        batch_op.drop_index(batch_op.f('ix_network_host_groups_id'))
        batch_op.drop_index(batch_op.f('ix_network_host_groups_code'))

    op.drop_table('network_host_groups')
    with op.batch_alter_table('network_alert_logs', schema=None) as batch_op:
        batch_op.drop_index(batch_op.f('ix_network_alert_logs_id'))
        batch_op.drop_index(batch_op.f('ix_network_alert_logs_created_at'))

    op.drop_table('network_alert_logs')
    with op.batch_alter_table('network_alert_contacts', schema=None) as batch_op:
        batch_op.drop_index(batch_op.f('ix_network_alert_contacts_id'))
        batch_op.drop_index(batch_op.f('ix_network_alert_contacts_code'))

    op.drop_table('network_alert_contacts')
    with op.batch_alter_table('network_alert_contact_groups', schema=None) as batch_op:
        batch_op.drop_index(batch_op.f('ix_network_alert_contact_groups_id'))
        batch_op.drop_index(batch_op.f('ix_network_alert_contact_groups_code'))

    op.drop_table('network_alert_contact_groups')
    with op.batch_alter_table('locations', schema=None) as batch_op:
        batch_op.drop_index(batch_op.f('ix_locations_id'))
        batch_op.drop_index(batch_op.f('ix_locations_code'))

    op.drop_table('locations')
    with op.batch_alter_table('floor_device_custom_types', schema=None) as batch_op:
        batch_op.drop_index(batch_op.f('ix_floor_device_custom_types_id'))
        batch_op.drop_index(batch_op.f('ix_floor_device_custom_types_category_key'))

    op.drop_table('floor_device_custom_types')
    with op.batch_alter_table('device_templates', schema=None) as batch_op:
        batch_op.drop_index(batch_op.f('ix_device_templates_library_group'))
        batch_op.drop_index(batch_op.f('ix_device_templates_id'))
        batch_op.drop_index(batch_op.f('ix_device_templates_category'))

    op.drop_table('device_templates')
    with op.batch_alter_table('ad_servers', schema=None) as batch_op:
        batch_op.drop_index(batch_op.f('ix_ad_servers_id'))

    op.drop_table('ad_servers')
