#!/usr/bin/env bash
# Creates a local kind cluster, a deliberately broken app, and a read-only kubeconfig for the agent.
# Safe to re-run. Every kubectl call is pinned to the lab cluster, never your current context.
set -euo pipefail
cd "$(dirname "$0")/.."

CLUSTER=ai-lab
CTX="kind-${CLUSTER}"
k() { kubectl --context "$CTX" "$@"; }

if ! kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  kind create cluster --name "$CLUSTER" --wait 120s
fi

k create namespace payments --dry-run=client -o yaml | k apply -f -
k apply -f k8s/agent-readonly-rbac.yaml

# A pod that will never start (bad image tag), so the agent has something to diagnose
k -n payments create deployment checkout --image=nginx:does-not-exist --dry-run=client -o yaml | k apply -f -

# Short-lived token for the agent's service account
TOKEN=$(k -n ai-agent create token ai-agent --duration=8h)

# --internal gives the API server address reachable from containers on the "kind" Docker network
INTERNAL=$(mktemp)
kind get kubeconfig --name "$CLUSTER" --internal > "$INTERNAL"
SERVER=$(kubectl --kubeconfig "$INTERNAL" config view --minify -o jsonpath='{.clusters[0].cluster.server}')
CA=$(kubectl --kubeconfig "$INTERNAL" config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
rm -f "$INTERNAL"

mkdir -p kube
cat > kube/agent-kubeconfig <<EOF
apiVersion: v1
kind: Config
clusters:
- name: ${CLUSTER}
  cluster:
    server: ${SERVER}
    certificate-authority-data: ${CA}
users:
- name: ai-agent
  user:
    token: ${TOKEN}
contexts:
- name: ai-agent
  context: {cluster: ${CLUSTER}, user: ai-agent, namespace: payments}
current-context: ai-agent
EOF
# Readable by the non-root user inside the agent container. Acceptable for a local lab:
# the token is read-only, scoped to one namespace, expires in 8h, and the file is gitignored.
chmod 644 kube/agent-kubeconfig

SA=system:serviceaccount:ai-agent:ai-agent
echo "can list pods in payments:   $(k auth can-i list pods -n payments --as=$SA || true)"
echo "can delete pods in payments: $(k auth can-i delete pods -n payments --as=$SA || true)"
echo "can list secrets anywhere:   $(k auth can-i list secrets -A --as=$SA || true)"
echo "Wrote kube/agent-kubeconfig (token valid 8h)"
