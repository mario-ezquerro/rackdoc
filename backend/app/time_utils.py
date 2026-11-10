"""Hora actual en UTC, sin el `datetime.utcnow()` que Python 3.12 desaconseja.

El contenedor corre Python 3.12, donde `datetime.utcnow()` emite ya un
DeprecationWarning y está anunciado para eliminarse. La sustitución que
recomienda la documentación, `datetime.now(timezone.utc)`, NO es equivalente
aquí: devuelve un datetime *con* zona horaria, y las columnas DateTime de
models.py guardan datetimes *sin* ella. Mezclarlos lanza

    TypeError: can't subtract offset-naive and offset-aware datetimes

en cuanto se compara con una fecha ya guardada en la base de datos.

Así que se calcula la hora en UTC de forma explícita y se quita la zona, que
es exactamente lo que hacía `utcnow()`: mismo valor, misma clase, sin aviso.
El día que se quieran fechas con zona horaria, el cambio se hace aquí y en
las columnas, de una vez y a propósito, no por un reemplazo masivo.
"""

from datetime import datetime, timezone


def utcnow() -> datetime:
    """Hora actual en UTC como datetime naíf (igual que el antiguo utcnow())."""
    return datetime.now(timezone.utc).replace(tzinfo=None)
