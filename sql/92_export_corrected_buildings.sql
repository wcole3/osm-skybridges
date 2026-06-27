-- 92_export_corrected_buildings.sql : buildings with detected span regions carved
-- out of their hosts, so the street opening is visible under the lifted lintel.
-- Identical to raw buildings except for the carved hosts. Focus-filtered.
--
-- Carve quality: before differencing, the cut is SNAPPED to this host's walls
-- (wall-following) so a cut edge sitting just inside a wall collapses instead of
-- leaving a hairline strip; the result is made valid and any tiny/thin leftover
-- parts are dropped (keep-largest, so a building never empties).
-- COALESCE defaults so a stale DB (export run before a re-`make sql` that adds a
-- key) can't NULL-out a var: psql \gset UNSETS a var on NULL -> ':var' stays
-- literal -> syntax error. Defaults mirror sql/01_prepare.sql.
SELECT
  COALESCE((SELECT value FROM config WHERE key='snap_tol'), 0.5)         AS snap_tol,
  COALESCE((SELECT value FROM config WHERE key='min_part_area'), 1.0)    AS min_part_area,
  COALESCE((SELECT value FROM config WHERE key='severe_inradius'), 0.5)  AS severe_inradius,
  COALESCE((SELECT value FROM config WHERE key='min_compactness'), 0.25) AS min_compactness,
  COALESCE((SELECT value FROM config WHERE key='vw_area_tol'), 0.5)      AS vw_area_tol,
  COALESCE((SELECT value FROM config WHERE key='hard_min_inradius'), 0.35) AS hard_min_inradius,
  COALESCE((SELECT value FROM config WHERE key='simplify_tol'), 0.1)     AS simplify_tol,
  COALESCE((SELECT value FROM config WHERE key='building_simplify_tol'), 0.5) AS building_simplify_tol,
  COALESCE((SELECT value FROM config WHERE key='max_carve_frac'), 0.95)  AS max_carve_frac
\gset
SELECT json_build_object(
  'type', 'FeatureCollection',
  'features', COALESCE(json_agg(f), '[]'::json)
)
FROM (
  SELECT json_build_object(
    'type', 'Feature',
    'geometry', ST_AsGeoJSON(ST_Transform(ST_SimplifyPreserveTopology(d.geom_out, :building_simplify_tol), 4326), 6)::json,
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
      -- building is essentially ALL span (cut covers >= max_carve_frac of it):
      -- render it lifted-only (NULL -> filtered below), not a grounded hairline
      -- remnant. Safe: such hosts have an overlapping lifted span.
      WHEN ST_Area(bc.cut_m) >= :max_carve_frac * ST_Area(b.geom_m) THEN NULL
      ELSE COALESCE(
        (SELECT g FROM (
           -- snap the cut onto THIS host's walls, difference, make valid, then
           -- Visvalingam-Whyatt (area-based) to collapse thin spikes, drop
           -- tiny/thin leftover slivers (keep-largest so the building survives),
           -- and finally drop near-collinear vertices so deck.gl's tessellator
           -- can't fan them into sliver-triangles on the extruded top.
           SELECT clean_span(ST_SimplifyPreserveTopology(
                    despike_parts(
                      drop_tiny_parts(
                        simplify_vw(
                          clean_span(
                            ST_Difference(
                              ST_MakeValid(b.geom_m),
                              ST_Snap(ST_CollectionExtract(ST_MakeValid(bc.cut_m), 3),
                                      ST_Boundary(b.geom_m), :snap_tol))),
                          :vw_area_tol),
                        :min_part_area),
                      :severe_inradius, :min_compactness, :hard_min_inradius),
                    :simplify_tol)) AS g
         ) z WHERE g IS NOT NULL AND NOT ST_IsEmpty(g)),
        b.geom_m)   -- fallback: keep the original footprint if the cut emptied it
    END AS geom_out
  ) d
  WHERE (b.building IS NOT NULL OR b.building_part IS NOT NULL)
    AND d.geom_out IS NOT NULL   -- near-fully-cut buildings are lifted-only (geom_out NULL)
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
