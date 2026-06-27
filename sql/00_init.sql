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

-- ===========================================================================
-- GEOMETRY-CLEANUP HELPERS (shared by 05_correct.sql / 91 / 99_selfcheck.sql)
-- All operate on metric (geom_m / region_srid) geometry. STABLE, not IMMUTABLE:
-- ST_MakeValid is not formally immutable across GEOS versions.
-- ===========================================================================

-- clean_span: the canonical "always-valid, polygon-only MultiPolygon" tail.
-- Repair -> keep polygons -> drop duplicate vertices (0.1 m) -> repair -> Multi.
-- Returns NULL only for NULL input; an all-non-polygon input yields MULTIPOLYGON EMPTY.
CREATE OR REPLACE FUNCTION clean_span(g geometry) RETURNS geometry AS $$
  SELECT CASE WHEN g IS NULL THEN NULL ELSE
    ST_Multi(ST_CollectionExtract(
      ST_MakeValid(ST_RemoveRepeatedPoints(
        ST_CollectionExtract(ST_MakeValid(g), 3), 0.1)), 3))
  END
$$ LANGUAGE sql STABLE;

-- simplify_vw: Visvalingam-Whyatt (AREA-based) simplification, kept always-valid.
-- Unlike ST_SimplifyPreserveTopology (Douglas-Peucker, distance-based, which
-- PRESERVES sharp narrow spikes), VW ranks vertices by the triangle area they form
-- with their neighbours and removes the smallest first, so it ELIMINATES thin
-- spikes/slivers (the QEM edge-collapse analog). area_tol is an m^2 floor.
-- ST_SimplifyVW does NOT guarantee validity, so it is wrapped in clean_span.
CREATE OR REPLACE FUNCTION simplify_vw(g geometry, area_tol double precision) RETURNS geometry AS $$
  SELECT CASE WHEN g IS NULL THEN NULL ELSE clean_span(ST_SimplifyVW(g, area_tol)) END
$$ LANGUAGE sql STABLE;

-- drop_tiny_parts: remove disjoint polygon parts below min_area (m^2); never
-- empties — falls back to the single largest part. Catches detached slivers.
CREATE OR REPLACE FUNCTION drop_tiny_parts(g geometry, min_area double precision) RETURNS geometry AS $$
  WITH parts AS (SELECT (ST_Dump(g)).geom AS gp)
  SELECT COALESCE(
    ST_Multi(ST_Collect(gp) FILTER (WHERE ST_Area(gp) >= min_area)),
    (SELECT ST_Multi(gp) FROM parts ORDER BY ST_Area(gp) DESC LIMIT 1)
  ) FROM parts
$$ LANGUAGE sql STABLE;

-- despike_parts: keep a part only if it is not pathologically thin — true min
-- half-width (max inscribed circle radius) >= min_inradius OR Polsby-Popper
-- compactness >= min_compact, AND in every case >= hard_min (an absolute thin-
-- floor a "compact-but-narrow" slab cannot pass on compactness alone). Never
-- empties (keep-largest fallback).
CREATE OR REPLACE FUNCTION despike_parts(g geometry, min_inradius double precision, min_compact double precision,
    hard_min double precision DEFAULT 0.35) RETURNS geometry AS $$
  WITH scored AS (
    SELECT gp,
           (ST_MaximumInscribedCircle(gp)).radius AS r,
           CASE WHEN ST_Perimeter(gp) > 0 THEN 4*pi()*ST_Area(gp)/(ST_Perimeter(gp)^2) ELSE 0 END AS pp
    FROM (SELECT (ST_Dump(g)).geom AS gp) parts
  )
  SELECT COALESCE(
    ST_Multi(ST_Collect(gp) FILTER (WHERE r >= hard_min AND (r >= min_inradius OR pp >= min_compact))),
    (SELECT ST_Multi(gp) FROM scored ORDER BY ST_Area(gp) DESC LIMIT 1)
  ) FROM scored
$$ LANGUAGE sql STABLE;

-- prune_parts: keep only polygon parts that are both big enough (>= min_area) and
-- not too thin (inscribed radius >= min_inradius OR compactness >= min_compact),
-- AND at least hard_min wide (absolute thin-floor, regardless of compactness).
-- Unlike drop_tiny_parts/despike_parts there is NO keep-largest fallback, so an
-- all-sliver input returns EMPTY. Used for building_cuts: a cut made entirely of
-- cross-building clip slivers should carve NOTHING (host reverts to its original
-- footprint in 92) rather than punch a hairline slit into a wall.
CREATE OR REPLACE FUNCTION prune_parts(g geometry, min_area double precision,
    min_inradius double precision, min_compact double precision,
    hard_min double precision DEFAULT 0.35) RETURNS geometry AS $$
  SELECT clean_span(ST_Collect(d.geom))
  FROM ST_Dump(g) d
  WHERE ST_Area(d.geom) >= min_area
    AND (ST_MaximumInscribedCircle(d.geom)).radius >= hard_min
    AND ((ST_MaximumInscribedCircle(d.geom)).radius >= min_inradius
         OR (CASE WHEN ST_Perimeter(d.geom) > 0
                  THEN 4*pi()*ST_Area(d.geom)/(ST_Perimeter(d.geom)^2) ELSE 0 END) >= min_compact)
