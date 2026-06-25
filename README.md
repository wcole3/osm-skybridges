# OSM Skybridge Detector & 3D Float-Corrector

Find places where OpenStreetMap's 3D building data **draws skybridges, skyways, and
covered passages as solid walls down to the street** — then compute the fix and show
the before/after in 3D.

New to maps/databases/3D? You're in the right place — this project is documented for
newcomers. Skim the [**glossary**](docs/glossary.md) for any unfamiliar word, and
read [**how it works**](docs/how-it-works.md) for the full guided tour.

---

## The problem (in one picture)

A 3D map turns a building's flat outline into a 3D block by stretching it up to its
height. The *bottom* of the block comes from the `min_height` tag — and when that tag
is missing, the bottom defaults to **the ground**. So an elevated walkway, or a
building that bridges over a street, gets drawn as a **solid wall blocking the road**
that's really open underneath.

```
   what OSM data draws            what's actually there
   ┌────────────────────┐         ┌────────────────────┐
   │   solid building   │   vs.   │████████████████████│  ← roof
   │█████ L Street █████ │         │▓▓▓▓▓ L Street ▓▓▓▓▓│  ← street, open underneath
   └────────────────────┘         └────────────────────┘
```

OpenStreetMap already supports the fix (`min_height` makes geometry float); the value
is just usually missing. **This project detects those cases and computes it.** Our
flagship example is the **Walter E. Washington Convention Center** in Washington DC,
which spans two streets that pass under it.

---

## Quickstart

You need **Docker**, **make**, **psql**, and **python3** — all standard. You do *not*
install a database or any GIS tools; Docker provides them.

```bash
make all       # start the database, load Washington DC, analyze, export  (~2 min)
make viewer    # serve the 3D viewer at http://localhost:8000
```

Open <http://localhost:8000>, click **“fly to convention center”** (the button is
labeled per region), and use the **view** dropdown to switch between:

- **Raw OSM** — the bug: solid buildings sitting on the streets.
- **Corrected float** — streets opened up, with the spans **lifted** to where they
  belong (blue), footways in orange.
- **Modified footprint** — the corrected building outlines, with the **removed**
  area shown in red.

That's the whole loop. To run pieces individually: `make up`, `make sql`,
`make export`, `make psql`, `make reset`.

---

## How it works (short version)

It's a **pipeline** of small steps, mostly plain SQL run by `make`. Data flows left
to right:

```
 download → load into PostGIS → DETECT → CORRECT → export GeoJSON → view in browser
  (.pbf)      (osm2pgsql/flex)   (SQL)     (SQL)      (web/data)     (deck.gl)
```

- **Detect** finds candidates two ways: by **tags** (e.g. a building that covers a
  `tunnel=building_passage`) and by **shape** (a long thin footprint that crosses a
  road and connects two buildings).
- **Correct** computes how high each span should float (its road/rail clearance),
  builds the floating geometry, and "carves" the opening out of the host building.
- The 3D viewer is one static HTML page using **deck.gl** over **MapLibre** — no
  build step; libraries load from a CDN.

Full details, with the data model and every file explained:
[**docs/how-it-works.md**](docs/how-it-works.md).

---

## Process another region

Switching cities is the easiest change in the project — the metric coordinate system
is **auto-detected from the data**, so you only supply a download URL and a camera
point:

```bash
make region REGION=minnesota \
  PBF_URL=https://download.geofabrik.de/north-america/us/minnesota-latest.osm.pbf \
  CLON=-93.2691 CLAT=44.9773 FOCUS_LABEL="Minneapolis Skyway"
make viewer
```

Or make it permanent: `cp region.example.mk region.mk`, edit it (it ships with DC +
Minneapolis/Calgary/Pittsburgh presets), then `make region`. Get extracts from
[Geofabrik](https://download.geofabrik.de/) (states/countries) or
[BBBike](https://extract.bbbike.org/) (any bounding box). Each `make region` replaces
the loaded data (one region at a time).

---

## What's in the box

```
Makefile              all commands; region config at the top
docker-compose.yml    the database + tools containers
pipeline/flex.lua     which OSM features to load
sql/00..05            the analysis: prepare → detect → correct  (run in order)
sql/90..93            turn results into GeoJSON for the viewer
sql/91                the QA review queue
web/index.html        the 3D viewer (one static file)
docs/                 glossary, how-it-works, OSM contribution guide
```

A file-by-file map and "I want to change X" recipes are in
[**CONTRIBUTING.md**](CONTRIBUTING.md).

---

## Outputs

- **3D viewer** — `web/index.html` + `web/data/*.geojson`, with the three view modes
  above, plus hover-for-details and a "highlight buildings missing a base" toggle.
- **QA review queue** — `qa/qa_flags.geojson`: one point per candidate, ranked
  `very_high → high → medium`, each with a link back to OpenStreetMap and the proposed
  `min_height` / `building:min_level`. Open it in
  [geojson.io](https://geojson.io), JOSM, or QGIS. Pushing fixes upstream is covered
  in [docs/osm-contribution-loop.md](docs/osm-contribution-loop.md).

---

## Configuration

| What | Where | Default |
|---|---|---|
| Region (extract + camera) | `region.mk` / CLI vars (`REGION`, `PBF_URL`, `CLON`, `CLAT`, `CRADIUS`, `FOCUS_LABEL`) | Washington DC |
| Metric CRS | `SRID` (Makefile); `0` = auto-derive the UTM zone | auto |
| Viewer export radius | `CRADIUS` (metres); raise for a wider area | 2600 m |
| Storey height, aspect threshold, default height | `config` table in `sql/01_prepare.sql` | 3.0 m, 4.0, 8.0 m |
| Corridor half-width, passage extension, clearances | `sql/05_correct.sql` | 9 m, 60 m, 4.5/5.0/6.0 m |

### Scaling to region / planet

For areas larger than a city: pre-filter with `osmium tags-filter` before
`osm2pgsql`, set `SRID=3857` if the extent spans multiple UTM zones, and switch the
viewer from whole-file GeoJSON to vector tiles (`tippecanoe → PMTiles` on a CDN) +
deck.gl `MVTLayer`.

---

## Limitations (worth knowing)

- **Coverage is bounded by tagging.** Most buildings worldwide lack `height` /
  `building:levels`, so heights are mostly estimated. The detector only finds what's
  mapped.
- **The 4:1 aspect threshold is an untuned starting point** — calibrate it on a
  labeled sample for your area.
- **`geom` / `footbridge` candidates are review-grade**, not auto-applied to OSM.

---

## Documentation index

| Doc | For |
|---|---|
| [docs/glossary.md](docs/glossary.md) | every term, in plain language |
| [docs/how-it-works.md](docs/how-it-works.md) | the full guided tour of the pipeline |
| [CONTRIBUTING.md](CONTRIBUTING.md) | setup, dev loop, "I want to change X" recipes |
| [docs/osm-contribution-loop.md](docs/osm-contribution-loop.md) | pushing verified fixes back to OSM |
