"""
Pydantic request / response models for the Agent API.
"""

from pydantic import BaseModel
from typing import Optional


class AgentRequest(BaseModel):
    """Request body for /api/v1/agent/run."""

    task: str
    session_id: Optional[str] = None


class AgentResponse(BaseModel):
    """Response body from /api/v1/agent/run."""

    task: str
    result: str
    steps: int
    tool_calls: int
    duration_ms: float
