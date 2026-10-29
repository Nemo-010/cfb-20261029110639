-- cfb control plane, revision 3
-- D1 holds intent. The agent holds reality. They are reconciled, never merged.

CREATE TABLE nodes (
  id           TEXT PRIMARY KEY,
  name         TEXT NOT NULL,
  capabilities TEXT NOT NULL DEFAULT '[]',   -- JSON array
  labels       TEXT NOT NULL DEFAULT '{}',   -- JSON object
  state        TEXT NOT NULL DEFAULT 'pending'
                 CHECK (state IN ('pending','ready','stale','draining','revoked')),
  conn_id      INTEGER NOT NULL DEFAULT 0,   -- fencing token
  last_seen    INTEGER,
  created_at   INTEGER NOT NULL
);

CREATE TABLE workloads (
  id          TEXT PRIMARY KEY,
  node_id     TEXT REFERENCES nodes(id) ON DELETE SET NULL,
  spec        TEXT NOT NULL,                 -- JSON WorkloadSpec
  -- The reconciliation key. Bumped on every spec change; the agent reports the generation it
  -- has applied, and the control plane pushes only when it is behind. One integer removes
  -- most reconcile bugs.
  generation  INTEGER NOT NULL DEFAULT 1,
  state       TEXT NOT NULL DEFAULT 'pending'
                CHECK (state IN ('pending','starting','running','succeeded','failed','stopped')),
  exit_code   INTEGER,
  started_at  INTEGER,
  finished_at INTEGER,
  updated_at  INTEGER NOT NULL
);

CREATE INDEX workloads_by_node ON workloads(node_id, state);
CREATE INDEX workloads_by_state ON workloads(state, updated_at);

-- One-shot submissions. A separate table from workloads because a job has an idempotency key
-- and a workload has a lifecycle; conflating them makes cancel ambiguous.
CREATE TABLE jobs (
  id            TEXT PRIMARY KEY,
  workload_id   TEXT NOT NULL REFERENCES workloads(id) ON DELETE CASCADE,
  idempotency   TEXT NOT NULL UNIQUE,
  submitted_by  TEXT NOT NULL,
  created_at    INTEGER NOT NULL
);

-- Enrolment tokens are single use. The row is deleted on redemption, so a replay finds nothing.
CREATE TABLE enrol_tokens (
  token_hash   TEXT PRIMARY KEY,
  node_id      TEXT NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,
  expires_at   INTEGER NOT NULL,
  created_at   INTEGER NOT NULL
);

CREATE TABLE node_credentials (
  node_id      TEXT PRIMARY KEY REFERENCES nodes(id) ON DELETE CASCADE,
  token_hash   TEXT NOT NULL,
  issued_at    INTEGER NOT NULL,
  last_used_at INTEGER
);

CREATE TABLE audit (
  id       INTEGER PRIMARY KEY AUTOINCREMENT,
  at       INTEGER NOT NULL,
  actor    TEXT NOT NULL,
  action   TEXT NOT NULL,
  target   TEXT NOT NULL,
  outcome  TEXT NOT NULL CHECK (outcome IN ('allowed','denied','error'))
);

CREATE INDEX audit_by_time ON audit(at);
