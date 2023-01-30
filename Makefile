SHELL := /bin/sh

#==================================================

# <username-or-UID>:<groupname-or-GID>
# Used to chown files modified by docker.
USR_GRP := 1000:998

# OSM region to download from geofabrik.de
# Warning: "europe" Is a quite large region of approx. 30GB!
REGION := europe


# Name and bounding box of the area that should be extracted from REGION.
# Important: REGION should completely cover EXTRACT_BBOX so that tiles can be generated for the whole EXTRACT_BBOX area.
# The VGN is a German transit authority. This bbox covers it's area.
EXTRACT_NAME := vgn
EXTRACT_BBOX := 10.011636032586688,48.70792025947608,12.223993889052613,50.25793688217101

# Initial center of map (lng, lat)
# The center is placed approximately at the Technical Faculty of the University of Erlangen–Nuremberg.
CENTER := 11.0264,49.5736

# URL of tile server
URL := https://localhost

#==================================================

REGION_FILE := $(REGION).osm.pbf
EXTRACT_FILE := $(EXTRACT_NAME).osm.pbf

.PHONY: all
all: start-tileserver

.PHONY: start-tileserver
start-tileserver: public
	sudo docker-compose -f tileserver.yml up -d

.PHONY: stop-tileserver
stop-tileserver:
	sudo docker-compose -f tileserver.yml stop
	sudo docker-compose -f tileserver.yml down

public: build/glyphs build/sprites build/tiles build/style.json build/index.html
	mkdir -p public
	cp -r $^ public

.PHONY: tiles
tiles: build/tiles

.PHONY: sprites
sprites: build/sprites

.PHONY: extract
extract: build/$(EXTRACT_FILE)

.PHONY: download
download: download/$(REGION_FILE)

build/glyphs: download/noto-sans.zip
	mkdir -p $@
	unzip $< -d $@

download/noto-sans.zip:
	# Archive containing the following directories:
	#  'Noto Sans Bold'  'Noto Sans Italic'  'Noto Sans Regular'
	curl -L --create-dirs --fail https://github.com/openmaptiles/fonts/releases/download/v2.0/noto-sans.zip -o $@

build/style.json:
	echo 'bicycle_tiles_version=v1' | j2 --format=env style.jinja.json - -o style.json
	jq '. | .sources.openmaptiles.url="'$(URL)'/tiles/metadata.json" | .sprite="'$(URL)'/sprites/sprite" | .glyphs="'$(URL)'/glyphs/{fontstack}/{range}.pbf"' style.json > $@


build/index.html:
	sed 's/.*center:.*/        center: ['$(CENTER)'],/g' index.html > build/index.html

build/tiles: build/$(EXTRACT_FILE) build/config-openmaptiles.json
	tilemaker \
		$< \
		--output=$@ \
		--config=$(word 2,$^) \
		--process=tilemaker/process-openmaptiles.lua

build/config-openmaptiles.json:
	# Change URLs and bounding box.
	jq '. | .settings.filemetadata.tiles=["'$(URL)'/tiles/{z}/{x}/{y}.pbf"] | .settings.bounding_box=['$(EXTRACT_BBOX)']' tilemaker/config-openmaptiles.json > $@

build/sprites: $(wildcard icons/**/*)
	mkdir -p $@
	sudo docker-compose run --rm openmaptiles-tools bash -c \
		'spritezero /'$@'/sprite /icons && \
		 spritezero --retina /'$@'/sprite@2x /icons'
	sudo chown -R $(USR_GRP) $@

build/$(EXTRACT_FILE): download/$(REGION_FILE)
	mkdir -p build
	osmium extract \
		download/$(REGION_FILE) \
		--bbox $(EXTRACT_BBOX) \
		--overwrite \
		-o $@

download/$(REGION_FILE):
	curl --create-dirs --fail https://download.geofabrik.de/$(REGION)-latest.osm.pbf -o $@

.PHONY: clean
clean:
	sudo rm -rf private
	rm -rf public build

.PHONY: clean-all
clean-all: clean
	rm -r download
