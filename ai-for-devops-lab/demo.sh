#!/usr/bin/env bash
# shellcheck disable=SC2015  # pass/fail always return 0, so "A && pass || fail" is safe
# End-to-end demo of the AI for DevOps lab. Runs every stage in containers and checks the result.
# Works with the bash that ships with macOS (3.2) and on Linux.
#
#   ./demo.sh             run everything, pause at screenshot moments
#   ./demo.sh --no-pause  run straight through
#   ./demo.sh --cleanup   remove the containers, volumes and kind cluster
#
# First run downloads about 8 GB (images + models). Expect 15 to 30 minutes, mostly downloads.
set -uo pipefail
cd "$(dirname "$0")" || exit 1

PAUSE=1
case "${1:-}" in
  --no-pause) PAUSE=0 ;;
  --cleanup)
    docker compose --profile tools down -v
    kind delete cluster --name ai-lab
    exit 0 ;;
esac

LOG_DIR=demo-output
mkdir -p "$LOG_DIR"
RESULTS=""
FAILED=0

bold() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
pass() { printf '\033[32mPASS\033[0m  %s\n' "$1"; RESULTS="${RESULTS}PASS  $1\n"; }
warn() { printf '\033[33mWARN\033[0m  %s\n' "$1"; RESULTS="${RESULTS}WARN  $1\n"; }
fail() { printf '\033[31mFAIL\033[0m  %s\n' "$1"; RESULTS="${RESULTS}FAIL  $1\n"; FAILED=1; }
die()  { fail "$1"; printf '\n%b' "$RESULTS"; exit 1; }
shot() {
  printf '\n\033[36m[SCREENSHOT %s] %s\033[0m\n' "$1" "$2"
  if [ "$PAUSE" = 1 ]; then read -r -p "Press Enter to continue..." _ </dev/tty; fi
}
port_busy() { lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
bold "Preflight"
docker info >/dev/null 2>&1 || die "Docker is not running. Start Docker Desktop and try again."
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 not found. Update Docker Desktop."
command -v kind >/dev/null    || die "kind not found. On a Mac: brew install kind"
command -v kubectl >/dev/null || die "kubectl not found. On a Mac: brew install kubectl"
command -v curl >/dev/null    || die "curl not found"
pass "docker, compose, kind, kubectl found"

MEM_BYTES=$(docker info --format '{{.MemTotal}}')
MEM_GB=$((MEM_BYTES / 1024 / 1024 / 1024))
if [ "$MEM_GB" -lt 7 ]; then
  die "Docker has ${MEM_GB} GB of memory. Give it at least 10 GB: Docker Desktop > Settings > Resources."
elif [ "$MEM_GB" -lt 10 ]; then
  warn "Docker has ${MEM_GB} GB of memory. 10+ GB recommended (Docker Desktop > Settings > Resources)."
else
  pass "Docker has ${MEM_GB} GB of memory"
fi

# Ports must be free, unless they are already ours from a previous run
if [ -z "$(docker compose ps -q ollama 2>/dev/null)" ]; then
  for p in 11434 5432 6006; do
    if port_busy "$p"; then
      case "$p" in
        11434) die "Port 11434 is in use, probably the Ollama Mac app. Quit it from the menu bar and re-run." ;;
        5432)  die "Port 5432 is in use, probably a local Postgres (Postgres.app or brew). Stop it and re-run." ;;
        6006)  die "Port 6006 is in use. Stop whatever is using it and re-run." ;;
      esac
    fi
  done
fi
pass "ports 11434, 5432 and 6006 available"

# ---------------------------------------------------------------------------
bold "Lab setup: start Ollama, pgvector and Phoenix"
docker compose up -d || die "docker compose up failed"

echo "Waiting for the model download job (one-time, several GB). Progress: docker compose logs -f ollama-init"
START=$(date +%s)
while true; do
  CID=$(docker compose ps -aq ollama-init)
  STATE=$(docker inspect -f '{{.State.Status}} {{.State.ExitCode}}' "$CID" 2>/dev/null || echo "missing 0")
  case "$STATE" in
    "exited 0") break ;;
    exited*)    docker compose logs --tail 20 ollama-init; die "Model download failed. Check the logs above." ;;
  esac
  if [ $(( $(date +%s) - START )) -gt 3600 ]; then die "Model download took more than an hour"; fi
  printf '.'; sleep 10
done
echo
docker compose ps -a
pass "ollama, db and phoenix running, models pulled"
shot 1 "docker compose ps: the whole AI lab running in containers"

# ---------------------------------------------------------------------------
bold "Stage 1: call the model over HTTP"
OUT=$(curl -s --max-time 600 http://localhost:11434/api/generate -d '{
  "model": "llama3.2", "prompt": "In one sentence: what causes CrashLoopBackOff?", "stream": false}')
