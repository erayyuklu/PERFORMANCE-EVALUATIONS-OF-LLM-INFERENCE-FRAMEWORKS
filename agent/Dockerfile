# syntax=docker/dockerfile:1
# =============================================================================
# LangGraph Agent API — FastAPI application
# =============================================================================
FROM python:3.12-slim

WORKDIR /app

# Install dependencies first for better layer caching
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application code
COPY app/ app/

EXPOSE 8000

# Use uvicorn with 4 workers for concurrent request handling.
# Workers use asyncio event loops, so each worker handles many
# concurrent requests via async/await (ideal for I/O-bound agent work).
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "4"]
