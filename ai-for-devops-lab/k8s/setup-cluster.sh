#!/usr/bin/env bash
# Creates a local kind cluster, a deliberately broken app, and a read-only kubeconfig for the agent.
set -euo pipefail
cd "$(dirname "$0")/.."

kind get clusters | grep -qx ai-lab || kind create cluster --name ai-lab

kubectl create namespace payments --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f k8s/agent-readonly-rbac.yaml

# A pod that will never start (bad image tag), so the agent has something to diagnose
kubectl -n payments create deployment checkout --image=nginx:does-not-exist --dry-run=client -o yaml | kubectl apply -f -

# Short-lived token for the agent's service account
TOKEN=$(kubectl -n ai-agent create token ai-agent --duration=8h)

# --internal gives the API server address reachable from containers on the "kind" Docker network
kind get kubeconfig --name ai-lab --internal > /tmp/ai-lab-internal.kubeconfig
SERVER=$(kubectl --kubeconfig /tmp/ai-lab-internal.kubeconfig config view --minify -o jsonpath='{.clusters[0].cluster.server}')
CA=$(kubectl --kubeconfig /tmp/ai-lab-internal.kubeconfig config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
rm -f /tmp/ai-lab-internal.kubeconfig

mkdir -p kube
umask 077
cat > kube/agent-kubeconfig <<EOF
apiVersion: v1
kind: Config
clusters:
- name: ai-lab
  cluster:
    server: ${SERVER}
    certificate-authority-data: ${CA}
users:
- name: ai-agent
  user:
    token: ${TOKEN}
contexts:
- name: ai-agent
  context: {cluster: ai-lab, user: ai-agent, namespace: payments}
current-context: ai-agent
EOF

SA=system:serviceaccount:ai-agent:ai-agent
echo "can list pods in payments:   $(kubectl auth can-i list pods -n payments --as=$SA)"
echo "can delete pods in payments: $(kubectl auth can-i delete pods -n payments --as=$SA)"
echo "can list secrets anywhere:   $(kubectl auth can-i list secrets -A --as=$SA)"
echo "Wrote kube/agent-kubeconfig (token valid 8h)"
