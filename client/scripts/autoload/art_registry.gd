extends Node
## Resolves art by logical key, never by path.
##
## Scenes ask for ("weapon_01", "legendary") and get a texture. Two reasons that
## indirection is worth it:
##
##  1. Code is never blocked on art. A missing asset falls back to a procedural
##     tier-coloured placeholder, so a screen can be built and played before
##     anything is drawn.
##  2. Nothing hardcodes res:// paths, so assets can be renamed, atlased, or
##     moved to a downloadable pack without touching a single scene.

const ITEM_DIR := "res://assets/items/"
const UI_DIR := "res://assets/ui/"
const PORTRAIT_DIR := "res://assets/portraits/"
const BRANDING_DIR := "res://assets/branding/"

var _cache: Dictionary = {}
var _missing: Dictionary = {}


## Returns a flat white UI glyph, tintable with modulate. Null when absent, so a
## caller can fall back to its own text rather than get a coloured diamond where
## a navigation icon belongs.
func ui_icon(name: String) -> Texture2D:
	var key := "ui:" + name
	if _cache.has(key):
		return _cache[key]
	var path := UI_DIR + name + ".png"
	if not ResourceLoader.exists(path):
		if not _missing.has(key):
			_missing[key] = true
			print("[art] missing ", path)
		return null
	var tex: Texture2D = load(path)
	_cache[key] = tex
	return tex


## Returns a player portrait, falling back to the first one that ships.
##
## A stored portrait can outlive the balance version that offered it -- the set
## is versioned config and a rollback must not orphan anyone -- so an unknown
## name resolves to a face rather than to nothing.
## The studio mark, for the loading screen. Nullable on purpose: a build with no
## branding art should still boot, just without a logo.
func branding(name: String) -> Texture2D:
	var path := BRANDING_DIR + name + ".png"
	if _cache.has(path):
		return _cache[path]
	if not ResourceLoader.exists(path):
		return null
	var tex: Texture2D = load(path)
	_cache[path] = tex
	return tex


func portrait(name: String) -> Texture2D:
	var key := "pp:" + name
	if _cache.has(key):
		return _cache[key]
	var candidates: Array[String] = [name, "knight"]
	for candidate in candidates:
		var path := PORTRAIT_DIR + candidate + ".png"
		if ResourceLoader.exists(path):
			if candidate != name and not _missing.has(key):
				_missing[key] = true
				print("[art] no portrait ", name, " — using ", candidate)
			var tex: Texture2D = load(path)
			_cache[key] = tex
			return tex
	return null


## Returns the icon for an item design.
##
## Painted icons are per DESIGN, not per design-and-tier. The old flat line art
## was recoloured into all seven tiers from one render, which was efficient and
## looked like an outline rather than an object; a painted sword cannot be
## hue-shifted without turning the steel green. Tier is carried by the card --
## its border, its name and its pip count -- which is how the reference game does
## it and how most RPGs do it.
##
## The tiered path is still tried as a fallback so a half-migrated asset folder
## keeps working.
func item_icon(art_key: String, tier: String) -> Texture2D:
	var key := "%s_%s" % [art_key, tier]
	if _cache.has(key):
		return _cache[key]

	var slot := art_key.split("_")[0]
	var candidates: Array[String] = [
		art_key,                          # painted, one per design
		"%s_%s" % [art_key, tier],        # the old tinted line art
		"%s_01" % slot,                   # a sibling of the same slot
	]
	for candidate in candidates:
		var path := ITEM_DIR + candidate + ".png"
		if ResourceLoader.exists(path):
			if candidate != art_key and not _missing.has(key):
				_missing[key] = true
				print("[art] no ", art_key, " — using ", candidate)
			var tex: Texture2D = load(path)
			_cache[key] = tex
			return tex

	if not _missing.has(key):
		_missing[key] = true
		print("[art] missing ", ITEM_DIR, art_key, " — using placeholder")
	var ph := _placeholder(tier)
	_cache[key] = ph
	return ph


## A tier-coloured diamond. Deliberately not a grey box: the tier must still read
## at a glance even when the real art is absent, or grey-box play tells you
## nothing about whether the rarity system is legible.
func _placeholder(tier: String) -> Texture2D:
	var size := 96
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))

	var c := Palette.tier(tier)
	var half := size / 2.0
	for y in size:
		for x in size:
			var d: float = abs(x - half) / half + abs(y - half) / half
			if d <= 0.92:
				img.set_pixel(x, y, Color(c.r * 0.25, c.g * 0.25, c.b * 0.25, 1.0))
			elif d <= 1.0:
				img.set_pixel(x, y, c)
	return ImageTexture.create_from_image(img)
