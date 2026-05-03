"""
Agent API — FastAPI + LangGraph
================================
Exposes the LangGraph agent as a REST API for load testing.

Endpoints:
    POST /api/v1/agent/run   — Execute a task through the agent (sync)
    GET  /health             — Health check

The LangGraph is compiled once at startup. Each request creates a new
graph invocation with a fresh thread_id (or uses session_id if provided
for stateful conversations via the checkpointer).
"""

import logging
import sys
import time
import uuid

from contextlib import asynccontextmanager
from fastapi import FastAPI
from langchain_core.messages import AIMessage, ToolMessage

from .config import settings
from .graph import create_agent_graph
from .schemas import AgentRequest, AgentResponse
from .observability import get_langfuse_handler, flush_langfuse, shutdown_langfuse

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
logging.basicConfig(
    stream=sys.stdout,
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)
logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Lifespan — initialize graph + checkpointer once at startup
# ---------------------------------------------------------------------------
@asynccontextmanager
async def lifespan(app: FastAPI):
    """Startup: compile the graph. Shutdown: cleanup."""
    checkpointer = None

    if settings.ENABLE_CHECKPOINTER:
        try:
            from langgraph.checkpoint.postgres.aio import AsyncPostgresSaver

            checkpointer = AsyncPostgresSaver.from_conn_string(settings.POSTGRES_URI)
            await checkpointer.setup()
            logger.info("[main] PostgreSQL checkpointer initialized.")
        except Exception as exc:
            logger.warning(
                f"[main] Failed to initialize PostgreSQL checkpointer: {exc}. "
                "Falling back to no checkpointer."
            )
            checkpointer = None

    app.state.graph = create_agent_graph(checkpointer=checkpointer)

    # Eagerly initialise the Langfuse handler so it logs at startup
    get_langfuse_handler()

    logger.info("[main] Agent API ready.")
    yield

    # Cleanup
    shutdown_langfuse()
    if checkpointer is not None:
        try:
            await checkpointer.conn.close()
        except Exception:
            pass
    logger.info("[main] Agent API shutdown complete.")


# ---------------------------------------------------------------------------
# FastAPI app
# ---------------------------------------------------------------------------
app = FastAPI(
    title="LangGraph Agent API",
    version="1.0.0",
    lifespan=lifespan,
)


@app.get("/health")
async def health():
    """Health check endpoint."""
    return {"status": "ok"}


@app.post("/api/v1/agent/run", response_model=AgentResponse)
async def run_agent(request: AgentRequest):
    """
    Execute a task through the LangGraph agent.

    The agent will reason about the task, optionally call tools, and return
    the final result. The entire execution is measured end-to-end.
    """
    graph = app.state.graph
    t_start = time.perf_counter()

    # Build config with optional Langfuse callback
    config: dict = {}
    handler = get_langfuse_handler()
    if handler:
        config["callbacks"] = [handler]

    # Use session_id for checkpointed conversations, or generate a fresh one
    thread_id = request.session_id or str(uuid.uuid4())
    config["configurable"] = {"thread_id": thread_id}

    # Invoke the graph
    result = await graph.ainvoke(
        {"messages": [("user", request.task)]},
        config=config,
    )

    # Flush Langfuse events so traces reach the server immediately
    flush_langfuse()

    t_end = time.perf_counter()
    duration_ms = (t_end - t_start) * 1000

    # Count steps and tool calls from the message history
    messages = result.get("messages", [])
    steps = len(messages)
    tool_calls = sum(1 for m in messages if isinstance(m, ToolMessage))

    # Extract final response text
    final_message = messages[-1] if messages else None
    result_text = ""
    if final_message and isinstance(final_message, AIMessage):
        result_text = final_message.content or ""

    return AgentResponse(
        task=request.task,
        result=result_text,
        steps=steps,
        tool_calls=tool_calls,
        duration_ms=round(duration_ms, 2),
    )
