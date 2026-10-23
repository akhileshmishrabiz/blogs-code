"""Stage 6: a tiny eval set. Run after every prompt change, model upgrade or re-chunking.

Usage (from the repo root): python evals/run_evals.py
Two checks per question:
  retrieval: did the right runbook come back first?
  answer:    does the answer mention the words a correct answer must contain?
Keyword checks are crude, but they catch regressions. Upgrade to an LLM judge later.
"""
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path[:0] = [str(ROOT / "agent"), str(ROOT)]  # works from the repo or inside the agent container
import rag  # noqa: E402

cases = json.loads((pathlib.Path(__file__).parent / "questions.json").read_text())
passed = 0
for case in cases:
    top_source = rag.search(case["question"], k=1)[0][0]
    retrieval_ok = top_source.endswith(case["expected_source"])
    answer = rag.ask(case["question"]).lower()
    answer_ok = all(word.lower() in answer for word in case["must_contain"])
    ok = retrieval_ok and answer_ok
    passed += ok
    print(f"{'PASS' if ok else 'FAIL'}  retrieval={retrieval_ok} answer={answer_ok}  {case['question']}")

print(f"\n{passed}/{len(cases)} passed")
sys.exit(0 if passed == len(cases) else 1)
