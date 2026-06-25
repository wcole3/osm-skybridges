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
make all       # starts the database, loads Washington DC, runs the analysis, exports (~2 min)
make viewer    # serves the 3D viewer at http://localhost:8000
```

Open <http://localhost:8000>. If you see a 3D city with a "view" dropdown, you're
ready. (First run downloads ~20 MB and builds a Docker image, so it's the slow one.)

Useful one-off commands:

| Command | What it does |
|---|---|
| `make up` | start just the database (localhost:5439) |
| `make sql` | re-run the analysis SQL (after editing `sql/*.sql`) |
| `make export` | re-write the GeoJSON the viewer reads |
| `make psql` | open a database shell to poke around |
| `make reset` | wipe the database volume (start clean) |

---

## 2. The development loop

Most changes follow the same rhythm:

```
edit sql/*.sql  →  make sql  →  make export  →  refresh the browser (Ctrl+Shift+R)
```

- Changed **analysis logic**? Run `make sql` then `make export`.
- Changed only an **export** (`sql/90`–`93`)? Just `make export`.
- Changed the **viewer** (`web/index.html`)? Just refresh the browser — it's static.
- Changed **how data is loaded** (`pipeline/flex.lua`)? Run `make ingest` then
  `make sql` then `make export`.

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
  00_init.sql               helper functions (parse_height, to_num)
  01_prepare.sql            classify data, pick the metric CRS, resolve heights
  02_detect_tagged.sql      candidates from TAGS (bridge_struct, passage, footbridge)
  03_detect_geometry.sql    candidates from SHAPE (untagged spans)
  04_score_dedupe.sql       assign confidence/action, remove duplicates
  05_correct.sql            compute min_height + the floating/cut geometry
  90_export_buildings.sql   ┐
  90_export_skybridges.sql  │  turn database rows into GeoJSON the viewer reads
  92_export_corrected_*.sql │
  93_export_cuts.sql        ┘
  91_export_qa.sql          the human review queue (qa/qa_flags.geojson)
web/index.html              the deck.gl + MapLibre 3D viewer (one static file)
docs/                       glossary, how-it-works, OSM contribution guide
```

The SQL files run **in number order** and each builds on the previous one's tables.
The important tables, in the order they're created:

`osm_polygons`/`osm_lines` (raw) → `buildings`/`roads`/`rail`/`water` (01) →
`cand_raw` (02, 03) → `skybridge_candidates` (04) →
`corrected_spans` + `building_cuts` (05).

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

### …tune a threshold (aspect ratio, clearance, default height)

These live in two places:

- **`sql/01_prepare.sql`**, the `config` table near the top: `level_height` (metres
  per floor, default 3.0), `aspect_min` (untagged-span shape threshold, default 4.0),
  `default_top` (fallback building height, default 8.0).
- **`sql/05_correct.sql`**: the corridor half-width (9 m), the passage line extension
  (60 m), and the clearance heights (4.5/5.0/6.0 m) in `clearance_floor`.

Change the value, `make sql && make export`, refresh. To see the effect on the count:

```sql
SELECT class, count(*) FROM skybridge_candidates GROUP BY 1;
```

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

Copy one of `sql/90`–`93` as a template (they each emit one GeoJSON
`FeatureCollection`), add a line to the `export` target in the `Makefile`, and (if the
viewer should read it) load it in `web/index.html`'s `map.on('load')` handler.

---

## 5. Testing your change

There's no formal test suite yet, but there **is** a verification routine — run it
before you commit. The gold-standard check is a clean rebuild from zero:

```bash
make reset && make all
```

This must finish with exit code 0. Then sanity-check invariants in `make psql`:

```sql
-- these should all return 0
SELECT count(*) FROM corrected_spans   WHERE base_h >= top_h;                       -- floats must be below their tops
SELECT count(*) FROM corrected_spans   WHERE ST_IsEmpty(geom_m) OR NOT ST_IsValid(geom_m);
SELECT count(*) FROM building_cuts     WHERE ST_IsEmpty(cut_m)  OR NOT ST_IsValid(cut_m);
SELECT count(*) FROM buildings         WHERE height_render < 0;                     -- no negative heights
```

And confirm the flagship example still works (Washington DC):

```sql
-- the convention center should be detected on its passages...
SELECT count(*) FROM skybridge_candidates WHERE osm_id = 55316481 AND class = 'passage';   -- expect 4
```

Finally, check the exported files parse and the viewer serves:

```bash
python3 -c "import json; [json.load(open(f)) for f in ['web/data/buildings.geojson','web/data/skybridges.geojson','qa/qa_flags.geojson']]; print('valid')"
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

---

## 7. Background & decisions

The detection tags, the rendering-engine choice, and the correction math are all
grounded in a research pass whose conclusions are summarized in
[docs/how-it-works.md](docs/how-it-works.md) and the project plan. If you're changing
a core assumption (e.g. which tags count as a skybridge), skim those first so you know
why it's the way it is.

Questions or unsure if an idea fits? Open an issue describing what you want to change
and why — small, well-described changes are easiest to review.
