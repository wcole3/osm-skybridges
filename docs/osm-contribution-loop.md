# Contributing corrections back to OpenStreetMap

This pipeline corrects the **local 3D model** and produces a review queue
(`qa/qa_flags.geojson`). Pushing those corrections *upstream* to OSM is an
**optional, review-gated** step. This document explains how to set it up safely.
It is intentionally **not automated** — read the policy section before editing.

> The detector finds two structurally different defects. The upstream fix
> differs for each, so treat them separately.

---

## 1. Decide: local-only or upstream?

| Situation | Action |
|---|---|
| The OSM object **genuinely is** an elevated span / a building genuinely bridges a street | Adding `min_height` / `building:min_level` is an **accurate physical attribute** — a legitimate edit that helps every data consumer. |
| You only want **your** render to look right | Do **not** edit OSM. Apply the local correction (this pipeline already does) and stop. |

Adding a true physical height is *not* "tagging for the renderer" — that rule
forbids *misleading* tags, not accurate ones
([wiki](https://wiki.openstreetmap.org/wiki/Tagging_for_the_renderer)). But every
edit must be **verified against imagery first** (see §4).

---

## 2. What to tag, per defect class

### Class `bridge_struct` / `geom` — an elevated span modelled solid to the ground
The span polygon (e.g. a `building:part`) needs a float base:

```
building:min_level = floor(proposed_min_height / 3)     # storeys, preferred (matches the QA export)
building:levels    = building:min_level + thickness_in_levels
# OR, when you have a real measurement:
min_height = <proposed_min_height m>
height     = <proposed_height m>
```

Prefer **storey** tags (`building:min_level`/`building:levels`) when the
connected floors are known — they are robust to per-country storey heights.
`building:levels` must be **strictly greater** than `building:min_level` and
must *include* the skipped levels.

### Class `passage` — a building footprint spanning a street (the WEWCC case)
Here the building correctly touches the ground on its supports; what is wrong is
that the **opening over the road is not modelled**. Two accepted fixes:

1. **Split the footprint** so the portion over the street is a separate
   `building:part` with a float base (`building:min_level` = clearance storeys),
   leaving the supports at ground. This is the most accurate.
2. Where a passage way already exists (`tunnel=building_passage`), ensure it is
   present and correctly `layer`-ed; some renderers already cut the building
   around it.

Do **not** simply add `min_height` to the *whole* convention-center outline —
that would float the entire building. The correction is **local to the span**.

---

## 3. The QA queue is the hand-off

`qa/qa_flags.geojson` is one `Point` per candidate, ordered very_high → high →
medium, each carrying:

- `osm_url` — direct link to the object on openstreetmap.org
- `class`, `confidence`, `action`, `reason` (the evidence that fired)
- `proposed_min_height`, `proposed_height`, `proposed_building_min_level`

Load it in [geojson.io](https://geojson.io), [JOSM](https://josm.openstreetmap.de/)
(remote control), or QGIS to walk the queue. Only the
`action = auto_correct` + `confidence in (very_high, high)` band is edit-ready;
`review` and `inventory` need a human decision.

---

## 4. Recommended review-gated workflow (not a mass edit)

1. **Filter** to `confidence = very_high` and a small area you can verify.
2. **Verify each** against aerial + street-level imagery (Bing/Esri/Mapillary):
   is it really elevated? what storey does it connect? what is the clearance?
3. **Edit one at a time** in JOSM or [Level0](http://level0.osmz.ru/), preferring
   storey tags, and **share nodes** with the two connected buildings at the
   abutments so the geometry stays topologically joined.
4. Use a clear **changeset comment** ("add building:min_level to elevated
   skyway, verified against imagery") and a `source`.
5. **Never bulk-upload.** Adding `min_height` across many objects programmatically
   is a *mechanical edit* and requires a community-reviewed proposal under the
   [Automated Edits code of conduct](https://wiki.openstreetmap.org/wiki/Automated_Edits_code_of_conduct)
   and [Import guidelines](https://wiki.openstreetmap.org/wiki/Import/Guidelines).

### A safe upstream tag set for an enclosed skyway connecting 3rd floors
```
building=bridge            # or keep building:part=yes if inside a host outline
layer=1
building:min_level=2       # skips ground+2nd -> deck begins at the 3rd floor
building:levels=3          # includes the skipped levels; strictly > min_level
# shares nodes with both connected buildings at the abutments
```

---

## 5. Optional: scripting the export (still human-gated)

If you want to stage edits, export the verified subset to an editor — do **not**
write to the OSM API directly from this pipeline:

```bash
# verified, edit-ready subset -> JOSM-openable GeoJSON
psql "$PGURI" -At -f - <<'SQL' > qa/edit_ready.geojson
SELECT json_build_object('type','FeatureCollection','features',COALESCE(json_agg(f),'[]'))
FROM (
  SELECT json_build_object('type','Feature',
    'geometry', json_build_object('type','Point','coordinates',json_build_array(lon,lat)),
    'properties', json_build_object('osm', osm_type||osm_id,
       'building:min_level', floor(s.base_h/3.0)::int,
       'min_height', round(s.base_h::numeric,1))
  ) f
  FROM skybridge_candidates c JOIN corrected_spans s USING (cand_id)
  WHERE c.confidence='very_high' AND c.action='auto_correct'
) sub;
SQL
```

Open it in JOSM, manually apply tags to the **real** objects (not the points),
verify, and upload individually. The points are a worklist, not the edit.
