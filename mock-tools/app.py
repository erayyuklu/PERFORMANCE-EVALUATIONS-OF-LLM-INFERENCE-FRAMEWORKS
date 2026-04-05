"""
Mock Tool Server — returns static data for agent tool calls.
============================================================
Endpoints mirror the tools defined in the LangGraph agent.
All responses return within ~1ms to ensure load tests measure
the Agent + vLLM bottleneck, not external service latency.

Endpoints:
    POST /tools/search_wikipedia   — search Wikipedia (static results)
    POST /tools/get_financial_data — stock data lookup (static)
    POST /tools/get_weather        — weather data lookup (static)
    POST /tools/calculate          — evaluate math expressions (computed)
    GET  /health                   — health check
"""

import json
import logging
import sys
from pathlib import Path

from fastapi import FastAPI, Query

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
# App
# ---------------------------------------------------------------------------
app = FastAPI(title="Mock Tool Server", version="1.0.0")

MOCK_DATA_DIR = Path(__file__).parent / "mock_data"

# Pre-load static data into memory at startup for maximum speed
_wikipedia_data: dict = {}
_financial_data: dict = {}
_weather_data: dict = {}


@app.on_event("startup")
def _load_mock_data():
    global _wikipedia_data, _financial_data, _weather_data
    _wikipedia_data = json.loads((MOCK_DATA_DIR / "wikipedia.json").read_text())
    _financial_data = json.loads((MOCK_DATA_DIR / "financial_data.json").read_text())
    _weather_data = json.loads((MOCK_DATA_DIR / "weather.json").read_text())
    logger.info(
        "[mock-tools] Loaded mock data: "
        f"{len(_wikipedia_data.get('results', []))} wiki articles, "
        f"{len(_financial_data)} tickers, "
        f"{len(_weather_data)} cities"
    )


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------
@app.get("/health")
async def health():
    return {"status": "ok"}


@app.post("/tools/search_wikipedia")
async def search_wikipedia(query: str = Query(default="")):
    """Return static Wikipedia search results (top 3)."""
    results = _wikipedia_data.get("results", [])[:3]
    return {"query": query, "results": results}


@app.post("/tools/get_financial_data")
async def get_financial_data(
    ticker: str = Query(default="AAPL"),
    period: str = Query(default="1y"),
):
    """Return static financial data for the requested ticker."""
    data = _financial_data.get(ticker.upper(), _financial_data.get("default", {}))
    return data


@app.post("/tools/get_weather")
async def get_weather(city: str = Query(default="Istanbul")):
    """Return static weather data for the requested city."""
    data = _weather_data.get(city, _weather_data.get("default", {}))
    return data


@app.post("/tools/calculate")
async def calculate(expression: str = Query(default="2+2")):
    """Evaluate a simple math expression. Sandboxed — no builtins."""
    try:
        # Only allow basic math operations
        allowed_chars = set("0123456789+-*/.() ")
        if not all(c in allowed_chars for c in expression):
            return {"expression": expression, "error": "Invalid characters in expression"}
        result = eval(expression, {"__builtins__": {}}, {})
        return {"expression": expression, "result": result}
    except Exception as e:
        return {"expression": expression, "error": str(e)}
