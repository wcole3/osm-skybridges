-- 03_detect_geometry.sql : UNTAGGED span detection by geometry.
-- A polygon is an untagged span candidate when ALL hold:
--   (a) elongation: oriented-bbox aspect ratio >= config.aspect_min (~4)
--   (b) it ST_Crosses a drivable/rail/water obstacle centerline
--   (c) it abuts >= 2 DISTINCT other buildings (connects two structures)
--   (d) it lacks a float base (missing_base)
-- Requiring all four together rejects DC rowhouses (elongated but cross nothing)
-- and ordinary buildings straddling a passage at ground level.

-- mbr_aspect (oriented-bbox long/short ratio) is defined in 00_init.sql.

BEGIN;

WITH cfg AS (
  SELECT (SELECT value FROM config WHERE key='aspect_min') AS aspect_min
),
shaped AS (   -- (a)+(d) first: cheap filters before spatial joins
  SELECT b.osm_type, b.osm_id, b.tags->>'name' AS name, b.geom_m, b.height_render,
         mbr_aspect(b.geom_m) AS aspect
  FROM buildings b, cfg
  WHERE b.missing_base
    AND b.building IS DISTINCT FROM 'bridge'
    AND ST_Area(b.geom_m) BETWEEN 20 AND 5000     -- bridge-plausible footprint
    AND mbr_aspect(b.geom_m) >= cfg.aspect_min
)
INSERT INTO cand_raw (class, osm_type, osm_id, name, geom_m, host_top, aspect, crosses, touch_bldgs, missing_base, reasons)
SELECT 'geom', s.osm_type, s.osm_id, s.name, s.geom_m, s.height_render, round(s.aspect::numeric,1),
       x.crosses, t.touch_bldgs, TRUE,
       ARRAY['aspect='||round(s.aspect::numeric,1)||' crosses='||x.crosses||' touches='||t.touch_bldgs||' buildings']
FROM shaped s
CROSS JOIN LATERAL (
  SELECT count(*) AS crosses FROM obstacles o WHERE o.geom_m && s.geom_m AND ST_Crosses(s.geom_m, o.geom_m)
) x
CROSS JOIN LATERAL (
  SELECT count(DISTINCT o2.osm_id) AS touch_bldgs FROM buildings o2
  WHERE o2.osm_id <> s.osm_id AND o2.geom_m && s.geom_m AND ST_Intersects(o2.geom_m, s.geom_m)
) t
WHERE x.crosses >= 1
  AND t.touch_bldgs >= 2
  -- don't double-insert something already caught as a tagged/passage candidate
  AND NOT EXISTS (SELECT 1 FROM cand_raw c WHERE c.osm_id = s.osm_id AND c.class <> 'geom');

COMMIT;

\echo 'after geometry detection:'
SELECT class, count(*) FROM cand_raw GROUP BY class ORDER BY class;
