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
--
-- GEOMETRY QUALITY (added): the passage corridor is built wall-to-wall, snapped
-- to the host facade (wall-following), always-valid (clean_span), then severe
-- shapes are surgically cleaned; anything still pathological reverts to the
-- constructed geometry and is downgraded to 'review' (see 91 / 99_selfcheck).

-- Load the geometry-correction tunables from the config table into psql vars so
-- the SQL below reads them by name. (String buffer options like join/endcap stay
-- as SQL literals — config holds only numeric scalars.)
SELECT
  (SELECT value FROM config WHERE key='corridor_halfwidth')  AS corridor_halfwidth,
  (SELECT value FROM config WHERE key='corridor_reach')      AS corridor_reach,
  (SELECT value FROM config WHERE key='corridor_reach_cap')  AS corridor_reach_cap,
  (SELECT value FROM config WHERE key='footbridge_halfwidth') AS footbridge_halfwidth,
  (SELECT value FROM config WHERE key='snap_tol')            AS snap_tol,
  (SELECT value FROM config WHERE key='open_k')              AS open_k,
  (SELECT value FROM config WHERE key='open_k_cut')          AS open_k_cut,
  (SELECT value FROM config WHERE key='min_cut_inradius')    AS min_cut_inradius,
  (SELECT value FROM config WHERE key='max_cut_aspect')      AS max_cut_aspect,
  (SELECT value FROM config WHERE key='cut_expand')          AS cut_expand,
  (SELECT value FROM config WHERE key='open_area_keep')      AS open_area_keep,
  (SELECT value FROM config WHERE key='min_part_area')       AS min_part_area,
  (SELECT value FROM config WHERE key='min_inradius')        AS min_inradius,
  (SELECT value FROM config WHERE key='min_compactness')     AS min_compactness,
  (SELECT value FROM config WHERE key='severe_inradius')     AS severe_inradius,
  (SELECT value FROM config WHERE key='vw_area_tol')         AS vw_area_tol,
  (SELECT value FROM config WHERE key='hard_min_inradius')   AS hard_min_inradius,
  (SELECT value FROM config WHERE key='clean_area_loss_max') AS clean_area_loss_max
\gset

BEGIN;

-- clearance floor for a candidate, in metres
CREATE OR REPLACE FUNCTION clearance_floor(g geometry, covered boolean) RETURNS double precision AS $$
  SELECT CASE
    WHEN EXISTS (SELECT 1 FROM rail r WHERE r.geom_m && g AND ST_Crosses(g, r.geom_m)) THEN 6.0
    WHEN covered THEN 5.0
    ELSE 4.5
  END;
$$ LANGUAGE sql STABLE;

-- extend_line: lengthen a linestring by d metres at BOTH ends along its end
-- segment directions. OSM splits a building_passage way to roughly the segment
-- under the building (often mapped a touch short), so we extend past both faces
-- and then clip to the footprint — guaranteeing the corridor slices edge-to-edge.
-- NOTE: d is now a small reach (config corridor_reach, ~20 m) rather than a blind
-- 60 m overshoot; a large overshoot clipped against an oblique wall is what used
-- to produce the triangular wedge.
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
  geom_m geometry, base_h double precision, top_h double precision, reason text,
  -- geom_build: the constructed geometry BEFORE the surgical auto-clean. It is the
  -- baseline the severity decision compares against and reverts to (so a correct
  -- shrink from the bounded-reach fix is never mistaken for cleanup area-loss).
  geom_build geometry,
  qa_halfwidth double precision, qa_compactness double precision, qa_min_part_area double precision,
  qa_cleaned boolean DEFAULT false,           -- did surgical cleanup get applied?
  qa_status  text    DEFAULT 'ok'             -- ok | auto_cleaned | clean_failed | area_loss_high | still_severe
);

