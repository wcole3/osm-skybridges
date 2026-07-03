-- 97_export_config.sql : snapshot of the processing settings as one JSON object.
--
-- Written to web/data/config.json by `make export` (the viewer's read-only
-- settings panel reads it) and to exports/config.json by `make config-export`
-- (the shareable settings file). Ingest one with:
--     make config-load FILE=path/to/config.json
-- which persists the values into sql/01_prepare.sql (exactly like `make tune`)
-- and re-derives, so two users running the same file get identical processing.
SELECT json_build_object(
  'format', 'osm-parser-config/1',
  'generated', now(),
  'region_srid', region_srid(),
  'values', (SELECT json_object_agg(c.key, c.value ORDER BY c.key) FROM config c),
  'meta',   (SELECT json_object_agg(m.key, json_build_object(
                      'stage', m.stage, 'descr', m.descr) ORDER BY m.key)
             FROM config_meta m)
);
