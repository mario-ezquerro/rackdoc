"""Aprovisionamiento Ansible, Exporters nativos y OpenTelemetry (baúl cifrado, jobs y tokens bootstrap).

Revision ID: c4e91a7b3d02
Revises: 8b4f9c2e10a1
Create Date: 2026-11-13 23:55:00.000000
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = "c4e91a7b3d02"
down_revision: Union[str, None] = "8b4f9c2e10a1"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    bind = op.get_bind()
    existing_tables = set(sa.inspect(bind).get_table_names())

    if "provisioning_credentials" not in existing_tables:
        op.create_table(
            "provisioning_credentials",
            sa.Column("id", sa.Integer(), nullable=False),
            sa.Column("name", sa.String(length=160), nullable=False),
            sa.Column("credential_type", sa.String(length=32), nullable=False),
            sa.Column("os_family", sa.String(length=24), nullable=False),
            sa.Column("username", sa.String(length=120), nullable=False),
            sa.Column("port", sa.Integer(), nullable=True),
            sa.Column("secret_ciphertext", sa.Text(), nullable=True),
            sa.Column("passphrase_ciphertext", sa.Text(), nullable=True),
            sa.Column("become_password_ciphertext", sa.Text(), nullable=True),
            sa.Column("winrm_transport", sa.String(length=32), nullable=True),
            sa.Column("winrm_use_ssl", sa.Boolean(), nullable=True),
            sa.Column("winrm_validate_certs", sa.Boolean(), nullable=True),
            sa.Column("key_fingerprint", sa.String(length=180), nullable=True),
            sa.Column("notes", sa.Text(), nullable=True),
            sa.Column("created_by", sa.String(length=120), nullable=True),
            sa.Column("created_at", sa.DateTime(), nullable=True),
            sa.Column("updated_at", sa.DateTime(), nullable=True),
            sa.PrimaryKeyConstraint("id"),
            sa.UniqueConstraint("name"),
        )
        with op.batch_alter_table("provisioning_credentials", schema=None) as batch_op:
            batch_op.create_index(
                batch_op.f("ix_provisioning_credentials_id"), ["id"], unique=False
            )

    if "provisioning_jobs" not in existing_tables:
        op.create_table(
            "provisioning_jobs",
            sa.Column("id", sa.Integer(), nullable=False),
            sa.Column("job_code", sa.String(length=64), nullable=False),
            sa.Column("title", sa.String(length=200), nullable=False),
            sa.Column("os_family", sa.String(length=24), nullable=False),
            sa.Column("action_profile", sa.String(length=48), nullable=False),
            sa.Column("targets", sa.JSON(), nullable=True),
            sa.Column("credential_id", sa.Integer(), nullable=True),
            sa.Column("credential_mode", sa.String(length=24), nullable=True),
            sa.Column("target_location_id", sa.Integer(), nullable=True),
            sa.Column("host_groups", sa.JSON(), nullable=True),
            sa.Column("otel_endpoint_url", sa.String(length=255), nullable=True),
            sa.Column("use_local_cache", sa.Boolean(), nullable=True),
            sa.Column("status", sa.String(length=32), nullable=True),
            sa.Column("host_results", sa.JSON(), nullable=True),
            sa.Column("console_log", sa.Text(), nullable=True),
            sa.Column("created_by", sa.String(length=120), nullable=True),
            sa.Column("started_at", sa.DateTime(), nullable=True),
            sa.Column("finished_at", sa.DateTime(), nullable=True),
            sa.Column("created_at", sa.DateTime(), nullable=True),
            sa.ForeignKeyConstraint(
                ["credential_id"], ["provisioning_credentials.id"], ondelete="SET NULL"
            ),
            sa.ForeignKeyConstraint(
                ["target_location_id"], ["locations.id"], ondelete="SET NULL"
            ),
            sa.PrimaryKeyConstraint("id"),
        )
        with op.batch_alter_table("provisioning_jobs", schema=None) as batch_op:
            batch_op.create_index(
                batch_op.f("ix_provisioning_jobs_id"), ["id"], unique=False
            )
            batch_op.create_index(
                batch_op.f("ix_provisioning_jobs_job_code"), ["job_code"], unique=True
            )
            batch_op.create_index(
                batch_op.f("ix_provisioning_jobs_credential_id"),
                ["credential_id"],
                unique=False,
            )
            batch_op.create_index(
                batch_op.f("ix_provisioning_jobs_target_location_id"),
                ["target_location_id"],
                unique=False,
            )
            batch_op.create_index(
                batch_op.f("ix_provisioning_jobs_status"), ["status"], unique=False
            )

    if "provisioning_tokens" not in existing_tables:
        op.create_table(
            "provisioning_tokens",
            sa.Column("id", sa.Integer(), nullable=False),
            sa.Column("name", sa.String(length=160), nullable=False),
            sa.Column("token_hash", sa.String(length=128), nullable=False),
            sa.Column("token_prefix", sa.String(length=24), nullable=True),
            sa.Column("os_family", sa.String(length=24), nullable=True),
            sa.Column("action_profile", sa.String(length=48), nullable=True),
            sa.Column("target_location_id", sa.Integer(), nullable=True),
            sa.Column("host_groups", sa.JSON(), nullable=True),
            sa.Column("reusable", sa.Boolean(), nullable=True),
            sa.Column("uses_count", sa.Integer(), nullable=True),
            sa.Column("max_uses", sa.Integer(), nullable=True),
            sa.Column("expires_at", sa.DateTime(), nullable=True),
            sa.Column("revoked", sa.Boolean(), nullable=True),
            sa.Column("created_by", sa.String(length=120), nullable=True),
            sa.Column("last_used_at", sa.DateTime(), nullable=True),
            sa.Column("notes", sa.Text(), nullable=True),
            sa.Column("created_at", sa.DateTime(), nullable=True),
            sa.ForeignKeyConstraint(
                ["target_location_id"], ["locations.id"], ondelete="SET NULL"
            ),
            sa.PrimaryKeyConstraint("id"),
        )
        with op.batch_alter_table("provisioning_tokens", schema=None) as batch_op:
            batch_op.create_index(
                batch_op.f("ix_provisioning_tokens_id"), ["id"], unique=False
            )
            batch_op.create_index(
                batch_op.f("ix_provisioning_tokens_token_hash"),
                ["token_hash"],
                unique=True,
            )
            batch_op.create_index(
                batch_op.f("ix_provisioning_tokens_target_location_id"),
                ["target_location_id"],
                unique=False,
            )


def downgrade() -> None:
    op.drop_table("provisioning_tokens")
    op.drop_table("provisioning_jobs")
    op.drop_table("provisioning_credentials")
