-- Runs automatically the first time the pgvector container starts
-- (files in /docker-entrypoint-initdb.d run only on an empty data volume).
CREATE EXTENSION IF NOT EXISTS vector;

CREATE TABLE IF NOT EXISTS runbook_chunks (
  id          bigserial PRIMARY KEY,
  source      text    NOT NULL,   -- file path or URL, used for citations
  chunk_index int     NOT NULL,   -- position of the chunk inside the source
  content     text    NOT NULL,
  embedding   vector(768) NOT NULL, -- nomic-embed-text returns 768 dimensions
  UNIQUE (source, chunk_index)
);
