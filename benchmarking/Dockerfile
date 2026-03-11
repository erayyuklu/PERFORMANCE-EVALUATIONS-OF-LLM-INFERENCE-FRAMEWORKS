# syntax=docker/dockerfile:1
# =============================================================================
# Locust image for vLLM load testing
# =============================================================================
FROM python:3.14-slim

WORKDIR /locust

# Install dependencies first for better layer caching
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy test files
COPY locustfile.py .
COPY prompts/ prompts/

# Expose ports:
#   8089  → Locust web UI (master only)
#   5557  → worker ↔ master heartbeat
#   5558  → worker ↔ master work distribution
#   9646  → Prometheus /metrics (master / standalone only)
EXPOSE 8089 5557 5558 9646

ENTRYPOINT ["locust"]
