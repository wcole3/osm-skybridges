-- 90_export_buildings.sql : all buildings as one GeoJSON FeatureCollection (EPSG:4326).
-- Emitted via `psql -At` to web/data/buildings.geojson for the deck.gl viewer.
-- Properties:
--   top_h        render height (m, never null)
--   base_h       resolved float base (m; 0 unless min_height/min_level tagged)
--   missing_base whether the float base is absent (candidate gate)
SELECT json_build_object(
  'type', 'FeatureCollection',
  'features', COALESCE(json_agg(f), '[]'::json)
)
FROM (
  SELECT json_build_object(
    'type', 'Feature',
    'geometry', ST_AsGeoJSON(geom_4326, 6)::json,
    'properties', json_build_object(
      'osm_id', osm_id,
      'kind', CASE WHEN building IS NOT NULL THEN 'building'
                   WHEN building_part IS NOT NULL THEN 'part'
                   ELSE man_made END,
      'name', tags->>'name',
      'top_h', round(height_render::numeric, 1),
      'base_h', round(min_height_resolved::numeric, 1),
      'missing_base', missing_base
    )
  ) AS f
  FROM buildings
  WHERE (building IS NOT NULL OR building_part IS NOT NULL)
    -- focus area: :clon/:clat/:radius (metres) passed by the Makefile.
    -- Use a large radius to export all of DC.
    AND ST_DWithin(geom_m,
                   ST_Transform(ST_SetSRID(ST_MakePoint(:clon, :clat), 4326), region_srid()),
                   :radius)
) sub;