$$ LANGUAGE sql STABLE;

-- mbr_aspect: long-side / short-side of the minimum-area rotated rectangle.
-- A compact opening is ~1-5; a long thin ribbon is >>10. (Lives here so the
-- cleanup helpers can use it; 03_detect_geometry.sql also uses it for detection.)
CREATE OR REPLACE FUNCTION mbr_aspect(g geometry) RETURNS double precision AS $$
DECLARE r geometry; a double precision; b double precision;
BEGIN
  r := ST_ExteriorRing(ST_OrientedEnvelope(g));
  IF r IS NULL THEN RETURN NULL; END IF;
  a := ST_Distance(ST_PointN(r,1), ST_PointN(r,2));
  b := ST_Distance(ST_PointN(r,2), ST_PointN(r,3));
  IF LEAST(a,b) = 0 THEN RETURN NULL; END IF;
  RETURN GREATEST(a,b) / LEAST(a,b);
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- drop_ribbons: remove disjoint polygon parts shaped like a long thin ribbon
-- (oriented-bbox aspect > max_aspect) — e.g. the footprint cut of a very long
-- (~100 m) building_passage, which is a real but visually slivery opening. No
-- keep-largest fallback: an all-ribbon input returns EMPTY (host stays uncarved;
-- the passage still shows as a lifted span). Compact openings (aspect <= max) stay.
CREATE OR REPLACE FUNCTION drop_ribbons(g geometry, max_aspect double precision) RETURNS geometry AS $$
  SELECT clean_span(ST_Collect(d.geom))
  FROM ST_Dump(g) d
  WHERE mbr_aspect(d.geom) IS NULL OR mbr_aspect(d.geom) <= max_aspect
$$ LANGUAGE sql STABLE;

-- morph_open: morphological opening (erode by k, then dilate by k) with mitre
-- caps so genuine right angles stay square. Melts protrusions/slivers < 2k wide.
CREATE OR REPLACE FUNCTION morph_open(g geometry, k double precision) RETURNS geometry AS $$
  SELECT clean_span(ST_Buffer(ST_Buffer(g, -k, 'join=mitre mitre_limit=2.0'),
                                       k, 'join=mitre mitre_limit=2.0'))
$$ LANGUAGE sql STABLE;

-- clean_geom_passage: the guarded auto-clean for passage spans/cuts.
-- 1) surgical: drop tiny disjoint parts, then drop pathologically thin parts;
-- 2) opening as a guarded fallback for a thin protrusion that is still connected
--    to a healthy slab — applied ONLY if it keeps >= area_keep of the area and
--    does NOT split the geometry into more parts (would erase a real narrow span).
-- Never empties. The revert-to-baseline + review routing is decided by the caller.
CREATE OR REPLACE FUNCTION clean_geom_passage(
    g geometry, min_part double precision, min_inradius double precision,
    min_compact double precision, open_k double precision, area_keep double precision
) RETURNS geometry AS $$
  WITH s1 AS (SELECT despike_parts(drop_tiny_parts(g, min_part), min_inradius, min_compact) AS g1),
       s2 AS (SELECT g1, morph_open(g1, open_k) AS go FROM s1)
  SELECT clean_span(CASE
    WHEN go IS NULL OR ST_IsEmpty(go)                       THEN g1   -- opening failed
    WHEN ST_Area(go) < area_keep * ST_Area(g1)              THEN g1   -- opening ate too much
    WHEN ST_NumGeometries(go) > ST_NumGeometries(g1)        THEN g1   -- opening split a part
    ELSE go END)
  FROM s2
$$ LANGUAGE sql STABLE;

-- ── shape-quality metrics (metric CRS); per-part via ST_Dump for MultiPolygons ──
CREATE OR REPLACE FUNCTION qa_min_halfwidth(g geometry) RETURNS double precision AS $$
  SELECT CASE WHEN g IS NULL OR ST_IsEmpty(g) THEN NULL
    ELSE (SELECT min((ST_MaximumInscribedCircle(d.geom)).radius) FROM ST_Dump(g) d) END
$$ LANGUAGE sql STABLE;

-- qa_max_halfwidth: the FATTEST part's inscribed radius (is there a substantial
-- part at all?). Used to tell a real opening (has a fat part) from a pure grazing
-- sliver (every part thin) when a wide corridor clips a building it only grazes.
CREATE OR REPLACE FUNCTION qa_max_halfwidth(g geometry) RETURNS double precision AS $$
  SELECT CASE WHEN g IS NULL OR ST_IsEmpty(g) THEN NULL
    ELSE (SELECT max((ST_MaximumInscribedCircle(d.geom)).radius) FROM ST_Dump(g) d) END
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION qa_compactness(g geometry) RETURNS double precision AS $$
  SELECT CASE WHEN g IS NULL OR ST_IsEmpty(g) OR ST_Perimeter(g) = 0 THEN NULL
    ELSE 4*pi()*ST_Area(g)/(ST_Perimeter(g)^2) END
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION qa_min_part_area(g geometry) RETURNS double precision AS $$
  SELECT CASE WHEN g IS NULL OR ST_IsEmpty(g) THEN NULL
    ELSE (SELECT min(ST_Area(d.geom)) FROM ST_Dump(g) d) END
$$ LANGUAGE sql STABLE;
