"""
LangGraph agent definition.
============================
Creates a ReAct-style agent using LangGraph's prebuilt create_react_agent.

The agent uses:
  - ChatOpenAI pointed at the in-cluster vLLM service (OpenAI-compatible API)
  - Tool definitions from mock_tools.py (routed to the mock-tools service)
  - Optional AsyncPostgresSaver checkpointer for state persistence

The graph is compiled once at application startup and reused for all requests.
"""

import json
import logging
from langchain_openai import ChatOpenAI
from langchain_google_vertexai import ChatVertexAI
from langchain_core.messages import SystemMessage
from langchain_core.runnables import RunnableConfig
from langgraph.prebuilt import create_react_agent
from langgraph.graph import StateGraph, MessagesState, START, END
from .mock_tools import get_mock_tools
from .config import settings
from .schemas import Plan

logger = logging.getLogger(__name__)


def _create_planner_llm() -> ChatVertexAI | ChatOpenAI:
    """Create the planner LLM depending on the mode."""
    if settings.MODE == "small-planner-executor":
        # Uses the small self-hosted model
        logger.info(
            f"[graph] Planner LLM configured (small): model={settings.VLLM_MODEL_NAME}, "
            f"base_url={settings.VLLM_BASE_URL}"
        )
        return ChatOpenAI(
            model=settings.VLLM_MODEL_NAME,
            openai_api_base=settings.VLLM_BASE_URL,
            openai_api_key="not-needed",  # vLLM doesn't require an API key
            temperature=settings.PLANNER_TEMPERATURE,
            max_tokens=settings.MAX_TOKENS,
        )
    else:
        # Default planner uses ChatVertexAI (Gemini)
        logger.info(
            f"[graph] Planner LLM configured (large/default): model={settings.PLANNER_MODEL_NAME}"
        )
        return ChatVertexAI(
            model=settings.PLANNER_MODEL_NAME,
            project=settings.GCP_PROJECT_ID,
            location=settings.GCP_LOCATION,
            temperature=settings.PLANNER_TEMPERATURE,
        )

def _create_executor_llm() -> ChatOpenAI | ChatVertexAI:
    """Create the executor LLM depending on the mode."""
    if settings.MODE == "large-planner-executor":
        # Uses the large model (Gemini)
        logger.info(
            f"[graph] Executor LLM configured (large): model={settings.PLANNER_MODEL_NAME}"
        )
        return ChatVertexAI(
            model=settings.PLANNER_MODEL_NAME,
            project=settings.GCP_PROJECT_ID,
            location=settings.GCP_LOCATION,
            temperature=settings.TEMPERATURE,
        )
    else:
        # Default/small executor uses ChatOpenAI pointing to the self-hosted vLLM backend
        logger.info(
            f"[graph] Executor LLM configured (small/default): model={settings.VLLM_MODEL_NAME}, "
            f"base_url={settings.VLLM_BASE_URL}"
        )
        return ChatOpenAI(
            model=settings.VLLM_MODEL_NAME,
            openai_api_base=settings.VLLM_BASE_URL,
            openai_api_key="not-needed",  # vLLM doesn't require an API key
            temperature=settings.TEMPERATURE,
            max_tokens=settings.MAX_TOKENS,
        )

def _build_tool_description(tools) -> str:
    """Build a formatted list of tool names and descriptions."""
    return "\n".join(f"  - {t.name}: {t.description}" for t in tools)


def _planner_system_prompt(tools) -> str:
    tool_desc = _build_tool_description(tools)
    return (
        "You are an expert planning assistant designed to help an execution agent solve complex, multi-step tasks "
        "from the GAIA benchmark. The GAIA benchmark contains tasks that require web searches, downloading and reading files, "
        "running python code to analyze data or do math, and synthesizing final answers.\n\n"
        "Your task is to analyze the user's request, identify constraints, and produce a detailed, logical execution plan "
        "and verification strategy.\n\n"
        "Guidelines for planning:\n"
        "1. **Identify Constraints**: Pay close attention to what the question is asking. If it asks for a specific format "
        "(e.g., date, floating-point rounding, unit of measurement, capital city), highlight this in the plan.\n"
        "2. **Python for Computation & Data**: If the task involves math, data processing, parsing Excel/CSV sheets, "
        "or string manipulation, instruct the executor to use the `python_execute` tool. Do NOT rely on LLM context arithmetic.\n"
        "3. **Step-by-Step Breakdown**: Provide clear, sequential steps. For example, if a file must be processed, the plan "
        "should specify: (a) find/read the file, (b) write python code to parse the target columns/rows, (c) execute code to get the calculation.\n"
        "4. **Verification**: Include a clear verification strategy. How can the executor prove its answer is correct? "
        "For example, 'Double-check the calculation using a different formula' or 'Compare the search result from two separate sources'.\n\n"
        f"Available tools:\n{tool_desc}"
    )


