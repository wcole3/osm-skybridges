-- 96_sample_data.sql : synthetic fixtures for `make tuner-sample`.
--
-- Inserts a hand-built miniature city into the sandbox's raw tables
-- (osm_polygons / osm_lines, created empty by 95_sandbox_seed.sql), one case
-- per geometry pathology the pipeline handles. Runs in ~a second, needs NO
-- downloaded region, and every knob has a case that visibly reacts:
--
--   case 1  clean passage      baseline: corridor cut + lifted lintel
--   case 2  remnant wall       corridor stops 0.8 m short of the far facade
--                              (cut_expand slices the standing wall)
--   case 3  grazing neighbour  building overlapping the host inside the
--                              corridor band (min_cut_inradius gate: no cut)
--   case 4  island leak        0.4 m slot beside the corridor end
--                              (expand grow-only guard: no crumb island)
--   case 5  long ribbon        200 m passage -> cut aspect > max_cut_aspect
--                              (drop_ribbons: host uncarved, span still lifts)
--   case 6  near-full carve    two passages covering a small host
--                              (max_carve_frac -> lifted-only)
--   case 7  bridge_struct      building=bridge slab between two towers
--   case 8  footbridge         footway+bridge deck over a road
--   case 9  geom (untagged)    elongated, crosses a road, touches 2 buildings
--                              (aspect_min slider makes it appear/disappear)
--
-- Geometry is authored in UTM METRES around the region focus point (passed as
-- -v clon/-v clat by pipeline/tuner.py) and transformed to 4326 on insert, so
-- the viewer camera + auto-derived region SRID work unchanged in any region.
-- All synthetic osm_ids are negative — they can never collide with real OSM.

-- UTM zone of the focus (same formula as 01_prepare) + focus in UTM metres.
SELECT 32600
       + LEAST(60, GREATEST(1, floor((:clon + 180) / 6)::int + 1))
       + CASE WHEN :clat < 0 THEN 100 ELSE 0 END AS z
\gset
SELECT round(ST_X(p))::int - 330 AS bx, round(ST_Y(p))::int - 20 AS by
FROM (SELECT ST_Transform(ST_SetSRID(ST_MakePoint(:clon, :clat), 4326), :z) AS p) q
\gset

BEGIN;

-- helper macro-style: rectangles via ST_MakeEnvelope(:bx+x1, :by+y1, …, :z)
-- polygons -----------------------------------------------------------------
INSERT INTO osm_polygons (osm_id, osm_type, tags, geom) VALUES
-- case 1: clean passage host (60 x 30, h=12)
(-101, 'W', '{"building":"yes","height":"12","name":"case1 clean passage host"}',
  ST_Transform(ST_MakeEnvelope(:bx-200, :by+0, :bx-140, :by+30, :z), 4326)),

-- case 2: remnant-wall host (60 x 30, h=12) — corridor will stop 0.8 m short
-- of the east facade (x=+20): passage line ends at x=-0.8, +20 m reach -> 19.2
(-102, 'W', '{"building":"yes","height":"12","name":"case2 remnant wall host"}',
  ST_Transform(ST_MakeEnvelope(:bx-40, :by+0, :bx+20, :by+30, :z), 4326)),

-- case 3: passage host + a neighbour overlapping 2 m INTO the corridor band
(-103, 'W', '{"building":"yes","height":"12","name":"case3 passage host"}',
  ST_Transform(ST_MakeEnvelope(:bx+120, :by+0, :bx+180, :by+30, :z), 4326)),
(-104, 'W', '{"building":"yes","height":"9","name":"case3 grazing neighbour"}',
  ST_Transform(ST_MakeEnvelope(:bx+120, :by+22, :bx+180, :by+90, :z), 4326)),

-- case 4: U-shaped host — two 28 m arms joined by a base, separated by a
-- 0.4 m slot; the corridor ends inside the west arm, cut_expand would leak
-- a crumb across the slot without the grow-only guard.
(-105, 'W', '{"building":"yes","height":"12","name":"case4 island leak host"}',
  ST_Transform(ST_Union(ARRAY[
    ST_MakeEnvelope(:bx+240,   :by+0,  :bx+268,   :by+30, :z),   -- west arm
    ST_MakeEnvelope(:bx+268.4, :by+0,  :bx+296.4, :by+30, :z),   -- east arm
    ST_MakeEnvelope(:bx+240,   :by-10, :bx+296.4, :by+0,  :z)    -- base
  ]), 4326)),

-- case 5: long ribbon host (200 x 40) — lengthwise passage makes an
-- 18 m x 200 m cut, aspect ~11 > max_cut_aspect
(-106, 'W', '{"building":"yes","height":"15","name":"case5 ribbon host"}',
  ST_Transform(ST_MakeEnvelope(:bx+360, :by-5, :bx+560, :by+35, :z), 4326)),

-- case 6: small host fully spanned by TWO passages -> lifted-only
(-107, 'W', '{"building":"yes","height":"8","name":"case6 near-full carve host"}',
  ST_Transform(ST_MakeEnvelope(:bx+600, :by+0, :bx+630, :by+20, :z), 4326)),

-- case 7: tagged bridge slab between two towers
(-108, 'W', '{"building":"bridge","height":"10","name":"case7 building=bridge"}',
  ST_Transform(ST_MakeEnvelope(:bx+660, :by+10, :bx+700, :by+20, :z), 4326)),
