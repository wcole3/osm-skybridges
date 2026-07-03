-- 95_sandbox_seed.sql : schema for the tuner's SANDBOX database (osm_sandbox).
--
-- The live tuner (`make tuner` -> pipeline/tuner.py) experiments on a SEPARATE
-- DATABASE, not a schema: the pipeline's unqualified `DROP TABLE IF EXISTS ...`
-- statements would resolve through a search_path and destroy the live tables,
-- so schema-level isolation is a footgun — database-level is total.
--
-- This file runs INSIDE the freshly created osm_sandbox database and creates
-- the raw-import tables (exact copies of the flex.lua DDL, see pipeline/flex.lua
-- and the live \d). tuner.py then COPY-pipes a focus-radius subset of the live
-- rows in (text COPY: geometry travels as hex EWKB, safe across databases),
-- and runs the ordinary pipeline files 00..06 + 99 against this database —
-- same SQL, zero duplicated logic, ~hundreds of buildings, ~seconds per run.
CREATE EXTENSION IF NOT EXISTS postgis;

DROP TABLE IF EXISTS osm_polygons;
CREATE TABLE osm_polygons (
  osm_id   int8      NOT NULL,
  tags     jsonb,
  geom     geometry  NOT NULL,
  osm_type bpchar(1) NOT NULL
);

DROP TABLE IF EXISTS osm_lines;
CREATE TABLE osm_lines (
  osm_id int8     NOT NULL,
  tags   jsonb,
  geom   geometry NOT NULL
);

-- gist indexes: 01_prepare's classification scans + the pipeline's spatial
-- joins hit these; tiny tables, but the indexes keep the hot loop snappy.
CREATE INDEX osm_polygons_geom_idx ON osm_polygons USING gist (geom);
CREATE INDEX osm_lines_geom_idx    ON osm_lines    USING gist (geom);