-- ---------------------------------------------------------------------------
-- PASSAGE: the lifted lintel = host footprint ∩ a wall-snapped street corridor,
-- raised to the clearance height. The SAME wall-snapped notch geometry feeds the
-- span and (below) the host cut — one source of truth. (One row per host×passage.)
--   * mitre_limit caps any spike from a corridor bend
--   * bounded reach (corridor_reach) limits overshoot
--   * ST_Snap pulls the corridor's exit edges onto the real walls (wall-following)
--   * clean_span makes it always-valid, polygon-only MultiPolygon
-- ---------------------------------------------------------------------------
INSERT INTO corrected_spans (cand_id, class, confidence, action, name, geom_m, geom_build, base_h, top_h, reason)
SELECT c.cand_id, c.class, c.confidence, c.action, c.name,
       notch.g, notch.g,
       clearance_floor(c.geom_m, array_to_string(c.reasons,' ') LIKE '%covered%') AS base_h,
       GREATEST(COALESCE(c.host_top, 8),
                clearance_floor(c.geom_m, false) + 3)                             AS top_h,
       array_to_string(c.reasons,'; ')
FROM skybridge_candidates c
JOIN LATERAL (
  SELECT ST_Transform(geom, region_srid()) AS g FROM osm_lines WHERE osm_id = c.passage_way LIMIT 1
) p ON true
CROSS JOIN LATERAL (
  SELECT clean_span(
           ST_Intersection(
             ST_Snap(
               ST_Buffer(extend_line(p.g, LEAST(:corridor_reach_cap, :corridor_reach)),
                         :corridor_halfwidth, 'endcap=flat join=mitre mitre_limit=2.0'),
               ST_Boundary(c.geom_m), :snap_tol),
             c.geom_m)) AS g
) notch
WHERE c.class = 'passage';

-- ---------------------------------------------------------------------------
-- BRIDGE_STRUCT / GEOM: the polygon itself is the span; float its base. These
-- represent whole real structures, so they are only made valid (clean_span) —
-- never eroded/opened (that would distort a real shape).
-- ---------------------------------------------------------------------------
INSERT INTO corrected_spans (cand_id, class, confidence, action, name, geom_m, geom_build, base_h, top_h, reason)
SELECT c.cand_id, c.class, c.confidence, c.action, c.name,
       clean_span(c.geom_m), clean_span(c.geom_m),
       clearance_floor(c.geom_m, false) AS base_h,
       GREATEST(COALESCE(c.host_top, 8), clearance_floor(c.geom_m, false) + 3) AS top_h,
       array_to_string(c.reasons,'; ')
FROM skybridge_candidates c
WHERE c.class IN ('bridge_struct','geom');

-- ---------------------------------------------------------------------------
-- FOOTBRIDGE: buffer the line into a thin deck (inventory; not a wall bug).
-- Flat caps + mitre (was round/round) so it has no rounded quarter-circle arcs.
-- ---------------------------------------------------------------------------
INSERT INTO corrected_spans (cand_id, class, confidence, action, name, geom_m, geom_build, base_h, top_h, reason)
SELECT c.cand_id, c.class, c.confidence, c.action, c.name,
       deck.g, deck.g,
       clearance_floor(c.geom_m, false) AS base_h,
       clearance_floor(c.geom_m, false) + 0.6 AS top_h,           -- thin walkway deck
       array_to_string(c.reasons,'; ')
FROM skybridge_candidates c
CROSS JOIN LATERAL (
  SELECT clean_span(ST_Buffer(c.geom_m, :footbridge_halfwidth,
                              'endcap=flat join=mitre mitre_limit=2.0')) AS g
) deck
WHERE c.class = 'footbridge';

-- enforce base < top, and drop anything that constructed empty
UPDATE corrected_spans SET top_h = base_h + 1 WHERE top_h <= base_h;
DELETE FROM corrected_spans
 WHERE geom_m IS NULL OR ST_IsEmpty(geom_m) OR geom_build IS NULL OR ST_IsEmpty(geom_build);

