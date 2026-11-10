"""Entorno de Alembic para RackDoc."""

from logging.config import fileConfig

from alembic import context

from app.database import Base, DATABASE_URL, engine
from app import models  # noqa: F401  (importa los modelos para que Base los registre)

config = context.config
if config.config_file_name is not None:
    # disable_existing_loggers=False es obligatorio aquí: Alembic corre dentro
    # del arranque de la aplicación, y con el valor por defecto (True) esta
    # llamada apaga todos los loggers ya creados —los de uvicorn y los de
    # 'rackdoc'—, de modo que a partir de la migración no se vuelve a ver una
    # sola línea de registro.
    fileConfig(config.config_file_name, disable_existing_loggers=False)

config.set_main_option("sqlalchemy.url", DATABASE_URL.replace("%", "%%"))

target_metadata = Base.metadata


def run_migrations_offline() -> None:
    context.configure(
        url=DATABASE_URL,
        target_metadata=target_metadata,
        literal_binds=True,
        dialect_opts={"paramstyle": "named"},
        render_as_batch=True,
    )
    with context.begin_transaction():
        context.run_migrations()


def run_migrations_online() -> None:
    with engine.connect() as connection:
        context.configure(
            connection=connection,
            target_metadata=target_metadata,
            # SQLite no soporta ALTER COLUMN / DROP COLUMN: el modo "batch" hace
            # que Alembic recree la tabla por detrás cuando hace falta.
            render_as_batch=True,
        )
        with context.begin_transaction():
            context.run_migrations()


if context.is_offline_mode():
    run_migrations_offline()
else:
    run_migrations_online()
