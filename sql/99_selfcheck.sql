-- 99_selfcheck.sql : fail-fast geometry invariants, run after correction.
-- Wired into `make sql` under ON_ERROR_STOP=1, so a violated invariant aborts
-- the build instead of shipping broken geometry to the viewer.
--
-- Two tiers:
--   FATAL (RAISE EXCEPTION) — true invariants the renderer/feature depend on.
--   WARN  (SELECT/\echo)    — "thin but maybe real" counts. Thin != broken;
--                             such spans are already reverted + routed to review
--                             (qa_status='still_severe'), so they must NOT abort.

SELECT
  (SELECT value FROM config WHERE key='severe_inradius') AS severe_inradius,
  (SELECT value FROM config WHERE key='min_part_area')   AS min_part_area
\gset

-- ── FATAL invariants ───────────────────────────────────────────────────────
DO $$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM corrected_spans WHERE base_h >= top_h;
  IF n > 0 THEN RAISE EXCEPTION 'selfcheck: % corrected_spans with base_h >= top_h', n; END IF;

  SELECT count(*) INTO n FROM corrected_spans
   WHERE geom_m IS NULL OR ST_IsEmpty(geom_m) OR NOT ST_IsValid(geom_m);
  IF n > 0 THEN RAISE EXCEPTION 'selfcheck: % corrected_spans with empty/invalid geom_m', n; END IF;

  -- the deck.gl viewer's explodeSpans/SolidPolygonLayer path requires polygonal spans
  SELECT count(*) INTO n FROM corrected_spans
   WHERE GeometryType(geom_m) NOT IN ('POLYGON','MULTIPOLYGON');
  IF n > 0 THEN RAISE EXCEPTION 'selfcheck: % corrected_spans with non-polygonal geom_m (breaks explodeSpans)', n; END IF;

  SELECT count(*) INTO n FROM building_cuts
   WHERE cut_m IS NULL OR ST_IsEmpty(cut_m) OR NOT ST_IsValid(cut_m);
  IF n > 0 THEN RAISE EXCEPTION 'selfcheck: % building_cuts with empty/invalid cut_m', n; END IF;

  -- WEWCC regression — only when the flagship building is in this region
  IF EXISTS (SELECT 1 FROM buildings WHERE osm_id = 55316481) THEN
    SELECT count(*) INTO n FROM skybridge_candidates WHERE osm_id = 55316481 AND class = 'passage';
    IF n <> 4 THEN RAISE EXCEPTION 'selfcheck: WEWCC passage count = % (expected 4)', n; END IF;
  END IF;
END $$;

\echo 'selfcheck: FATAL invariants passed.'

-- ── WARN-only: still-thin geometry remaining (already routed to review) ──────
\echo 'selfcheck: parts thinner than severe_inradius (warn-only, flagged to review):'
SELECT count(*) AS severe_parts
FROM (SELECT (ST_MaximumInscribedCircle((ST_Dump(geom_m)).geom)).radius AS r
      FROM corrected_spans) q
WHERE r < :severe_inradius;

\echo 'selfcheck: corrected_spans by qa_status:'
SELECT qa_status, count(*) FROM corrected_spans GROUP BY 1 ORDER BY 1;
