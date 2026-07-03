-- 92_export_corrected_buildings.sql : viewer layer — buildings with detected
-- span regions carved out of their hosts, so the street opening is visible
-- under the lifted lintel. Focus-filtered + simplified for rendering.
--
-- The carve itself is materialized ONCE in sql/06_finalize.sql (carved_hosts /
-- buildings_final); this file only formats the viewer's slice of it. The
-- full-fidelity dataset (no filter, no simplify) is sql/94_export_final_*.sql.
-- COALESCE default: see the stale-config note in sql/06_finalize.sql.
SELECT
  COALESCE((SELECT value FROM config WHERE key='building_simplify_tol'), 0.5) AS building_simplify_tol
\gset
SELECT json_build_object(
  'type', 'FeatureCollection',
  'features', COALESCE(json_agg(f), '[]'::json)
)
FROM (
  SELECT json_build_object(
    'type', 'Feature',
    'geometry', ST_AsGeoJSON(ST_Transform(ST_SimplifyPreserveTopology(bf.geom_m, :building_simplify_tol), 4326), 6)::json,
    'properties', json_build_object(
      'osm_id', bf.osm_id,
      'kind', bf.kind,
      'name', bf.name,
      'top_h', round(bf.height_render::numeric, 1),
      'base_h', round(bf.min_height::numeric, 1),
      'missing_base', bf.missing_base,
      'carved', bf.carved
    )
  ) AS f
  FROM buildings_final bf
  WHERE ST_DWithin(bf.geom_m,
          ST_Transform(ST_SetSRID(ST_MakePoint(:clon, :clat), 4326), region_srid()), :radius)
  ORDER BY bf.id
) sub;
