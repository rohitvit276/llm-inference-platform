"""API gateway in front of the llama.cpp model server.

Responsibilities:
- Bearer-token auth (keys from the API_KEYS env var, comma-separated)
- Per-key sliding-window rate limiting
- Prometheus metrics: request counts, latency histograms, token usage
- Proxies the OpenAI-compatible /v1/chat/completions endpoint
"""

import os
import time
from collections import defaultdict, deque

import httpx
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse, Response
from prometheus_client import (
    CONTENT_TYPE_LATEST,
    Counter,
    Histogram,
    generate_latest,
)

MODEL_UPSTREAM = os.environ.get("MODEL_UPSTREAM", "http://llm-model:8080")
API_KEYS = {k.strip() for k in os.environ.get("API_KEYS", "dev-key").split(",") if k.strip()}
RATE_LIMIT_PER_MINUTE = int(os.environ.get("RATE_LIMIT_PER_MINUTE", "60"))
REQUEST_TIMEOUT_SECONDS = float(os.environ.get("REQUEST_TIMEOUT_SECONDS", "120"))

app = FastAPI(title="llm-gateway")

REQUESTS = Counter(
    "gateway_requests_total", "Requests through the gateway", ["path", "status"]
)
LATENCY = Histogram(
    "gateway_request_duration_seconds",
    "End-to-end request latency",
    ["path"],
    buckets=(0.1, 0.5, 1, 2, 5, 10, 20, 30, 60, 120),
)
TOKENS = Counter(
    "gateway_tokens_total", "Tokens processed, from upstream usage", ["kind"]
)

_request_log: dict[str, deque] = defaultdict(deque)


def check_rate_limit(key: str) -> None:
    now = time.monotonic()
    window = _request_log[key]
    while window and now - window[0] > 60:
        window.popleft()
    if len(window) >= RATE_LIMIT_PER_MINUTE:
        raise HTTPException(status_code=429, detail="Rate limit exceeded")
    window.append(now)


def authenticate(request: Request) -> str:
    auth = request.headers.get("authorization", "")
    if not auth.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Missing bearer token")
    key = auth.removeprefix("Bearer ").strip()
    if key not in API_KEYS:
        raise HTTPException(status_code=401, detail="Invalid API key")
    return key


@app.get("/healthz")
async def healthz():
    return {"status": "ok"}


@app.get("/metrics")
async def metrics():
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)


@app.post("/v1/chat/completions")
async def chat_completions(request: Request):
    key = authenticate(request)
    check_rate_limit(key)

    body = await request.json()
    start = time.monotonic()
    status = "500"
    try:
        async with httpx.AsyncClient(timeout=REQUEST_TIMEOUT_SECONDS) as client:
            upstream = await client.post(
                f"{MODEL_UPSTREAM}/v1/chat/completions", json=body
            )
        status = str(upstream.status_code)
        payload = upstream.json()
        usage = payload.get("usage") or {}
        TOKENS.labels("prompt").inc(usage.get("prompt_tokens", 0))
        TOKENS.labels("completion").inc(usage.get("completion_tokens", 0))
        return JSONResponse(payload, status_code=upstream.status_code)
    except httpx.TimeoutException:
        status = "504"
        raise HTTPException(status_code=504, detail="Model upstream timed out")
    finally:
        LATENCY.labels("/v1/chat/completions").observe(time.monotonic() - start)
        REQUESTS.labels("/v1/chat/completions", status).inc()
