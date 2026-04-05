"""
LangGraph agent definition.
============================
Creates a ReAct-style agent using LangGraph's prebuilt create_react_agent.

The agent uses:
  - ChatOpenAI pointed at the in-cluster vLLM service (OpenAI-compatible API)
  - Tool definitions from tools.py (routed to the mock-tools service)
  - Optional AsyncPostgresSaver checkpointer for state persistence

The graph is compiled once at application startup and reused for all requests.
"""

import logging
from langchain_openai import ChatOpenAI
from langgraph.prebuilt import create_react_agent
from .tools import get_tools
from .config import settings

logger = logging.getLogger(__name__)


def _create_llm() -> ChatOpenAI:
    """Create a ChatOpenAI instance pointing at the vLLM service."""
    llm = ChatOpenAI(
        model=settings.VLLM_MODEL_NAME,
        openai_api_base=settings.VLLM_BASE_URL,
        openai_api_key="not-needed",  # vLLM doesn't require an API key
        temperature=settings.TEMPERATURE,
        max_tokens=settings.MAX_TOKENS,
    )
    logger.info(
        f"[graph] LLM configured: model={settings.VLLM_MODEL_NAME}, "
        f"base_url={settings.VLLM_BASE_URL}"
    )
    return llm


def create_agent_graph(checkpointer=None):
    """
    Build and compile the LangGraph ReAct agent.

    Args:
        checkpointer: Optional LangGraph checkpointer (e.g. AsyncPostgresSaver)
                      for persisting graph state across invocations.

    Returns:
        A compiled LangGraph that can be invoked with .ainvoke().
    """
    llm = _create_llm()
    tools = get_tools()

    logger.info(f"[graph] Tools registered: {[t.name for t in tools]}")

    graph = create_react_agent(
        llm,
        tools,
        checkpointer=checkpointer,
    )

    logger.info("[graph] ReAct agent graph compiled successfully.")
    return graph
