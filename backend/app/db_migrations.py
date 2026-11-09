"""
Aplicación de migraciones de esquema con Alembic.

Sustituye a la lista de sentencias ALTER TABLE ejecutadas en try/except que
había antes: aquellas fallaban en silencio y no dejaban constancia de qué
versión de esquema tenía cada base de datos.
"""

from pathlib import Path

from alembic import command
from alembic.config import Config
from sqlalchemy import inspect

from .database import engine

BACKEND_ROOT = Path(__file__).resolve().parent.parent
ALEMBIC_INI = BACKEND_ROOT / "alembic.ini"
ALEMBIC_DIR = BACKEND_ROOT / "alembic"


def _alembic_config() -> Config:
    cfg = Config(str(ALEMBIC_INI))
    # Ruta absoluta: el proceso puede arrancar desde cualquier directorio.
    cfg.set_main_option("script_location", str(ALEMBIC_DIR))
    return cfg


def run_migrations() -> str:
    """
    Deja el esquema al día y devuelve qué acción se tomó.

    - Base de datos vacía          -> se aplican todas las migraciones.
    - Base de datos ya existente
      sin tabla alembic_version    -> viene de una versión anterior, cuyo esquema
                                      ya equivalía al baseline: se marca (stamp)
                                      en la revisión actual sin reaplicarla.
    - Resto                        -> upgrade normal hasta head.
    """
    tablas = set(inspect(engine).get_table_names())
    cfg = _alembic_config()

    if tablas and "alembic_version" not in tablas:
        command.stamp(cfg, "head")
        return "stamped"

    command.upgrade(cfg, "head")
    return "created" if not tablas else "upgraded"