-- ---------------------------------------------------------------------------
-- SEVERE-GEOMETRY AUTO-CLEAN (passage spans only).
-- Surgically clean each constructed passage span. Then decide per the chosen
-- policy: auto-clean mild cases; for severe/uncertain ones REVERT to geom_build
-- and downgrade auto_correct -> review so a human inspects it (nothing broken
-- ships silently). bridge_struct/geom/footbridge are never eroded.
-- ---------------------------------------------------------------------------
WITH cleaned AS (
  SELECT s.cand_id, s.geom_build AS gb,
         clean_geom_passage(s.geom_build, :min_part_area, :min_inradius,
                            :min_compactness, :open_k, :open_area_keep) AS gc
  FROM corrected_spans s
  WHERE s.class = 'passage'
), decided AS (
  SELECT cand_id, gb, gc,
    CASE
      WHEN gc IS NULL OR ST_IsEmpty(gc)                              THEN 'clean_failed'
      WHEN 1 - ST_Area(gc)/NULLIF(ST_Area(gb),0) > :clean_area_loss_max THEN 'area_loss_high'
      WHEN qa_min_halfwidth(gc) < :severe_inradius                  THEN 'still_severe'
      ELSE 'auto_cleaned'
    END AS status
  FROM cleaned
)
UPDATE corrected_spans s SET
  geom_m     = CASE WHEN d.status = 'auto_cleaned' THEN d.gc ELSE d.gb END,
  qa_cleaned = (d.status = 'auto_cleaned'),
  qa_status  = d.status,
  action     = CASE WHEN d.status <> 'auto_cleaned' AND s.action = 'auto_correct'
                    THEN 'review' ELSE s.action END
FROM decided d
WHERE d.cand_id = s.cand_id;

