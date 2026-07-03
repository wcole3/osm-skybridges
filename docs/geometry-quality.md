# Geometry quality & tuning

The correction stage ([`sql/05_correct.sql`](../sql/05_correct.sql)) produces two
geometries per detected span:

- **`corrected_spans`** — the floating piece the viewer lifts (the blue skybridge).
- **`building_cuts`** — the region subtracted from the host footprint so the street
  shows through underneath (the red "removed from footprint").

OSM footprints are messy (over-noded walls, near-collinear vertices, buildings that
overlap their neighbours), and a buffered passage corridor rarely lines up perfectly
with a wall. Left raw, that produces **sharp spikes, thin slivers, rounded arcs,
hairline "walls" along openings, and tessellation "fans"** in the 3D view. This stage
cleans all of that up, and exposes the behaviour as **tunable knobs in the `config`
table** so a modeler can dial it without editing SQL logic.

> TL;DR — to cut **more** (or less) of a building out from under a span:
> ```bash
> make tuner                            # drag the cut_expand slider, watch it live
> make tune KEY=cut_expand VAL=0.8      # or one-shot: default 0.6 m; higher = cut more
> ```

---

## 0. Fixed-precision geometry — why slivers stopped appearing

Since the precision rework, **every metric overlay runs on a fixed-precision
grid** (`grid_size`, default **0.01 m**): `ST_Intersection` / `ST_Union` /
`ST_Difference` get a `gridSize` argument (GEOS OverlayNG snap-rounding) and
`clean_span` passes everything through `ST_ReducePrecision` +
`ST_MakeValid(…, 'method=structure')`. Near-coincident edges — a wall-snapped
corridor against the wall it snapped to — now round to the **same** coordinates
and cancel exactly, instead of leaving the sub-centimetre hairline slivers the
part-filters used to chase. The despike/prune/revert machinery below is kept as
a **backstop** for *real* thin geometry (a genuinely narrow span is thin, not
noise).

Grid choice: 0.01 m is 10× below `clean_span`'s 0.1 m vertex dedupe and 50× below
`snap_tol`, so it never fights the wall-following; it is ~7 orders of magnitude
above float64 noise; and it is invisible at export (the viewer rounds to ~8.7 cm).
`99_selfcheck` **fails the build** if any cut/span part smaller than
`(2·grid_size)²` survives — under fixed precision such overlay crumbs must not
exist. Requires GEOS ≥ 3.10: the compose image is `postgis/postgis:16-3.5-alpine`
(ships GEOS 3.14); the Debian `postgis/postgis:16-3.5` image ships GEOS 3.9, which
is why the alpine variant is pinned.

---

## 1. Tuning knobs the easy way

All tunables live in one place: the **`config` table**, populated from the labelled
block near the top of [`sql/01_prepare.sql`](../sql/01_prepare.sql) (slider ranges +
the pipeline **stage** each knob re-runs live next to it in `config_meta`).

```bash
make tuner                           # live: sliders + 3D result in seconds (see below)
make config                          # list every knob and its current value
make tune KEY=cut_expand VAL=0.8     # change one knob, persist it, re-derive + re-export
make config-export                   # snapshot all settings -> exports/config.json (shareable)
make config-load FILE=their.json     # ingest someone's settings + re-derive with them
```

**Sharing settings:** `make export` also drops the snapshot at `web/data/config.json`,
which the plain viewer shows as a read-only "processing settings" panel — so anyone
looking at the result can see exactly which knob values produced it. To reproduce a
colleague's output: they run `make config-export` and send you the file; you run
`make config-load FILE=…` — the values are validated, persisted into
`sql/01_prepare.sql` (same rewrite as `make tune`, visible in `git diff`), and the
pipeline re-derives with them.

### The live tuner (`make tuner` / `make tuner-sample`)

`make tuner` serves the viewer with a **tuning panel** (sliders for every knob,
grouped by re-run cost). It is **sandbox-first**: on startup it copies the raw
OSM data within `SANDBOX_RADIUS` (default 800 m) of the focus point into a
separate scratch **database** (`osm_sandbox`), runs the ordinary pipeline files
against it, and exports to `web/data/sandbox/`. **`make tuner-sample`** seeds the
sandbox with tiny built-in synthetic fixtures instead
([`sql/96_sample_data.sql`](../sql/96_sample_data.sql) — one labelled case per
pathology: remnant wall, grazing neighbour, ribbon cut, island leak, near-full
carve, …) so it needs **no downloaded region at all** and every knob has a case
that visibly reacts. Dragging a slider re-runs ONLY
the affected pipeline suffix on the sandbox (~2–5 s) and refreshes the 3D view —
the live database, `web/data/*.geojson` and `sql/01_prepare.sql` are untouched.
Rapid slider changes coalesce (latest value wins; never two runs at once), and a
selfcheck failure shows as a red banner while the viewer keeps the last good
data. Then, explicitly:

