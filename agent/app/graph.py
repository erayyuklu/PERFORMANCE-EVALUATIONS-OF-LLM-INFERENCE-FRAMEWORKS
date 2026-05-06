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

import json
import logging
from langchain_openai import ChatOpenAI
from langchain_google_genai import ChatGoogleGenerativeAI
from langchain_core.messages import SystemMessage
from langgraph.prebuilt import create_react_agent
from langgraph.graph import StateGraph, MessagesState, START, END
from .tools import get_tools
from .config import settings
from .schemas import Plan

logger = logging.getLogger(__name__)


def _create_planner_llm() -> ChatGoogleGenerativeAI:
    """External API LLM for planning (Gemini)."""
    return ChatGoogleGenerativeAI(
        model=settings.PLANNER_MODEL_NAME,
        google_api_key=settings.PLANNER_API_KEY,
        temperature=settings.PLANNER_TEMPERATURE,
    )

def _create_executor_llm() -> ChatOpenAI:
    """Self-hosted vLLM LLM for execution (Qwen3-8B)."""
    llm = ChatOpenAI(
        model=settings.VLLM_MODEL_NAME,
        openai_api_base=settings.VLLM_BASE_URL,
        openai_api_key="not-needed",  # vLLM doesn't require an API key
        temperature=settings.TEMPERATURE,
        max_tokens=settings.MAX_TOKENS,
    )
    logger.info(
        f"[graph] Executor LLM configured: model={settings.VLLM_MODEL_NAME}, "
        f"base_url={settings.VLLM_BASE_URL}"
    )
    return llm

PLANNER_SYSTEM_PROMPT = (
    "You are a planning assistant. Given the user's request, produce a concise "
    "plan that will help a smaller language model answer the question "
    "correctly. Focus on the approach, key facts to look up, and which tools to use. "
    "Available tools: search_wikipedia, get_financial_data, get_weather, calculate."
)

EXECUTOR_SYSTEM_PROMPT = (
    "You are an executor agent. You will receive a plan from a larger model. "
    "Follow the plan strictly to answer the user's request using the available tools."
)

async def planner_node(state: MessagesState) -> dict:
    """Call the Planner LLM to generate a structured plan."""
    planner_llm = _create_planner_llm()
    structured_llm = planner_llm.with_structured_output(Plan)
    
    # Build planner messages: system prompt + user's original message
    user_message = state["messages"][-1]
    planner_messages = [
        SystemMessage(content=PLANNER_SYSTEM_PROMPT),
        user_message,
    ]
    
    plan_obj = await structured_llm.ainvoke(planner_messages)
    plan_json = json.dumps(plan_obj.model_dump(), indent=2)
    
    # Inject the plan as a SystemMessage for the Executor
    plan_as_context = SystemMessage(
        content=f"{EXECUTOR_SYSTEM_PROMPT}\n\n[PLAN FROM PLANNER]\n{plan_json}\n[END PLAN]\n\n"
                "Now execute the above plan to answer the user's request."
    )
    
    return {"messages": [plan_as_context]}

def create_agent_graph(checkpointer=None):
    """
    Build and compile the LangGraph agent depending on the configured MODE.
    """
    executor_llm = _create_executor_llm()
    tools = get_tools()

    logger.info(f"[graph] Tools registered: {[t.name for t in tools]}")
    logger.info(f"[graph] Mode configured: {settings.MODE}")

    if settings.MODE != "planner-executor":
        graph = create_react_agent(
            executor_llm,
            tools,
            checkpointer=checkpointer,
        )
        logger.info("[graph] Single-agent ReAct graph compiled successfully.")
        return graph

    # Build the Executor as a prebuilt ReAct sub-agent
    executor_agent = create_react_agent(executor_llm, tools)

    # Build the outer graph
    workflow = StateGraph(MessagesState)
    workflow.add_node("planner", planner_node)
    workflow.add_node("executor", executor_agent)
    
    workflow.add_edge(START, "planner")
    workflow.add_edge("planner", "executor")
    workflow.add_edge("executor", END)
    
    graph = workflow.compile(checkpointer=checkpointer)
    logger.info("[graph] Planner-Executor graph compiled successfully.")
    return graph
