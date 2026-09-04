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

var _cache: Dictionary = {}
var _missing: Dictionary = {}


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