-- keep skybridge_candidates.action in sync (91's QA queue reads action from there)
UPDATE skybridge_candidates sc SET action = 'review'
FROM corrected_spans s
WHERE s.cand_id = sc.cand_id AND s.class = 'passage'
  AND s.qa_status <> 'auto_cleaned' AND sc.action = 'auto_correct';

-- materialise the shape-quality metrics ONCE on the final geometry (reused by 91/99)
UPDATE corrected_spans SET
  qa_halfwidth     = qa_min_halfwidth(geom_m),
  qa_compactness   = qa_compactness(geom_m),
  qa_min_part_area = qa_min_part_area(geom_m);

-- ---------------------------------------------------------------------------
-- BUILDING CUTS: for the "modified footprint", subtract from each building the
-- footprint of ANY detected span that overlaps it (passage corridors, and any
-- other span sitting inside a building). For passages s.geom_m is now the
-- wall-snapped notch, so the cut aligns exactly with the span (single source of
-- truth). The < 0.9*host area per-span guard prevents a span that IS the whole
-- building (bridge_struct/geom) from deleting it — those are removed and shown
-- lifted instead. Footbridges (thin decks over streets) are excluded.
-- cut_m is built in stages to keep only genuine openings:
--   (1) OVERLAP-SUBSTANCE GATE (the key fix for grazing slivers): a span lives
--       inside its host, so where that host overlaps a NEIGHBOUR (common in OSM),
--       the span clips a thin 1-3 m strip off the neighbour along the shared wall.
--       Keep an overlap only if it has a substantial part (fattest inscribed
--       radius >= min_cut_inradius) — real openings do (own-host cuts are >=2.5 m,
--       legit relation-member cuts too); pure grazing strips don't.
--   (2) simplify_vw (Visvalingam-Whyatt, area-based) collapses thin spikes, then
--       prune_parts drops any residual thin/tiny disjoint parts within a kept overlap;
--   (3) drop_ribbons removes long-thin ribbon parts (a very long passage's cut is
--       a real but slivery opening) — the passage still shows as a lifted span;
--   (4) morph_open smooths thin tongues still CONNECTED to a fat cut.
--   (5) EXPAND (modeler knob): dilate the clean cut by cut_expand toward the
--       facade and clip back to the host, so it slices the thin remnant "walls"
--       the span left un-cut along the opening edges. Clipping to the host keeps
--       it from spilling past the footprint; too-large values over-cut (empty the
--       host -> 92 falls back to the original footprint).
-- The <0.9*host-area guard still stops a span that IS the whole building from
-- carving it away. A cut that cleans to nothing is deleted; 92 then keeps the
-- original footprint.
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS building_carves CASCADE;   -- legacy name (pre-generalisation)
DROP TABLE IF EXISTS building_cuts CASCADE;
CREATE TABLE building_cuts AS
WITH span_overlap AS (   -- NB: 'overlaps' is a reserved SQL keyword, do not use it
  SELECT b.osm_id AS host_osm_id, b.osm_type AS host_osm_type, b.geom_m AS bgeom,
         clean_span(ST_Intersection(s.geom_m, b.geom_m)) AS ix
  FROM buildings b
  JOIN corrected_spans s
    ON s.geom_m && b.geom_m AND ST_Intersects(s.geom_m, b.geom_m)
  WHERE s.class <> 'footbridge'
),
kept AS (
  SELECT host_osm_id, host_osm_type, ix
  FROM span_overlap
  WHERE ix IS NOT NULL AND NOT ST_IsEmpty(ix)
    AND ST_Area(ix) < 0.9 * ST_Area(bgeom)          -- not the whole building
    AND qa_max_halfwidth(ix) >= :min_cut_inradius   -- a real opening, not a graze
),
cleaned AS (
  SELECT host_osm_id, host_osm_type,
         morph_open(
           drop_ribbons(
             prune_parts(simplify_vw(clean_span(ST_Union(ix)), :vw_area_tol),
                         :min_part_area, :severe_inradius, :min_compactness, :hard_min_inradius),
             :max_cut_aspect),
           :open_k_cut) AS c
  FROM kept
  GROUP BY host_osm_id, host_osm_type
)
SELECT cl.host_osm_id, cl.host_osm_type,
       CASE
         WHEN :cut_expand <= 0 OR cl.c IS NULL OR ST_IsEmpty(cl.c) THEN cl.c
         -- over-cut guard: if the EXPANDED cut would cover >= 90% of the host
         -- (a near-whole-building passage), keep the unexpanded cut so the host
         -- stays carved rather than emptying to the solid-original fallback.
         WHEN ex.g IS NULL OR ST_IsEmpty(ex.g)
              OR ST_Area(ex.g) >= 0.9 * ST_Area(b.geom_m) THEN cl.c
         ELSE ex.g
       END AS cut_m
FROM cleaned cl
JOIN buildings b ON b.osm_id = cl.host_osm_id AND b.osm_type = cl.host_osm_type
CROSS JOIN LATERAL (
  SELECT clean_span(ST_Intersection(
           ST_Buffer(cl.c, :cut_expand, 'join=mitre mitre_limit=2.0'),
           b.geom_m)) AS g
) ex;
DELETE FROM building_cuts WHERE cut_m IS NULL OR ST_IsEmpty(cut_m);
CREATE INDEX bcuts_geom_idx ON building_cuts USING gist (cut_m);
CREATE INDEX bcuts_host_idx ON building_cuts (host_osm_id, host_osm_type);

COMMIT;

\echo 'corrected_spans by class:'
SELECT class, action, count(*), round(min(base_h)::numeric,1) min_base, round(max(top_h)::numeric,1) max_top
FROM corrected_spans GROUP BY 1,2 ORDER BY 1;
\echo 'corrected_spans by qa_status:'
SELECT qa_status, count(*), round(min(qa_halfwidth)::numeric,2) min_halfwidth
FROM corrected_spans GROUP BY 1 ORDER BY 1;
\echo 'WEWCC corrected slabs:'
SELECT cand_id, action, round(base_h::numeric,1) base_h, round(top_h::numeric,1) top_h,
       round(qa_halfwidth::numeric,2) qa_halfwidth, qa_status, reason
FROM corrected_spans WHERE name = 'Walter E. Washington Convention Center';
