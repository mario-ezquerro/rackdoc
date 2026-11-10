"""Registro de eventos del backend.

Hasta ahora el backend no tenía registro ninguno: los fallos se tragaban con
`except Exception: pass` y no quedaba rastro en ningún sitio. Cuando algo no
funcionaba —un heartbeat que no se ejecuta, un ajuste que no se guarda, una
hoja que falta en el Excel— la única pista era que la interfaz "parecía no
hacer nada".

Esto no cambia el control de flujo de nadie: lo que antes se tragaba se sigue
tragando, pero ahora deja una línea en `docker compose logs rackdoc-backend`.

Uso en cualquier módulo:

    from ..logging_setup import get_logger

    logger = get_logger(__name__)
    ...
    except Exception:
        logger.warning("No se pudo X; se continúa sin ello", exc_info=True)

El nivel se controla con la variable de entorno LOG_LEVEL (por defecto INFO).
Con LOG_LEVEL=DEBUG salen además los sondeos de red que fallan, que en
funcionamiento normal son ruido.
"""

import logging
import os
import sys

RAIZ = "rackdoc"
_configurado = False


def configure_logging() -> str:
    """Prepara el logger raíz de la aplicación. Idempotente."""
    global _configurado
    nivel_txt = (os.getenv("LOG_LEVEL") or "INFO").strip().upper()
    nivel = getattr(logging, nivel_txt, None)
    if not isinstance(nivel, int):
        nivel_txt, nivel = "INFO", logging.INFO

    logger = logging.getLogger(RAIZ)
    logger.setLevel(nivel)
    if not _configurado:
        manejador = logging.StreamHandler(sys.stdout)
        manejador.setFormatter(
            logging.Formatter(
                "%(asctime)s  %(levelname)-8s %(name)s  %(message)s",
                datefmt="%Y-%m-%d %H:%M:%S",
            )
        )
        logger.addHandler(manejador)
        # Sin propagar: uvicorn ya tiene sus propios manejadores en la raíz y
        # si no, cada línea saldría dos veces.
        logger.propagate = False
        _configurado = True
    return nivel_txt


def get_logger(nombre: str) -> logging.Logger:
    """Logger para un módulo. Acepta __name__ y lo cuelga de 'rackdoc.'."""
    corto = nombre.split(".")[-1] if nombre else "app"
    return logging.getLogger(f"{RAIZ}.{corto}")
