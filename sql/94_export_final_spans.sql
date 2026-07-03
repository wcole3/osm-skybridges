-- 94_export_final_spans.sql : full-fidelity lifted spans — the corrected
-- geometry pieces that float (skybridges / passage lintels / footbridge decks),
-- with the computed correction as attributes:
--   min_height = proposed base clearance (the OSM min_height fix)
--   height     = render top
-- Whole region, no simplification, full precision. Companion of
-- 94_export_final_buildings.sql (lifted-only hosts appear ONLY here).
SELECT json_build_object(
  'type', 'FeatureCollection',
  'features', COALESCE(json_agg(f), '[]'::json)
)
FROM (
  SELECT json_build_object(
    'type', 'Feature',
    'geometry', ST_AsGeoJSON(geom_4326)::json,
    'properties', json_build_object(
      'cand_id', cand_id,
      'class', class,
      'confidence', confidence,
      'action', action,
      'name', name,
      'reason', reason,
      'qa_status', qa_status,
      'min_height', min_height,
      'height', height
    )
  ) AS f
  FROM spans_final
  ORDER BY cand_id
) sub;
