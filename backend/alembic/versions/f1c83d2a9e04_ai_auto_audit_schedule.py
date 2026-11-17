"""Fase 3: Programación de auditoría periódica Solo-Lectura en AiAgentSettings.

Revision ID: f1c83d2a9e04
Revises: e8a41c9f2b07
Create Date: 2026-11-16 23:12:00.000000
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = "f1c83d2a9e04"
down_revision: Union[str, None] = "e8a41c9f2b07"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    bind = op.get_bind()
    inspector = sa.inspect(bind)
    if "ai_agent_settings" in inspector.get_table_names():
        existing_cols = {c["name"] for c in inspector.get_columns("ai_agent_settings")}
        with op.batch_alter_table("ai_agent_settings", schema=None) as batch_op:
            if "auto_audit_enabled" not in existing_cols:
                batch_op.add_column(sa.Column("auto_audit_enabled", sa.Boolean(), nullable=True))
            if "auto_audit_interval_hours" not in existing_cols:
                batch_op.add_column(sa.Column("auto_audit_interval_hours", sa.Integer(), nullable=True))
            if "last_auto_audit_at" not in existing_cols:
                batch_op.add_column(sa.Column("last_auto_audit_at", sa.DateTime(), nullable=True))


def downgrade() -> None:
    with op.batch_alter_table("ai_agent_settings", schema=None) as batch_op:
        batch_op.drop_column("last_auto_audit_at")
        batch_op.drop_column("auto_audit_interval_hours")
        batch_op.drop_column("auto_audit_enabled")
