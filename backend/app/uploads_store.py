"""Almacén en disco de los planos subidos (imágenes de sedes, plantas y salas)."""

import base64

from sqlalchemy.orm import Session

from .database import DEFAULT_DB_PATH
from .models import Floor, Location, Room

UPLOADS_DIR = DEFAULT_DB_PATH.parent / "uploads"
UPLOADS_DIR.mkdir(parents=True, exist_ok=True)


_TRANSPARENT_1X1_PNG = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII="
)


def _sanitize_missing_upload_urls(db: Session):
    """Limpia URLs de planos subidos cuyo archivo físico ya no exista en disco."""
    changed = False
    for model_cls in (Location, Floor, Room):
        rows = db.query(model_cls).all()
        for row in rows:
            url = (getattr(row, "map_image_url", None) or "").strip()
            if url.startswith("/api/uploads/"):
                fname = url.split("/api/uploads/")[-1].split("?")[0]
                if not (UPLOADS_DIR / fname).is_file():
                    row.map_image_url = ""
                    changed = True
    if changed:
        db.commit()
