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


## Returns the icon for an item design at a tier, or a placeholder.
func item_icon(art_key: String, tier: String) -> Texture2D:
	var key := "%s_%s" % [art_key, tier]
	if _cache.has(key):
		return _cache[key]

	var path := ITEM_DIR + key + ".png"
	if ResourceLoader.exists(path):
		var tex: Texture2D = load(path)
		_cache[key] = tex
		return tex

	# Fall back to the first design of the same slot before giving up. A missing
	# variant should show a sibling sword, not a coloured diamond — that is also
	# the right behaviour in production if one asset ever fails to ship.
	var slot := art_key.split("_")[0]
	var sibling := ITEM_DIR + "%s_01_%s.png" % [slot, tier]
	if ResourceLoader.exists(sibling):
		if not _missing.has(key):
			_missing[key] = true
			print("[art] no ", key, " — using ", slot, "_01")
		var sib: Texture2D = load(sibling)
		_cache[key] = sib
		return sib

	if not _missing.has(key):
		_missing[key] = true
		print("[art] missing ", path, " — using placeholder")
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
