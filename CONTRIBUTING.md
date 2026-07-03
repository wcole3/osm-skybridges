# Contributing

Welcome! This guide gets you from "just cloned it" to "made a change and verified
it." You don't need a GIS or 3D background — if you can read SQL and a little
JavaScript, you can contribute. New to the vocabulary? Keep
[docs/glossary.md](docs/glossary.md) open. Want the big picture first?
Read [docs/how-it-works.md](docs/how-it-works.md).

---

## 1. One-time setup

You need: **Docker**, **make**, **psql** (the Postgres client), and **python3** —
all standard on Linux/macOS/WSL. You do **not** install Postgres, PostGIS, or any
mapping tools; Docker provides them.

```bash
make all       # starts the database, loads Washington DC, runs the analysis, exports
make viewer    # serves the 3D viewer at http://localhost:8000
```

Open <http://localhost:8000>. If you see a 3D city with a "view" dropdown, you're
ready. (First run is the slow one — it downloads ~20 MB and builds a Docker image,
~2 min; a warm rebuild is ~30 s.)

Useful one-off commands:

| Command | What it does |
|---|---|
| `make up` | start just the database (localhost:5439) |
| `make sql` | re-run the analysis SQL (after editing `sql/*.sql`) |
| `make export` | re-write the GeoJSON the viewer reads |
| `make export-final` | full-fidelity final dataset → `exports/final_*.geojson` |
| `make gpkg` | same dataset as a GeoPackage → `exports/final.gpkg` (QGIS-ready) |
| `make tuner` | viewer + live tuning sliders (sandboxed — see §4) |
| `make tuner-sample` | same, on built-in synthetic fixtures (works before any `make all`) |
| `make psql` | open a database shell to poke around |
| `make config` | list the tunable `config` values |
| `make config-export` | write the settings as shareable JSON (`exports/config.json`) |
| `make config-load FILE=…` | ingest a shared settings file, persist + re-derive |
| `make tune KEY=… VAL=…` | change one tunable, persist it, and re-derive (see §4) |
| `make down` | stop the containers, **keep** the data |
| `make reset` | wipe the database volume (start clean) |

---

## 2. The development loop

Most changes follow the same rhythm:

```
edit sql/*.sql  →  make sql  →  make export  →  refresh the browser (Ctrl+Shift+R)
```

- Changed **analysis logic** (`sql/01`–`06`)? Run `make sql` then `make export`.
- Changed only a **viewer export** (`sql/90`–`93`)? Just `make export`. (The carve
  itself lives in `sql/06_finalize.sql`, run by `make sql` — the 9x files only
  format it.)
- Changed a **final export** (`sql/94_*`)? Just `make export-final` / `make gpkg`.
- Changed the **viewer** (`web/index.html`)? Just refresh the browser — it's static.
- Changed **how data is loaded** (`pipeline/flex.lua`)? Run `make ingest` then
  `make sql` then `make export`.
- **Tuning a threshold?** Skip the loop entirely: `make tuner` gives you live
  sliders against a sandbox (§4).

To inspect results, `make psql` and run queries, e.g.:

```sql
SELECT class, confidence, action, count(*) FROM skybridge_candidates GROUP BY 1,2,3 ORDER BY 1;
```

---

## 3. Project map

```
Makefile                    every command; region config lives at the top
docker-compose.yml          defines the database + tools containers
region.example.mk           copy to region.mk to switch cities
pipeline/flex.lua           tells osm2pgsql which OSM features to load
sql/
  00_init.sql               helper functions (parse_height, cleanup helpers, cfg)
  01_prepare.sql            classify data, pick the metric CRS, resolve heights,
                            config + config_meta (tuner metadata)
  02_detect_tagged.sql      candidates from TAGS (bridge_struct, passage, footbridge)
  03_detect_geometry.sql    candidates from SHAPE (untagged spans)
  04_score_dedupe.sql       assign confidence/action, remove duplicates
  05_correct.sql            compute min_height + the floating/cut geometry
  06_finalize.sql           the carve (building − cut) + buildings_final/spans_final
  90_export_buildings.sql   ┐
  90_export_skybridges.sql  │  the viewer's GeoJSON slice (92 reads buildings_final;
  92_export_corrected_*.sql │  the carve itself is in 06)
  93_export_cuts.sql        ┘
  91_export_qa.sql          the human review queue (qa/qa_flags.geojson)
  94_export_final_*.sql     full-fidelity final dataset (make export-final / gpkg)
  95_sandbox_seed.sql       raw tables for the tuner's sandbox database
  96_sample_data.sql        synthetic fixtures for `make tuner-sample`
  99_selfcheck.sql          fail-fast geometry invariants (run last by `make sql`)
pipeline/tuner.py           the live tuner server (`make tuner` — stdlib only)
web/index.html              the deck.gl + MapLibre 3D viewer (one static file)
docs/                       glossary, how-it-works, geometry-quality (tuning), OSM loop
```

