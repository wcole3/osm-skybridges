-- 90_export_skybridges.sql : corrected floating spans as a GeoJSON
-- FeatureCollection (EPSG:4326). Focus-filtered by :clon/:clat/:radius.
SELECT json_build_object(
  'type', 'FeatureCollection',
  'features', COALESCE(json_agg(f), '[]'::json)
)
FROM (
  SELECT json_build_object(
    'type', 'Feature',
    'geometry', ST_AsGeoJSON(ST_Transform(g.clean, 4326), 6)::json,
    'properties', json_build_object(
      'cand_id', cs.cand_id, 'class', cs.class, 'confidence', cs.confidence,
      'action', cs.action, 'name', cs.name, 'reason', cs.reason,
      'base_h', round(cs.base_h::numeric, 1), 'top_h', round(cs.top_h::numeric, 1)
    )
  ) AS f
  FROM corrected_spans cs
  -- clean slivers / duplicate vertices before extrusion (avoids deck.gl
  -- tessellation artifacts) and DROP anything that cleans to an empty geometry.
  CROSS JOIN LATERAL (
    SELECT ST_CollectionExtract(ST_MakeValid(ST_RemoveRepeatedPoints(cs.geom_m, 0.1)), 3) AS clean
  ) g
  WHERE ST_DWithin(cs.geom_m,
          ST_Transform(ST_SetSRID(ST_MakePoint(:clon, :clat), 4326), region_srid()), :radius)
    AND g.clean IS NOT NULL AND NOT ST_IsEmpty(g.clean)
) sub;
