# Region config — copy to `region.mk` and edit, then run `make region`.
# (region.mk is git-ignored and auto-included by the Makefile.)
#
# You only need: a Geofabrik/BBBike .osm.pbf URL + a focus lon/lat for the
# viewer camera. The metric CRS (UTM zone) is auto-derived from the data, so
# leave SRID=0 unless you want to force one (or 3857 for a very large area).

# ── Washington DC (default) ────────────────────────────────────────────
REGION      = dc
PBF_URL     = https://download.geofabrik.de/north-america/us/district-of-columbia-latest.osm.pbf
CLON        = -77.0230
CLAT        = 38.9051
CRADIUS     = 2600
FOCUS_LABEL = convention center

# ── Other examples (uncomment one block; comment out DC above) ──────────
# Minneapolis, MN — the iconic enclosed Skyway network
# REGION      = minnesota
# PBF_URL     = https://download.geofabrik.de/north-america/us/minnesota-latest.osm.pbf
# CLON        = -93.2691
# CLAT        = 44.9773
# CRADIUS     = 2500
# FOCUS_LABEL = Minneapolis Skyway

# Calgary, AB — the +15 elevated walkway system
# REGION      = alberta
# PBF_URL     = https://download.geofabrik.de/north-america/canada/alberta-latest.osm.pbf
# CLON        = -114.0631
# CLAT        = 51.0461
# CRADIUS     = 2500
# FOCUS_LABEL = Calgary +15

# Pittsburgh, PA
# REGION      = pennsylvania
# PBF_URL     = https://download.geofabrik.de/north-america/us/pennsylvania-latest.osm.pbf
# CLON        = -79.9959
# CLAT        = 40.4406
# CRADIUS     = 2500
# FOCUS_LABEL = downtown Pittsburgh

# Any custom bbox: grab a .osm.pbf from https://extract.bbbike.org and point
# PBF_URL at it (or a local file path via a file:// URL won't work with curl —
# instead drop it at data/<REGION>.osm.pbf and skip `make download`).

# SRID = 0          # 0 = auto UTM; set e.g. 3857 for a continent-scale extent
# SANDBOX_RADIUS = 800   # `make tuner` sandbox subset radius (m) around the focus
