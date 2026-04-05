"""
Langfuse callback handler for LangGraph tracing.
=================================================
Wraps LangGraph execution to log every graph step, tool execution time,
and token usage to a self-hosted Langfuse instance.

If LANGFUSE_HOST is not set, returns None and tracing is disabled.
"""

import logging
from .config import settings

logger = logging.getLogger(__name__)


def get_langfuse_handler():
    """Create and return a Langfuse callback handler, or None if unconfigured."""
    if not settings.LANGFUSE_HOST:
        logger.info("[observability] Langfuse not configured — tracing disabled.")
        return None

    try:
        from langfuse.callback import CallbackHandler

        handler = CallbackHandler(
            host=settings.LANGFUSE_HOST,
            public_key=settings.LANGFUSE_PUBLIC_KEY,
            secret_key=settings.LANGFUSE_SECRET_KEY,
        )
        logger.info(
            f"[observability] Langfuse handler created — tracing to {settings.LANGFUSE_HOST}"
        )
        return handler
    except ImportError:
        logger.warning(
            "[observability] langfuse package not installed — tracing disabled."
        )
        return None
    except Exception as exc:
        logger.warning(
            f"[observability] Failed to create Langfuse handler: {exc}"
        )
        return None
