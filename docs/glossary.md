# Glossary

New to maps, databases, or 3D on the web? Start here. Every term the rest of the
docs use is defined below in plain language, roughly grouped by topic. You do
**not** need to memorize this — skim it once, then come back when a word trips you up.

---

## OpenStreetMap (the data source)

- **OpenStreetMap (OSM)** — a free, editable map of the world, like "Wikipedia for
  maps." Anyone can add or edit features. We download a copy and analyze it.
- **Node** — a single point with a latitude/longitude (e.g. a bench, a tree, or a
  corner of a building). The most basic OSM element.
- **Way** — an ordered list of nodes. An **open way** is a line (a road, a path). A
  **closed way** (first node = last node) encloses an area (a building footprint).
- **Relation** — a group of nodes/ways with a role, used for complex shapes. A
  **multipolygon** relation describes an area with holes (e.g. a building with a
  courtyard).
- **Tag** — a `key=value` label on an element that says what it is. Examples:
  `building=yes`, `highway=footway`, `height=12`. **Everything in OSM is described
  by tags** — our whole detector is "look for buildings with this combination of
  tags and this shape."
- **Footprint** — the 2D outline of a building as seen from directly above (its
  ground shape). In OSM this is a closed way or multipolygon tagged `building=*`.

## The tags this project cares about

- **`building=*`** — marks a building footprint (`building=yes`, `building=house`, …).
- **`building:part=*`** — a piece of a building used for detailed 3D modeling (one
  building can be many parts of different heights).
- **`height` / `building:levels`** — how tall a building is. `height` is in metres;
  `building:levels` is a floor count (we multiply by ~3 m per floor when there's no
  explicit height). **Most buildings have neither** — only a few percent worldwide —
  so we fall back to a default.
- **`min_height` / `building:min_level`** — the height at which a building/part
  **begins** above the ground. This is the key tag: it makes geometry **float**.
  A skybridge that starts 5 m up and is 3 m thick is `min_height=5, height=8`.
  When these tags are absent, the bottom defaults to **0 (the ground)** — which is
  exactly why skybridges get drawn as solid walls down to the street.
- **`layer`** — a drawing-order hint for overlapping features (which is "on top").
  It is **not** a height. `layer=1` alone does not lift anything off the ground.
- **`tunnel=building_passage`** — marks a road/path that passes **under** a building
  (the building bridges over the street). This is a primary signal we look for: a
  building footprint covering one of these is spanning a street.
- **`man_made=bridge`** — an outline drawn around a whole bridge structure.
- **`bridge=yes`** — marks a way (often a `highway=footway`) as a bridge.

## The problem words

- **Skybridge / skyway / skywalk / breezeway** — an elevated walkway connecting two
  buildings, usually over a street. The thing we are trying to model correctly.
- **Span** — our generic word for "the elevated piece that should float": a
  skybridge, or the part of a building that bridges over a street.
- **Mis-modeled / the "solid-wall bug"** — when a span is drawn as a solid block
  from the roof all the way down to the street, blocking it, because its `min_height`
  is missing (so it defaults to 0).

## Geometry & coordinate systems

- **Polygon** — a closed shape (a building footprint). A **MultiPolygon** is several
  polygons treated as one feature (e.g. a building split into two by a passage).
- **Geometry** — any shape: a point, line, or polygon. We store a 2D shape per OSM
  feature and do math on it (does it cross a road? how long is it?).
- **Latitude / Longitude (EPSG:4326)** — positions on the round Earth, in degrees.
  Great for web maps, **bad for measuring metres** (a degree is a different distance
  near the equator vs. the poles).
- **UTM (EPSG:326xx / 327xx)** — a family of flat, metre-based coordinate systems,
  each covering a vertical slice ("zone") of the Earth. We convert OSM data into the
  right UTM zone so "5 metres" actually means 5 metres. The project **auto-picks** the
  zone from the data, so you never set it by hand.
- **SRID** — a number identifying a coordinate system (4326 = lat/long,
  32618 = UTM zone 18 North, which covers Washington DC).
