# How it works (a guided tour)

This walks through the whole project end to end, in plain language. If a word is
unfamiliar, check the [glossary](glossary.md). By the end you'll understand what
every file does and why.

> **The one-sentence version:** we download OpenStreetMap data for a city, find
> buildings and walkways that are *elevated in real life but drawn solid to the
> ground*, compute how high they should float, and show the before/after in 3D.

---

## 1. The problem, concretely

3D map renderers turn a building's flat outline (its **footprint**) into a 3D block
by **extruding** it upward to its height. To know where the *bottom* of the block
is, they read the `min_height` tag. If that tag is missing, the bottom defaults to
**0 — the ground.**

That's fine for normal buildings (they do start at the ground). But a **skybridge**
or a building that **bridges over a street** starts several metres up. With no
`min_height`, the renderer draws it as a **solid wall from the roof down to the
street**, blocking a road that's actually open underneath.

Our flagship example: the **Walter E. Washington Convention Center** in Washington
DC sits over two streets (L St and M St NW). Those streets are tagged
`tunnel=building_passage` ("the road passes under the building"), but the building's
footprint has no `min_height`, so 3D maps draw a solid block across both streets.

```
   what OSM data draws            what's actually there
   ┌────────────────────┐         ┌────────────────────┐
   │                    │         │████████████████████│  roof
   │   solid building   │   vs.   │                    │  ← open gap (cars pass)
   │█████ L Street █████ │         │▓▓▓▓▓ L Street ▓▓▓▓▓│  ← street, visible
   └────────────────────┘         └────────────────────┘
```

OSM already supports the fix (`min_height` / `building:min_level` make geometry
float). The tags are just usually missing. **Our job: detect these cases and
compute the missing values.**

---

## 2. The big picture

The project is a **pipeline**: a series of steps, each feeding the next. You run it
with `make` commands. Data flows left to right:

```
 download → load into database → DETECT → CORRECT → export files → view in browser
  (.pbf)      (osm2pgsql)        (SQL)     (SQL)     (GeoJSON)      (deck.gl)
```

Two design choices keep it simple:

1. **SQL-first.** Almost all the logic is plain SQL files (`sql/00`…`sql/05`) run in
   order by `make sql`. The database (PostGIS) does the geometry math. There's no
   heavy application code to learn — if you can read SQL, you can read the analysis.
2. **Everything runs in Docker.** You don't install Postgres or mapping tools; Docker
   starts them for you. The only things you need locally are `docker`, `make`,
   `psql`, and `python3` (all standard).

---

## 3. Stage by stage

### Stage 0 — Get the data  (`make download`, `make ingest`)

