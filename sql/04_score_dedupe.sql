-- 04_score_dedupe.sql : score raw candidates into the final skybridge_candidates
-- table, assigning a confidence band and an action (auto_correct vs review).
--
-- Confidence policy (from the verified research):
--   very_high : tagged bridge structure (building=bridge / building:part=bridge)
--   high      : building spans a building_passage (the solid-wall bug), or a
--               strong untagged geometric triple
--   medium    : weaker geometric hit, or a footway bridge (renders as a route,
--               not a wall — inventory only)
-- auto_correct applies the local float fix; review queues for a human.

BEGIN;

DROP TABLE IF EXISTS skybridge_candidates CASCADE;
CREATE TABLE skybridge_candidates AS
SELECT
  rid AS cand_id,
  class, osm_type, osm_id, name, geom_m, passage_way, host_top,
  aspect, crosses, touch_bldgs, missing_base, covered, reasons,
  CASE
    WHEN class = 'bridge_struct'        THEN 'very_high'
    WHEN class = 'passage' AND covered  THEN 'very_high'   -- structured flag, set in 02
    WHEN class = 'passage'              THEN 'high'
    WHEN class = 'geom' AND aspect >= 6 THEN 'high'        -- (touch>=2 is already implied for geom)
    WHEN class = 'geom'                 THEN 'medium'
    WHEN class = 'footbridge'           THEN 'medium'
    ELSE 'medium'
  END AS confidence,
  round(ST_X(ST_Transform(ST_Centroid(geom_m),4326))::numeric,6) AS lon,
  round(ST_Y(ST_Transform(ST_Centroid(geom_m),4326))::numeric,6) AS lat
FROM cand_raw cr
-- DEDUP: one physical span can be mapped as both a footway-bridge LINE and a
-- building/passage POLYGON. Drop the footbridge line when most of it lies inside
-- a passage / geom / bridge_struct polygon candidate (the polygon is the better
-- representation and carries the wall-correction).
WHERE NOT (cr.class = 'footbridge' AND EXISTS (
  SELECT 1 FROM cand_raw p
  WHERE p.class IN ('passage', 'geom', 'bridge_struct')
    AND p.geom_m && cr.geom_m
    AND ST_Intersects(p.geom_m, cr.geom_m)
    AND ST_Length(ST_Intersection(cr.geom_m, p.geom_m)) > 0.5 * ST_Length(cr.geom_m)
));

ALTER TABLE skybridge_candidates ADD COLUMN action text;
UPDATE skybridge_candidates SET action =
  CASE
    WHEN class = 'footbridge'                         THEN 'inventory'   -- not a solid-wall bug
    WHEN confidence IN ('very_high','high')           THEN 'auto_correct'
    ELSE 'review'
  END;

ALTER TABLE skybridge_candidates ADD PRIMARY KEY (cand_id);
CREATE INDEX sc_geom_idx ON skybridge_candidates USING gist (geom_m);

COMMIT;

\echo 'final candidates by class x confidence x action:'
SELECT class, confidence, action, count(*)
FROM skybridge_candidates GROUP BY 1,2,3 ORDER BY 1,2;