- **CRS (Coordinate Reference System)** — the general term for "which coordinate
  system." UTM and lat/long are both CRSs.
- **Aspect ratio** — long side ÷ short side of a shape's bounding rectangle. A
  skybridge footprint is long and thin (high aspect ratio); a typical building is not.

## The tools

- **PostgreSQL / Postgres** — a relational database (stores tables, runs SQL).
- **PostGIS** — an extension that teaches Postgres about geometry, adding functions
  like `ST_Intersects` (do two shapes touch?), `ST_Area`, `ST_Difference` (subtract
  one shape from another). Most of our analysis is PostGIS SQL.
- **SQL** — the language for querying/transforming a database. Our detection and
  correction logic is plain SQL files run in order.
- **osm2pgsql** — a tool that loads OSM data into PostGIS. We use its **flex** mode,
  configured by a small Lua script (`pipeline/flex.lua`).
- **osmium** — a command-line tool for slicing and filtering raw OSM files.
- **Docker** — runs software in isolated "containers" so you don't have to install
  Postgres/PostGIS/osmium on your machine. `docker compose` starts our database and
  tools from a config file.
- **Make / Makefile** — a task runner. `make all`, `make sql`, etc. are shortcuts
  defined in the `Makefile`.
- **GeoJSON** — a plain-text (JSON) format for geographic shapes. We export our
  results as GeoJSON files the web viewer reads.

## The 3D web viewer

- **deck.gl** — a JavaScript library that draws large amounts of data on a map using
  the GPU, including **3D extruded shapes**. It's the only free, maintained library
  that lets us change a single building's shape at runtime (needed to lift a span).
- **MapLibre GL JS** — a library that draws the **base map** (streets, labels). We
  layer deck.gl's 3D buildings on top of it.
- **Extrusion** — turning a flat 2D footprint into a 3D block by giving it a height.
  A footprint extruded to 12 m is a 12 m-tall box.
- **`SolidPolygonLayer` / `GeoJsonLayer`** — deck.gl "layers" (types of drawing). We
  use `GeoJsonLayer` for normal buildings and `SolidPolygonLayer` for the floating
  spans (it lets us put the bottom at a chosen height).
- **CDN** — a "content delivery network": a public web address that serves libraries
  (we load deck.gl and MapLibre from one, so there's no install step for the viewer).

## Our pipeline words

- **Pipeline** — the ordered series of steps that turns raw OSM data into the final
  viewer + review queue: download → load → detect → correct → export.
- **Candidate** — a feature our detector thinks might be a mis-modeled span. Each has
  a **class** (what kind) and a **confidence** (how sure we are).
- **Confidence** — `very_high` / `high` / `medium`: how strong the evidence is.
- **Correction** — the computed fix: a `min_height` (the floor it should float at)
  and the floating geometry to draw.
- **Cut / carve** — subtracting a span's footprint from its host building so the
  street opening shows through underneath (the "modified footprint").
- **`cut_expand`** — a tunable (in the `config` table) that grows each cut outward
  toward the building façade before subtracting it, so the opening reaches the wall
  instead of leaving a thin remnant "wall." The "cut knob." Adjust with
  `make tune KEY=cut_expand VAL=…`. See [geometry-quality.md](geometry-quality.md).
- **Config table / knob** — `config(key, value)`: every numeric threshold the pipeline
  uses (cut size, clearances, aspect ratio, simplification, …). Defaults live in
  `sql/01_prepare.sql`; `make config` lists them, `make tune` changes one.
- **Sliver / spike / thin "wall"** — degenerate bits of geometry: a near-zero-area
  triangle, a thin protrusion, or a hairline remnant of a building left after a cut.
  The cleanup layer detects and removes them (see [geometry-quality.md](geometry-quality.md)).
- **Lifted-only** — a building so fully covered by a span that carving it would leave
  only a hairline remnant; instead it is shown purely as the lifted span (the grounded
  footprint is dropped), like a tagged bridge structure.
- **QA queue** — `qa/qa_flags.geojson`: the ranked list of candidates for a human to
  review, with links back to OpenStreetMap.
