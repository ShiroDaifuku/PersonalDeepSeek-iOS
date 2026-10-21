-- Additive and deliberately NOT applied to production by this change.
CREATE TABLE IF NOT EXISTS chat_jobs (
  user_id TEXT NOT NULL,
  id TEXT NOT NULL,
  conversation_id TEXT NOT NULL,
  user_message_id TEXT NOT NULL,
  assistant_message_id TEXT NOT NULL,
  request_hash TEXT NOT NULL,
  request_json TEXT,
  status TEXT NOT NULL CHECK(status IN ('queued','running','succeeded','failed','cancelled')),
  content TEXT NOT NULL DEFAULT '',
  reasoning TEXT NOT NULL DEFAULT '',
  error_code TEXT,
  usage_json TEXT,
  created_at INTEGER NOT NULL,
  started_at INTEGER,
  updated_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  PRIMARY KEY(user_id,id)
);
CREATE INDEX IF NOT EXISTS chat_jobs_owner_created ON chat_jobs(user_id,created_at);
CREATE INDEX IF NOT EXISTS chat_jobs_expiry ON chat_jobs(expires_at);