if echo "$OUT" | grep -q '"response": *"[^"]'; then
  echo "$OUT" | sed -n 's/.*"response": *"\([^"]*\)".*/\1/p'
  pass "llama3.2 answered over the Ollama API"
else
  fail "Ollama API call failed: $OUT"
fi

# ---------------------------------------------------------------------------
bold "Building the lab's Python image"
docker compose --profile tools build >"$LOG_DIR/build.log" 2>&1 \
  && pass "rag and agent images built" || die "Image build failed. See $LOG_DIR/build.log"

# ---------------------------------------------------------------------------
bold "Stage 2: log file to validated JSON"
if docker compose run --rm -T rag python log_analyzer.py samples/events.log | tee "$LOG_DIR/stage2.log"; then
  pass "log analyzer returned valid JSON with root_cause, evidence, fix"
else
  fail "log analyzer did not return valid JSON (see $LOG_DIR/stage2.log)"
fi

# ---------------------------------------------------------------------------
bold "Stage 3: RAG over runbooks"
docker compose run --rm -T rag | tee "$LOG_DIR/ingest.log"
grep -q "chunks" "$LOG_DIR/ingest.log" && pass "runbooks ingested into pgvector" || fail "ingest failed"

docker compose run --rm -T rag python rag.py "A pod is stuck in Pending. What should I check first?" \
  | tee "$LOG_DIR/stage3.log"
grep -q "Sources: runbooks/pod-pending.md" "$LOG_DIR/stage3.log" \
  && pass "answer came back with the right runbook as top source" \
  || fail "answer missing or wrong top source (see $LOG_DIR/stage3.log)"
shot 2 "RAG answer citing the runbook it came from"

bold "Stage 6 (part 1): evals"
if docker compose run --rm -T rag python evals/run_evals.py | tee "$LOG_DIR/evals.log"; then
  pass "all evals passed"
else
  warn "some evals failed. Normal with a small model: this is what evals are for. See $LOG_DIR/evals.log"
fi

# ---------------------------------------------------------------------------
bold "Stage 4: kind cluster with a read-only agent identity"
./k8s/setup-cluster.sh | tee "$LOG_DIR/cluster.log" || die "cluster setup failed"
grep -q "can delete pods in payments: no" "$LOG_DIR/cluster.log" \
  && pass "agent service account cannot delete pods" || fail "RBAC check did not return 'no' for delete"
grep -q "can list pods in payments:   yes" "$LOG_DIR/cluster.log" \
  && pass "agent service account can list pods" || fail "RBAC check did not return 'yes' for list"
shot 3 "RBAC check: the agent can read, but cannot delete or see secrets"

echo "Waiting for the broken checkout pod to report its image error..."
for _ in $(seq 1 30); do
  kubectl --context kind-ai-lab -n payments get pods 2>/dev/null | grep -Eq "ErrImagePull|ImagePullBackOff" && break
  sleep 5
done
kubectl --context kind-ai-lab -n payments get pods

# ---------------------------------------------------------------------------
bold "Stages 4 and 5: incident lead agent with two specialists (slow on CPU, a few minutes)"
docker compose run --rm -T agent python agent.py \
  "Checkout is failing. Investigate the payments namespace and tell me why." | tee "$LOG_DIR/agent.log"
if grep -qiE "ImagePull|does-not-exist|image pull|pull(ing)? (the )?image" "$LOG_DIR/agent.log"; then
  pass "agent identified the image pull problem"
elif [ -s "$LOG_DIR/agent.log" ]; then
  warn "agent answered but did not mention the image problem. Re-run, or try a bigger MODEL_ID."
else
  fail "agent produced no output"
fi
shot 4 "Agent incident summary"

# ---------------------------------------------------------------------------
bold "Stage 6 (part 2): traces in Phoenix"
sleep 5
SPANS=$(curl -s "http://localhost:6006/v1/projects/default/spans?limit=200" | grep -o '"span_id"' | wc -l | tr -d ' ')
if [ "${SPANS:-0}" -gt 0 ]; then
  pass "Phoenix received ${SPANS} spans from the agent run"
else
  warn "could not count spans through the Phoenix API. Check the UI directly."
fi
echo "Open http://localhost:6006 and click the latest trace."
shot 5 "Phoenix trace tree: agent, model calls and tool calls"

# ---------------------------------------------------------------------------
bold "Summary"
printf '%b' "$RESULTS"
echo
echo "Logs: $LOG_DIR/"
echo "Clean up later with: ./demo.sh --cleanup"
exit $FAILED
