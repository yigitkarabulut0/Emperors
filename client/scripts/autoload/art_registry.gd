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
const FONT_DIR := "res://assets/fonts/"

var _cache: Dictionary = {}
var _missing: Dictionary = {}


## Sets the game's type and the two chrome surfaces the engine draws for us.
##
## Written into ThemeDB's DEFAULT theme rather than assigned to the shell's root
## Control, because six of this game's overlays are CanvasLayers -- Confirm, the
## portrait picker, the item chooser, the unit sheet, the reconnect curtain and
## the battle replay -- and a theme on a Control does not cross a CanvasLayer.
## Eleven roots would each need the assignment, and the next overlay someone adds
## would be the one that quietly renders in the engine font.
##
## This is also why UI.label() needs no font override: every label in the game
## inherits from here, and only the display face and the tabular figures are set
## per node.
##
## Safe against lint check 3 (autoload ordering): nothing here touches another
## autoload.
func _ready() -> void:
	var t := ThemeDB.get_default_theme()
	var body := font("body")
	if body != null:
		t.default_font = body
	t.default_font_size = UI.F_BODY

	# The engine draws a dark panel behind a ScrollContainer, which on parchment
	# is a grey slab down the middle of every list in the game.
	t.set_stylebox("panel", "ScrollContainer", StyleBoxEmpty.new())

	# And a scrollbar. The default is sized and coloured for a desktop tool; this
	# is a gold thread in a carved groove.
	for bar in ["VScrollBar", "HScrollBar"]:
		var groove := UI.panel_box(Palette.RAIL, Color.TRANSPARENT, 4)
		groove.content_margin_left = 0
		groove.content_margin_right = 0
		groove.content_margin_top = 0
		groove.content_margin_bottom = 0
		t.set_stylebox("scroll", bar, groove)
		t.set_stylebox("grabber", bar, UI.panel_box(Palette.GOLD_DEEP, Color.TRANSPARENT, 4))
		t.set_stylebox("grabber_highlight", bar, UI.panel_box(Palette.GOLD, Color.TRANSPARENT, 4))
		t.set_stylebox("grabber_pressed", bar, UI.panel_box(Palette.GOLD, Color.TRANSPARENT, 4))


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


## The two faces the game is set in, resolved by role rather than by filename.
##
## Roles, not files, for the same reason art is addressed by logical key: a face
## can be swapped without touching the call sites that ask for a heading.
##
##  display    Cinzel -- Roman engraved capitals, the carved-stone register the
##             design asks for. It draws capitals for lowercase input too, which
##             is what titles want and what makes it unusable as body copy.
##  body       Alegreya -- a literary text serif from the same foundry. High
##             x-height, holds up small on a phone.
##  body_bold  Alegreya at 700.
##  number     Alegreya at 600 with tabular, lining figures. Without tnum the
##             gold counter reflows horizontally every time it rolls
##             1,199 -> 1,200, and that counter ticks four times a second;
##             without lnum Alegreya can serve oldstyle figures, whose varying
##             heights read as a typo in a row of stats.
##
## docs/design/client.md sec 9.3 named Alegreya SANS here. The serif is used
## instead because the reference the owner is building to is set in a serif
## throughout -- names, stats and captions alike -- and pairing a sans body with
## a Roman display face read as two unrelated designs. Alegreya is the sans's
## own serif sibling, so the pairing is the one its designer intended.
##
## Both are variable fonts with a 400-900 wght axis, so four roles come out of
## two files rather than four.
##
## Returns null when a font is absent, like ui_icon() does, so a build with no
## fonts still renders in the engine default rather than crashing.
const _FONTS := {
	"display":   ["Cinzel-Variable.ttf", 600.0, false],
	"body":      ["Alegreya-Variable.ttf", 400.0, false],
	"body_bold": ["Alegreya-Variable.ttf", 700.0, false],
	"number":    ["Alegreya-Variable.ttf", 600.0, true],
}


func font(kind: String) -> Font:
	var key := "font:" + kind
	if _cache.has(key):
		return _cache[key]

	if not _FONTS.has(kind):
		push_warning("[art] unknown font role " + kind)
		return null
	var spec: Array = _FONTS[kind]

	var path: String = FONT_DIR + str(spec[0])
	if not ResourceLoader.exists(path):
		if not _missing.has(key):
			_missing[key] = true
			print("[art] missing ", path)
		return null

	# A FontVariation even at the default weight: it is what carries the wght
	# coordinate, and a bare FontFile would render every role at 400.
	var fv := FontVariation.new()
	fv.base_font = load(path)
	fv.variation_opentype = {"wght": float(spec[1])}
	if bool(spec[2]):
		fv.opentype_features = {"tnum": 1, "lnum": 1}

	_cache[key] = fv
	return fv
