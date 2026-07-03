-- 01_prepare.sql : classify raw osm_polygons / osm_lines into metric analysis
-- tables and resolve heights.
--
-- CRS NOTE: all *_m geometry is in a metre-accurate UTM zone, AUTO-DERIVED from
-- the data's bounding-box centre (so any region works with no manual CRS step). Override by
-- passing -v srid=<epsg> (the Makefile passes SRID, default 0 = auto). Aspect
-- ratios are CRS-independent; lengths/areas/clearances in metres need a metric
-- CRS, hence UTM. For a very large/multi-zone area, override with 3857 instead.

-- default the srid var to 0 (auto) when not provided on the command line
\if :{?srid}
\else
  \set srid 0
\endif

BEGIN;

-- Default storey height (m). Adjustable per region/building type; 3.0 is the
-- documented OSM default used by F4Map et al.
-- config_meta drops FIRST: it holds a foreign key into config, so on a re-run
-- the child must go before the parent (else DROP config errors out).
DROP TABLE IF EXISTS config_meta;
DROP TABLE IF EXISTS config;
CREATE TABLE config (key text PRIMARY KEY, value double precision);
INSERT INTO config VALUES
  ('level_height', 3.0),     -- metres per building level
  ('aspect_min',   4.0),     -- min oriented-bbox aspect ratio for untagged spans
  ('default_top',  8.0),     -- fallback building height for rendering only
  -- ── geometry-correction tunables (05_correct.sql) ──────────────────────
  ('corridor_halfwidth',   9.0),   -- half-width (m) of a passage corridor slab
  ('corridor_reach',      20.0),   -- (m) extend the passage line past each end to clear the wall
  ('corridor_reach_cap',  60.0),   -- (m) hard cap on the corridor extension
  ('footbridge_halfwidth', 2.0),   -- half-width (m) of a footbridge deck
  ('snap_tol',             0.5),   -- (m) snap the corridor onto the host facade (wall-following)
  ('simplify_tol',         0.1),   -- (m) drop near-collinear vertices from carved hosts (anti-fan)
  ('building_simplify_tol',0.5),   -- (m) Douglas-Peucker tol for ALL exported buildings: removes dense near-collinear/narrow-triangle vertices (OSM over-noding) so extruded tops don't tessellate into sliver-fans
  -- ── severe-geometry detection + auto-clean (passage spans) ─────────────
  ('open_k',               0.5),   -- (m) morphological-opening radius for spans
  ('open_k_cut',           0.5),   -- (m) opening radius for cuts: smooths connected thin tongues
  ('min_cut_inradius',     1.5),   -- (m) a span must overlap a building by a part >= this to cut it (drops grazing-neighbour slivers)
  ('max_cut_aspect',      20.0),   -- drop cut parts longer-than-this:1 (suppress long thin passage-ribbon cuts; span still lifts)
  ('cut_expand',           0.6),   -- (m) MODELER KNOB: dilate each cut toward the facade (clipped to host) so it slices the thin remnant "walls" the span left un-cut. 0 disables; raise to cut more, but too high empties hosts (over-cut).
  ('max_carve_frac',       0.95),  -- if a building is >= this fraction covered by its cut, it IS essentially the span: render it lifted-only (drop the grounded hairline remnant) instead of carving a thin wall.
  ('open_area_keep',       0.7),   -- skip opening if it would remove > 30% of the area
  ('min_part_area',        1.0),   -- (m^2) drop disjoint parts smaller than this
  ('min_inradius',         1.0),   -- (m) per-part keep floor (true min half-width)
  ('min_compactness',      0.25),  -- Polsby-Popper keep floor (OR'd with inradius)
  ('severe_inradius',      0.5),   -- (m) below this a span is "still severe" -> revert + review
  ('vw_area_tol',          0.5),   -- (m^2) Visvalingam-Whyatt area floor: collapses thin spikes Douglas-Peucker preserves (QEM edge-collapse analog; see simplify_vw)
  ('hard_min_inradius',    0.35),  -- (m) absolute thin-floor in despike/prune: drop ANY part below this inradius regardless of compactness (kills slivers kept on compactness alone)
  ('clean_area_loss_max',  0.30),  -- revert + review if cleanup loses more than this fraction
  ('hull_frac',            0.85),  -- ST_SimplifyPolygonHull vertex fraction (reserved; span polish)
  ('grid_size',            0.01);  -- (m) fixed-precision grid for ALL metric overlays/cleanup (clean_span + gridSize overlay args): near-coincident edges snap-round to the same coordinates so hairline slivers cancel at the source. 10x below clean_span's 0.1 dedupe, 50x below snap_tol; invisible at export (6dp ~ 8.7 cm). 0 disables (not recommended).

-- config_meta: UI metadata for the live tuner (pipeline/tuner.py) — slider
-- range/step, a one-line description, and the STAGE: the cheapest pipeline
-- suffix that must re-run when the knob changes (prepare 01→, detect 02→,
-- correct 05→, finalize 06→, export = re-export only). Kept SEPARATE from
-- config: `make tune`'s sed matches the ('key', value) rows above and must not
-- see extra columns. A knob used by several stages gets the heaviest user.
-- (Dropped above, before config — FK ordering.)
CREATE TABLE config_meta (
  key   text PRIMARY KEY REFERENCES config(key),
  stage text NOT NULL CHECK (stage IN ('prepare','detect','correct','finalize','export')),
  min   double precision NOT NULL,
  max   double precision NOT NULL,
  step  double precision NOT NULL,
  descr text NOT NULL
);
INSERT INTO config_meta VALUES
  ('level_height',        'prepare',  2.0,  5.0, 0.1,  'metres per building:levels floor'),
  ('aspect_min',          'detect',   2.0, 10.0, 0.5,  'min bbox aspect for untagged span detection'),
  ('default_top',         'prepare',  3.0, 30.0, 0.5,  'fallback render height (no height tag)'),
  ('corridor_halfwidth',  'correct',  3.0, 15.0, 0.5,  'half-width of a passage corridor slab'),
  ('corridor_reach',      'correct',  5.0, 60.0, 1.0,  'extend passage line past each face'),
  ('corridor_reach_cap',  'correct', 20.0,120.0, 5.0,  'hard cap on that extension'),
  ('footbridge_halfwidth','correct',  0.5,  5.0, 0.25, 'half-width of a footbridge deck'),
  ('snap_tol',            'correct',  0.0,  2.0, 0.05, 'snap corridor/cut onto the host wall'),
  ('simplify_tol',        'finalize', 0.0,  1.0, 0.05, 'drop near-collinear vertices from carved hosts'),
  ('building_simplify_tol','export',  0.0,  2.0, 0.05, 'simplify ALL exported buildings (anti-fan)'),
  ('open_k',              'correct',  0.0,  2.0, 0.05, 'morphological-opening radius for spans'),
  ('open_k_cut',          'correct',  0.0,  2.0, 0.05, 'opening radius for cuts'),
  ('min_cut_inradius',    'correct',  0.0,  5.0, 0.1,  'span must overlap host this wide to cut'),
  ('max_cut_aspect',      'correct',  2.0, 40.0, 1.0,  'drop cut parts longer than this:1'),
  ('cut_expand',          'correct',  0.0,  3.0, 0.1,  'dilate cut toward the facade (slice walls)'),
  ('max_carve_frac',      'finalize', 0.5,  1.0, 0.01, 'host cut >= this fraction -> lifted-only'),
  ('open_area_keep',      'correct',  0.3,  1.0, 0.05, 'skip opening if it removes more area'),
  ('min_part_area',       'correct',  0.0, 10.0, 0.5,  'drop disjoint parts smaller than this m^2'),
  ('min_inradius',        'correct',  0.0,  3.0, 0.05, 'per-part keep floor (min half-width)'),
  ('min_compactness',     'correct',  0.0,  1.0, 0.05, 'Polsby-Popper keep floor'),
  ('severe_inradius',     'correct',  0.0,  2.0, 0.05, 'below this a span reverts to review'),
  ('vw_area_tol',         'correct',  0.0,  3.0, 0.1,  'Visvalingam area floor (collapses spikes)'),
  ('hard_min_inradius',   'correct',  0.0,  1.0, 0.05, 'absolute thin-floor in despike/prune'),
  ('clean_area_loss_max', 'correct',  0.0,  1.0, 0.05, 'revert if cleanup loses more than this'),
  ('hull_frac',           'correct',  0.5,  1.0, 0.05, 'SimplifyPolygonHull fraction (reserved)'),
  ('grid_size',           'prepare',  0.0,  0.1, 0.005,'fixed-precision grid for all overlays');

-- Metric CRS for the whole pipeline: explicit :srid if > 0, else the UTM zone
-- of the data's bounding-box centre (EPSG 326xx north / 327xx south).
-- region_srid() is then used everywhere in place of a hardcoded SRID.
DROP TABLE IF EXISTS region;
CREATE TABLE region AS
WITH ext AS (
  SELECT ST_Centroid(ST_SetSRID(ST_Extent(geom)::geometry, 4326)) AS p FROM osm_polygons
)
SELECT CASE
  WHEN :srid > 0 THEN :srid
  ELSE 32600
       + LEAST(60, GREATEST(1, floor((ST_X(p) + 180) / 6)::int + 1))   -- UTM zone 1..60
       + CASE WHEN ST_Y(p) < 0 THEN 100 ELSE 0 END                     -- +100 -> 327xx (south)
END AS srid
FROM ext;

CREATE OR REPLACE FUNCTION region_srid() RETURNS int AS $$
  SELECT srid FROM region LIMIT 1
$$ LANGUAGE sql STABLE;

\echo 'metric CRS (region_srid):'
SELECT srid FROM region;

-- ---------------------------------------------------------------------------
-- BUILDINGS (+ building:parts + man_made=bridge outlines)
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS buildings CASCADE;
CREATE TABLE buildings AS
SELECT
  row_number() OVER ()                                  AS id,
  osm_type,
  osm_id,
  tags,
  ST_Transform(geom, region_srid())                             AS geom_m,
  geom                                                  AS geom_4326,
  tags->>'building'                                     AS building,
  tags->>'building:part'                                AS building_part,
  tags->>'man_made'                                     AS man_made,
  -- TOP (height above ground): height > levels*3 > NULL(unknown)
  CASE
    WHEN tags ? 'height'          THEN parse_height(tags->>'height')
    WHEN tags ? 'building:levels' THEN GREATEST(0, to_num(tags->>'building:levels')
                                       * (SELECT value FROM config WHERE key='level_height'))
    ELSE NULL
  END                                                   AS height_resolved,
  -- BASE / float (height above ground at which the part begins):
  -- min_height > building:min_level*3 > 0
  CASE
    WHEN tags ? 'min_height'             THEN parse_height(tags->>'min_height')
    WHEN tags ? 'building:min_level'     THEN GREATEST(0, to_num(tags->>'building:min_level')
                                              * (SELECT value FROM config WHERE key='level_height'))
    ELSE 0
  END                                                   AS min_height_resolved,
  -- The "missing base" gate: no usable float tag present. Because
  -- building:min_level defaults to 0 and is omitted when 0, absence == ground,
  -- so the detector must lean on geometry, not tag-absence, to infer elevation.
  (NOT (tags ? 'min_height')
     AND COALESCE(to_num(tags->>'building:min_level'), 0) = 0)
                                                        AS missing_base
FROM osm_polygons
WHERE tags ? 'building' OR tags ? 'building:part' OR tags->>'man_made' = 'bridge';

-- Render-only top height (never NULL) for the viewer.
ALTER TABLE buildings ADD COLUMN height_render double precision;
UPDATE buildings
   SET height_render = COALESCE(height_resolved,
                                (SELECT value FROM config WHERE key='default_top'));

-- Repair invalid OSM polygons ONCE, at the source, so every downstream ST_*
-- operation (intersection / crosses / difference / export) is safe in any region.
-- geom_m is additionally snapped to the fixed-precision grid (grid_size) so every
-- downstream overlay is grid-vs-grid — near-coincident edges cancel exactly
-- instead of producing hairline slivers. Vertices move <= ~7 mm; the WEWCC
-- passage-count FATAL in 99_selfcheck guards the detection predicates against
-- that shift. geom_4326 stays RAW degrees (metric grid must never touch it; the
-- full-fidelity export uses it untouched) and is only repaired when invalid.
UPDATE buildings SET geom_m = ST_CollectionExtract(
  ST_ReducePrecision(ST_MakeValid(geom_m, 'method=structure keepcollapsed=false'),
                     (SELECT value FROM config WHERE key='grid_size')), 3);
UPDATE buildings SET geom_4326 = ST_CollectionExtract(ST_MakeValid(geom_4326), 3) WHERE NOT ST_IsValid(geom_4326);

ALTER TABLE buildings ADD PRIMARY KEY (id);
CREATE INDEX buildings_geom_m_idx   ON buildings USING gist (geom_m);
CREATE INDEX buildings_geom_4326_idx ON buildings USING gist (geom_4326);

-- ---------------------------------------------------------------------------
-- LINEAR FEATURES
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS roads CASCADE;
CREATE TABLE roads AS
SELECT row_number() OVER () AS id, osm_id, tags,
       tags->>'highway' AS highway,
       ST_Transform(geom, region_srid()) AS geom_m
FROM osm_lines WHERE tags ? 'highway';
CREATE INDEX roads_geom_m_idx ON roads USING gist (geom_m);

DROP TABLE IF EXISTS rail CASCADE;
CREATE TABLE rail AS
SELECT row_number() OVER () AS id, osm_id, tags,
       ST_Transform(geom, region_srid()) AS geom_m
FROM osm_lines WHERE tags ? 'railway';
CREATE INDEX rail_geom_m_idx ON rail USING gist (geom_m);

DROP TABLE IF EXISTS water CASCADE;
CREATE TABLE water AS
SELECT row_number() OVER () AS id, osm_id, tags,
       ST_Transform(geom, region_srid()) AS geom_m
FROM osm_lines WHERE tags ? 'waterway';
CREATE INDEX water_geom_m_idx ON water USING gist (geom_m);

-- Obstacles a real skybridge would span OVER: drivable/rail/water centerlines,
-- explicitly EXCLUDING pedestrian ways (so a footbridge crossing another
-- footway is not counted as "crossing a road").
DROP VIEW IF EXISTS obstacles CASCADE;
CREATE VIEW obstacles AS
  SELECT geom_m FROM roads
   WHERE highway IN ('motorway','motorway_link','trunk','trunk_link','primary',
                     'primary_link','secondary','secondary_link','tertiary',
                     'tertiary_link','residential','unclassified','service',
                     'living_street','road')
  UNION ALL SELECT geom_m FROM rail
  UNION ALL SELECT geom_m FROM water;

COMMIT;

\echo 'prepare: buildings / roads / rail / water built'
SELECT 'buildings' t, count(*) FROM buildings
UNION ALL SELECT 'roads', count(*) FROM roads
UNION ALL SELECT 'rail',  count(*) FROM rail
UNION ALL SELECT 'water', count(*) FROM water;
