# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A pipeline that finds OpenStreetMap buildings/walkways that are elevated in reality but
drawn solid-to-the-ground in 3D (missing `min_height`), computes the fix, and renders a
before/after 3D viewer plus a human review queue. Default region is Washington DC; the
flagship test case is the Walter E. Washington Convention Center (`osm_id=55316481`),
which spans L St and M St NW.

Read `docs/how-it-works.md` for the full architecture narrative and `docs/glossary.md`
for terminology. `CONTRIBUTING.md` has change recipes.

## Commands

The whole project is driven by `make` (Docker + SQL-first; no Node/pip). Postgres is
exposed on **localhost:5439** (db `osm`, user/pass `osm`/`osm`).

```bash
make all        # from zero: up + build tools + download + ingest + sql + export (~30s)
make sql        # re-run analysis SQL after editing sql/*.sql
make export      # re-write web/data/*.geojson + qa/qa_flags.geojson after sql changes
make viewer     # serve the 3D viewer at http://localhost:8000 (static)
make psql       # open a DB shell
make reset      # drop the DB volume (start clean)
make ingest     # reload OSM after editing pipeline/flex.lua
```

### Dev loop
`edit sql/*.sql → make sql → make export → hard-refresh browser (Ctrl+Shift+R)`.
Viewer-only edits (`web/index.html`) need just a refresh.

### Verification (there is no test framework — use this instead)
The gold-standard check is a clean rebuild: `make reset && make all` must exit 0.
Then assert invariants in `make psql` (all must return 0): `corrected_spans` with
`base_h >= top_h`; empty/invalid `geom_m` in `corrected_spans`; empty/invalid `cut_m`
in `building_cuts`; `buildings` with `NOT ST_IsValid(geom_m)` or `height_render < 0`.
Regression: `SELECT count(*) FROM skybridge_candidates WHERE osm_id=55316481 AND class='passage'` should be 4.

### Switch regions (auto-detects the UTM zone — no CRS step)
```bash
make region REGION=<slug> PBF_URL=<geofabrik .osm.pbf> CLON=<lon> CLAT=<lat> FOCUS_LABEL="..."
```
Or `cp region.example.mk region.mk` and edit. `SRID=0` (default) auto-derives the metric
CRS; set `SRID=3857` only for multi-UTM-zone extents.

## Architecture

A linear pipeline; each `sql/NN_*.sql` file builds tables the next one consumes.
**The analysis is the SQL — PostGIS does the geometry math, not application code.**

```
.osm.pbf → osm2pgsql/flex → osm_polygons, osm_lines        (raw import)
  01_prepare   → buildings, roads, rail, water, obstacles(view), region(table)
  02_detect_tagged + 03_detect_geometry → cand_raw          (candidates)
  04_score_dedupe → skybridge_candidates                    (+confidence/action)
  05_correct   → corrected_spans, building_cuts             (the fix geometry)
  90/92/93/91 export → web/data/*.geojson, qa/qa_flags.geojson
  web/index.html (deck.gl + MapLibre) reads web/data/*
```

Detection classes (in `cand_raw.class`): `bridge_struct` (tagged `building=bridge`),
`passage` (footprint covering a `tunnel=building_passage` — the dominant real case),
`footbridge` (footway+bridge, inventory only), `geom` (untagged: long+thin AND crosses
an obstacle AND touches 2 buildings AND missing base). Confidence → `action` of
`auto_correct` / `review` / `inventory`.

Correction: `min_height = clearance_floor` (~4.5/5/6 m for road/covered/rail);
passages get their corridor sliced edge-to-edge (the passage line is `extend_line`'d
60 m past both building faces first); `building_cuts` is subtracted from hosts to make
the "modified footprint."

### Two coordinate columns — do not mix them
- `geom_m` — metric UTM (from `region_srid()`). **All distance/area/crossing math uses
  this.** Aspect ratios are CRS-independent but metres require it.
- `geom_4326` — lat/long, used ONLY at export time for the map.
The UTM zone is auto-derived in `01_prepare.sql` and exposed via the `region_srid()`
function; never hardcode an SRID.

### Viewer lift mechanism
deck.gl has no "extrude from height N" property. Floating spans put their `min_height`
into the polygon's **Z coordinate** (`liftRings`), and deck.gl extrudes upward from
there. `SolidPolygonLayer` is used for spans (it accepts per-vertex Z) and **cannot
render a MultiPolygon** — spans are split to single polygons via `explodeSpans` first.
Normal buildings use `GeoJsonLayer`. The three view modes (`raw`/`corrected`/`footprint`)
swap datasets in `buildLayers()`. Camera/label come from `web/data/meta.json` (per region).

## Cross-cutting gotchas

- **Makefile values must have NO trailing whitespace** — Make folds it into the value
  and it corrupts file paths (this broke ingest once). Keep comments on their own lines;
  `$(strip ...)` guards the derived vars.
- **`(osm_id, osm_type)` together** identify a feature; `osm_id` alone is not unique
  across node/way/relation. Join on both.
- **Validate OSM geometry** — real data has self-crossing polygons. `01_prepare.sql`
  repairs `buildings.geom_m`/`geom_4326` once; new geometry sources need `ST_MakeValid`.
- **`layer` is not a height** — only `min_height`/`building:min_level` lift geometry.
- **`missing_base`** (no float tag) gates candidates, but `building:min_level` defaults
  to 0 and is omitted when 0, so absence ≠ ground — geometry, not tag presence, decides.
- A building spanning multiple passages legitimately yields multiple `passage` rows
  (one per `passage_way`); that is not a duplicate.
- `04_score_dedupe.sql` does light dedup (drops a footbridge line mostly inside a polygon
  candidate) and 02's passage tier skips features already caught as `bridge_struct`;
  preserve those guards when adding tiers.

## graphify

This project has a knowledge graph at graphify-out/ with god nodes, community structure, and cross-file relationships.

Rules:
- For codebase questions, first run `graphify query "<question>"` when graphify-out/graph.json exists. Use `graphify path "<A>" "<B>"` for relationships and `graphify explain "<concept>"` for focused concepts. These return a scoped subgraph, usually much smaller than GRAPH_REPORT.md or raw grep output.
- If graphify-out/wiki/index.md exists, use it for broad navigation instead of raw source browsing.
- Read graphify-out/GRAPH_REPORT.md only for broad architecture review or when query/path/explain do not surface enough context.
- After modifying code, run `graphify update .` to keep the graph current (AST-only, no API cost).
