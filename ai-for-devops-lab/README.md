# AI for DevOps Lab

Companion code for **"Stop Over-Complicating AI: This Is How You Learn AI for DevOps"**.
Everything runs locally. No API keys, no cloud account. Every step is a plain command you run yourself.

## Before you start

- Docker Desktop running (Mac) or Docker Engine with Compose v2 (Linux)
- Docker memory set to 10 GB or more (Docker Desktop > Settings > Resources)
- About 15 GB free disk
- kind and kubectl: `brew install kind kubectl` on a Mac
- Quit the Ollama menu bar app and any local Postgres. They use ports 11434 and 5432.

Clone the repo and go into the lab folder. Every command below runs from here:

```bash
git clone https://github.com/akhileshmishrabiz/blogs-code.git
cd blogs-code/ai-for-devops-lab
```

## Step 1: Create the kind cluster

Create the cluster first. kind creates a Docker network called `kind`, and the agent container joins it later. Compose fails if that network doesn't exist yet.

```bash
kind create cluster --name ai-lab
kubectl config use-context kind-ai-lab
kubectl get nodes
```

`kubectl get nodes` should show one node, `ai-lab-control-plane`, with status `Ready`.

Create the broken app the agent will investigate:

```bash
kubectl create namespace payments
kubectl -n payments create deployment checkout --image=nginx:does-not-exist
```

Create the read-only identity for the agent:

```bash
kubectl apply -f k8s/agent-readonly-rbac.yaml
```

Check what that identity can do. The first answer should be `yes`, the other two `no`:

```bash
kubectl auth can-i list pods -n payments --as=system:serviceaccount:ai-agent:ai-agent
kubectl auth can-i delete pods -n payments --as=system:serviceaccount:ai-agent:ai-agent
kubectl auth can-i list secrets -A --as=system:serviceaccount:ai-agent:ai-agent
```

Build the agent's own kubeconfig. It holds a token for that identity and no admin credentials. The token lasts 8 hours.

```bash
mkdir -p kube
kind get kubeconfig --name ai-lab --internal > kube/internal.yaml
SERVER=$(kubectl --kubeconfig kube/internal.yaml config view --minify -o jsonpath='{.clusters[0].cluster.server}')
kubectl --kubeconfig kube/internal.yaml config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d > kube/ca.crt
TOKEN=$(kubectl create token ai-agent -n ai-agent --duration=8h)

kubectl config set-cluster ai-lab --kubeconfig kube/agent-kubeconfig --server="$SERVER" --certificate-authority=kube/ca.crt --embed-certs=true
kubectl config set-credentials ai-agent --kubeconfig kube/agent-kubeconfig --token="$TOKEN"
kubectl config set-context ai-agent --kubeconfig kube/agent-kubeconfig --cluster=ai-lab --user=ai-agent --namespace=payments
kubectl config use-context ai-agent --kubeconfig kube/agent-kubeconfig

rm kube/internal.yaml kube/ca.crt
```

Check that the file works for the agent identity only:

```bash
kubectl --kubeconfig kube/agent-kubeconfig get pods
```

You should see `checkout` in `ImagePullBackOff` or `ErrImagePull`.

## Step 2: Start the lab with Compose

```bash
docker compose up -d
docker compose ps -a
```

`ollama`, `db` and `phoenix` should show `Up`. `ollama-init` pulls the models, then shows `Exited (0)`. The first pull downloads several GB, so wait until that status appears:

```bash
docker compose logs ollama-init
```

Check the model server is answering:

```bash
curl http://localhost:11434/api/tags
```

## Step 3: Run each stage

Each command below is one stage from the article.

**Stage 1: call the model with curl**

```bash
curl http://localhost:11434/api/generate -d '{"model": "llama3.2", "prompt": "What causes CrashLoopBackOff?", "stream": false}'
```

**Stage 2: log file to validated JSON**

```bash
docker compose run --rm rag python log_analyzer.py samples/events.log
```

**Stage 3: ingest runbooks, then ask a question**

```bash
docker compose run --rm rag
docker compose run --rm rag python rag.py "A pod is stuck in Pending. What should I check first?"
```

The answer ends with `Sources: runbooks/...`.

**Stage 4 and 5: the incident lead agent**

```bash
docker compose run --rm agent python agent.py "Checkout is failing. Investigate the payments namespace and tell me why."
```

**Stage 6: evals and traces**

```bash
docker compose run --rm rag python evals/run_evals.py
```

Then open http://localhost:6006 in your browser. The newest trace shows the lead agent, the specialists, every model call and every tool call.

## Clean up

```bash
docker compose down -v
kind delete cluster --name ai-lab
```

`down -v` removes the database and model volumes. `kind delete cluster` removes the cluster.

## Safety model

The agent uses `kube/agent-kubeconfig`, a token for the `ai-agent` service account. That account can only get, list and watch pods, pod logs and events in `payments`. It cannot delete anything or read secrets. Never mount your own admin kubeconfig into the agent.

## Troubleshooting

- **`network kind declared as external, but could not be found`**: you started the `agent` service before Step 1. Create the cluster first. The `rag` service doesn't need it.
- **Port 11434 or 5432 already in use**: the Ollama Mac app or a local Postgres is running. Quit it. To stop Homebrew's Ollama service: `brew services stop ollama`.
- **Containers killed or very slow**: give Docker more memory. Docker Desktop > Settings > Resources, 10 GB or more.
- **Tool calls ignored or flaky**: small models struggle with tools. Set `MODEL_ID` in `docker-compose.yml` to a larger model.
- **`Unauthorized` from the agent**: the token expired after 8 hours. Repeat the Step 1 kubeconfig commands from `kind get kubeconfig` onwards.
- **`docker compose up` pulls slowly or stalls**: that's the model download. Check progress with `docker compose logs ollama-init`.
- **No traces in Phoenix**: the agent sends traces to `http://phoenix:6006` inside Compose. Run the agent with `docker compose run`, not on your laptop.
