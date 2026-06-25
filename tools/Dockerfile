# OSM ingest toolbox: osmium-tool (clip/filter) + osm2pgsql (flex load) + psql client.
# Both osmium-tool and osm2pgsql are packaged in Debian bookworm (osm2pgsql 1.8.x).
FROM debian:bookworm-slim

RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      osmium-tool \
      osm2pgsql \
      postgresql-client \
      ca-certificates \
      curl \
 && rm -rf /var/lib/apt/lists/*

CMD ["bash"]
