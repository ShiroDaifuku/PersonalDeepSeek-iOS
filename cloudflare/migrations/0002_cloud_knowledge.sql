ALTER TABLE tasks ADD COLUMN knowledge_base_ids_json TEXT NOT NULL DEFAULT '[]';

CREATE TABLE IF NOT EXISTS knowledge_bases (
  id TEXT NOT NULL,
  user_id TEXT NOT NULL,
  name TEXT NOT NULL,
  enabled INTEGER NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY(user_id, id)
);

CREATE TABLE IF NOT EXISTS knowledge_chunks (
  id TEXT NOT NULL,
  user_id TEXT NOT NULL,
  knowledge_base_id TEXT NOT NULL,
  document_name TEXT NOT NULL,
  chunk_index INTEGER NOT NULL,
  text TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY(user_id, id),
  FOREIGN KEY(user_id, knowledge_base_id) REFERENCES knowledge_bases(user_id, id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS knowledge_chunks_user_base_idx ON knowledge_chunks(user_id, knowledge_base_id);
