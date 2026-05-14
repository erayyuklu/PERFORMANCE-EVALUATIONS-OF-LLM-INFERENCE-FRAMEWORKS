#!/usr/bin/env python3
"""
test_tools.py — Smoke-test each agent tool with explicit prompts.
Discovers the agent URL via kubectl, sends one prompt per tool,
and prints pass/fail for each.
"""

import subprocess
import sys
import httpx
import time
import json

NAMESPACE = "agent"
SERVICE = "agent-service"
TIMEOUT = 300

TOOL_TESTS = [
    {
        "name": "web_search",
        "task": (
            "Use the web_search tool to search for 'Python programming language' "
            "and tell me the year Python was first released. "
            "FINAL ANSWER: <year>"
        ),
        "check": lambda r: "1991" in r or "1989" in r or "1990" in r,
    },
    {
        "name": "visit_webpage",
        "task": (
            "Use the visit_webpage tool to fetch the page at "
            "https://httpbin.org/html and tell me the first word in the heading. "
            "FINAL ANSWER: <word>"
        ),
        "check": lambda r: "herman" in r.lower() or "moby" in r.lower(),
    },
    {
        "name": "python_execute",
        "task": (
            "Use the python_execute tool to run this Python code: print(7 * 6) "
            "and tell me the result. "
            "FINAL ANSWER: <number>"
        ),
        "check": lambda r: "42" in r,
    },
    {
        "name": "read_document (fallback)",
        "task": (
            "Use the read_document tool to read the file at /tmp/nonexistent.txt "
            "and tell me what happened. "
            "FINAL ANSWER: <description>"
        ),
        "check": lambda r: "not found" in r.lower() or "error" in r.lower() or "no such" in r.lower(),
    },
]


def discover_agent_url() -> str:
    def kubectl(jsonpath):
        return subprocess.check_output(
            ["kubectl", "get", "svc", SERVICE, "-n", NAMESPACE,
             "-o", f"jsonpath={jsonpath}"],
            text=True,
        ).strip()

    ip = kubectl("{.status.loadBalancer.ingress[0].ip}")
    if not ip:
        print(f"ERROR: No external IP for {SERVICE} in namespace {NAMESPACE}")
        sys.exit(1)
    port = kubectl("{.spec.ports[0].port}")
    url = f"http://{ip}:{port}"
    print(f"Agent endpoint: {url}\n")
    return url


def call_agent(base_url: str, task: str) -> tuple[str, float]:
    t0 = time.perf_counter()
    resp = httpx.post(
        f"{base_url}/api/v1/agent/run",
        json={"task": task},
        timeout=TIMEOUT,
    )
    duration = (time.perf_counter() - t0) * 1000
    resp.raise_for_status()
    return resp.json().get("result", ""), duration


def main():
    url = discover_agent_url()
    passed = 0
    failed = 0

    for test in TOOL_TESTS:
        name = test["name"]
        print(f"--- Testing: {name} ---")
        try:
            result, duration_ms = call_agent(url, test["task"])
            ok = test["check"](result)
            status = "PASS" if ok else "FAIL"
            if ok:
                passed += 1
            else:
                failed += 1
            print(f"  [{status}] {duration_ms:.0f}ms")
            print(f"  Response: {result[:300]}")
        except Exception as exc:
            failed += 1
            print(f"  [ERROR] {exc}")
        print()

    print("=" * 50)
    print(f"Results: {passed} passed, {failed} failed out of {len(TOOL_TESTS)}")
    print("=" * 50)
    sys.exit(0 if failed == 0 else 1)


if __name__ == "__main__":
    main()