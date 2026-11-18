"""Targets dinámicos Prometheus/OpenTelemetry multipuerto y Perfiles/Gráficas personalizadas.

Revision ID: a2b94e1c8d05
Revises: f1c83d2a9e04
Create Date: 2026-11-18 08:35:00.000000
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = "a2b94e1c8d05"
down_revision: Union[str, None] = "f1c83d2a9e04"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    bind = op.get_bind()
    existing_tables = set(sa.inspect(bind).get_table_names())

    if "telemetry_scrape_targets" not in existing_tables:
        op.create_table(
            "telemetry_scrape_targets",
            sa.Column("id", sa.Integer(), nullable=False),
            sa.Column("asset_id", sa.Integer(), nullable=False),
            sa.Column("name", sa.String(length=160), nullable=False),
            sa.Column("exporter_type", sa.String(length=48), nullable=False),
            sa.Column("mode", sa.String(length=16), nullable=False),
            sa.Column("target_host", sa.String(length=255), nullable=True),
            sa.Column("port", sa.Integer(), nullable=False),
            sa.Column("metrics_path", sa.String(length=160), nullable=False),
            sa.Column("scheme", sa.String(length=12), nullable=False),
            sa.Column("scrape_interval", sa.String(length=16), nullable=False),
            sa.Column("bearer_token_encrypted", sa.Text(), nullable=True),
            sa.Column("extra_labels", sa.JSON(), nullable=True),
            sa.Column("enabled", sa.Boolean(), nullable=True),
            sa.Column("last_probe_status", sa.String(length=24), nullable=True),
            sa.Column("last_probe_at", sa.DateTime(), nullable=True),
            sa.Column("last_probe_summary", sa.Text(), nullable=True),
            sa.Column("detected_metric_families_count", sa.Integer(), nullable=True),
            sa.Column("created_at", sa.DateTime(), nullable=True),
            sa.ForeignKeyConstraint(
                ["asset_id"], ["cmdb_assets.id"], ondelete="CASCADE"
            ),
            sa.PrimaryKeyConstraint("id"),
        )
        with op.batch_alter_table("telemetry_scrape_targets", schema=None) as batch_op:
            batch_op.create_index(
                batch_op.f("ix_telemetry_scrape_targets_id"), ["id"], unique=False
            )
            batch_op.create_index(
                batch_op.f("ix_telemetry_scrape_targets_asset_id"),
                ["asset_id"],
                unique=False,
            )
            batch_op.create_index(
                batch_op.f("ix_telemetry_scrape_targets_exporter_type"),
                ["exporter_type"],
                unique=False,
            )

    if "telemetry_profiles" not in existing_tables:
        op.create_table(
            "telemetry_profiles",
            sa.Column("id", sa.Integer(), nullable=False),
            sa.Column("code", sa.String(length=64), nullable=False),
            sa.Column("name", sa.String(length=160), nullable=False),
            sa.Column("description", sa.Text(), nullable=True),
            sa.Column("icon_key", sa.String(length=40), nullable=True),
            sa.Column("is_builtin", sa.Boolean(), nullable=True),
            sa.Column("auto_match_exporter_types", sa.JSON(), nullable=True),
            sa.Column("assigned_asset_ids", sa.JSON(), nullable=True),
            sa.Column("assigned_host_group_ids", sa.JSON(), nullable=True),
            sa.Column("kpi_badges", sa.JSON(), nullable=True),
            sa.Column("panels", sa.JSON(), nullable=True),
            sa.Column("created_at", sa.DateTime(), nullable=True),
            sa.Column("updated_at", sa.DateTime(), nullable=True),
            sa.PrimaryKeyConstraint("id"),
            sa.UniqueConstraint("code"),
        )
        with op.batch_alter_table("telemetry_profiles", schema=None) as batch_op:
            batch_op.create_index(
                batch_op.f("ix_telemetry_profiles_id"), ["id"], unique=False
            )
            batch_op.create_index(
                batch_op.f("ix_telemetry_profiles_code"), ["code"], unique=True
            )

    if "telemetry_asset_custom_charts" not in existing_tables:
        op.create_table(
            "telemetry_asset_custom_charts",
            sa.Column("id", sa.Integer(), nullable=False),
            sa.Column("asset_id", sa.Integer(), nullable=False),
            sa.Column("title", sa.String(length=160), nullable=False),
            sa.Column("unit", sa.String(length=24), nullable=True),
            sa.Column("chart_type", sa.String(length=24), nullable=True),
            sa.Column("promql_a", sa.Text(), nullable=False),
            sa.Column("label_a", sa.String(length=80), nullable=True),
            sa.Column("color_a", sa.String(length=16), nullable=True),
            sa.Column("promql_b", sa.Text(), nullable=True),
            sa.Column("label_b", sa.String(length=80), nullable=True),
            sa.Column("color_b", sa.String(length=16), nullable=True),
            sa.Column("legend_label", sa.String(length=64), nullable=True),
            sa.Column("warn_threshold", sa.Float(), nullable=True),
            sa.Column("crit_threshold", sa.Float(), nullable=True),
            sa.Column("sort_order", sa.Integer(), nullable=True),
            sa.Column("enabled", sa.Boolean(), nullable=True),
            sa.Column("created_at", sa.DateTime(), nullable=True),
            sa.ForeignKeyConstraint(
                ["asset_id"], ["cmdb_assets.id"], ondelete="CASCADE"
            ),
            sa.PrimaryKeyConstraint("id"),
        )
        with op.batch_alter_table(
            "telemetry_asset_custom_charts", schema=None
        ) as batch_op:
            batch_op.create_index(
                batch_op.f("ix_telemetry_asset_custom_charts_id"),
                ["id"],
                unique=False,
            )
            batch_op.create_index(
                batch_op.f("ix_telemetry_asset_custom_charts_asset_id"),
                ["asset_id"],
                unique=False,
            )


def downgrade() -> None:
    op.drop_table("telemetry_asset_custom_charts")
    op.drop_table("telemetry_profiles")
    op.drop_table("telemetry_scrape_targets")