The SQL files run **in number order** and each builds on the previous one's tables.
The important tables, in the order they're created:

`osm_polygons`/`osm_lines` (raw) → `buildings`/`roads`/`rail`/`water` (01) →
`cand_raw` (02, 03) → `skybridge_candidates` (04) →
`corrected_spans` + `building_cuts` (05) →
`carved_hosts` + the `buildings_final`/`spans_final` views (06).

---

## 4. "I want to…" recipes

### …analyze a different city

Easiest change in the project — see the README's "Process another region" section.
In short:

```bash
make region REGION=minnesota \
  PBF_URL=https://download.geofabrik.de/north-america/us/minnesota-latest.osm.pbf \
  CLON=-93.2691 CLAT=44.9773 FOCUS_LABEL="Minneapolis Skyway"
make viewer
```

The metric coordinate system is auto-detected, so you only supply the data URL and a
camera point. To make it permanent, `cp region.example.mk region.mk` and edit it.

### …tune a threshold (cut size, aspect ratio, clearance, default height)

**All numeric tunables live in the `config` table** (defaults in the labelled block at
the top of `sql/01_prepare.sql`; slider ranges + the pipeline stage each knob re-runs
live next to it in `config_meta`). The best way to explore is **live**:

```bash
make tuner          # sliders in the viewer; re-derives a sandbox in seconds
make tuner-sample   # same, on tiny built-in fixtures — one per geometry pathology
```

Experiments touch only the sandbox database; click **apply to real dataset** to push
the values to the live data and **save as defaults** to persist them into
`sql/01_prepare.sql`. The one-shot alternative:

```bash
make config                          # list every knob + current value
make tune KEY=cut_expand VAL=0.8     # change it, persist it, re-derive + re-export
```

`make tune` rewrites the default in `sql/01_prepare.sql` (so it persists and shows in
`git diff`), then runs `make sql` + `make export`; then hard-refresh the viewer. It
works for any key — e.g. `aspect_min` (untagged-span shape threshold), `cut_expand`
(how much host to slice out under a span — the one you reach for when openings leave
thin "walls"), `corridor_halfwidth`, `level_height`, `default_top`.

**Every knob is documented in [docs/geometry-quality.md](docs/geometry-quality.md)** —
what it does, its default, and which way to turn it. To see the effect on the count:

```sql
SELECT class, count(*) FROM skybridge_candidates GROUP BY 1;
```

(Clearance heights themselves — 4.5/5.0/6.0 m — are still literals in
`clearance_floor` in `sql/05_correct.sql`; edit there if you need to change them.)

### …add a new detection rule

Detection is just SQL `INSERT`s into the `cand_raw` table. To add a tag-based rule,
add an `INSERT` to `sql/02_detect_tagged.sql` following the existing tiers; to add a
shape-based rule, work in `sql/03_detect_geometry.sql`. Each row needs a `class`, a
geometry (`geom_m`), and a `reasons` array explaining why it fired. Then make sure
`sql/04` gives your new `class` a confidence and an action, and `sql/05` knows how to
build its corrected geometry. **Tip:** add a guard so you don't double-insert a
feature another tier already caught (see the `NOT EXISTS` checks in 02 and 03).

### …change what the viewer shows

Everything is in [`web/index.html`](web/index.html) — one file, no build step. The
`buildLayers()` function decides which deck.gl layers to draw for each view mode
(`raw` / `corrected` / `footprint`). Colors, heights, and the hover tooltip are all
there. Edit, save, refresh the browser.

### …add a new export

Copy one of `sql/90`–`94` as a template (they each emit one GeoJSON
`FeatureCollection`), add a line to the `export` (viewer) or `export-final` target in
the `Makefile`, and (if the viewer should read it) load it in `web/index.html`'s
`loadData()`. Prefer reading the `buildings_final` / `spans_final` views — they carry
the corrections already applied; that's what `sql/94_export_final_*.sql` and the
GeoPackage (`make gpkg`, via the typed `export_final_*` views) do.

---

## 5. Testing your change

