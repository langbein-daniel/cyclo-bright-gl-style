# OSM region to download from geofabrik.de
# Warning: "europe" is a quite large region of approx. 30GB!
REGION := europe

# Name and bounding box of the area that should be extracted from REGION.
# Important: REGION should completely cover EXTRACT_BBOX so that tiles can be generated for the whole EXTRACT_BBOX area.
# The VGN is a German transit authority. This bbox covers it's area.
EXTRACT_NAME := vgn

MIN_LAT := 48.70792025947608
MAX_LAT := 50.25793688217101
MIN_LON := 10.011636032586688
MAX_LON := 12.223993889052613

# Manually specify center of map (lng, lat). Otherwise, the center of the EXTRACT_BBOX is used.
# CENTER := 11.0264,49.5736
CENTER :=

# URL of tile server
URL := https://localhost

# <username-or-UID>:<groupname-or-GID>
# Used to chown files modified by docker.
USR_GRP := 1000:998

#==================================================

SHELL := /bin/sh
RSYNC := rsync -r --inplace --append-verify --checksum

EXTRACT_BBOX := $(MIN_LON),$(MIN_LAT),$(MAX_LON),$(MAX_LAT)

# If CENTER is undefined or empty use the arithmetic center of EXTRACT_BBOX
ifeq ($(CENTER),)
CENTER_LAT := $(shell echo "0.5 * ($(MIN_LAT)+$(MAX_LAT))" | bc)
CENTER_LON := $(shell echo "0.5 * ($(MIN_LON)+$(MAX_LON))" | bc)
CENTER := $(CENTER_LON),$(CENTER_LAT)
endif

REGION_FILE := $(REGION).osm.pbf
EXTRACT_FILE := $(EXTRACT_NAME).osm.pbf
MBTILES := $(EXTRACT_NAME).mbtiles

.PHONY: all
all: help

#
# SERVE TILES
#

.PHONY: start-static-tileserver
start-static-tileserver: serve-static.yml data-static  ## Start a webserver to serve (static) vector tiles.
	sudo docker-compose -f $< up -d

.PHONY: stop-static-tileserver
stop-static-tileserver: serve-static.yml  ## Stop webserver if running.
	sudo docker-compose -f $< stop
	sudo docker-compose -f $< down

.PHONY: start-tileserver-gl
start-tileserver-gl: serve-tileserver-gl.yml data-tileserver-gl  ## Start tileserver-gl to serve vector and raster tiles.
	sudo docker-compose -f $< up -d

.PHONY: follow-log-tileserver-gl
follow-log-tileserver-gl: serve-tileserver-gl.yml
	sudo docker-compose -f $< logs --follow tileserver-gl

.PHONY: stop-tileserver-gl
stop-tileserver-gl: serve-tileserver-gl.yml  ## Stop tileserver-gl if running.
	sudo docker-compose -f $< stop
	sudo docker-compose -f $< down

.PHONY: stop
stop: stop-static-tileserver stop-tileserver-gl  ## Stops webserver or tileserver-gl if running.

#
# COPY DATA
#

.PHONY: data
data: data-static data-tileserver-gl  # Create directories to serve with both webserver and tileserver-gl.

data-static: build/glyphs build/sprites build/tiles build/style-static.json build/index.html  ## Create directory with (static) data for a webserver.
	mkdir -p $@
	$(RSYNC) $^ $@

data-tileserver-gl: build/$(MBTILES) build/glyphs build/sprites build/style-tileserver-gl.json maptiler.json  ## Create directory with data for tileserver-gl.
	mkdir -p $@
	$(RSYNC) $<            $@/tiles.mbtiles
	$(RSYNC) $(word 2,$^)/ $@/fonts
	$(RSYNC) $(word 3,$^)/ $@/sprites
	$(RSYNC) $(word 4,$^)  $@/style.json
	$(RSYNC) $(word 5,$^)  $@/config.json

