-- 06_finalize.sql : materialize the FINAL corrected geometry once, so that
--   * the viewer export (92) and the full-fidelity exports (94) read the same
--     carve instead of each re-deriving it, and
--   * the live tuner's hot loop (max_carve_frac / simplify_tol) re-runs in
--     sub-seconds (carved_hosts is small: one row per host in building_cuts).
--
-- Produces:
--   carved_hosts            TABLE  — the carve (building − cut), one row per cut host
--   buildings_final         VIEW   — ALL buildings, corrections applied (the dataset)
--   spans_final             VIEW   — lifted spans with min_height/height attributes
--   export_final_buildings  VIEW   — typed (MultiPolygon,4326) layer for GDAL/ogr2ogr
--   export_final_spans      VIEW   — typed (MultiPolygon,4326) layer for GDAL/ogr2ogr
--
-- COALESCE defaults mirror sql/01_prepare.sql (see 92 for the rationale: \gset
-- unsets a var on NULL and a stale/partial config must not break the build).
SELECT
  COALESCE((SELECT value FROM config WHERE key='snap_tol'), 0.5)           AS snap_tol,
  COALESCE((SELECT value FROM config WHERE key='min_part_area'), 1.0)      AS min_part_area,
  COALESCE((SELECT value FROM config WHERE key='severe_inradius'), 0.5)    AS severe_inradius,
  COALESCE((SELECT value FROM config WHERE key='min_compactness'), 0.25)   AS min_compactness,
  COALESCE((SELECT value FROM config WHERE key='vw_area_tol'), 0.5)        AS vw_area_tol,
  COALESCE((SELECT value FROM config WHERE key='hard_min_inradius'), 0.35) AS hard_min_inradius,
  COALESCE((SELECT value FROM config WHERE key='simplify_tol'), 0.1)       AS simplify_tol,
  COALESCE((SELECT value FROM config WHERE key='max_carve_frac'), 0.95)    AS max_carve_frac,
  COALESCE((SELECT value FROM config WHERE key='grid_size'), 0.01)         AS grid_size
\gset

BEGIN;

