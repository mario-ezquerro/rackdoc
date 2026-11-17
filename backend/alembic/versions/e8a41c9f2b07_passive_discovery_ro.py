"""Fase 2: Descubrimiento Pasivo Solo-Lectura (SSH Linux RO, WinRM Windows RO y Walk SNMP IF-MIB / LLDP-MIB).

Revision ID: e8a41c9f2b07
Revises: d7f32b8e4c19
Create Date: 2026-11-16 22:45:00.000000
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = "e8a41c9f2b07"
down_revision: Union[str, None] = "d7f32b8e4c19"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    bind = op.get_bind()
    existing_tables = set(sa.inspect(bind).get_table_names())

    if "ai_passive_discovery_snapshots" not in existing_tables:
        op.create_table(
            "ai_passive_discovery_snapshots",
            sa.Column("id", sa.Integer(), nullable=False),
            sa.Column("run_code", sa.String(length=64), nullable=False),
            sa.Column("collector_type", sa.String(length=40), nullable=False),
            sa.Column("target_host", sa.String(length=255), nullable=False),
            sa.Column("asset_id", sa.Integer(), nullable=True),
            sa.Column("status", sa.String(length=24), nullable=True),
            sa.Column("hostname_detected", sa.String(length=180), nullable=True),
            sa.Column("os_or_sysdescr", sa.String(length=255), nullable=True),
            sa.Column("listening_ports", sa.JSON(), nullable=True),
            sa.Column("peer_connections", sa.JSON(), nullable=True),
            sa.Column("running_services", sa.JSON(), nullable=True),
            sa.Column("containers", sa.JSON(), nullable=True),
            sa.Column("web_vhosts_or_dbs", sa.JSON(), nullable=True),
            sa.Column("snmp_interfaces", sa.JSON(), nullable=True),
            sa.Column("inferred_dependencies", sa.JSON(), nullable=True),
            sa.Column("topology_applied", sa.Boolean(), nullable=True),
            sa.Column("applied_by", sa.String(length=120), nullable=True),
            sa.Column("applied_at", sa.DateTime(), nullable=True),
            sa.Column("error_detail", sa.Text(), nullable=True),
            sa.Column("collected_by", sa.String(length=120), nullable=True),
            sa.Column("collected_at", sa.DateTime(), nullable=True),
            sa.ForeignKeyConstraint(
                ["asset_id"], ["cmdb_assets.id"], ondelete="SET NULL"
            ),
            sa.PrimaryKeyConstraint("id"),
        )
        with op.batch_alter_table("ai_passive_discovery_snapshots", schema=None) as batch_op:
            batch_op.create_index(
                batch_op.f("ix_ai_passive_discovery_snapshots_id"), ["id"], unique=False
            )
            batch_op.create_index(
                batch_op.f("ix_ai_passive_discovery_snapshots_run_code"),
                ["run_code"],
                unique=False,
            )
            batch_op.create_index(
                batch_op.f("ix_ai_passive_discovery_snapshots_collector_type"),
                ["collector_type"],
                unique=False,
            )
            batch_op.create_index(
                batch_op.f("ix_ai_passive_discovery_snapshots_target_host"),
                ["target_host"],
                unique=False,
            )
            batch_op.create_index(
                batch_op.f("ix_ai_passive_discovery_snapshots_asset_id"),
                ["asset_id"],
                unique=False,
            )
            batch_op.create_index(
                batch_op.f("ix_ai_passive_discovery_snapshots_status"),
                ["status"],
                unique=False,
            )
            batch_op.create_index(
                batch_op.f("ix_ai_passive_discovery_snapshots_collected_at"),
                ["collected_at"],
                unique=False,
            )


def downgrade() -> None:
    op.drop_table("ai_passive_discovery_snapshots")
