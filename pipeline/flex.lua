-- osm2pgsql FLEX style for the skybridge pipeline.
-- Loads two broad, lightly-filtered tables in EPSG:4326; classification into
-- buildings / roads / rail / water and metric reprojection happens later in SQL
-- (sql/01_prepare.sql). Keeping flex simple makes the tag logic easy to iterate.
--
-- flex is the forward-looking osm2pgsql output (legacy `pgsql` output was
-- deprecated in osm2pgsql v2.0.0, Sept 2024).

local srid = 4326

local polygons = osm2pgsql.define_table({
  name = 'osm_polygons',
  ids = { type = 'any', type_column = 'osm_type', id_column = 'osm_id' },
  columns = {
    { column = 'tags', type = 'jsonb' },
    { column = 'geom', type = 'geometry', projection = srid, not_null = true },
  },
})

local lines = osm2pgsql.define_table({
  name = 'osm_lines',
  ids = { type = 'way', id_column = 'osm_id' },
  columns = {
    { column = 'tags', type = 'jsonb' },
    { column = 'geom', type = 'linestring', projection = srid, not_null = true },
  },
})

-- Areas we care about: any building, any building:part, and man_made=bridge outlines.
local function poly_interesting(t)
  return t.building ~= nil or t['building:part'] ~= nil or t.man_made == 'bridge'
end

-- Linear features we care about: roads (incl. footway bridges), rail, waterways.
-- NOTE: an OPEN way tagged only man_made=bridge is intentionally dropped here
-- (we keep man_made=bridge only as a CLOSED outline polygon, via poly_interesting).
local function line_interesting(t)
  return t.highway ~= nil or t.railway ~= nil or t.waterway ~= nil
end

function osm2pgsql.process_way(object)
  local t = object.tags
  if object.is_closed and poly_interesting(t) then
    polygons:insert({ tags = t, geom = object:as_polygon() })
  elseif line_interesting(t) then
    lines:insert({ tags = t, geom = object:as_linestring() })
  end
end

function osm2pgsql.process_relation(object)
  local t = object.tags
  -- Only type=multipolygon relations are assembled into a polygon here. A
  -- type=building / type=bridge relation is NOT assembled, but its member
  -- footprints still enter via their member ways in process_way (and the SQL
  -- classifies by tag, not by relation membership), so parts are not lost.
  if t.type == 'multipolygon' and poly_interesting(t) then
    polygons:insert({ tags = t, geom = object:as_multipolygon() })
  end
end
