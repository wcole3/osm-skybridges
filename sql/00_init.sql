-- 00_init.sql : extensions + shared helper functions.
CREATE EXTENSION IF NOT EXISTS postgis;
-- SFCGAL is only needed for the optional server-side 3D-Tiles export path
-- (ST_Extrude/CG_Extrude). The deck.gl viewer lifts geometry client-side, so
-- this is best-effort; ignore if the build lacks it.
DO $$ BEGIN
  CREATE EXTENSION IF NOT EXISTS postgis_sfcgal;
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'postgis_sfcgal not available (ok for MVP): %', SQLERRM;
END $$;

-- parse_height: OSM height strings -> metres.
-- Handles "12", "12.5", "12 m", and the feet/inch form 7'4" / 7' (typewriter
-- apostrophe). Returns NULL when unparseable. Assumes metres for the plain form.
CREATE OR REPLACE FUNCTION parse_height(v text) RETURNS double precision AS $$
DECLARE
  s text := btrim(coalesce(v, ''));
  m text[];
BEGIN
  IF s = '' THEN RETURN NULL; END IF;

  -- feet/inch, apostrophe form: 7'4"  | 7'  | 7'4
  IF position('''' in s) > 0 THEN
    m := regexp_match(s, '^([0-9]+(?:\.[0-9]+)?)''\s*([0-9]+(?:\.[0-9]+)?)?');
    IF m IS NOT NULL THEN
      RETURN (m[1]::double precision * 12.0
              + coalesce(m[2], '0')::double precision) * 0.0254;
    END IF;
  END IF;

  -- feet/inch, unit-suffix form: 7 ft | 7ft 4in | 24 feet
  m := regexp_match(lower(s),
        '^([0-9]+(?:\.[0-9]+)?)\s*(?:ft|feet|foot)\s*([0-9]+(?:\.[0-9]+)?)?\s*(?:in|inch|inches|")?');
  IF m IS NOT NULL THEN
    RETURN (m[1]::double precision * 12.0
            + coalesce(m[2], '0')::double precision) * 0.0254;
  END IF;

  -- leading number; convert cm/km if suffixed, otherwise assume metres
  m := regexp_match(lower(s), '^([0-9]+(?:\.[0-9]+)?)\s*(cm|km)?');
  IF m IS NOT NULL THEN
    RETURN m[1]::double precision
           * CASE m[2] WHEN 'cm' THEN 0.01 WHEN 'km' THEN 1000.0 ELSE 1.0 END;
  END IF;

  RETURN NULL;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- to_num: tolerant numeric cast for tags like layer/building:min_level.
CREATE OR REPLACE FUNCTION to_num(v text) RETURNS double precision AS $$
DECLARE m text[];
BEGIN
  IF v IS NULL THEN RETURN NULL; END IF;
  m := regexp_match(btrim(v), '^(-?[0-9]+(?:\.[0-9]+)?)');
  IF m IS NULL THEN RETURN NULL; END IF;
  RETURN m[1]::double precision;
END;
$$ LANGUAGE plpgsql IMMUTABLE;
