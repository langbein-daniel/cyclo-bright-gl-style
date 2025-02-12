# OSM region to download from geofabrik.de
REGION_URL := https://download.geofabrik.de/europe/germany-latest.osm.pbf

# Name and bounding box of the area that should be extracted from REGION.
# Important: REGION should completely cover EXTRACT_BBOX so that tiles can be generated for the whole EXTRACT_BBOX area.
# The VGN is a German transit authority.
NAME := vgn
# This bbox covers (almost) the full area of the VGN.
MIN_LON := 10.011636032586688
MAX_LON := 12.223993889052613
MIN_LAT := 48.70792025947608
MAX_LAT := 50.25793688217101

# Manually specify center of map (lng, lat). Otherwise, the center of the EXTRACT_BBOX is used.
# CENTER := 11.0264,49.5736
CENTER :=

# URL of tile server
URL := https://localhost

# <username-or-UID>:<groupname-or-GID>
# Used to chown files modified by docker.
USR_GRP := 1000:998

#==================================================

VERBOSE := 1
SHELL := /bin/sh
CP := cp --recursive

REGION_FILE := $(shell basename "$(REGION_URL)")
EXTRACT_BBOX := $(MIN_LON),$(MIN_LAT),$(MAX_LON),$(MAX_LAT)

# If CENTER is undefined or empty use the arithmetic center of EXTRACT_BBOX
ifeq ($(CENTER),)
CENTER_LON := $(shell echo "0.5 * ($(MIN_LON)+$(MAX_LON))" | bc)
CENTER_LAT := $(shell echo "0.5 * ($(MIN_LAT)+$(MAX_LAT))" | bc)
CENTER := $(CENTER_LON),$(CENTER_LAT)
endif

.PHONY: all
all: help

#
# SERVE TILES
#

.PHONY: start-static-tileserver
start-static-tileserver: serve-static.yml stop data-static  ## Start a webserver that serves (static) vector tiles.
	sudo docker compose -f $< up -d

.PHONY: stop-static-tileserver
stop-static-tileserver: serve-static.yml  ## Stop running webserver.
	sudo docker compose -f $< stop
	sudo docker compose -f $< down

.PHONY: start-tileserver-gl
start-tileserver-gl: serve-tileserver-gl.yml stop data-tileserver-gl  ## Start tileserver-gl which serves vector and raster tiles.
	sudo docker compose -f $< up -d

.PHONY: follow-log-tileserver-gl
follow-log-tileserver-gl: serve-tileserver-gl.yml
	sudo docker compose -f $< logs --follow tileserver-gl

.PHONY: stop-tileserver-gl
stop-tileserver-gl: serve-tileserver-gl.yml  ## Stop running tileserver-gl.
	sudo docker compose -f $< stop
	sudo docker compose -f $< down

.PHONY: stop
stop:  ## Stop running webserver or tileserver-gl.
	# Stopping the static tileserver fails if
	# it tileserver-gl is running.
	# Therefore, we ignore the first error and continue trying to stop tileserver-gl.
	 $(MAKE) stop-static-tileserver || :
	 $(MAKE) stop-tileserver-gl

#
# COPY DATA
#

.PHONY: data
data: data-static data-tileserver-gl  ## Create data for both, a webserver and tileserver-gl.

.PHONY: data-static
data-static: data-static/.data-$(NAME)  ## Create (static) data for a webserver.

data-static/.data-$(NAME): build/glyphs build/sprites build/$(NAME)/tiles build/style-static.json build/$(NAME)/index.html
	# Cleanup: The target-dir might contain data from a different $(NAME).
	rm -rf $(@D)
	# Copy data.
	mkdir -p $(@D)
	$(CP) $^ $(@D)
	# Marker that indicates that the target-dir contains data from $(NAME)
	touch $< $@

.PHONY: data-tileserver-gl
data-tileserver-gl: data-tileserver-gl/.data-$(NAME)  ## Create data for tileserver-gl.

data-tileserver-gl/.data-$(NAME): build/$(NAME)/tiles.mbtiles build/glyphs build/sprites build/style-tileserver-gl.json maptiler.json
	# Cleanup: The target-dir might contain data from a different $(NAME).
	rm -rf $(@D)
	# Copy data.
	mkdir -p $(@D)
	$(CP) $<            $(@D)/tiles.mbtiles
	$(CP) $(word 2,$^)/ $(@D)/fonts
	$(CP) $(word 3,$^)/ $(@D)/sprites
	$(CP) $(word 4,$^)  $(@D)/style.json
	$(CP) $(word 5,$^)  $(@D)/config.json
	# Marker that indicates that the target-dir contains data from $(NAME)
	touch $@

#
# BUILD
#

.PHONY: tiles
tiles: build/$(NAME)/tiles  ## Build (static) vector tiles.