- **apply to real dataset** — push the tuned values to the live `config`,
  re-derive the live database (stage-scoped) and rewrite `web/data/`.
- **save as defaults** — persist the values into `sql/01_prepare.sql`
  (byte-identical to what `make tune` writes, so it shows in `git diff`).
- **revert** — back to the file defaults; **reseed** — rebuild the sandbox.

`make tune`:
1. rewrites that knob's default in `sql/01_prepare.sql` (so the change **persists**
   across rebuilds and shows up in `git diff`),
2. re-runs the analysis SQL and the GeoJSON export,
3. then you **hard-refresh** the viewer (Ctrl+Shift+R).

It works for *any* key in the config block, requires the DB to be loaded already
(`make all` once), and aborts on an unknown key. Equivalent by hand:

```bash
# edit the value in sql/01_prepare.sql, then:
make sql && make export
```

---

## 2. The cut knob — `cut_expand`

**Problem it solves.** A span's footprint, snapped to the host walls, sometimes stops
a few centimetres short of a façade, leaving a **thin remnant "wall"** — a sliver of
the original building standing under/beside the lifted span.

**What it does.** Before the cut is finalized it is **dilated outward by `cut_expand`
metres** (mitre buffer, square corners) and **clipped back to the host footprint**, so
it reaches all the way to the façade and removes the wall — without spilling past the
building into the street.

```
cut_expand = 0                 cut_expand = 0.6 (default)
┌───────────────┐              ┌───────────────┐
│   host wall   │              │               │
│┌─────────────┐│  thin wall   ┌───────────────┐   wall gone: cut
││    cut      ││← left here   │    cut        │←  reaches the wall
│└─────────────┘│              └───────────────┘
└───────────────┘              └───────────────┘
```

**Default `0.6` m** — measured to close every remnant wall in the DC dataset.

**Tuning it.**
- **Raise it** to cut more (remove thicker walls). 
- **Lower it / set `0`** to cut less (disable the expand entirely).
- It is **guarded against over-cut**: if expanding a host would make the cut cover
  ≥ 90 % of the footprint (i.e. carve it to almost nothing), that host keeps its
  *unexpanded* cut instead — so a too-high value can't empty a building or paint a
  whole footprint red. Very high values simply stop helping those borderline hosts.
- It may only **grow** the cut: dilating then clipping to the host can leak through
  a thin interior wall into a *disconnected* pocket and spawn a stray crumb there,
  so any expanded part that doesn't touch the unexpanded cut is dropped (if all
  parts drop, the unexpanded cut is kept).

```bash
make tune KEY=cut_expand VAL=1.0    # cut more aggressively
make tune KEY=cut_expand VAL=0      # turn the expand off
```

**Related knob — `max_carve_frac` (default `0.95`).** Some small building:parts are
~100 % covered by a span — the building essentially *is* the passage. Carving them
only ever leaves a hairline remnant, so when a span covers ≥ `max_carve_frac` of a
building it is rendered **lifted-only** (the grounded remnant is dropped, exactly like
a tagged bridge structure). Lower it to send more near-full buildings to lifted-only;
raise it toward `1.0` to keep carving them.

---

## 3. Every knob

Defaults in [`sql/01_prepare.sql`](../sql/01_prepare.sql); change with `make tuner`
(live) or `make tune` (one-shot). All distances are **metres** in the metric (UTM)
CRS. Each knob's slider range and its **stage** — the pipeline suffix that re-runs
when it changes (`prepare` 01→ / `detect` 02→ / `correct` 05→ / `finalize` 06→ /
`export`) — live in the `config_meta` table and are shown in the tuner panel; the
tables below are grouped accordingly (all "corridor"/"severe"/"cut" knobs are stage
`correct`; `simplify_tol` + `max_carve_frac` are `finalize`; `building_simplify_tol`
is `export`; `grid_size` is `prepare`).