- **Download.** We fetch a `.osm.pbf` file — a compressed export of OSM for a region
  (Washington DC by default) — from [Geofabrik](https://download.geofabrik.de/).
- **Load.** `osm2pgsql` reads that file into the PostGIS database. A tiny Lua script,
  [`pipeline/flex.lua`](../pipeline/flex.lua), tells it what to keep: building-ish
  **areas** go into a table called `osm_polygons`, and road/rail/water **lines** go
  into `osm_lines`. Everything else is dropped, which keeps the database small.

### Stage 1 — Prepare  (`sql/01_prepare.sql`)

This turns the raw import into clean, analysis-ready tables:

- **Pick a measuring system.** Lat/long degrees are bad for measuring metres, so we
  convert every shape into the correct **UTM zone** (a flat, metre-based grid). The
  zone is **computed automatically** from where the data is, so you never set it.
  The result lives in a `geom_m` ("metres") column; we keep the original lat/long in
  `geom_4326` for the map.
- **Classify.** From `osm_polygons` we build a `buildings` table; from `osm_lines` we
  build `roads`, `rail`, and `water`. A view called `obstacles` is "things a real
  skybridge would cross over" (drivable roads + rail + water), deliberately excluding
  footpaths.
- **Resolve heights.** For each building we compute a top height: use the `height`
  tag if present, else `building:levels × 3 m`, else leave it unknown (and use an 8 m
  default just for drawing). We also compute the **base** (`min_height`, or
  `building:min_level × 3 m`, or 0).
- **The "missing base" flag.** A building is a *candidate* for the bug only if it has
  **no** float tag (`missing_base = true`). Careful: `building:min_level` defaults to
  0 and mappers omit it when it's 0, so "absent" looks the same as "on the ground" —
  which is exactly why we **also** look at shape, not just tags.
- **Repair.** Invalid OSM polygons (self-crossing outlines) are fixed once here, so
  every later step is safe.

### Stage 2 — Detect (tagged)  (`sql/02_detect_tagged.sql`)

We collect **candidates** into a table `cand_raw`. There are several "tiers," from
most to least certain. Each is just a SQL `INSERT` selecting rows that match a tag
pattern:

| Tier | What it matches | Example |
|---|---|---|
| **bridge_struct** | `building=bridge` or `building:part=bridge` | an explicitly-tagged skyway |
| **passage** | a building footprint that covers a `tunnel=building_passage` way | the convention center over L St |
| **footbridge** | `highway=footway/path/…` + a truthy `bridge` tag | an open pedestrian overpass |

The **passage** tier is the most important in practice (most cities don't use
`building=bridge`). To avoid listing the same thing twice, a building already caught
as `bridge_struct` is **not** re-added as a `passage`.

### Stage 3 — Detect (untagged, by shape)  (`sql/03_detect_geometry.sql`)

Many real spans have **no helpful tag at all**. We find those by geometry. A footprint
is a `geom` candidate only if **all** of these are true:

1. **Long and thin** — its bounding rectangle's aspect ratio is ≥ 4.
2. **Crosses an obstacle** — it genuinely passes over a road/rail/water centerline
   (`ST_Crosses`, which is stricter than just touching).
3. **Connects two buildings** — its ends touch **two different** building footprints.
4. **Missing base** — no float tag.

Requiring all four together is what stops false alarms. For example, Washington DC is
full of long thin **rowhouses** (high aspect ratio) — but they don't cross roads, so
they're correctly ignored.

### Stage 4 — Score & de-duplicate  (`sql/04_score_dedupe.sql`)

This builds the final `skybridge_candidates` table:

- **Confidence.** Each candidate gets `very_high` / `high` / `medium` based on its
  class and evidence (e.g. an enclosed `covered` passage is `very_high`).
- **Action.** `auto_correct` (apply the fix locally), `review` (a human should check),
  or `inventory` (footbridges — they don't cause the wall bug, we just list them).
- **De-duplicate.** One physical skyway can appear *both* as a footway line *and* as a
  building polygon. When a footbridge line lies mostly inside a polygon candidate, we
  drop the line and keep the polygon (it carries the correction).

### Stage 5 — Correct  (`sql/05_correct.sql`)

Now we compute the actual fix and the geometry to draw.

- **How high should it float?** `min_height = clearance_floor` — the legal minimum
  clearance of whatever it crosses: ~4.5 m over a road, ~5 m if covered, ~6 m over
  rail. (Since candidates have no storey info, clearance is the safest floor.)
  The top stays at the building's real height; we enforce `base < top`.
- **The floating geometry** goes into `corrected_spans`. For a passage, the floating
  piece is the part of the building over the street; we **extend** the passage line
  past both faces of the building before slicing, so the opening goes all the way
  through (otherwise a too-short OSM line leaves a half-cut).
- **The "cut"** goes into `building_cuts`: the region to subtract from the host
  footprint so the street shows through under the lifted piece. A safety guard stops a
  cut from ever erasing a whole building.

### Stage 6 — Export  (`sql/90`–`93`, `make export`)

SQL can output JSON, so each export file is one query that builds a **GeoJSON**
`FeatureCollection`:

- `web/data/buildings.geojson` — every building (the raw, "buggy" view).
- `web/data/buildings_corrected.geojson` — buildings with span regions cut out.
- `web/data/skybridges.geojson` — the floating spans (with their `base`/`top` heights).
- `web/data/cuts.geojson` — the removed regions (drawn flat red).
- `web/data/meta.json` — where the viewer's camera should start (per region).
- `qa/qa_flags.geojson` — the **review queue**: one point per candidate, ranked, with
  a link back to OpenStreetMap and the proposed `min_height`. This is the analysis
  product a human acts on.

### Stage 7 — View  (`web/index.html`, `make viewer`)

A single static HTML page. It loads **MapLibre** for the base map and **deck.gl** for
the 3D buildings (both from a CDN — no build step). A dropdown switches three views:

- **Raw OSM** — the bug: solid buildings sitting on the streets.
- **Corrected float** — cut buildings + the spans **lifted** to their float height.
- **Modified footprint** — the cut footprints with the removed area shown in red.

**The lift trick:** deck.gl has no "start at height N" property. Instead we put the
height *into the polygon's Z coordinate* — each corner of the floating piece is given
a Z value equal to its `min_height`, and deck.gl extrudes upward from there. (One
gotcha handled in the viewer: deck.gl's `SolidPolygonLayer` can't draw a MultiPolygon,
so we split each span into single polygons first.)

---

## 4. Why these choices?

- **Why deck.gl and not CesiumJS/Mapbox?** We must change a single building's shape at
  runtime to lift it. CesiumJS's 3D tiles are fixed once built; Mapbox v2+ is paid and
  its flat-base extrusion can't make a sloped/spanning piece. deck.gl is free,
  maintained, and lets us set per-corner heights.
- **Why SQL in PostGIS and not Python?** The work is 90% geometry math (intersections,
  areas, crossings). PostGIS does that in the database with an index, so it's fast and
  there's no extra language/runtime to manage.
- **Why auto-pick the UTM zone?** So switching to a new city is just "change the
  download URL and the camera location" — no GIS knowledge required.

---

## 5. Known limits (be honest about these)

- **Coverage depends on mappers.** Most buildings worldwide lack height tags, so our
  heights are mostly estimated (3 m/floor, 8 m default). The detector can only find
  what's mapped.
- **The aspect-ratio threshold (4:1) is a starting guess**, not tuned against a
  labeled dataset.
- **`geom` and `footbridge` candidates are review-grade**, not auto-applied to OSM.
- **One UTM zone per run.** Fine for a city; for a whole continent you'd switch the
  metric system to Web Mercator (`SRID=3857`). See the README.

---

## 6. Where to go next

- Want to **change or extend** something? → [CONTRIBUTING.md](../CONTRIBUTING.md)
- Want to **push fixes back to OpenStreetMap**? → [osm-contribution-loop.md](osm-contribution-loop.md)
- Want the **file-by-file map** and commands? → [README.md](../README.md)
