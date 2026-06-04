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
import os
import shutil
import sys
import time
import uuid

from contextlib import asynccontextmanager
from fastapi import FastAPI, Request, BackgroundTasks
from langchain_core.messages import AIMessage, ToolMessage, SystemMessage

from .config import settings
from .graph import create_agent_graph
from .schemas import AgentRequest, AgentResponse
from .observability import get_langfuse_handler, flush_langfuse, shutdown_langfuse, TokenTrackerCallbackHandler

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


def _cleanup_uploads(thread_id: str):
    """Delete the upload directory for the given thread_id."""
    upload_dir = os.path.join("uploads", thread_id)
    if os.path.exists(upload_dir):
        try:
            shutil.rmtree(upload_dir, ignore_errors=True)
            logger.info(f"Cleaned up uploads for thread: {thread_id}")
        except Exception as e:
            logger.warning(f"Error cleaning up uploads for thread {thread_id}: {e}")


@app.post("/api/v1/agent/run", response_model=AgentResponse)
async def run_agent(
    request: Request,
    background_tasks: BackgroundTasks,
):
    """
    Execute a task through the LangGraph agent.

    The agent will reason about the task, optionally call tools, and return
    the final result. The entire execution is measured end-to-end.
    """
    content_type = request.headers.get("content-type", "")

    task = ""
    session_id = None
    file_bytes = None
    file_name = None

    if "multipart/form-data" in content_type:
        form = await request.form()
        task = form.get("task", "")
        if not isinstance(task, str):
            task = str(task)
        session_id = form.get("session_id")
        if session_id is not None and not isinstance(session_id, str):
            session_id = str(session_id)
        file_obj = form.get("file")
        if file_obj and hasattr(file_obj, "filename") and file_obj.filename:
            file_name = file_obj.filename
            file_bytes = await file_obj.read()
    else:
        # Fallback to JSON
        try:
            body = await request.json()
            task = body.get("task", "")
            session_id = body.get("session_id")
        except Exception:
            pass

    # Use session_id for checkpointed conversations, or generate a fresh one
    thread_id = session_id or str(uuid.uuid4())

    # Save uploaded file if present
    if file_bytes and file_name:
        upload_dir = os.path.join("uploads", thread_id)
        os.makedirs(upload_dir, exist_ok=True)
        file_path = os.path.join(upload_dir, file_name)
        with open(file_path, "wb") as f:
            f.write(file_bytes)
        # Register cleanup background task
        background_tasks.add_task(_cleanup_uploads, thread_id)

    graph = app.state.graph
    t_start = time.perf_counter()

    # Build config with optional Langfuse callback and token tracker
    token_tracker = TokenTrackerCallbackHandler()
    config: dict = {}
    callbacks = [token_tracker]
    handler = get_langfuse_handler()
    if handler:
        callbacks.append(handler)
    config["callbacks"] = callbacks

    config["configurable"] = {"thread_id": thread_id}

    # Invoke the graph
    result = await graph.ainvoke(
        {"messages": [("user", task)]},
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
        content = final_message.content
        if isinstance(content, list):
            text_parts = []
            for block in content:
                if isinstance(block, str):
                    text_parts.append(block)
                elif isinstance(block, dict):
                    if block.get("type") == "text":
                        text_parts.append(block.get("text", ""))
                    elif "text" in block:
                        text_parts.append(block["text"])
                else:
                    text_parts.append(str(block))
            result_text = "".join(text_parts)
        else:
            result_text = str(content) if content is not None else ""

    # Extract plan from the planner's SystemMessage if present
    plan_text = None
    for m in messages:
        if isinstance(m, SystemMessage) and m.content and "[PLAN FROM PLANNER]" in str(m.content):
            content = m.content
            if isinstance(content, list):
                plan_text = "".join(
                    block if isinstance(block, str) else (block.get("text", "") if isinstance(block, dict) else str(block))
                    for block in content
                )
            else:
                plan_text = str(content)
            break

    return AgentResponse(
        task=task,
        result=result_text,
        plan=plan_text,
        steps=steps,
        tool_calls=tool_calls,
        duration_ms=round(duration_ms, 2),
        planner_input_tokens=token_tracker.planner_input_tokens,
        planner_output_tokens=token_tracker.planner_output_tokens,
        executor_input_tokens=token_tracker.executor_input_tokens,
        executor_output_tokens=token_tracker.executor_output_tokens,
    )
