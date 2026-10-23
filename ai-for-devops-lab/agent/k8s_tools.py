"""Read-only Kubernetes tools for the agent.

The real security boundary is the RBAC on the service account in KUBECONFIG
(see k8s/agent-readonly-rbac.yaml). These checks are a second layer.
"""
import os
import re
import subprocess

from strands import tool

ALLOWED_NAMESPACES = set(os.getenv("ALLOWED_NAMESPACES", "payments").split(","))
K8S_NAME = re.compile(r"^[a-z0-9]([-a-z0-9.]{0,251}[a-z0-9])?$")
MAX_OUTPUT = 4000  # characters returned to the model, keeps token use bounded


def kubectl(*args: str) -> str:
    try:
        r = subprocess.run(["kubectl", *args], capture_output=True, text=True, timeout=15)
    except subprocess.TimeoutExpired:
        return "ERROR: kubectl timed out after 15s"
    except FileNotFoundError:
        return "ERROR: kubectl is not installed"
    if r.returncode != 0:
        return f"ERROR (exit {r.returncode}): {r.stderr.strip()[:500]}"
    return r.stdout[:MAX_OUTPUT]


def check(namespace: str, name: str | None = None) -> str | None:
    if namespace not in ALLOWED_NAMESPACES:
        return f"ERROR: namespace '{namespace}' is not allowed. Allowed: {sorted(ALLOWED_NAMESPACES)}"
    if name is not None and not K8S_NAME.match(name):
        return f"ERROR: '{name}' is not a valid Kubernetes name"
    return None


@tool
def get_pods(namespace: str) -> str:
    """List pods and their status in a Kubernetes namespace."""
    return check(namespace) or kubectl("get", "pods", "-n", namespace, "-o", "wide")


@tool
def get_logs(pod: str, namespace: str) -> str:
    """Get the last 50 log lines from a pod."""
    return check(namespace, pod) or kubectl("logs", pod, "-n", namespace, "--tail=50")


@tool
def get_events(namespace: str) -> str:
    """Get recent Kubernetes events in a namespace, newest last."""
    return check(namespace) or kubectl("get", "events", "-n", namespace, "--sort-by=.lastTimestamp")
