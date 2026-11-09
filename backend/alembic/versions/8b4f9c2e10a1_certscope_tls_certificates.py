"""CertScope: tabla certscope_certificates para auditoría y caducidad de certificados SSL/TLS.

Revision ID: 8b4f9c2e10a1
Revises: 36d83056894d
Create Date: 2026-11-09 22:22:00.000000
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = '8b4f9c2e10a1'
down_revision: Union[str, None] = '36d83056894d'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    bind = op.get_bind()
    insp = sa.inspect(bind)
    if 'certscope_certificates' in insp.get_table_names():
        return

    op.create_table(
        'certscope_certificates',
        sa.Column('id', sa.Integer(), nullable=False),
        sa.Column('code', sa.String(length=80), nullable=False),
        sa.Column('name', sa.String(length=180), nullable=False),
        sa.Column('check_mode', sa.String(length=32), nullable=True),
        sa.Column('renewal_type', sa.String(length=32), nullable=True),
        sa.Column('target_host', sa.String(length=255), nullable=True),
        sa.Column('port', sa.Integer(), nullable=True),
        sa.Column('sni_hostname', sa.String(length=255), nullable=True),
        sa.Column('environment', sa.String(length=32), nullable=True),
        sa.Column('asset_id', sa.Integer(), nullable=True),
        sa.Column('rack_device_id', sa.Integer(), nullable=True),
        sa.Column('floor_device_id', sa.Integer(), nullable=True),
        sa.Column('location_id', sa.Integer(), nullable=True),
        sa.Column('common_name', sa.String(length=255), nullable=True),
        sa.Column('issuer_cn', sa.String(length=255), nullable=True),
        sa.Column('issuer_org', sa.String(length=255), nullable=True),
        sa.Column('san_domains', sa.JSON(), nullable=True),
        sa.Column('serial_number', sa.String(length=160), nullable=True),
        sa.Column('fingerprint_sha256', sa.String(length=180), nullable=True),
        sa.Column('tls_version', sa.String(length=64), nullable=True),
        sa.Column('cipher_suite', sa.String(length=128), nullable=True),
        sa.Column('is_self_signed', sa.Boolean(), nullable=True),
        sa.Column('valid_from', sa.DateTime(), nullable=True),
        sa.Column('valid_until', sa.DateTime(), nullable=True),
        sa.Column('days_remaining', sa.Integer(), nullable=True),
        sa.Column('pem_certificate', sa.Text(), nullable=True),
        sa.Column('status', sa.String(length=32), nullable=True),
        sa.Column('warn_days_before', sa.Integer(), nullable=True),
        sa.Column('critical_days_before', sa.Integer(), nullable=True),
        sa.Column('auto_probe_enabled', sa.Boolean(), nullable=True),
        sa.Column('notify_enabled', sa.Boolean(), nullable=True),
        sa.Column('owner_team', sa.String(length=140), nullable=True),
        sa.Column('responsible_person', sa.String(length=140), nullable=True),
        sa.Column('notify_emails', sa.String(length=500), nullable=True),
        sa.Column('contact_group_ids', sa.JSON(), nullable=True),
        sa.Column('contact_ids', sa.JSON(), nullable=True),
        sa.Column('last_checked_at', sa.DateTime(), nullable=True),
        sa.Column('last_probe_error', sa.Text(), nullable=True),
        sa.Column('last_notified_at', sa.DateTime(), nullable=True),
        sa.Column('last_notified_severity', sa.String(length=32), nullable=True),
        sa.Column('renewal_notes', sa.Text(), nullable=True),
        sa.Column('notes', sa.Text(), nullable=True),
        sa.Column('created_at', sa.DateTime(), nullable=True),
        sa.Column('updated_at', sa.DateTime(), nullable=True),
        sa.ForeignKeyConstraint(['asset_id'], ['cmdb_assets.id'], ondelete='SET NULL'),
        sa.ForeignKeyConstraint(['floor_device_id'], ['floor_devices.id'], ondelete='SET NULL'),
        sa.ForeignKeyConstraint(['location_id'], ['locations.id'], ondelete='SET NULL'),
        sa.ForeignKeyConstraint(['rack_device_id'], ['rack_devices.id'], ondelete='SET NULL'),
        sa.PrimaryKeyConstraint('id'),
    )
    with op.batch_alter_table('certscope_certificates', schema=None) as batch_op:
        batch_op.create_index(batch_op.f('ix_certscope_certificates_id'), ['id'], unique=False)
        batch_op.create_index(batch_op.f('ix_certscope_certificates_code'), ['code'], unique=True)
        batch_op.create_index(batch_op.f('ix_certscope_certificates_asset_id'), ['asset_id'], unique=False)
        batch_op.create_index(batch_op.f('ix_certscope_certificates_rack_device_id'), ['rack_device_id'], unique=False)
        batch_op.create_index(batch_op.f('ix_certscope_certificates_floor_device_id'), ['floor_device_id'], unique=False)
        batch_op.create_index(batch_op.f('ix_certscope_certificates_location_id'), ['location_id'], unique=False)


def downgrade() -> None:
    op.drop_table('certscope_certificates')
