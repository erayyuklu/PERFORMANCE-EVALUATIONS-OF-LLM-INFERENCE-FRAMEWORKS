"""
Pydantic request / response models for the Agent API.
"""

from pydantic import BaseModel
from typing import Optional, List


class Plan(BaseModel):
    approach: str
    tools_to_use: List[str]
    key_facts_to_lookup: List[str]


class AgentRequest(BaseModel):
    """Request body for /api/v1/agent/run."""

    task: str
    session_id: Optional[str] = None


class AgentResponse(BaseModel):
    """Response body from /api/v1/agent/run."""

    task: str
    result: str
    plan: Optional[str] = None
    steps: int
    tool_calls: int
    duration_ms: float