There's no formal test suite yet, but there **is** a verification routine — run it
before you commit. The gold-standard check is a clean rebuild from zero:

```bash
make reset && make all
```

This must finish with exit code 0. Most invariants are now enforced automatically:
`make sql` runs [`sql/99_selfcheck.sql`](sql/99_selfcheck.sql), which **aborts the
build** if any of them fail. You can also assert them by hand in `make psql`:

```sql
-- these should all return 0
SELECT count(*) FROM corrected_spans   WHERE base_h >= top_h;                       -- floats must be below their tops
SELECT count(*) FROM corrected_spans   WHERE ST_IsEmpty(geom_m) OR NOT ST_IsValid(geom_m);
SELECT count(*) FROM corrected_spans   WHERE GeometryType(geom_m) NOT IN ('POLYGON','MULTIPOLYGON');  -- viewer needs polygons
SELECT count(*) FROM building_cuts     WHERE ST_IsEmpty(cut_m)  OR NOT ST_IsValid(cut_m);
SELECT count(*) FROM carved_hosts      WHERE NOT lifted_only AND (geom_m IS NULL OR ST_IsEmpty(geom_m) OR NOT ST_IsValid(geom_m));
SELECT count(*) FROM buildings         WHERE height_render < 0;                     -- no negative heights
-- overlay crumbs: fixed-precision overlays make these impossible-in-practice
SELECT count(*) FROM building_cuts c, LATERAL ST_Dump(c.cut_m) d
WHERE ST_Area(d.geom) < 4 * (SELECT value FROM config WHERE key='grid_size')^2;
```

If you change the cleanup/cut geometry, also see
[docs/geometry-quality.md](docs/geometry-quality.md) §6 — and remember thin "walls",
slivers, and tessellation fans often only show up **visually**, so eyeball the viewer.

And confirm the flagship example still works (Washington DC) — `99_selfcheck` now
asserts this automatically whenever the building is in the region, but by hand:

```sql
-- the convention center should be detected on its passages...
SELECT count(*) FROM skybridge_candidates WHERE osm_id = 55316481 AND class = 'passage';   -- expect 4
```

Finally, check the exported files parse and the viewer serves:

```bash
python3 -c "import json; [json.load(open(f)) for f in ['web/data/buildings.geojson','web/data/skybridges.geojson','qa/qa_flags.geojson']]; print('valid')"
# and, if you ran `make export-final`:
python3 -m json.tool exports/final_buildings.geojson > /dev/null && echo valid
```

If you changed geometry logic, also eyeball the result in the viewer — some things
(z-fighting, slivers) only show up visually.

---

## 6. Conventions & gotchas

- **Metres vs. degrees.** Do distance/area math on `geom_m` (metres). Only convert to
  `geom_4326` (lat/long) at export time, for the map. Never measure metres on
  lat/long.
- **Always validate geometry from OSM.** Real-world data has self-crossing polygons.
  We repair them once in `01_prepare.sql`; if you introduce a new geometry source,
  wrap it in `ST_MakeValid(...)`.
- **`(osm_id, osm_type)` together identify a feature** — an `osm_id` alone is not
  unique across nodes/ways/relations. Join on both.
- **Makefile values must have no trailing spaces.** Make folds trailing whitespace
  into the value and it will corrupt file paths. Keep comments on their own lines, not
  after a value. (We learned this the hard way — see the README config block.)
- **deck.gl `SolidPolygonLayer` can't draw a MultiPolygon.** Split into single
  polygons first (the viewer's `explodeSpans` does this).
- **`layer` is not a height.** Never derive an elevation from the `layer` tag; only
  `min_height` / `building:min_level` lift geometry.
- **All metric overlays run on a fixed-precision grid** (`grid_size`, 1 cm — see
  [docs/geometry-quality.md §0](docs/geometry-quality.md)). New overlay calls on
  `geom_m` should pass the `gridSize` argument (or go through `clean_span`), and the
  database image must stay `postgis/postgis:16-3.5-alpine` — the Debian `16-3.5`
  image ships GEOS 3.9, which lacks the required functions (need GEOS ≥ 3.10).

---

## 7. Background & decisions

The detection tags, the rendering-engine choice, and the correction math are all
grounded in a research pass whose conclusions are summarized in
[docs/how-it-works.md](docs/how-it-works.md) and the project plan. If you're changing
a core assumption (e.g. which tags count as a skybridge), skim those first so you know
why it's the way it is.

Questions or unsure if an idea fits? Open an issue describing what you want to change
and why — small, well-described changes are easiest to review.