build/$(NAME)/tiles: build/$(NAME)/extract.osm.pbf build/$(NAME)/config-static.json tilemaker/process-openmaptiles.lua build/coastline build/landcover
	# There is no commandline option to specify
	# the path to the  `coastline` or `landcover` directories.
	# Instead, `tilemaker` searches for these in the current
	# working directory.
	# See https://github.com/systemed/tilemaker#out-of-the-box-setup
	#
	# Therefore, we create temporary symlinks from coastline and landcover
	# to build/coastline and build/landcover.
	ln -f -s $(word 4,$^) coastline
	ln -f -s $(word 5,$^) landcover

	tilemaker \
		$< \
		--output=$@ \
		--config=$(word 2,$^) \
		--process=$(word 3,$^)

	rm -r coastline landcover

.PHONY: mbtiles
mbtiles: build/$(NAME)/tiles.mbtiles  ## Build vector tile file (.mbtiles).

# Create a single .mbtiles file
# - https://github.com/systemed/tilemaker#out-of-the-box-setup
# - https://github.com/stadtnavi/digitransit-ansible/blob/32d250beeb6c29370ef022ab21a7924dd62ba5e1/roles/tilemaker/templates/build-mbtiles#L62
build/$(NAME)/tiles.mbtiles: build/$(NAME)/extract.osm.pbf build/$(NAME)/config-tileserver-gl.json
	mkdir -p build/$(NAME)
	tilemaker \
		$< \
		--output=$@ \
		--config=$(word 2,$^) \
		--process=tilemaker/process-openmaptiles.lua

.PHONY: extract
extract: build/$(NAME)/extract.osm.pbf  ## Extract region from OSM data.

build/$(NAME)/extract.osm.pbf: download/$(REGION_FILE)
	mkdir -p build/$(NAME)
	osmium extract \
		download/$(REGION_FILE) \
		--bbox $(EXTRACT_BBOX) \
		--overwrite \
		-o $@

build/coastline: download/water-polygons-split-4326.zip
	# The zipfile contains a top-level directory `water-polygons-split-4326`.
	# We extract it to `build/water-polygons-split-4326`.
	unzip -q $< -d $(@D)
	# Then we rename it to `build/coastline`.
	mv $(@D)/water-polygons-split-4326 $@

.PHONY: build/landcover
build/landcover: build/landcover/ne_10m_urban_areas build/landcover/ne_10m_antarctic_ice_shelves_polys build/landcover/ne_10m_glaciated_areas

build/landcover/ne_10m_urban_areas:	download/ne_10m_urban_areas.zip
	mkdir -p $@
	unzip -q $< -d $@

build/landcover/ne_10m_antarctic_ice_shelves_polys:	download/ne_10m_antarctic_ice_shelves_polys.zip
	mkdir -p $@
	unzip -q $< -d $@

build/landcover/ne_10m_glaciated_areas:	download/ne_10m_glaciated_areas.zip
	mkdir -p $@
	unzip -q $< -d $@

.PHONY: sprites
sprites: build/sprites  ## Build sprites (rendered icons).

build/sprites: $(wildcard icons/**/*)
	mkdir -p $@
	sudo docker compose run --rm openmaptiles-tools bash -c \
		'spritezero /'$@'/style /icons && \
		spritezero --retina /'$@'/style@2x /icons'
	sudo chown -R $(USR_GRP) $@

.PHONY: glyphs
glyphs: build/glyphs  ## Extract glyphs (fonts).

build/glyphs: download/noto-sans.zip
	mkdir -p $@
	unzip -q $< -d $@

#
# CONFIGURATION
#

build/$(NAME)/index.html: index.html
	mkdir -p build/$(NAME)
	sed 's/.*center:.*/        center: ['$(CENTER)'],/g' $< > $@

build/style-static.json: style.json
	mkdir -p build
	jq '. | .sources.openmaptiles.url="'$(URL)'/tiles/metadata.json" | .sprite="'$(URL)'/sprites/style" | .glyphs="'$(URL)'/glyphs/{fontstack}/{range}.pbf"' $< > $@

# https://github.com/stadtnavi/digitransit-ansible/blob/master/roles/tileserver/templates/bicycle.json
# https://tileserver.readthedocs.io/en/latest/config.html#referencing-local-files-from-style-json
build/style-tileserver-gl.json: style.json
	mkdir -p build
	jq '. | .sources.openmaptiles.url="mbtiles://{v3}" | .sprite="{style}" | .glyphs="{fontstack}/{range}.pbf"' $< > $@

style.json: style.jinja.json
	j2 $< -o $@

build/$(NAME)/config-static.json: tilemaker/config-openmaptiles.json
	mkdir -p build/$(NAME)
	# Change tile URL and bounding box.
	jq '. | .settings.filemetadata.tiles=["'$(URL)'/tiles/{z}/{x}/{y}.pbf"] | .settings.bounding_box=['$(EXTRACT_BBOX)']' $< > $@

