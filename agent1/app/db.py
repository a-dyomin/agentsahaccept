"""PostgreSQL access for Agent1 control plane."""
from __future__ import annotations

import os
from contextlib import contextmanager
from typing import Any, Iterator

import psycopg
from psycopg.rows import dict_row

DATABASE_URL = os.environ.get(
    "AGENT1_DATABASE_URL",
    "postgresql://agent1:agent1@127.0.0.1:5432/agent1",
)


@contextmanager
def db() -> Iterator[psycopg.Connection]:
    conn = psycopg.connect(DATABASE_URL, row_factory=dict_row, autocommit=False)
    try:
        yield conn
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


SCHEMA_SQL = """
CREATE TABLE IF NOT EXISTS meta (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS runs (
  id TEXT PRIMARY KEY,
  day TEXT NOT NULL,
  status TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL,
  started_at TIMESTAMPTZ,
  finished_at TIMESTAMPTZ,
  note TEXT
);
CREATE TABLE IF NOT EXISTS jobs (
  id TEXT PRIMARY KEY,
  run_id TEXT NOT NULL REFERENCES runs(id),
  order_id BIGINT NOT NULL,
  kind TEXT NOT NULL,
  payload JSONB NOT NULL,
  status TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL,
  leased_at TIMESTAMPTZ,
  finished_at TIMESTAMPTZ,
  error TEXT
);
CREATE INDEX IF NOT EXISTS idx_jobs_status_created ON jobs(status, created_at);
CREATE INDEX IF NOT EXISTS idx_jobs_run ON jobs(run_id);
CREATE INDEX IF NOT EXISTS idx_jobs_order ON jobs(order_id);
CREATE TABLE IF NOT EXISTS results (
  id TEXT PRIMARY KEY,
  run_id TEXT NOT NULL REFERENCES runs(id),
  job_id TEXT NOT NULL REFERENCES jobs(id),
  order_id BIGINT NOT NULL,
  agent_verdict TEXT,
  agent_detail JSONB,
  human_verdict TEXT,
  match_flag SMALLINT,
  created_at TIMESTAMPTZ NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_results_created ON results(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_results_order ON results(order_id);
CREATE INDEX IF NOT EXISTS idx_results_match ON results(match_flag);
CREATE TABLE IF NOT EXISTS events (
  id BIGSERIAL PRIMARY KEY,
  ts TIMESTAMPTZ NOT NULL,
  level TEXT NOT NULL,
  message TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_events_id ON events(id DESC);
"""


def init_db() -> None:
    with db() as conn:
        conn.execute(SCHEMA_SQL)
        row = conn.execute(
            "SELECT value FROM meta WHERE key=%s", ("agent_state",)
        ).fetchone()
        if not row:
            conn.execute(
                "INSERT INTO meta(key, value) VALUES (%s, %s)",
                ("agent_state", "idle"),
            )


def fetch_one(conn: psycopg.Connection, sql: str, params: tuple[Any, ...] = ()) -> dict | None:
    return conn.execute(sql, params).fetchone()


def fetch_all(conn: psycopg.Connection, sql: str, params: tuple[Any, ...] = ()) -> list[dict]:
    return list(conn.execute(sql, params).fetchall())
