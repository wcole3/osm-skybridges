-- 91_export_qa.sql : the Osmose-style review queue — one Point per candidate
-- (all candidates, not focus-filtered) with the proposed correction + evidence.
-- Ordered very_high -> high -> medium, then cand_id for a stable, diff-friendly file.
SELECT json_build_object(
  'type', 'FeatureCollection',
  'features', COALESCE(json_agg(f ORDER BY ord, cand_id), '[]'::json)
)
FROM (
  SELECT
    c.cand_id,
    CASE c.confidence WHEN 'very_high' THEN 0 WHEN 'high' THEN 1 ELSE 2 END AS ord,
    json_build_object(
      'type', 'Feature',
      'geometry', json_build_object('type','Point','coordinates', json_build_array(c.lon, c.lat)),
      'properties', json_build_object(
        'cand_id', c.cand_id, 'class', c.class, 'confidence', c.confidence,
        'action', c.action,
        'osm', c.osm_type || c.osm_id,
        'osm_url', 'https://www.openstreetmap.org/' ||
           CASE c.osm_type WHEN 'W' THEN 'way/' WHEN 'R' THEN 'relation/' WHEN 'N' THEN 'node/' ELSE 'way/' END
           || c.osm_id,
        'name', c.name,
        'reason', array_to_string(c.reasons, '; '),
        -- has_proposal=false means the correction came out empty (no geometry to
        -- apply); the row is still listed so the candidate isn't silently dropped.
        'has_proposal', (s.cand_id IS NOT NULL),
        'proposed_min_height', round(s.base_h::numeric, 1),
        'proposed_height', round(s.top_h::numeric, 1),
        -- storey hint: floor(base) for min_level, levels guaranteed strictly
        -- greater (>= min_level + 1) so the OSM invariant always holds.
        'proposed_building_min_level', floor(s.base_h / 3.0)::int,
        'proposed_building_levels',
            GREATEST(floor(s.base_h / 3.0)::int + 1, ceil(s.top_h / 3.0)::int)
      )
    ) AS f
  FROM skybridge_candidates c
  LEFT JOIN corrected_spans s ON s.cand_id = c.cand_id
) sub;
