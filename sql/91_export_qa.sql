-- 91_export_qa.sql : the Osmose-style review queue — one Point per candidate
-- (all candidates, not focus-filtered) with the proposed correction + evidence.
-- Ordered severe-shape-first, then very_high -> high -> medium, then cand_id for
-- a stable, diff-friendly file.
-- COALESCE defaults: psql \gset unsets a var on NULL, which would leave ':var'
-- literal and break this export if run against a DB missing the key.
SELECT
  COALESCE((SELECT value FROM config WHERE key='severe_inradius'), 0.5) AS severe_inradius,
  COALESCE((SELECT value FROM config WHERE key='min_part_area'), 1.0)   AS min_part_area
\gset
SELECT json_build_object(
  'type', 'FeatureCollection',
  'features', COALESCE(json_agg(f ORDER BY sev_ord, ord, cand_id), '[]'::json)
)
FROM (
  SELECT
    c.cand_id,
    CASE c.confidence WHEN 'very_high' THEN 0 WHEN 'high' THEN 1 ELSE 2 END AS ord,
    -- severe-shape rows float to the top of the queue
    CASE WHEN s.cand_id IS NOT NULL
          AND (s.qa_halfwidth < :severe_inradius OR s.qa_min_part_area < :min_part_area)
         THEN 0 ELSE 1 END AS sev_ord,
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
            GREATEST(floor(s.base_h / 3.0)::int + 1, ceil(s.top_h / 3.0)::int),
        -- shape-quality provenance: how the corrected geometry was cleaned and
        -- whether it is still pathological (so reviewers see WHY it is queued).
        'qa_status', s.qa_status,
        'qa_cleaned', s.qa_cleaned,
        'qa_min_halfwidth', round(s.qa_halfwidth::numeric, 2),
        'qa_compactness', round(s.qa_compactness::numeric, 2),
        'qa_severity', CASE
            WHEN s.cand_id IS NULL THEN 'none'
            WHEN s.qa_halfwidth < :severe_inradius OR s.qa_min_part_area < :min_part_area THEN 'severe'
            WHEN s.qa_compactness < 0.20 THEN 'sliver_watch'
            ELSE 'ok' END
      )
    ) AS f
  FROM skybridge_candidates c
  LEFT JOIN corrected_spans s ON s.cand_id = c.cand_id
) sub;