#
# BUILD
#

.PHONY: tiles
tiles: build/tiles  ## Build (static) vector tiles.

build/tiles: build/$(EXTRACT_FILE) build/config-static.json tilemaker/process-openmaptiles.lua
	tilemaker \
		$< \
		--output=$@ \
		--config=$(word 2,$^) \
		--process=$(word 3,$^)

.PHONY: mbtiles
mbtiles: build/$(MBTILES)  ## Build vector tile file (.mbtiles).

# Create a single .mbtiles file
# - https://github.com/systemed/tilemaker#out-of-the-box-setup
# - https://github.com/stadtnavi/digitransit-ansible/blob/32d250beeb6c29370ef022ab21a7924dd62ba5e1/roles/tilemaker/templates/build-mbtiles#L62
build/$(MBTILES): build/$(EXTRACT_FILE) build/config-tileserver-gl.json
	mkdir -p build
	tilemaker \
		$< \
		--output=$@ \
		--config=$(word 2,$^) \
		--process=tilemaker/process-openmaptiles.lua

.PHONY: extract
extract: build/$(EXTRACT_FILE)  ## Extract region from OSM data.

build/$(EXTRACT_FILE): download/$(REGION_FILE)
	mkdir -p build
	osmium extract \
		download/$(REGION_FILE) \
		--bbox $(EXTRACT_BBOX) \
		--overwrite \
		-o $@

.PHONY: sprites
sprites: build/sprites  ## Build sprites (rendered icons).

build/sprites: $(wildcard icons/**/*)
	mkdir -p $@
	sudo docker-compose run --rm openmaptiles-tools bash -c \
		'spritezero /'$@'/style /icons && \
		spritezero --retina /'$@'/style@2x /icons'
	sudo chown -R $(USR_GRP) $@

.PHONY: glyphs
glyphs: build/glyphs  ## Extract glyphs (fonts).

build/glyphs: download/noto-sans.zip
	mkdir -p $@
	unzip $< -d $@

#
# CONFIGURATION
#

build/index.html: index.html
	mkdir -p build
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
	echo 'bicycle_tiles_version=v1' | j2 --format=env $< - -o $@

build/config-static.json: tilemaker/config-openmaptiles.json
	# Change tile URL and bounding box.
	jq '. | .settings.filemetadata.tiles=["'$(URL)'/tiles/{z}/{x}/{y}.pbf"] | .settings.bounding_box=['$(EXTRACT_BBOX)']' $< > $@

# https://github.com/stadtnavi/digitransit-ansible/blob/master/roles/tilemaker/templates/config-openmaptiles.json
build/config-tileserver-gl.json: tilemaker/config-openmaptiles.json
	mkdir -p build
	# Change bounding box and compress; remove tile URL.
	jq '. | .settings.bounding_box=['$(EXTRACT_BBOX)'] | .settings.compress="gzip" | del(.settings.filemetadata.tiles)' $< > $@

#
# DOWNLOAD
#

.PHONY: download
download: download/$(REGION_FILE) download/noto-sans.zip  ## Download OSM data and glyphs (fonts).

download/$(REGION_FILE):
	curl --create-dirs --fail https://download.geofabrik.de/$(REGION)-latest.osm.pbf -o $@

download/noto-sans.zip:
	# Archive containing the following directories:
	#  'Noto Sans Bold'  'Noto Sans Italic'  'Noto Sans Regular'
	curl -L --create-dirs --fail https://github.com/openmaptiles/fonts/releases/download/v2.0/noto-sans.zip -o $@

#
# CLEANUP
#

.PHONY: clean
clean:  ## Remove built/rendered files. This excludes downloaded files.
	sudo rm -rf private
	rm -rf data-static data-tileserver-gl build style.json

.PHONY: clean-all
clean-all: clean  ## Remove all built/rendered/downloaded files.
	rm -r download

.PHONY: help
help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'
