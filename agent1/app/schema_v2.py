"""Extended schema for Phase-1 shadow agent."""
from __future__ import annotations

SCHEMA_V2 = """
CREATE TABLE IF NOT EXISTS ingest_snapshots (
  id BIGSERIAL PRIMARY KEY,
  day DATE NOT NULL UNIQUE,
  exported_at TIMESTAMPTZ,
  counts JSONB NOT NULL DEFAULT '{}',
  status TEXT NOT NULL DEFAULT 'done',
  error TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS orders_day (
  day DATE NOT NULL,
  order_id BIGINT NOT NULL,
  state TEXT,
  site_id BIGINT,
  site_address TEXT,
  site_stype TEXT,
  site_lat DOUBLE PRECISION,
  site_lon DOUBLE PRECISION,
  schedule_id BIGINT,
  vehicle_id BIGINT,
  plate TEXT,
  provider_name TEXT,
  waste_type_name TEXT,
  create_type TEXT,
  change_source TEXT,
  transfered BOOLEAN,
  container_count INT,
  started_at TIMESTAMPTZ,
  finished_at TIMESTAMPTZ,
  canceled_at TIMESTAMPTZ,
  human_breach_state TEXT,
  human_accept_note TEXT,
  human_regoper_note TEXT,
  has_report BOOLEAN,
  report_success BOOLEAN,
  report_comment TEXT,
  fail_reason TEXT,
  photo_count INT,
  geo_flag TEXT,
  geo_min_m DOUBLE PRECISION,
  geo_out INT,
  geo_no_coord INT,
  track_exists BOOLEAN,
  track_flag TEXT,
  track_min_m DOUBLE PRECISION,
  arrival_ts BIGINT,
  time_flag TEXT,
  time_dev_min DOUBLE PRECISION,
  foto_doezd_flag TEXT,
  foto_doezd_m DOUBLE PRECISION,
  raw JSONB,
  PRIMARY KEY (day, order_id)
);
CREATE INDEX IF NOT EXISTS idx_orders_day_state ON orders_day(day, state);
-- migrate older DBs that were created before schedule_id existed
ALTER TABLE orders_day ADD COLUMN IF NOT EXISTS schedule_id BIGINT;
ALTER TABLE orders_day ADD COLUMN IF NOT EXISTS foto_doezd_flag TEXT;
ALTER TABLE orders_day ADD COLUMN IF NOT EXISTS foto_doezd_m DOUBLE PRECISION;
ALTER TABLE photos_day ADD COLUMN IF NOT EXISTS photo_url TEXT;
ALTER TABLE photos_day ADD COLUMN IF NOT EXISTS schedule_id BIGINT;
CREATE INDEX IF NOT EXISTS idx_orders_day_schedule ON orders_day(day, schedule_id);

-- Greta Schedule = «смена»; id == orders.schedule_id / photos.schedule_id
CREATE TABLE IF NOT EXISTS schedules_day (
  day DATE NOT NULL,
  schedule_id BIGINT NOT NULL,
  vehicle_id BIGINT,
  plate TEXT,
  driver_id BIGINT,
  state TEXT,
  start_at TIMESTAMPTZ,
  finish_at TIMESTAMPTZ,
  started_at TIMESTAMPTZ,
  finished_at TIMESTAMPTZ,
  route_id BIGINT,
  scope_type TEXT,
  change_source TEXT,
  mileage DOUBLE PRECISION,
  provider_id BIGINT,
  raw JSONB,
  PRIMARY KEY (day, schedule_id)
);
CREATE INDEX IF NOT EXISTS idx_schedules_day_vehicle ON schedules_day(day, vehicle_id);

CREATE TABLE IF NOT EXISTS photos_day (
  day DATE NOT NULL,
  photo_id BIGINT NOT NULL,
  order_id BIGINT NOT NULL,
  ptype TEXT,
  time TIMESTAMPTZ,
  filename TEXT,
  blob_key TEXT,
  photo_url TEXT,
  lon DOUBLE PRECISION,
  lat DOUBLE PRECISION,
  cached_path TEXT,
  schedule_id BIGINT,
  PRIMARY KEY (day, photo_id)
);
CREATE INDEX IF NOT EXISTS idx_photos_day_order ON photos_day(day, order_id);
CREATE INDEX IF NOT EXISTS idx_photos_day_schedule ON photos_day(day, schedule_id);
-- migrate older DBs
ALTER TABLE photos_day ADD COLUMN IF NOT EXISTS photo_url TEXT;
ALTER TABLE photos_day ADD COLUMN IF NOT EXISTS schedule_id BIGINT;

CREATE TABLE IF NOT EXISTS agent_decisions (
  day DATE NOT NULL,
  order_id BIGINT NOT NULL,
  run_id TEXT,
  itog TEXT NOT NULL,
  za_chto TEXT,
  pometki TEXT,
  checklist TEXT,
  stage1 JSONB,
  stage2 JSONB,
  latency_ms INT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (day, order_id)
);
CREATE INDEX IF NOT EXISTS idx_agent_decisions_itog ON agent_decisions(day, itog);

CREATE TABLE IF NOT EXISTS human_decisions (
  day DATE NOT NULL,
  order_id BIGINT NOT NULL,
  breach_state TEXT,
  accept_note TEXT,
  regoper_note TEXT,
  synced_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (day, order_id)
);

CREATE TABLE IF NOT EXISTS comparisons (
  day DATE NOT NULL,
  order_id BIGINT NOT NULL,
  agent_itog TEXT,
  human_breach_state TEXT,
  match_flag SMALLINT,
  diff_reason TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (day, order_id)
);
CREATE INDEX IF NOT EXISTS idx_comparisons_match ON comparisons(day, match_flag);

CREATE TABLE IF NOT EXISTS vision_usage (
  id BIGSERIAL PRIMARY KEY,
  day DATE NOT NULL,
  order_id BIGINT NOT NULL,
  run_id TEXT,
  model TEXT,
  prompt_tokens INT NOT NULL DEFAULT 0,
  completion_tokens INT NOT NULL DEFAULT 0,
  total_tokens INT NOT NULL DEFAULT 0,
  cost_usd DOUBLE PRECISION NOT NULL DEFAULT 0,
  checklist TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_vision_usage_day ON vision_usage(day);
CREATE INDEX IF NOT EXISTS idx_vision_usage_created ON vision_usage(created_at);
"""
