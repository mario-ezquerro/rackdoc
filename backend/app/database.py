"""Configuración del motor SQLAlchemy, modo WAL en SQLite y sesión por petición."""

import os
from pathlib import Path
from sqlalchemy import create_engine, event
from sqlalchemy.orm import sessionmaker, declarative_base

_candidate_docker_data = Path("/app/data")
if os.getenv("RACKDOC_DATA_DIR"):
    DATA_DIR = Path(os.environ["RACKDOC_DATA_DIR"])
elif _candidate_docker_data.exists() or os.getenv("DATABASE_URL", "").startswith("sqlite:////app/data"):
    DATA_DIR = _candidate_docker_data
else:
    DATA_DIR = Path(__file__).resolve().parent.parent.parent / "data"

DATA_DIR.mkdir(parents=True, exist_ok=True)
DEFAULT_DB_PATH = DATA_DIR / "rackdoc.db"

DATABASE_URL = os.getenv("DATABASE_URL", f"sqlite:///{DEFAULT_DB_PATH}")

connect_args = {"check_same_thread": False} if DATABASE_URL.startswith("sqlite") else {}

engine = create_engine(DATABASE_URL, connect_args=connect_args)

if DATABASE_URL.startswith("sqlite"):
    @event.listens_for(engine, "connect")
    def set_sqlite_pragma(dbapi_connection, connection_record):
        cursor = dbapi_connection.cursor()
        cursor.execute("PRAGMA journal_mode=WAL")
        cursor.execute("PRAGMA synchronous=NORMAL")
        cursor.execute("PRAGMA foreign_keys=ON")
        cursor.close()

SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)
Base = declarative_base()


def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()