(-109, 'W', '{"building":"yes","height":"20","name":"case7 tower west"}',
  ST_Transform(ST_MakeEnvelope(:bx+640, :by+0, :bx+660, :by+30, :z), 4326)),
(-110, 'W', '{"building":"yes","height":"20","name":"case7 tower east"}',
  ST_Transform(ST_MakeEnvelope(:bx+700, :by+0, :bx+720, :by+30, :z), 4326)),

-- case 9: untagged geom candidate (50 x 12: aspect ~4.2, area 600) + the two
-- buildings it connects
(-111, 'W', '{"building":"yes","name":"case9 untagged span"}',
  ST_Transform(ST_MakeEnvelope(:bx+860, :by+10, :bx+910, :by+22, :z), 4326)),
(-112, 'W', '{"building":"yes","height":"18","name":"case9 anchor west"}',
  ST_Transform(ST_MakeEnvelope(:bx+850, :by+5, :bx+860, :by+27, :z), 4326)),
(-113, 'W', '{"building":"yes","height":"18","name":"case9 anchor east"}',
  ST_Transform(ST_MakeEnvelope(:bx+910, :by+5, :bx+920, :by+27, :z), 4326));

-- lines ----------------------------------------------------------------------
INSERT INTO osm_lines (osm_id, tags, geom) VALUES
-- case 1: passage way wall-to-wall (+ its street underneath)
(-201, '{"tunnel":"building_passage","covered":"yes","name":"case1 passage"}',
  ST_Transform(ST_SetSRID(ST_MakeLine(ST_MakePoint(:bx-210, :by+15), ST_MakePoint(:bx-130, :by+15)), :z), 4326)),
(-301, '{"highway":"primary","name":"case1 street"}',
  ST_Transform(ST_SetSRID(ST_MakeLine(ST_MakePoint(:bx-260, :by+15), ST_MakePoint(:bx-80, :by+15)), :z), 4326)),

-- case 2: passage way ending at x=-0.8 (east facade at +20; reach 20 -> 19.2)
(-202, '{"tunnel":"building_passage","name":"case2 short passage"}',
  ST_Transform(ST_SetSRID(ST_MakeLine(ST_MakePoint(:bx-50, :by+15), ST_MakePoint(:bx-0.8, :by+15)), :z), 4326)),
(-302, '{"highway":"residential","name":"case2 street"}',
  ST_Transform(ST_SetSRID(ST_MakeLine(ST_MakePoint(:bx-70, :by+15), ST_MakePoint(:bx-25, :by+15)), :z), 4326)),

-- case 3: passage way through the host (the neighbour only grazes the band)
(-203, '{"tunnel":"building_passage","name":"case3 passage"}',
  ST_Transform(ST_SetSRID(ST_MakeLine(ST_MakePoint(:bx+110, :by+15), ST_MakePoint(:bx+190, :by+15)), :z), 4326)),

-- case 4: passage into the west arm only: ends at x=+247.3, reach 20 ->
-- corridor face at 267.3, 0.7 m short of the arm face (268); the 0.4 m slot
-- sits at 268..268.4 — cut_expand >= 1.1 would cross it without the guard
(-204, '{"tunnel":"building_passage","name":"case4 pocket passage"}',
  ST_Transform(ST_SetSRID(ST_MakeLine(ST_MakePoint(:bx+230, :by+15), ST_MakePoint(:bx+247.3, :by+15)), :z), 4326)),

-- case 5: lengthwise 200 m passage
(-205, '{"tunnel":"building_passage","name":"case5 ribbon passage"}',
  ST_Transform(ST_SetSRID(ST_MakeLine(ST_MakePoint(:bx+350, :by+15), ST_MakePoint(:bx+570, :by+15)), :z), 4326)),

-- case 6: two parallel passages covering the small host end-to-end
(-206, '{"tunnel":"building_passage","name":"case6 passage south"}',
  ST_Transform(ST_SetSRID(ST_MakeLine(ST_MakePoint(:bx+590, :by+5), ST_MakePoint(:bx+640, :by+5)), :z), 4326)),
(-207, '{"tunnel":"building_passage","name":"case6 passage north"}',
  ST_Transform(ST_SetSRID(ST_MakeLine(ST_MakePoint(:bx+590, :by+15), ST_MakePoint(:bx+640, :by+15)), :z), 4326)),

-- case 8: footway bridge over a street
(-208, '{"highway":"footway","bridge":"yes","name":"case8 footbridge"}',
  ST_Transform(ST_SetSRID(ST_MakeLine(ST_MakePoint(:bx+760, :by+15), ST_MakePoint(:bx+820, :by+15)), :z), 4326)),
(-303, '{"highway":"primary","name":"case8 street"}',
  ST_Transform(ST_SetSRID(ST_MakeLine(ST_MakePoint(:bx+790, :by-40), ST_MakePoint(:bx+790, :by+60)), :z), 4326)),

-- case 9: the street the untagged span crosses
(-304, '{"highway":"primary","name":"case9 street"}',
  ST_Transform(ST_SetSRID(ST_MakeLine(ST_MakePoint(:bx+885, :by-30), ST_MakePoint(:bx+885, :by+60)), :z), 4326));

COMMIT;

\echo 'sample fixtures loaded:'
SELECT (SELECT count(*) FROM osm_polygons) AS polygons,
       (SELECT count(*) FROM osm_lines)    AS lines;
