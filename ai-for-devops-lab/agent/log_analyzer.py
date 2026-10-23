"""Stage 2: turn a log file into validated JSON.

Usage: python log_analyzer.py events.log
"""
import json
import os
import sys

import requests

OLLAMA = os.getenv("OLLAMA_HOST", "http://localhost:11434")
REQUIRED = {"root_cause", "evidence", "fix"}

log = open(sys.argv[1]).read()[-8000:]  # last ~8,000 chars: send less context, pay for fewer tokens

resp = requests.post(f"{OLLAMA}/api/chat", timeout=300, json={
    "model": "llama3.2",
    "stream": False,
    "format": "json",
    "options": {"temperature": 0},
    "messages": [
        {"role": "system", "content": (
            "You are an SRE reviewing Kubernetes events. "
            "Reply in JSON with keys: root_cause, evidence, fix. "
            'If you are not sure, set root_cause to "unknown".')},
        {"role": "user", "content": log},
    ],
})
resp.raise_for_status()

try:
    result = json.loads(resp.json()["message"]["content"])
except json.JSONDecodeError:
    sys.exit("Model did not return valid JSON")

missing = REQUIRED - result.keys()
if missing:
    sys.exit(f"Model response is missing keys: {missing}")

print(json.dumps(result, indent=2))
