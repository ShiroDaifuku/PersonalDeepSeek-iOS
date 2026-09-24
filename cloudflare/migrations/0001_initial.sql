PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS tasks (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  title TEXT NOT NULL,
  kind TEXT NOT NULL,
  schedule_json TEXT NOT NULL,
  prompt TEXT NOT NULL,
  tools_json TEXT NOT NULL,
  notify INTEGER NOT NULL,
  enabled INTEGER NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  next_run_at TEXT,
  consecutive_unread INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS tasks_user_idx ON tasks(user_id, updated_at DESC);
CREATE INDEX IF NOT EXISTS tasks_due_idx ON tasks(enabled, next_run_at);

CREATE TABLE IF NOT EXISTS task_runs (
  id TEXT PRIMARY KEY,
  task_id TEXT NOT NULL,
  user_id TEXT NOT NULL,
  started_at TEXT NOT NULL,
  completed_at TEXT NOT NULL,
  status TEXT NOT NULL,
  model TEXT NOT NULL,
  output TEXT,
  error TEXT,
  prompt_tokens INTEGER NOT NULL DEFAULT 0,
  completion_tokens INTEGER NOT NULL DEFAULT 0,
  cost_micros INTEGER NOT NULL DEFAULT 0,
  read INTEGER NOT NULL DEFAULT 0,
  notification_status TEXT,
  FOREIGN KEY(task_id) REFERENCES tasks(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS runs_user_time_idx ON task_runs(user_id, started_at DESC);
CREATE INDEX IF NOT EXISTS runs_task_time_idx ON task_runs(task_id, started_at DESC);

CREATE TABLE IF NOT EXISTS execution_claims (
  task_id TEXT NOT NULL,
  due_at TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'queued',
  updated_at TEXT NOT NULL,
  PRIMARY KEY(task_id, due_at),
  FOREIGN KEY(task_id) REFERENCES tasks(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS push_registrations (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  token TEXT NOT NULL,
  kind TEXT NOT NULL,
  environment TEXT NOT NULL,
  operation_id TEXT,
  activity_id TEXT,
  updated_at TEXT NOT NULL,
  UNIQUE(user_id, token, kind)
);
CREATE INDEX IF NOT EXISTS push_user_kind_idx ON push_registrations(user_id, kind);