-- ---------------------------------------------------------------------------
-- carved_hosts: building − cut, computed ONCE per host (moved here from 92).
-- lifted_only: the cut covers >= max_carve_frac of the host — the building
-- essentially IS the span; it renders lifted-only and is EXCLUDED from the
-- grounded datasets (geom columns NULL).
-- Carve tail: fixed-precision difference (host and cut are on the grid_size
-- grid; ST_Snap's off-grid edge insertions are re-noded by the gridded overlay)
-- -> collapse thin spikes (simplify_vw) -> drop tiny/thin leftovers (keep-
-- largest, a building never empties) -> drop near-collinear vertices. Falls
-- back to the original footprint if the carve empties.
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS carved_hosts CASCADE;
CREATE TABLE carved_hosts AS
SELECT b.osm_id   AS host_osm_id,
       b.osm_type AS host_osm_type,
       (ST_Area(bc.cut_m) >= :max_carve_frac * ST_Area(b.geom_m)) AS lifted_only,
       carve.g    AS geom_m,
       CASE WHEN carve.g IS NULL THEN NULL
            ELSE ST_Transform(carve.g, 4326) END                  AS geom_4326
FROM building_cuts bc
JOIN buildings b ON b.osm_id = bc.host_osm_id AND b.osm_type = bc.host_osm_type
CROSS JOIN LATERAL (
  SELECT CASE
    WHEN ST_Area(bc.cut_m) >= :max_carve_frac * ST_Area(b.geom_m) THEN NULL
    ELSE COALESCE(
      (SELECT g FROM (
         SELECT clean_span(ST_SimplifyPreserveTopology(
                  despike_parts(
                    drop_tiny_parts(
                      simplify_vw(
                        clean_span(
                          ST_Difference(
                            ST_MakeValid(b.geom_m, 'method=structure keepcollapsed=false'),
                            ST_Snap(ST_CollectionExtract(ST_MakeValid(bc.cut_m, 'method=structure keepcollapsed=false'), 3),
                                    ST_Boundary(b.geom_m), :snap_tol),
                            :grid_size)),
                        :vw_area_tol),
                      :min_part_area),
                    :severe_inradius, :min_compactness, :hard_min_inradius),
                  :simplify_tol)) AS g
       ) z WHERE g IS NOT NULL AND NOT ST_IsEmpty(g)),
      ST_Multi(b.geom_m))   -- fallback: original footprint if the carve emptied
  END AS g
) carve;

ALTER TABLE carved_hosts ADD PRIMARY KEY (host_osm_id, host_osm_type);
CREATE INDEX carved_hosts_geom_idx ON carved_hosts USING gist (geom_m);

-- ---------------------------------------------------------------------------
-- buildings_final: EVERY building/part with corrections applied — the final
-- geometry dataset. Semantics identical to the viewer export (92):
--   * carved hosts get the carved footprint;
--   * lifted_only hosts and lifted whole-polygon spans (bridge_struct/geom
--     candidates) are EXCLUDED here — they live in spans_final;
--   * all other buildings keep their footprint untouched; geom_4326 for them is
--     the RAW OSM polygon (max fidelity — no metric round-trip).
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS buildings_final CASCADE;
CREATE VIEW buildings_final AS
SELECT b.id,
       b.osm_id,
       b.osm_type,
       CASE WHEN b.building IS NOT NULL THEN 'building'
            WHEN b.building_part IS NOT NULL THEN 'part' ELSE b.man_made END AS kind,
       b.tags->>'name'                    AS name,
       b.height_resolved                  AS height,
       b.height_render,
       b.min_height_resolved              AS min_height,
       to_num(b.tags->>'building:levels') AS levels,
       b.missing_base,
       (ch.host_osm_id IS NOT NULL)       AS carved,
       -- NO ST_Multi here: uncarved buildings keep their raw geometry exactly as
       -- 92 exported them (Polygon stays Polygon); the GDAL views cast to Multi.
       COALESCE(ch.geom_m,    b.geom_m)    AS geom_m,
       COALESCE(ch.geom_4326, b.geom_4326) AS geom_4326
FROM buildings b
LEFT JOIN carved_hosts ch
       ON ch.host_osm_id = b.osm_id AND ch.host_osm_type = b.osm_type
      AND NOT ch.lifted_only
WHERE (b.building IS NOT NULL OR b.building_part IS NOT NULL)
  AND NOT EXISTS (SELECT 1 FROM carved_hosts lo
                  WHERE lo.host_osm_id = b.osm_id AND lo.host_osm_type = b.osm_type
                    AND lo.lifted_only)
  AND NOT EXISTS (SELECT 1 FROM skybridge_candidates sc
                  WHERE sc.osm_id = b.osm_id AND sc.osm_type = b.osm_type
                    AND sc.class IN ('bridge_struct','geom'));

-- ---------------------------------------------------------------------------
-- spans_final: the lifted pieces with their correction attributes. min_height
-- is the proposed OSM tag value (clearance floor); height is the render top.
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS spans_final CASCADE;
CREATE VIEW spans_final AS
SELECT cand_id, class, confidence, action, name, reason, qa_status,
       base_h AS min_height,
       top_h  AS height,
       geom_m,
       ST_Transform(geom_m, 4326) AS geom_4326
FROM corrected_spans;

-- Typed single-geometry layers for GDAL (ogr2ogr reads these directly; the cast
-- fails loudly on a wrong type/SRID instead of writing a broken GeoPackage).
DROP VIEW IF EXISTS export_final_buildings CASCADE;
CREATE VIEW export_final_buildings AS
SELECT id, osm_id, osm_type, kind, name, height, min_height, levels,
       missing_base, carved,
       ST_Multi(geom_4326)::geometry(MultiPolygon, 4326) AS geom
FROM buildings_final;

DROP VIEW IF EXISTS export_final_spans CASCADE;
CREATE VIEW export_final_spans AS
SELECT cand_id, class, confidence, action, name, reason, qa_status,
       min_height, height,
       geom_4326::geometry(MultiPolygon, 4326) AS geom
FROM spans_final;

COMMIT;

\echo 'finalize: carved hosts / lifted-only / buildings_final:'
SELECT (SELECT count(*) FROM carved_hosts WHERE NOT lifted_only) AS carved,
       (SELECT count(*) FROM carved_hosts WHERE lifted_only)     AS lifted_only,
       (SELECT count(*) FROM buildings_final)                    AS buildings_final;
