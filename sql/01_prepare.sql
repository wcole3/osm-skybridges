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
DROP TABLE IF EXISTS config;
CREATE TABLE config (key text PRIMARY KEY, value double precision);
INSERT INTO config VALUES
  ('level_height', 3.0),     -- metres per building level
  ('aspect_min',   4.0),     -- min oriented-bbox aspect ratio for untagged spans
  ('default_top',  8.0);     -- fallback building height for rendering only

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
UPDATE buildings SET geom_m    = ST_CollectionExtract(ST_MakeValid(geom_m), 3)    WHERE NOT ST_IsValid(geom_m);
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
