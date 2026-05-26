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
from typing import Any
from langchain_core.callbacks import AsyncCallbackHandler
from langchain_core.outputs import LLMResult
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


class TokenTrackerCallbackHandler(AsyncCallbackHandler):
    """
    Callback handler to track token usage for planner and executor models separately.
    """
    def __init__(self):
        self.planner_input_tokens = 0
        self.planner_output_tokens = 0
        self.executor_input_tokens = 0
        self.executor_output_tokens = 0

    async def on_llm_end(self, response: LLMResult, **kwargs: Any) -> None:
        input_tokens = 0
        output_tokens = 0

        # 1. Try modern LangChain usage_metadata
        for gen_list in response.generations:
            for gen in gen_list:
                if hasattr(gen, "message"):
                    message = gen.message
                    if hasattr(message, "usage_metadata") and message.usage_metadata:
                        input_tokens += message.usage_metadata.get("input_tokens", 0)
                        output_tokens += message.usage_metadata.get("output_tokens", 0)

        # 2. Fallback to llm_output if usage_metadata didn't populate anything
        if input_tokens == 0 and output_tokens == 0 and response.llm_output:
            token_usage = response.llm_output.get("token_usage", {})
            if token_usage:
                input_tokens = token_usage.get("prompt_tokens") or token_usage.get("input_tokens") or 0
                output_tokens = token_usage.get("completion_tokens") or token_usage.get("output_tokens") or 0

        # Determine model role (planner or executor)
        tags = kwargs.get("tags") or []
        from .config import settings
        is_planner = (settings.MODE == "planner-only") or ("planner" in tags)

        if is_planner:
            self.planner_input_tokens += input_tokens
            self.planner_output_tokens += output_tokens
        else:
            self.executor_input_tokens += input_tokens
            self.executor_output_tokens += output_tokens
