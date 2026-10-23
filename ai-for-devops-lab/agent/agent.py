"""Capstone: incident lead agent with two specialists, runbook search, and tracing.

Usage: python agent.py "Checkout is returning 500 errors. Investigate payments."
"""
import os
import sys

from strands import Agent, tool
from strands.models.ollama import OllamaModel
from strands.telemetry import StrandsTelemetry

import rag
from k8s_tools import get_events, get_logs, get_pods

# Tracing first, before any agent runs. The OTLP/HTTP exporter reads
# OTEL_EXPORTER_OTLP_ENDPOINT (e.g. http://phoenix:6006) and appends /v1/traces.
if os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT"):
    StrandsTelemetry().setup_otlp_exporter()

model = OllamaModel(
    host=os.getenv("OLLAMA_HOST", "http://localhost:11434"),
    model_id=os.getenv("MODEL_ID", "llama3.1"),
    temperature=0,
)


@tool
def search_runbooks(question: str) -> str:
    """Search the team's runbooks and return the most relevant sections with their source files."""
    hits = rag.search(question)
    return "\n\n".join(f"[source: {src}]\n{content}" for src, content in hits) or "No runbooks found."


@tool
def log_analyst(question: str) -> str:
    """Investigates pod logs in a namespace and reports errors with evidence."""
    analyst = Agent(model=model, tools=[get_pods, get_logs], callback_handler=None,
                    system_prompt="You analyse pod logs. Report errors with the exact log lines as evidence.")
    return str(analyst(question))


@tool
def k8s_inspector(question: str) -> str:
    """Checks pod status and recent events in a namespace."""
    inspector = Agent(model=model, tools=[get_pods, get_events], callback_handler=None,
                      system_prompt="You inspect Kubernetes pods and events. Report what is unhealthy and why.")
    return str(inspector(question))


lead = Agent(
    model=model,
    tools=[k8s_inspector, log_analyst, search_runbooks],
    system_prompt=(
        "You are the incident lead. Delegate to your specialists, check the runbooks, "
        "then write a short incident summary: impact, likely cause, evidence, suggested next step. "
        "You have no write access. Suggest fixes, never claim you applied them."
    ),
)

if __name__ == "__main__":
    lead(" ".join(sys.argv[1:]) or "Are there failing pods in the payments namespace? Why?")
