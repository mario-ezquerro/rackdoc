"""Agente IA Solo-Lectura y Documentador Automático (Ollama local / API externa, biblioteca de documentos y sugerencias CMDB).

Revision ID: d7f32b8e4c19
Revises: c4e91a7b3d02
Create Date: 2026-11-16 22:15:00.000000
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = "d7f32b8e4c19"
down_revision: Union[str, None] = "c4e91a7b3d02"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    bind = op.get_bind()
    existing_tables = set(sa.inspect(bind).get_table_names())

    if "ai_agent_settings" not in existing_tables:
        op.create_table(
            "ai_agent_settings",
            sa.Column("id", sa.Integer(), nullable=False),
            sa.Column("provider_type", sa.String(length=40), nullable=False),
            sa.Column("base_url", sa.String(length=255), nullable=False),
            sa.Column("model_name", sa.String(length=120), nullable=False),
            sa.Column("api_key_ciphertext", sa.Text(), nullable=True),
            sa.Column("temperature", sa.Float(), nullable=True),
            sa.Column("max_tokens", sa.Integer(), nullable=True),
            sa.Column("timeout_seconds", sa.Integer(), nullable=True),
            sa.Column("language", sa.String(length=16), nullable=True),
            sa.Column("custom_system_instructions", sa.Text(), nullable=True),
            sa.Column("mcp_token_hash", sa.String(length=128), nullable=True),
            sa.Column("mcp_token_prefix", sa.String(length=24), nullable=True),
            sa.Column("passive_discovery_enabled", sa.Boolean(), nullable=True),
            sa.Column("updated_by", sa.String(length=120), nullable=True),
            sa.Column("updated_at", sa.DateTime(), nullable=True),
            sa.PrimaryKeyConstraint("id"),
        )
        with op.batch_alter_table("ai_agent_settings", schema=None) as batch_op:
            batch_op.create_index(
                batch_op.f("ix_ai_agent_settings_id"), ["id"], unique=False
            )

    if "ai_generated_documents" not in existing_tables:
        op.create_table(
            "ai_generated_documents",
            sa.Column("id", sa.Integer(), nullable=False),
            sa.Column("doc_code", sa.String(length=64), nullable=False),
            sa.Column("title", sa.String(length=220), nullable=False),
            sa.Column("scope_type", sa.String(length=40), nullable=True),
            sa.Column("scope_target_id", sa.Integer(), nullable=True),
            sa.Column("scope_label", sa.String(length=180), nullable=True),
            sa.Column("markdown_content", sa.Text(), nullable=True),
            sa.Column("mermaid_diagram", sa.Text(), nullable=True),
            sa.Column("structured_findings", sa.JSON(), nullable=True),
            sa.Column("provider_used", sa.String(length=80), nullable=True),
            sa.Column("model_used", sa.String(length=120), nullable=True),
            sa.Column("generation_mode", sa.String(length=32), nullable=True),
            sa.Column("created_by", sa.String(length=120), nullable=True),
            sa.Column("created_at", sa.DateTime(), nullable=True),
            sa.PrimaryKeyConstraint("id"),
        )
        with op.batch_alter_table("ai_generated_documents", schema=None) as batch_op:
            batch_op.create_index(
                batch_op.f("ix_ai_generated_documents_id"), ["id"], unique=False
            )
            batch_op.create_index(
                batch_op.f("ix_ai_generated_documents_doc_code"),
                ["doc_code"],
                unique=True,
            )
            batch_op.create_index(
                batch_op.f("ix_ai_generated_documents_scope_type"),
                ["scope_type"],
                unique=False,
            )
            batch_op.create_index(
                batch_op.f("ix_ai_generated_documents_created_at"),
                ["created_at"],
                unique=False,
            )

    if "ai_cmdb_suggestions" not in existing_tables:
        op.create_table(
            "ai_cmdb_suggestions",
            sa.Column("id", sa.Integer(), nullable=False),
            sa.Column("asset_id", sa.Integer(), nullable=False),
            sa.Column("field_name", sa.String(length=64), nullable=False),
            sa.Column("current_value", sa.Text(), nullable=True),
            sa.Column("proposed_value", sa.Text(), nullable=False),
            sa.Column("rationale", sa.Text(), nullable=True),
            sa.Column("confidence", sa.Float(), nullable=True),
            sa.Column("status", sa.String(length=24), nullable=True),
            sa.Column("source_doc_id", sa.Integer(), nullable=True),
            sa.Column("reviewed_by", sa.String(length=120), nullable=True),
            sa.Column("reviewed_at", sa.DateTime(), nullable=True),
            sa.Column("created_at", sa.DateTime(), nullable=True),
            sa.ForeignKeyConstraint(
                ["asset_id"], ["cmdb_assets.id"], ondelete="CASCADE"
            ),
            sa.ForeignKeyConstraint(
                ["source_doc_id"], ["ai_generated_documents.id"], ondelete="SET NULL"
            ),
            sa.PrimaryKeyConstraint("id"),
        )
        with op.batch_alter_table("ai_cmdb_suggestions", schema=None) as batch_op:
            batch_op.create_index(
                batch_op.f("ix_ai_cmdb_suggestions_id"), ["id"], unique=False
            )
            batch_op.create_index(
                batch_op.f("ix_ai_cmdb_suggestions_asset_id"),
                ["asset_id"],
                unique=False,
            )
            batch_op.create_index(
                batch_op.f("ix_ai_cmdb_suggestions_status"),
                ["status"],
                unique=False,
            )


def downgrade() -> None:
    op.drop_table("ai_cmdb_suggestions")
    op.drop_table("ai_generated_documents")
    op.drop_table("ai_agent_settings")