EXECUTOR_SYSTEM_PROMPT = (
    "You are an expert executor agent designed to solve complex multi-step GAIA tasks using tools.\n"
    "You will receive a plan from a planning assistant. Treat this plan as your guiding blueprint, "
    "but adapt dynamically as you gather more information. If a step fails, backtrack and try a different approach.\n\n"
    "CRITICAL RULES FOR EXECUTION:\n"
    "1. **Python-First for Quantitative Tasks**: NEVER perform complex math, data parsing, or file analysis in your head/context. "
    "Always use the `python_execute` tool to calculate formulas, parse large Excel/CSV sheets, read text files, or slice data. "
    "Print the final result in your python code to retrieve it.\n"
    "2. **Adaptive Tool Use**: If a search query yields no results, reformulate the query with different keywords. "
    "If a webpage is truncated or failed to load, find another source or try to search for the specific paragraph or quote.\n"
    "3. **Read Files Carefully**: When reading local files (PDF, DOCX, CSV, Excel), write python code if they are large, "
    "or read them using `read_document`. Ensure you inspect all sheets in Excel worksheets and read the text thoroughly.\n"
    "4. **Verification Loop**: Once you have a candidate answer, VERIFY IT. Ask yourself:\n"
    "   - Does it directly answer the user's question? Did they ask for a name, a date, a percentage, or a specific count?\n"
    "   - Did I follow all constraints (e.g., rounding to 2 decimals, using a specific date format, removing units)?\n"
    "   - Is the calculation verified by code?\n"
    "5. **Final Output Formatting**: GAIA evaluations are graded by exact string matches. Work hard to eliminate conversational filler. "
    "At the very end of your response, output the final answer formatted exactly as requested, preceded by '**Final Answer:**'. "
    "Example: '**Final Answer:** 42.5' or '**Final Answer:** 2023-11-09'."
)

async def planner_node(state: MessagesState, config: RunnableConfig = None) -> dict:
    """Call the Planner LLM to generate a structured plan."""
    planner_llm = _create_planner_llm()
    structured_llm = planner_llm.with_structured_output(Plan)
    
    # Build planner messages: system prompt + user's original message
    tools = get_mock_tools()
    user_message = state["messages"][-1]
    planner_messages = [
        SystemMessage(content=_planner_system_prompt(tools)),
        user_message,
    ]
    
    # Inject planner tag to help the callback handler identify this run
    planner_config = dict(config) if config else {}
    tags = list(planner_config.get("tags") or [])
    if "planner" not in tags:
        tags.append("planner")
    planner_config["tags"] = tags
    
    plan_obj = await structured_llm.ainvoke(planner_messages, config=planner_config)
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
    tools = get_mock_tools()

    logger.info(f"[graph] Tools registered: {[t.name for t in tools]}")
    logger.info(f"[graph] Mode configured: {settings.MODE}")

    if settings.MODE == "planner-only":
        planner_llm = _create_planner_llm()
        graph = create_react_agent(
            planner_llm,
            tools,
            checkpointer=checkpointer,
        )
        logger.info("[graph] Planner-only ReAct graph compiled successfully.")
        return graph

    elif settings.MODE in ("planner-executor", "small-planner-executor", "large-planner-executor"):
        executor_llm = _create_executor_llm()
        def _executor_prompt(state: MessagesState) -> list:
            # OpenAI-compatible APIs require SystemMessages to precede HumanMessages.
            # planner_node appends the plan as a SystemMessage (add_messages reducer),
            # so we reorder here: system messages first, then the rest.
            msgs = state["messages"]
            sys_msgs = [m for m in msgs if isinstance(m, SystemMessage)]
            other_msgs = [m for m in msgs if not isinstance(m, SystemMessage)]
            return sys_msgs + other_msgs

        # Build the Executor as a prebuilt ReAct sub-agent
        executor_agent = create_react_agent(executor_llm, tools, prompt=_executor_prompt)

        # Build the outer graph
        workflow = StateGraph(MessagesState)
        workflow.add_node("planner", planner_node)
        workflow.add_node("executor", executor_agent)
        
        workflow.add_edge(START, "planner")
        workflow.add_edge("planner", "executor")
        workflow.add_edge("executor", END)
        
        graph = workflow.compile(checkpointer=checkpointer)
        logger.info(f"[graph] {settings.MODE} graph compiled successfully.")
        return graph

    else:
        # Default to single-agent
        executor_llm = _create_executor_llm()
        graph = create_react_agent(
            executor_llm,
            tools,
            checkpointer=checkpointer,
        )
        logger.info("[graph] Single-agent ReAct graph compiled successfully.")
        return graph
