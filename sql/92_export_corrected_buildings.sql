-- 92_export_corrected_buildings.sql : buildings with detected span regions carved
-- out of their hosts, so the street opening is visible under the lifted lintel.
-- Identical to raw buildings except for the carved hosts. Focus-filtered.
SELECT json_build_object(
  'type', 'FeatureCollection',
  'features', COALESCE(json_agg(f), '[]'::json)
)
FROM (
  SELECT json_build_object(
    'type', 'Feature',
    'geometry', ST_AsGeoJSON(ST_Transform(d.geom_out, 4326), 6)::json,
    'properties', json_build_object(
      'osm_id', b.osm_id,
      'kind', CASE WHEN b.building IS NOT NULL THEN 'building'
                   WHEN b.building_part IS NOT NULL THEN 'part' ELSE b.man_made END,
      'name', b.tags->>'name',
      'top_h', round(b.height_render::numeric, 1),
      'base_h', round(b.min_height_resolved::numeric, 1),
      'missing_base', b.missing_base,
      'carved', (bc.cut_m IS NOT NULL)
    )
  ) AS f
  FROM buildings b
  LEFT JOIN building_cuts bc ON bc.host_osm_id = b.osm_id AND bc.host_osm_type = b.osm_type
  CROSS JOIN LATERAL (
    SELECT CASE
      WHEN bc.cut_m IS NULL THEN b.geom_m
      ELSE COALESCE(
        (SELECT ST_RemoveRepeatedPoints(g, 0.1) FROM (
           -- sanitise BOTH operands (cut_m can be a GeometryCollection)
           SELECT ST_CollectionExtract(ST_MakeValid(
                    ST_Difference(ST_MakeValid(b.geom_m),
                                  ST_CollectionExtract(ST_MakeValid(bc.cut_m), 3))), 3) AS g
         ) z WHERE NOT ST_IsEmpty(z.g)),
        b.geom_m)   -- fallback: keep the original footprint if the cut emptied it
    END AS geom_out
  ) d
  WHERE (b.building IS NOT NULL OR b.building_part IS NOT NULL)
    -- drop polygons that ARE a lifted span (bridge_struct/geom): they are
    -- replaced by the floating skybridge layer, so they must not also render
    -- grounded here. Passage HOSTS stay (carved, not removed).
    AND NOT EXISTS (
      SELECT 1 FROM skybridge_candidates sc
      WHERE sc.osm_id = b.osm_id AND sc.osm_type = b.osm_type
        AND sc.class IN ('bridge_struct','geom'))
    AND ST_DWithin(b.geom_m,
          ST_Transform(ST_SetSRID(ST_MakePoint(:clon, :clat), 4326), region_srid()), :radius)
) sub;
