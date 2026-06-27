# OSM Skybridge pipeline — Docker + SQL-first.
#
#   make up        bring up PostGIS (localhost:5439), wait for healthy
#   make build     build the osmium/osm2pgsql tools image
#   make download  fetch the region extract
#   make ingest    osm2pgsql flex load -> osm_polygons / osm_lines
#   make sql       run the prepare + detect + correct SQL in order
#   make export    write web/data/*.geojson and qa/qa_flags.geojson
#   make viewer    serve the static deck.gl viewer on :8000
#   make region    download + ingest + sql + export for the current region
#   make all       up + build + region
#   make reset     tear down DB volume (start clean)

# ─── REGION CONFIG ─────────────────────────────────────────────────────
# Switch regions by either (a) overriding on the CLI:
#     make region REGION=mpls \
#       PBF_URL=https://download.geofabrik.de/north-america/us/minnesota-latest.osm.pbf \
#       CLON=-93.2677 CLAT=44.9778
# or (b) copying region.example.mk -> region.mk and editing it (auto-included).
#
# NOTE: keep these as bare values with NO trailing inline comments — Make would
# fold the trailing spaces into the value and corrupt filenames/paths.
-include region.mk

REGION      ?= dc
PBF_URL     ?= https://download.geofabrik.de/north-america/us/district-of-columbia-latest.osm.pbf
SRID        ?= 0
CLON        ?= -77.0230
CLAT        ?= 38.9051
CRADIUS     ?= 2600
FOCUS_LABEL ?= convention center
# REGION       : slug used for the extract filename (data/<REGION>.osm.pbf)
# PBF_URL      : any Geofabrik / BBBike .osm.pbf URL
# SRID         : metric CRS; 0 = auto-derive the UTM zone from the data
# CLON/CLAT    : viewer focus point (longitude, latitude)
# CRADIUS      : viewer export radius in metres (raise for a wider area)
# FOCUS_LABEL  : label on the viewer's "fly to" button + title
# ───────────────────────────────────────────────────────────────────────

COMPOSE := docker compose
PGURI   ?= postgresql://osm:osm@localhost:5439/osm
# $(strip ...) guards against any stray whitespace sneaking into a value
PSQL    := psql "$(PGURI)" -v ON_ERROR_STOP=1 -v srid=$(strip $(SRID))
PBF     := data/$(strip $(REGION)).osm.pbf
EXPORT_VARS := -v clon=$(strip $(CLON)) -v clat=$(strip $(CLAT)) -v radius=$(strip $(CRADIUS))

# the pipeline stages are order-dependent (data flows db -> sql -> export), so
# never run them in parallel even under `make -j`.
.NOTPARALLEL:
.PHONY: up build download ingest sql export viewer region all reset psql tune config

up:
	# --wait blocks until the healthcheck passes (or fails), bounded by the
	# compose healthcheck retries — no hand-rolled, unbounded poll loop.
	$(COMPOSE) up -d --wait db
	@echo "db healthy on localhost:5439"

build:
	$(COMPOSE) build tools

$(PBF):
	mkdir -p data
	curl -L --fail --retry 3 -o $(PBF) "$(PBF_URL)"

download: $(PBF)

ingest: $(PBF)
	$(COMPOSE) run --rm tools \
	  osm2pgsql --output=flex --style=/work/pipeline/flex.lua \
	            -d osm -H db -U osm -P 5432 /work/$(PBF)

sql:
	$(PSQL) -f sql/00_init.sql
	$(PSQL) -f sql/01_prepare.sql
	$(PSQL) -f sql/02_detect_tagged.sql
	$(PSQL) -f sql/03_detect_geometry.sql
	$(PSQL) -f sql/04_score_dedupe.sql
	$(PSQL) -f sql/05_correct.sql
	$(PSQL) -f sql/99_selfcheck.sql

export:
	mkdir -p web/data qa
	$(PSQL) $(EXPORT_VARS) -At -f sql/90_export_buildings.sql           > web/data/buildings.geojson
	$(PSQL) $(EXPORT_VARS) -At -f sql/92_export_corrected_buildings.sql > web/data/buildings_corrected.geojson
	$(PSQL) $(EXPORT_VARS) -At -f sql/90_export_skybridges.sql          > web/data/skybridges.geojson
	$(PSQL) $(EXPORT_VARS) -At -f sql/93_export_cuts.sql                > web/data/cuts.geojson
	$(PSQL) -At -f sql/91_export_qa.sql                                 > qa/qa_flags.geojson
	@printf '{"center":[%s,%s],"zoom":15.3,"pitch":55,"bearing":-20,"label":"%s"}\n' \
	  "$(strip $(CLON))" "$(strip $(CLAT))" "$(strip $(FOCUS_LABEL))" > web/data/meta.json
	@echo "exported web/data/{buildings,buildings_corrected,skybridges,cuts}.geojson + meta.json + qa/qa_flags.geojson"

viewer:
	@echo "serving viewer at http://localhost:8000/  (Ctrl-C to stop)"
	cd web && python3 -m http.server 8000

# process the configured region end-to-end (assumes db is up + tools built)
region: download ingest sql export

all: up build region

psql:
	psql "$(PGURI)"

# show the current tunables (the config table). Run `make all` once first.
config:
	@$(PSQL) -c "SELECT key, value FROM config ORDER BY key"

# Tune one config knob and re-derive everything. Defaults live in the config block
# of sql/01_prepare.sql; this rewrites the chosen one IN PLACE (so it persists) then
# re-runs the analysis + export. Requires the DB to be loaded (run `make all` once).
#   make tune KEY=cut_expand     VAL=0.8    # ← the cut knob: slice MORE/less host under spans
#   make tune KEY=max_carve_frac VAL=0.90   # building >= this fraction cut => lifted-only
#   make tune KEY=aspect_min     VAL=5      # any config key works
# See docs/geometry-quality.md for every knob and what it does.
tune:
	@test -n "$(KEY)" -a -n "$(VAL)" || { echo "usage: make tune KEY=<config key> VAL=<number>   (see: make config)"; exit 2; }
	@grep -qE "\('$(strip $(KEY))', *[0-9.]+\)" sql/01_prepare.sql \
	  || { echo "unknown config key '$(strip $(KEY))'. Known keys:"; $(MAKE) -s config; exit 2; }
	sed -i -E "s/(\('$(strip $(KEY))', *)[0-9.]+( *\))/\1$(strip $(VAL))\2/" sql/01_prepare.sql
	@echo ">> set $(strip $(KEY)) = $(strip $(VAL)) in sql/01_prepare.sql — re-deriving…"
	$(MAKE) sql
	$(MAKE) export
	@echo ">> done. $(strip $(KEY)) = $(strip $(VAL)). Hard-refresh the viewer (Ctrl+Shift+R)."

reset:
	$(COMPOSE) down -v
