-- 02_detect_tagged.sql : tag-based + passage-based skybridge candidates.
-- Populates the shared cand_raw table (created here, extended by 03).
--
-- Tuned to real DC data, where building=bridge has 0 uses and the dominant
-- mis-modelling is a building footprint spanning a street that passes under it
-- as tunnel=building_passage (the WEWCC case).

BEGIN;

DROP TABLE IF EXISTS cand_raw CASCADE;
CREATE TABLE cand_raw (
  rid           bigserial PRIMARY KEY,
  class         text,            -- bridge_struct | passage | footbridge | geom
  osm_type      text,
  osm_id        bigint,
  name          text,
  geom_m        geometry,        -- primary geometry (polygon, or line for footbridge)
  passage_way   bigint,          -- for class=passage: the building_passage way osm_id
  host_top      double precision,
  aspect        double precision,
  crosses       integer,
  touch_bldgs   integer,
  missing_base  boolean,
  covered       boolean,       -- structured flag (passages); drives the very_high band in 04
  reasons       text[]
);

-- ---------------------------------------------------------------------------
-- TIER 1 — tagged bridge structures: building=bridge / building:part=bridge
-- (highest precision; 0 building=bridge in DC, a couple of building:part=bridge)
-- ---------------------------------------------------------------------------
INSERT INTO cand_raw (class, osm_type, osm_id, name, geom_m, host_top, missing_base, reasons)
SELECT 'bridge_struct', osm_type, osm_id, tags->>'name', geom_m, height_render, missing_base,
       ARRAY['tag:'||COALESCE(NULLIF(building,''),'')||
             CASE WHEN building_part IS NOT NULL THEN ' building:part='||building_part ELSE '' END]
FROM buildings
WHERE building = 'bridge' OR building_part = 'bridge';

-- ---------------------------------------------------------------------------
-- TIER 2 — building / building:part footprint spanning a building_passage way
-- (the convention-center case). Strong signal: a polygon that genuinely covers
-- a road marked as passing UNDER a building.
-- ---------------------------------------------------------------------------
WITH passages AS (
  SELECT osm_id AS pway,
         tags->>'name' AS pname,
         (tags->>'covered' = 'yes') AS covered,
         ST_Transform(geom, region_srid()) AS g
  FROM osm_lines
  WHERE tags->>'tunnel' = 'building_passage'
)
INSERT INTO cand_raw (class, osm_type, osm_id, name, geom_m, passage_way, host_top, missing_base, covered, reasons)
SELECT DISTINCT ON (b.osm_id, p.pway)
       'passage', b.osm_type, b.osm_id, b.tags->>'name', b.geom_m, p.pway, b.height_render,
       b.missing_base, p.covered,
       ARRAY['spans building_passage'||COALESCE(' '||p.pname,'')||
             ' ('||round(ST_Length(ST_Intersection(b.geom_m, p.g))::numeric)||' m)'||
             CASE WHEN p.covered THEN ' covered' ELSE '' END]
FROM passages p
JOIN buildings b
  ON ST_Intersects(b.geom_m, p.g)
 AND (b.building IS NOT NULL OR b.building_part IS NOT NULL)
WHERE ST_Length(ST_Intersection(b.geom_m, p.g)) > 4   -- meaningfully spans
  -- don't re-flag a feature already caught as a tagged bridge structure (Tier 1)
  AND NOT EXISTS (SELECT 1 FROM cand_raw c WHERE c.osm_id = b.osm_id AND c.osm_type = b.osm_type)
-- deterministic pick per (building, passage): keep the longest-spanning row
ORDER BY b.osm_id, p.pway, ST_Length(ST_Intersection(b.geom_m, p.g)) DESC;

-- ---------------------------------------------------------------------------
-- TIER 3 — elevated pedestrian footways tagged as bridges (lines).
-- These render as routes (not solid walls) so they are a secondary, inventory
-- class — still surfaced for completeness ("Full" detection scope).
-- ---------------------------------------------------------------------------
INSERT INTO cand_raw (class, osm_type, osm_id, name, geom_m, host_top, missing_base, reasons)
SELECT 'footbridge', 'W', osm_id, tags->>'name', geom_m,
       NULL,
       TRUE,   -- footways carry no base by definition
       ARRAY['footway bridge'||
             COALESCE(' layer='||(tags->>'layer'),'')||
             CASE WHEN tags->>'covered'='yes' THEN ' covered' ELSE '' END||
             CASE WHEN tags ? 'level' THEN ' level='||(tags->>'level') ELSE '' END]
FROM roads
WHERE highway IN ('footway','path','pedestrian','steps','corridor')
  -- any truthy bridge value (yes, covered, viaduct, …), excluding ground-level boardwalks
  AND tags ? 'bridge' AND tags->>'bridge' NOT IN ('', 'no', 'boardwalk');

COMMIT;

\echo 'tagged detection:'
SELECT class, count(*) FROM cand_raw GROUP BY class ORDER BY class;