# https://github.com/stadtnavi/digitransit-ansible/blob/master/roles/tilemaker/templates/config-openmaptiles.json
build/$(NAME)/config-tileserver-gl.json: tilemaker/config-openmaptiles.json
	mkdir -p build/$(NAME)
	# Change bounding box and compress; remove tile URL.
	jq '. | .settings.bounding_box=['$(EXTRACT_BBOX)'] | .settings.compress="gzip" | del(.settings.filemetadata.tiles)' $< > $@

#
# DOWNLOAD
#

.PHONY: download
download: download/$(REGION_FILE) download/water-polygons-split-4326.zip download/ne_10m_urban_areas.zip download/ne_10m_antarctic_ice_shelves_polys.zip download/ne_10m_glaciated_areas.zip download/noto-sans.zip  ## Download OSM data, Natural Earth data and glyphs (fonts).

# Download OSM region.
download/$(REGION_FILE):
	curl -L --create-dirs --fail "$(REGION_URL)" -o $@

# Download OSM coastline.
# https://osmdata.openstreetmap.de/data/water-polygons.html
# License: Open Database License (ODbL), https://osmdata.openstreetmap.de/info/license.html
download/water-polygons-split-4326.zip:
	curl -L --create-dirs --fail "https://osmdata.openstreetmap.de/download/water-polygons-split-4326.zip" -o $@

# License: Public Domain, https://www.naturalearthdata.com/about/terms-of-use/
download/ne_10m_urban_areas.zip:
	curl -L --create-dirs --fail "https://www.naturalearthdata.com/http//www.naturalearthdata.com/download/10m/cultural/ne_10m_urban_areas.zip" -o $@

# License: Public Domain, https://www.naturalearthdata.com/about/terms-of-use/
download/ne_10m_antarctic_ice_shelves_polys.zip:
	curl -L --create-dirs --fail "https://www.naturalearthdata.com/http//www.naturalearthdata.com/download/10m/physical/ne_10m_antarctic_ice_shelves_polys.zip" -o $@

# License: Public Domain, https://www.naturalearthdata.com/about/terms-of-use/
download/ne_10m_glaciated_areas.zip:
	curl -L --create-dirs --fail "https://www.naturalearthdata.com/http//www.naturalearthdata.com/download/10m/physical/ne_10m_glaciated_areas.zip" -o $@

# License: All fonts are either licensed under OFL or Apache, https://github.com/openmaptiles/fonts/#font-license
# Currently, the cyclo bright style uses only the Noto font family which is licensed as OFL.
#
# TODO:
#   The README mentions
#     Noto Sans (patched by Klokan Technologies)
#   Which is probably this repo: https://github.com/klokantech/klokantech-gl-fonts
#   which says that
#     you must keep the name of the font as it is in this repository - to credit KlokanTech
#   And they are named as e.g.
#     KlokanTech Noto Sans Bold
#   Their README links to
#     https://www.google.com/get/noto/
#   which says
#     All Noto fonts are licensed under the Open Font License (OFL).
download/noto-sans.zip:
	# Archive containing the following directories:
	#  'Noto Sans Bold'  'Noto Sans Italic'  'Noto Sans Regular'
	curl -L --create-dirs --fail "https://github.com/openmaptiles/fonts/releases/download/v2.0/noto-sans.zip" -o $@

#
# CLEANUP
#

.PHONY: clean-build
clean-build:  ## Remove built/rendered files but keep OSM extracts. This excludes downloaded files and web-/tileserver data.
	if [ -d private ]; then \
		sudo rm -rf private ; \
	fi

	rm -rf coastline landcover style.json build/glyphs build/sprites

	# https://unix.stackexchange.com/a/389706
	# The command needs to be terminated with a ; for find to know where it ends
	# (as there may be further options afterwards).
	# To protect the ; from the shell, it needs to be quoted as \;
	if [ -d build ]; then \
  		find build -type f ! -regex '.*/.*\.osm\.pbf' -exec rm {} \; ; \
	fi

.PHONY: clean-extract
clean-extract: clean-build  ## Remove built/rendered files. This excludes downloaded files and web-/tileserver data.
	rm -rf build

.PHONY: clean-data
clean-data:  ## Remove web-/tileserver data.
	rm -rf data-static data-tileserver-gl

.PHONY: clean-download
clean-download: ## Remove downloaded files.
	rm -rf download

.PHONY: clean
clean: clean-extract clean-download  ## Remove built/rendered/downloaded files. This excludes web-/tileserver data.

.PHONY: clean-all
clean-all: clean clean-data  ## Remove built/rendered/downloaded files and web-/tileserver data.

.PHONY: help
help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'
