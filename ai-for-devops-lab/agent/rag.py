"""Stage 3: ingest runbooks into pgvector and answer questions with sources."""
import os
import pathlib
import sys

import psycopg
import requests

OLLAMA = os.getenv("OLLAMA_HOST", "http://localhost:11434")
DB = os.getenv("DATABASE_URL", "postgresql://postgres:postgres@localhost:5432/postgres")
CHAT_MODEL = os.getenv("CHAT_MODEL", "llama3.2")
EMBED_MODEL = "nomic-embed-text"


def embed(text: str) -> str:
    r = requests.post(f"{OLLAMA}/api/embed", json={"model": EMBED_MODEL, "input": text}, timeout=60)
    r.raise_for_status()
    return str(r.json()["embeddings"][0])  # pgvector accepts the "[0.1, 0.2, ...]" text form


def chunk(text: str, max_chars: int = 1000) -> list[str]:
    """Split on blank lines and pack paragraphs into chunks of about max_chars."""
    chunks, current = [], ""
    for para in text.split("\n\n"):
        if current and len(current) + len(para) > max_chars:
            chunks.append(current.strip())
            current = ""
        current += para + "\n\n"
    if current.strip():
        chunks.append(current.strip())
    return chunks


def ingest(path: str) -> int:
    """Re-embed one file. Old chunks are deleted first so answers never come from stale text."""
    text = pathlib.Path(path).read_text()
    with psycopg.connect(DB) as conn:
        conn.execute("DELETE FROM runbook_chunks WHERE source = %s", (path,))
        for i, part in enumerate(chunk(text)):
            conn.execute(
                "INSERT INTO runbook_chunks (source, chunk_index, content, embedding) "
                "VALUES (%s, %s, %s, %s::vector)",
                (path, i, part, embed(part)),
            )
    return len(chunk(text))


def search(question: str, k: int = 3) -> list[tuple[str, str]]:
    with psycopg.connect(DB) as conn:
        return conn.execute(
            "SELECT source, content FROM runbook_chunks ORDER BY embedding <=> %s::vector LIMIT %s",
            (embed(question), k),
        ).fetchall()


def ask(question: str) -> str:
    hits = search(question)
    context = "\n\n".join(f"[source: {src}]\n{content}" for src, content in hits)
    r = requests.post(f"{OLLAMA}/api/chat", timeout=300, json={
        "model": CHAT_MODEL,
        "stream": False,
        "options": {"temperature": 0},
        "messages": [
            {"role": "system", "content": (
                "Answer only from the context. Cite the source file for every claim. "
                "If the answer is not in the context, say you don't know.")},
            {"role": "user", "content": f"Context:\n{context}\n\nQuestion: {question}"},
        ],
    })
    r.raise_for_status()
    sources = list(dict.fromkeys(src for src, _ in hits))  # most relevant first
    return r.json()["message"]["content"] + "\n\nSources: " + ", ".join(sources)


if __name__ == "__main__":
    if sys.argv[1:2] == ["ingest"]:
        for f in sorted(pathlib.Path(sys.argv[2] if len(sys.argv) > 2 else "runbooks").glob("*.md")):
            print(f"{f}: {ingest(str(f))} chunks")
    else:
        print(ask(" ".join(sys.argv[1:]) or "Why is my pod stuck in Pending?"))