### Corridor construction (the passage span) — used in `05_correct.sql`
| key | default | what it does |
|---|---|---|
| `corridor_halfwidth` | 9.0 | half-width of the street-corridor slab a passage line is buffered into |
| `corridor_reach` | 20.0 | how far the passage line is extended past each end so the corridor crosses the host wall-to-wall |
| `corridor_reach_cap` | 60.0 | hard cap on that extension (degenerate-line guard) |
| `footbridge_halfwidth` | 2.0 | half-width of a footbridge deck |
| `snap_tol` | 0.5 | snap distance pulling the corridor / cut onto the real wall (wall-following) |

### Severe-geometry detection & auto-clean (passage spans)
| key | default | what it does |
|---|---|---|
| `open_k` | 0.5 | morphological-opening radius for spans (melts protrusions < 2·k wide) |
| `open_k_cut` | 0.5 | opening radius for cuts (smooths connected thin tongues) |
| `open_area_keep` | 0.7 | skip an opening if it would remove > 30 % of the area |
| `min_part_area` | 1.0 | drop disjoint parts smaller than this (m²) |
| `min_inradius` | 1.0 | per-part keep floor — true min half-width |
| `min_compactness` | 0.25 | Polsby-Popper keep floor (OR'd with `min_inradius`) |
| `severe_inradius` | 0.5 | below this a span is "still severe" → revert + route to review |
| `hard_min_inradius` | 0.35 | absolute thin-floor in `despike_parts`/`prune_parts`: drop ANY part below this inscribed radius regardless of compactness (kills slivers kept on compactness alone) |
| `clean_area_loss_max` | 0.30 | revert + review if cleanup loses more than this fraction |
| `hull_frac` | 0.85 | `ST_SimplifyPolygonHull` vertex fraction (**reserved** — staged for span polish, not wired yet) |

### Precision (§0)
| key | default | what it does |
|---|---|---|
| `grid_size` | 0.01 | (m) fixed-precision grid for every metric overlay + `clean_span`; overlay slivers cancel at the source. 0 disables (not recommended) |

### Cut shaping
| key | default | what it does |
|---|---|---|
| `min_cut_inradius` | 1.5 | a span must overlap a building by a part this wide to cut it (drops grazing-neighbour slivers) |
| `max_cut_aspect` | 10.0 | drop cut parts longer-than-this : 1 (suppresses long thin passage-ribbon cuts; the span still lifts) |
| **`cut_expand`** | **0.6** | **dilate each cut toward the façade to slice thin remnant walls (see §2)** |
| `max_carve_frac` | 0.95 | building ≥ this fraction cut → render lifted-only, not a hairline remnant (see §2) |

### Simplification / rendering
| key | default | what it does |
|---|---|---|
| `vw_area_tol` | 0.5 | Visvalingam-Whyatt **area** (m²) floor applied in the cut build and the carve: collapses thin spikes Douglas-Peucker *preserves* (the QEM edge-collapse analog; `simplify_vw`) |
| `simplify_tol` | 0.1 | drop near-collinear vertices from carved hosts (anti-fan, internal) |
| `building_simplify_tol` | 0.5 | Douglas-Peucker tolerance for **all** exported buildings: strips dense near-collinear / narrow-triangle vertices (OSM over-noding) so extruded tops don't tessellate into sliver-fans |

### Detection / heights (pre-existing)
| key | default | what it does |
|---|---|---|
| `level_height` | 3.0 | metres per `building:levels` floor |
| `aspect_min` | 4.0 | min oriented-bbox aspect ratio for untagged (`geom`) span detection |
| `default_top` | 8.0 | fallback render height for buildings with no height tag |

---

## 4. The cleanup pipeline (how it works)

Shared helper functions live in [`sql/00_init.sql`](../sql/00_init.sql) so every stage
and export can reuse them:

- **`clean_span(g)`** — the canonical "always-valid, polygon-only MultiPolygon" tail:
  `ST_MakeValid` → keep polygons → drop duplicate vertices → repair → `ST_Multi`.
  Every produced geometry goes through it, so nothing downstream is ever invalid or
  non-polygonal (which would break the viewer's `SolidPolygonLayer`).
- **`simplify_vw(g, area_tol)`** — Visvalingam-Whyatt (area-based) simplification,
  re-validated through `clean_span`. Unlike Douglas-Peucker (which *preserves* sharp
  narrow spikes), VW *collapses* them — the QEM edge-collapse analog. Run in the cut
  build and the carve **before** the part-level filters, so they judge clean parts.
- **`drop_tiny_parts` / `despike_parts`** — drop disjoint parts that are too small or
  too thin (inscribed-circle radius / compactness, and an absolute `hard_min_inradius`
  floor); keep-largest fallback so a span never empties.
- **`prune_parts`** — like the above (incl. the `hard_min_inradius` floor) but with
  **no** keep-largest fallback (used for cuts, where an all-sliver cut should carve
  nothing).
- **`drop_ribbons`** — drop disjoint parts shaped like a long thin ribbon
  (`mbr_aspect` > `max_cut_aspect`) — a very long passage's cut is a real but slivery
  opening; the passage still shows as a lifted span.
- **`morph_open(g, k)`** — morphological opening (erode by k, dilate by k, mitre caps)
  to melt thin connected tongues while keeping right angles square.
- **`qa_min_halfwidth` / `qa_max_halfwidth` / `qa_compactness` / `qa_min_part_area`**
  and **`mbr_aspect`** — the shape-quality metrics the cleanup and the QA queue use.

**Span build** ([`05_correct.sql`](../sql/05_correct.sql)): the passage corridor is
buffered with a **capped mitre** join (no runaway spikes), extended by a **bounded
reach** (no giant overshoot wedge), **snapped to the host walls** (wall-following),
and `clean_span`'d. Each passage span is then surgically cleaned; if a span is still
pathologically thin after cleanup it is **reverted to the constructed geometry and
downgraded `auto_correct` → `review`** so a human inspects it rather than shipping a
mangled shape. `bridge_struct`/`geom` spans are only made valid (never eroded — they
are whole real structures); footbridge decks use flat/mitre caps (no rounded arcs).

**Cut build** ([`05_correct.sql`](../sql/05_correct.sql)): per host, the union of
overlapping span∩building clips is passed through an **overlap-substance gate**
(`min_cut_inradius` — drops thin grazes of neighbour buildings), then `simplify_vw`
(collapse thin spikes), `prune_parts`, `drop_ribbons`, `morph_open`, and finally the
**`cut_expand`** dilation (§2). The expansion may only **grow** the cut: dilating
then clipping to the host can leak through a thin wall into a disconnected pocket
and spawn a crumb island, so expanded parts that don't touch the unexpanded cut
are dropped (all-dropped → the unexpanded cut is kept).

**Carve** ([`06_finalize.sql`](../sql/06_finalize.sql)): building − cut
(fixed-precision `ST_Difference`), with the cut snapped to that host's walls, made
valid, thin spikes collapsed (`simplify_vw`), leftover slivers dropped,
near-collinear vertices simplified, and near-fully-cut hosts sent to lifted-only
(`max_carve_frac`). The result is materialized ONCE in `carved_hosts` and exposed
as **`buildings_final`** / **`spans_final`** — the viewer export
([`92`](../sql/92_export_corrected_buildings.sql)) and the full-fidelity exports
([`94_export_final_*.sql`](../sql/94_export_final_buildings.sql), `make
export-final` / `make gpkg`) all read the same carve.

---

## 5. The viewer "fan" (a rendering note)

If a hovered building showed a **fan of thin grey/yellow triangles**, that was the
deck.gl hover-highlight: a *semi-transparent* highlight over an extruded polygon
double-draws at every tessellation triangle edge, revealing them as a fan. Two fixes,
both already in place:

- the hover highlight in [`web/index.html`](../web/index.html) is now **opaque**
  (it overwrites instead of accumulating), and
- `building_simplify_tol` strips the dense near-collinear vertices that produced all
  those triangles in the first place.

It was a rendering artifact, **not** a geometry sliver — the underlying footprint was
valid. Viewer-only changes need just a browser refresh.

---

## 6. Verifying after a tune

`make sql` runs [`sql/99_selfcheck.sql`](../sql/99_selfcheck.sql), which **fails the
build** on the true invariants (base ≥ top, empty/invalid/non-polygonal spans,
empty/invalid cuts, empty/invalid `carved_hosts`, any overlay-crumb part smaller
than `(2·grid_size)²` — see §0, and the flagship Convention Center
`osm_id=55316481` passage count = 4) and prints warn-only counts for still-thin
geometry. After tuning, eyeball the
result in the viewer too — some things (a wall, a sliver) only show up visually. See
[CONTRIBUTING.md](../CONTRIBUTING.md) §5 for the full invariant checklist.
