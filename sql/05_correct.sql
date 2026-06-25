-- 05_correct.sql : compute the corrected floating geometry for each candidate.
--
-- Outputs:
--   corrected_spans   the lifted slab/deck to render (base_h..top_h, the region UTM CRS)
--   building_cuts     per host, the union of overlapping span footprints to
--                     subtract (the "modified footprint" / breezeway opening)
--
-- min_height (base_h) = clearance_floor: the legal under-clearance of whatever
--   is crossed (~4.5 m over a road, ~5.0 m if covered, ~6.0 m over rail).
--   Candidates are gated to lack a float tag, so there is no storey floor to
--   anchor to — clearance is the floor.
-- height (top) = ground-to-top of the span; we keep the host's top where known.
-- Invariant enforced: base_h < top_h (renderers reject base >= height).

BEGIN;

-- half-width (m) used to turn a passage centreline into a street corridor slab
\set corridor_halfwidth 9

-- clearance floor for a candidate, in metres
CREATE OR REPLACE FUNCTION clearance_floor(g geometry, covered boolean) RETURNS double precision AS $$
  SELECT CASE
    WHEN EXISTS (SELECT 1 FROM rail r WHERE r.geom_m && g AND ST_Crosses(g, r.geom_m)) THEN 6.0
    WHEN covered THEN 5.0
    ELSE 4.5
  END;
$$ LANGUAGE sql STABLE;

-- extend_line: lengthen a linestring by d metres at BOTH ends along its end
-- segment directions. OSM splits a building_passage way to exactly the segment
-- under the building (often mapped a touch short), so we extend past both faces
-- and then clip to the footprint — guaranteeing the corridor slices edge-to-edge.
CREATE OR REPLACE FUNCTION extend_line(line geometry, d double precision) RETURNS geometry AS $$
DECLARE
  n int; s geometry; s2 geometry; e geometry; e2 geometry;
  az_s double precision; az_e double precision; ns geometry; ne geometry;
BEGIN
  line := ST_LineMerge(line);
  IF GeometryType(line) <> 'LINESTRING' THEN
    SELECT geom INTO line FROM (SELECT (ST_Dump(line)).geom AS geom) q
     ORDER BY ST_Length(geom) DESC LIMIT 1;     -- longest part of a multilinestring
  END IF;
  n := ST_NPoints(line);
  IF n IS NULL OR n < 2 THEN RETURN line; END IF;
  s := ST_PointN(line,1); s2 := ST_PointN(line,2);
  e := ST_PointN(line,n); e2 := ST_PointN(line,n-1);
  az_s := ST_Azimuth(s2, s); az_e := ST_Azimuth(e2, e);
  ns := CASE WHEN az_s IS NULL THEN s
        ELSE ST_SetSRID(ST_MakePoint(ST_X(s)+d*sin(az_s), ST_Y(s)+d*cos(az_s)), ST_SRID(line)) END;
  ne := CASE WHEN az_e IS NULL THEN e
        ELSE ST_SetSRID(ST_MakePoint(ST_X(e)+d*sin(az_e), ST_Y(e)+d*cos(az_e)), ST_SRID(line)) END;
  RETURN ST_MakeLine(ARRAY[ns, line, ne]);
END;
$$ LANGUAGE plpgsql IMMUTABLE;

DROP TABLE IF EXISTS corrected_spans CASCADE;
CREATE TABLE corrected_spans (
  cand_id bigint, class text, confidence text, action text, name text,
  geom_m geometry, base_h double precision, top_h double precision, reason text
);

-- ---------------------------------------------------------------------------
-- PASSAGE: the lifted lintel = host footprint ∩ street corridor, raised to the
-- clearance height. (One row per host×passage candidate.)
-- ---------------------------------------------------------------------------
INSERT INTO corrected_spans
SELECT c.cand_id, c.class, c.confidence, c.action, c.name,
       ST_Multi(ST_CollectionExtract(
         ST_Intersection(c.geom_m,
           ST_Buffer(extend_line(p.g, 60), :corridor_halfwidth, 'endcap=flat join=mitre')), 3)) AS geom_m,
       clearance_floor(c.geom_m, array_to_string(c.reasons,' ') LIKE '%covered%') AS base_h,
       GREATEST(COALESCE(c.host_top, 8),
                clearance_floor(c.geom_m, false) + 3)                             AS top_h,
       array_to_string(c.reasons,'; ')
