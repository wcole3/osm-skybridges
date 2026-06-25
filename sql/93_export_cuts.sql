-- 93_export_cuts.sql : the regions SUBTRACTED from building footprints (the
-- "removed" area), as a GeoJSON FeatureCollection. Rendered flat in the
-- "modified footprint" view to show exactly what the correction removes.
SELECT json_build_object(
  'type', 'FeatureCollection',
  'features', COALESCE(json_agg(f), '[]'::json)
)
FROM (
  SELECT json_build_object(
    'type', 'Feature',
    'geometry', ST_AsGeoJSON(ST_Transform(
        ST_CollectionExtract(ST_MakeValid(cut_m), 3), 4326), 6)::json,
    'properties', json_build_object('host_osm', host_osm_type || host_osm_id)
  ) AS f
  FROM building_cuts
  WHERE ST_DWithin(cut_m,
          ST_Transform(ST_SetSRID(ST_MakePoint(:clon, :clat), 4326), region_srid()), :radius)
) sub;
