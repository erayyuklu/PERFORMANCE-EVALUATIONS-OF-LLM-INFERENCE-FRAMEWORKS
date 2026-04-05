"""
Agent tools — each tool sends an HTTP request to the mock-tools service.
=========================================================================
These tools are registered with the LangGraph agent and are called when
the LLM decides to use them via function calling.

The mock-tools service returns static data in <10ms, ensuring that load
tests measure the Agent + vLLM bottleneck rather than external services.
"""

import httpx
from langchain_core.tools import tool
from .config import settings

MOCK_URL = settings.MOCK_TOOLS_URL


@tool
async def search_wikipedia(query: str) -> str:
    """Search Wikipedia for information about a topic. Returns article summaries."""
    async with httpx.AsyncClient(timeout=10.0) as client:
        resp = await client.post(
            f"{MOCK_URL}/tools/search_wikipedia", params={"query": query}
        )
        resp.raise_for_status()
        data = resp.json()
        # Format results as readable text for the LLM
        results = data.get("results", [])
        if not results:
            return "No results found."
        parts = []
        for r in results:
            parts.append(f"**{r['title']}**: {r['summary']}")
        return "\n\n".join(parts)


@tool
async def get_financial_data(ticker: str, period: str = "1y") -> str:
    """Get financial data for a stock ticker symbol (e.g. AAPL, GOOGL, MSFT)."""
    async with httpx.AsyncClient(timeout=10.0) as client:
        resp = await client.post(
            f"{MOCK_URL}/tools/get_financial_data",
            params={"ticker": ticker, "period": period},
        )
        resp.raise_for_status()
        data = resp.json()
        return (
            f"Ticker: {data.get('ticker', 'N/A')}\n"
            f"Company: {data.get('company', 'N/A')}\n"
            f"Price: ${data.get('price', 'N/A')}\n"
            f"Market Cap: {data.get('market_cap', 'N/A')}\n"
            f"P/E Ratio: {data.get('pe_ratio', 'N/A')}\n"
            f"EPS: ${data.get('eps', 'N/A')}\n"
            f"Dividend Yield: {data.get('dividend_yield', 'N/A')}%\n"
            f"52-Week High: ${data.get('52_week_high', 'N/A')}\n"
            f"52-Week Low: ${data.get('52_week_low', 'N/A')}\n"
            f"Volume: {data.get('volume', 'N/A')}\n"
            f"Revenue (TTM): {data.get('revenue_ttm', 'N/A')}\n"
            f"Net Income (TTM): {data.get('net_income_ttm', 'N/A')}\n"
            f"Sector: {data.get('sector', 'N/A')}"
        )


@tool
async def get_weather(city: str) -> str:
    """Get current weather information for a city."""
    async with httpx.AsyncClient(timeout=10.0) as client:
        resp = await client.post(
            f"{MOCK_URL}/tools/get_weather", params={"city": city}
        )
        resp.raise_for_status()
        data = resp.json()
        return (
            f"City: {data.get('city', 'N/A')}, {data.get('country', 'N/A')}\n"
            f"Temperature: {data.get('temperature_c', 'N/A')}°C "
            f"({data.get('temperature_f', 'N/A')}°F)\n"
            f"Feels Like: {data.get('feels_like_c', 'N/A')}°C\n"
            f"Condition: {data.get('condition', 'N/A')}\n"
            f"Humidity: {data.get('humidity', 'N/A')}%\n"
            f"Wind: {data.get('wind_speed_kmh', 'N/A')} km/h "
            f"{data.get('wind_direction', 'N/A')}\n"
            f"UV Index: {data.get('uv_index', 'N/A')}\n"
            f"Visibility: {data.get('visibility_km', 'N/A')} km"
        )


@tool
async def calculate(expression: str) -> str:
    """Evaluate a mathematical expression. Supports +, -, *, /, parentheses."""
    async with httpx.AsyncClient(timeout=10.0) as client:
        resp = await client.post(
            f"{MOCK_URL}/tools/calculate", params={"expression": expression}
        )
        resp.raise_for_status()
        data = resp.json()
        if "error" in data:
            return f"Calculation error: {data['error']}"
        return f"{expression} = {data['result']}"


def get_tools():
    """Return all available agent tools."""
    return [search_wikipedia, get_financial_data, get_weather, calculate]
