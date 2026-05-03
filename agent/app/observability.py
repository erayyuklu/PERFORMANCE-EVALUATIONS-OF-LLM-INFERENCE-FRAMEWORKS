"""
Langfuse callback handler for LangGraph tracing.
=================================================
Wraps LangGraph execution to log every graph step, tool execution time,
and token usage to a self-hosted Langfuse instance.

If LANGFUSE_HOST is not set, returns None and tracing is disabled.

The handler is created once (singleton) so the background flush thread
persists across requests.  After each graph invocation the caller should
call ``flush_langfuse()`` to guarantee buffered events reach the server.

Langfuse SDK v3+ / v4 note
---------------------------
The ``CallbackHandler`` no longer accepts ``public_key``, ``secret_key``,
or ``host`` as constructor arguments.  These values are read automatically
from the environment variables ``LANGFUSE_PUBLIC_KEY``,
``LANGFUSE_SECRET_KEY``, and ``LANGFUSE_HOST`` — which are already
injected via the ``agent-config`` ConfigMap.  Flushing and shutdown are
done through the top-level ``langfuse`` module, not on the handler itself.
"""

import logging
from .config import settings

logger = logging.getLogger(__name__)

# Module-level singleton — initialised lazily by get_langfuse_handler()
_handler = None
_initialised = False


def get_langfuse_handler():
    """
    Return the singleton Langfuse CallbackHandler, or None if unconfigured.

    The handler is created once and reused for all requests so that the
    Langfuse SDK's background flush thread stays alive.
    """
    global _handler, _initialised

    if _initialised:
        return _handler

    _initialised = True

    if not settings.LANGFUSE_HOST:
        logger.info("[observability] Langfuse not configured — tracing disabled.")
        return None

    try:
        from langfuse.langchain import CallbackHandler

        # Langfuse SDK v3+/v4: configuration is read from environment
        # variables (LANGFUSE_PUBLIC_KEY, LANGFUSE_SECRET_KEY, LANGFUSE_HOST)
        # which are already set by the agent-config ConfigMap.
        handler = CallbackHandler()
        _handler = handler
        logger.info(
            f"[observability] Langfuse handler created — tracing to {settings.LANGFUSE_HOST}"
        )
        return _handler
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


def flush_langfuse():
    """Flush any buffered Langfuse events to the server."""
    if _handler is not None:
        try:
            import langfuse
            langfuse.flush()
        except Exception as exc:
            logger.warning(f"[observability] Langfuse flush failed: {exc}")


def shutdown_langfuse():
    """Flush and shut down the Langfuse client cleanly."""
    if _handler is not None:
        try:
            import langfuse
            langfuse.flush()
            langfuse.shutdown()
            logger.info("[observability] Langfuse shut down cleanly.")
        except Exception as exc:
            logger.warning(f"[observability] Langfuse shutdown error: {exc}")
