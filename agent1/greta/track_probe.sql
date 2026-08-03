SET statement_timeout = '30s';
SHOW timezone;
SELECT EXTRACT(EPOCH FROM TIMESTAMPTZ '2026-07-12 00:00:00')::bigint AS from_ts,
       EXTRACT(EPOCH FROM TIMESTAMPTZ '2026-07-13 00:00:00')::bigint AS to_ts;

WITH vid AS (
  SELECT s.vehicle_id AS id
  FROM orders o
  JOIN schedules s ON s.id = o.schedule_id
  WHERE o.date = DATE '2026-07-12' AND o.discarded_at IS NULL AND s.vehicle_id IS NOT NULL
  LIMIT 1
)
SELECT id AS vid FROM vid;

WITH vid AS (
  SELECT s.vehicle_id AS id
  FROM orders o
  JOIN schedules s ON s.id = o.schedule_id
  WHERE o.date = DATE '2026-07-12' AND o.discarded_at IS NULL AND s.vehicle_id IS NOT NULL
  LIMIT 1
), bounds AS (
  SELECT EXTRACT(EPOCH FROM TIMESTAMPTZ '2026-07-12 00:00:00')::bigint AS from_ts,
         EXTRACT(EPOCH FROM TIMESTAMPTZ '2026-07-13 00:00:00')::bigint AS to_ts
)
SELECT 'unix' AS kind, COUNT(*) AS cnt
FROM vehicle_trackings vt, vid, bounds
WHERE vt.vehicle_id = vid.id AND vt.time >= bounds.from_ts AND vt.time < bounds.to_ts
UNION ALL
SELECT 'ms' AS kind, COUNT(*) AS cnt
FROM vehicle_trackings vt, vid, bounds
WHERE vt.vehicle_id = vid.id AND vt.time >= bounds.from_ts*1000 AND vt.time < bounds.to_ts*1000;

WITH vid AS (
  SELECT s.vehicle_id AS id
  FROM orders o
  JOIN schedules s ON s.id = o.schedule_id
  WHERE o.date = DATE '2026-07-12' AND o.discarded_at IS NULL AND s.vehicle_id IS NOT NULL
  LIMIT 1
)
SELECT vt.time, vt.speed,
       CASE WHEN vt.lonlat IS NULL THEN NULL ELSE ST_X(vt.lonlat::geometry) END AS lon,
       CASE WHEN vt.lonlat IS NULL THEN NULL ELSE ST_Y(vt.lonlat::geometry) END AS lat
FROM vehicle_trackings vt, vid
WHERE vt.vehicle_id = vid.id
ORDER BY vt.time DESC
LIMIT 5;
