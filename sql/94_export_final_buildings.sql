-- 94_export_final_buildings.sql : the FULL-FIDELITY final dataset — every
-- building in the region with corrections applied (carved where a span opening
-- was detected, untouched raw OSM geometry otherwise). For use in OTHER
-- applications, so unlike the viewer exports (90/92) there is:
--   * NO focus filter (whole region),
--   * NO simplification,
--   * full coordinate precision (ST_AsGeoJSON default 9 decimal digits),
--   * complete attributes (osm_id + osm_type identify the OSM feature).
-- Lifted-only hosts and whole-polygon spans live in 94_export_final_spans.sql.
--
-- NOTE: json_agg builds the FeatureCollection as one value (PostgreSQL 1 GB text
-- cap). A DC-sized region is ~10^2 MB — fine. For a huge region, emit one
-- feature per row (ndjson) and wrap externally.
SELECT json_build_object(
  'type', 'FeatureCollection',
  'features', COALESCE(json_agg(f), '[]'::json)
)
FROM (
  SELECT json_build_object(
    'type', 'Feature',
    'geometry', ST_AsGeoJSON(geom_4326)::json,
    'properties', json_build_object(
      'osm_id', osm_id,
      'osm_type', osm_type,
      'kind', kind,
      'name', name,
      'height', height,
      'min_height', min_height,
      'levels', levels,
      'missing_base', missing_base,
      'carved', carved
    )
  ) AS f
  FROM buildings_final
  ORDER BY id
) sub;
