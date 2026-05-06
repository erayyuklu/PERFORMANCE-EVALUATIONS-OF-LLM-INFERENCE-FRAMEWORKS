"""
Application settings — all configuration via environment variables.
"""

import os


class Settings:
    """Settings loaded from environment variables with sensible defaults."""

    # Architecture Flag
    MODE: str = os.getenv("MODE", "single-agent").lower()

    # Planner (external API)
    PLANNER_MODEL_NAME: str = os.getenv("PLANNER_MODEL_NAME", "gemini-2.5-pro")
    PLANNER_API_KEY: str = os.getenv("PLANNER_API_KEY", "")
    PLANNER_TEMPERATURE: float = float(os.getenv("PLANNER_TEMPERATURE", "0.0"))

    VLLM_MODEL_NAME: str = os.getenv("VLLM_MODEL_NAME", "Qwen/Qwen3-8B")
    VLLM_BASE_URL: str = os.getenv(
        "VLLM_BASE_URL", "http://vllm-service.vllm.svc.cluster.local/v1"
    )
    MOCK_TOOLS_URL: str = os.getenv(
        "MOCK_TOOLS_URL",
        "http://mock-tools-service.mock-tools.svc.cluster.local",
    )
    TEMPERATURE: float = float(os.getenv("AGENT_TEMPERATURE", "0.0"))
    MAX_TOKENS: int = int(os.getenv("AGENT_MAX_TOKENS", "2048"))

    # Langfuse observability
    LANGFUSE_HOST: str = os.getenv("LANGFUSE_HOST", "")
    LANGFUSE_PUBLIC_KEY: str = os.getenv("LANGFUSE_PUBLIC_KEY", "")
    LANGFUSE_SECRET_KEY: str = os.getenv("LANGFUSE_SECRET_KEY", "")

    # PostgreSQL checkpointer
    POSTGRES_URI: str = os.getenv(
        "POSTGRES_URI",
        "postgresql://langgraph:langgraph@agent-postgres.agent.svc.cluster.local:5432/langgraph",
    )
    ENABLE_CHECKPOINTER: bool = os.getenv("ENABLE_CHECKPOINTER", "true").lower() in (
        "true",
        "1",
        "yes",
    )


settings = Settings()