FROM skybridge_candidates c
JOIN LATERAL (
  SELECT ST_Transform(geom, region_srid()) AS g FROM osm_lines WHERE osm_id = c.passage_way LIMIT 1
) p ON true
WHERE c.class = 'passage';

-- ---------------------------------------------------------------------------
-- BRIDGE_STRUCT / GEOM: the polygon itself is the span; float its base.
-- ---------------------------------------------------------------------------
INSERT INTO corrected_spans
SELECT c.cand_id, c.class, c.confidence, c.action, c.name,
       ST_Multi(c.geom_m),
       clearance_floor(c.geom_m, false) AS base_h,
       GREATEST(COALESCE(c.host_top, 8), clearance_floor(c.geom_m, false) + 3) AS top_h,
       array_to_string(c.reasons,'; ')
FROM skybridge_candidates c
WHERE c.class IN ('bridge_struct','geom');

-- ---------------------------------------------------------------------------
-- FOOTBRIDGE: buffer the line into a thin deck (inventory; not a wall bug).
-- ---------------------------------------------------------------------------
INSERT INTO corrected_spans
SELECT c.cand_id, c.class, c.confidence, c.action, c.name,
       ST_Multi(ST_Buffer(c.geom_m, 2.0, 'endcap=round join=round')),
       clearance_floor(c.geom_m, false) AS base_h,
       clearance_floor(c.geom_m, false) + 0.6 AS top_h,           -- thin walkway deck
       array_to_string(c.reasons,'; ')
FROM skybridge_candidates c
WHERE c.class = 'footbridge';

-- enforce base < top
UPDATE corrected_spans SET top_h = base_h + 1 WHERE top_h <= base_h;
DELETE FROM corrected_spans WHERE geom_m IS NULL OR ST_IsEmpty(geom_m);

-- ---------------------------------------------------------------------------
-- BUILDING CUTS: for the "modified footprint", subtract from each building the
-- footprint of ANY detected span that overlaps it (passage corridors, and any
-- other span sitting inside a building). The < 0.9*host area guard prevents a
-- span that IS the whole building (bridge_struct/geom) from deleting it — those
-- are removed and shown lifted instead. Footbridges (thin decks over streets)
-- are not building modifications, so they are excluded.
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS building_carves CASCADE;   -- legacy name (pre-generalisation)
DROP TABLE IF EXISTS building_cuts CASCADE;
CREATE TABLE building_cuts AS
SELECT b.osm_id AS host_osm_id, b.osm_type AS host_osm_type,
       ST_Union(ST_Intersection(s.geom_m, b.geom_m)) AS cut_m
FROM buildings b
JOIN corrected_spans s
  ON s.geom_m && b.geom_m AND ST_Intersects(s.geom_m, b.geom_m)
WHERE s.class <> 'footbridge'
  -- guard on the CLIPPED area actually subtracted (not the full span), so a span
  -- that nearly fills the host can't carve it to nothing (92 also keeps the
  -- original footprint if the difference comes out empty).
  AND ST_Area(ST_Intersection(s.geom_m, b.geom_m)) < 0.9 * ST_Area(b.geom_m)
GROUP BY b.osm_id, b.osm_type;
CREATE INDEX bcuts_geom_idx ON building_cuts USING gist (cut_m);
CREATE INDEX bcuts_host_idx ON building_cuts (host_osm_id, host_osm_type);

COMMIT;

\echo 'corrected_spans by class:'
SELECT class, action, count(*), round(min(base_h)::numeric,1) min_base, round(max(top_h)::numeric,1) max_top
FROM corrected_spans GROUP BY 1,2 ORDER BY 1;
\echo 'WEWCC corrected slabs:'
SELECT cand_id, round(base_h::numeric,1) base_h, round(top_h::numeric,1) top_h, reason
FROM corrected_spans WHERE name = 'Walter E. Washington Convention Center';
