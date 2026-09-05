class_name UI
extends RefCounted
## Small builders for the widgets this game repeats everywhere.
##
## Built in code rather than as .tscn files because almost every screen is a
## data-driven list: the rows come from the server, so there is no fixed
## hierarchy for the editor to hold.

## The type scale, in stretch units. docs/design/client.md sec 9.3 specified it and
## the client was built at roughly 55% of it -- the most-used label in the game
## was 12 units, which is 7.3 pt on the owner's phone against iOS body text of 17.
##
## Why fixed units and not a per-device multiplier: with canvas_items + expand the
## viewport is never narrower than 720, so a unit is worth between 0.52 pt (an SE)
## and 0.92 pt (an iPad) -- a spread of 17% across the phones, which is small
## enough that sizing for the smallest device and letting larger ones scale up is
## both correct and keeps 720 a real design grid. A runtime scalar would reflow
## the layout differently on every device and there would be no single truth to
## test against.
const F_DISPLAY := 58
const F_H1 := 40
const F_H2 := 32
const F_NUMBER := 30
const F_BODY := 26
const F_CAPTION := 22
const F_MICRO := 19

## Touch targets, in units, calibrated on an iPhone 16 Pro Max where a unit is
## 0.611 pt.
##
## These were once sized so that the SMALLEST supported device cleared 44 pt,
## which sounds right and is not: it inflates every dimension by 20% on every
## other phone, and on a modern one the result reads as a zoomed-in, low
## resolution UI -- list rows at 81 pt where iOS uses 44 to 60, and a top bar
## eating a sixth of the screen. Fitting the device in the player's hand and
## accepting 40 pt on an iPhone SE is the better trade: 40 pt is still a
## comfortable target, and the SE is not what this is played on.
const TAP_MIN := 76        ## 46 pt here, 40 pt on an SE
const TAP_PRIMARY := 96    ## the one button a screen is about
const TAP_ROW := 104       ## a list row: 64 pt, the top of Apple's own range
const TAP_ROW_TIGHT := 88

const ICON_SM := 24
const ICON_MD := 40
const ICON_LG := 56
const ICON_XL := 80

## Spacing on a 4-unit grid.
const GAP_XS := 4
const GAP_S := 8
const GAP_M := 16
const GAP_L := 24
const GAP_XL := 32
const GUTTER := 24


## Nine-slice margins for the generated skins. The source art is 128 square: a
## 14-unit shadow margin, then a body with a 22-unit corner radius. The slice has
## to contain the shadow and the whole corner, and SKIN_BLEED pushes the drawn
## area back out by the shadow margin so the BODY lines up with the control's
## rect -- without it every button would render inset by its own shadow and look
## smaller than the space it occupies.
const SKIN_SLICE := 42
const SKIN_BLEED := 14

static var _skins: Dictionary = {}


## One of the generated surfaces from scripts/gen-ui-skin.py.
##
## StyleBoxFlat can only draw a flat colour, which is why every panel and button
## in this game used to read as a wireframe rather than a made object. These carry
## a vertical gradient, a lit top edge and a shaded foot, so the same StyleBox
## machinery draws surfaces that catch light.
##
## Falls back to a flat box when the art is missing, so a build without the skin
## still renders rather than crashing.
static func skin(name: String, fallback: Color, pad_h: int = 16, pad_v: int = 12) -> StyleBox:
	var key := "%s|%d|%d" % [name, pad_h, pad_v]
	if _skins.has(key):
		return _skins[key]

	# Fetched through the tree rather than by name: UI is a static helper, and a
	# static function cannot resolve an autoload at compile time.
	var tex: Texture2D = null
	var loop := Engine.get_main_loop()
	if loop is SceneTree:
		var registry: Node = (loop as SceneTree).root.get_node_or_null("/root/ArtRegistry")
		if registry != null:
			tex = registry.call("ui_icon", "skin/" + name)
	if tex == null:
		var flat := panel_box(fallback)
		flat.content_margin_left = pad_h
		flat.content_margin_right = pad_h
		flat.content_margin_top = pad_v
		flat.content_margin_bottom = pad_v
		_skins[key] = flat
		return flat

	var s := StyleBoxTexture.new()
	s.texture = tex
	for side in ["left", "top", "right", "bottom"]:
		s.set("texture_margin_" + side, SKIN_SLICE)
		s.set("expand_margin_" + side, SKIN_BLEED)
	s.content_margin_left = pad_h
	s.content_margin_right = pad_h
	s.content_margin_top = pad_v
	s.content_margin_bottom = pad_v
	_skins[key] = s
	return s


static func panel_box(bg: Color, border: Color = Color.TRANSPARENT, radius: int = 10) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.set_corner_radius_all(radius)
	s.content_margin_left = 14
	s.content_margin_right = 14
	s.content_margin_top = 10
	s.content_margin_bottom = 10
	if border.a > 0.0:
		s.set_border_width_all(2)
		s.border_color = border
	return s


## A panel box with tight padding, for the small stamped things -- a level badge,
## a currency chip -- where panel_box's 14/10 content margin is most of the width.
## The surface for a row or card that can be selected.
##
## Selected reads as a lit panel with a gold edge rather than a different colour,
## and locked as a sunk one -- both of which say "this is the same kind of thing,
## in a different state", which a flat colour swap does not.
static func card_box(selected: bool = false, locked: bool = false) -> StyleBox:
	if locked:
		return skin("panel_sunk", Palette.BG, 14, 10)
	return skin("panel_gold" if selected else "panel", Palette.PANEL, 14, 10)


static func chip_box(bg: Color, border: Color = Color.TRANSPARENT, radius: int = 12) -> StyleBoxFlat:
	var s := panel_box(bg, border, radius)
	s.content_margin_left = 10
	s.content_margin_right = 10
	s.content_margin_top = 2
	s.content_margin_bottom = 2
	return s


static func label(text: String, size: int, color: Color, align: int = HORIZONTAL_ALIGNMENT_LEFT) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.horizontal_alignment = align
	return l


static func button(text: String, size: int = F_H2) -> Button:
	var b := Button.new()
	b.text = text
	# A floor, not a fixed height: four buttons in the overlays set no size at all
	# and fell back to about 18 pt, and every explicit height in the client was
	# below Apple's 44 pt minimum on every device we ship to.
	b.custom_minimum_size.y = TAP_MIN
	b.add_theme_font_size_override("font_size", size)
	b.add_theme_color_override("font_color", Palette.BG)
	b.add_theme_color_override("font_hover_color", Palette.BG)
	b.add_theme_color_override("font_pressed_color", Palette.BG)
	b.add_theme_color_override("font_disabled_color", Palette.TEXT_FAINT)
	# A dark rim on light text and a light one on dark: at a glance it is what
	# stops a caption dissolving into the gradient underneath it.
	b.add_theme_constant_override("outline_size", 0)
	b.add_theme_color_override("font_shadow_color", Color(1, 1, 1, 0.35))
	b.add_theme_constant_override("shadow_offset_x", 0)
	b.add_theme_constant_override("shadow_offset_y", 1)
	b.add_theme_stylebox_override("normal", skin("gold", Palette.GOLD))
	b.add_theme_stylebox_override("hover", skin("gold_hover", Color("#F0D793")))
	b.add_theme_stylebox_override("pressed", skin("gold_press", Palette.GOLD_DEEP))
	b.add_theme_stylebox_override("disabled", skin("disabled", Palette.PANEL_HIGH))
	b.focus_mode = Control.FOCUS_NONE
	return b


## A commit button for something irreversible. Same shape as button(), in the
## danger colour, so "sell this" and "buy this" never look like the same tap.
static func danger_button(text: String, size: int = F_H2) -> Button:
	var b := button(text, size)
	b.add_theme_stylebox_override("normal", skin("danger", Palette.DANGER))
	b.add_theme_stylebox_override("hover", skin("danger", Color("#E4726A")))
	b.add_theme_stylebox_override("pressed", skin("danger_press", Color("#B2483E")))
	b.add_theme_color_override("font_color", Palette.TEXT)
	b.add_theme_color_override("font_hover_color", Palette.TEXT)
	b.add_theme_color_override("font_pressed_color", Palette.TEXT)
	return b


static func ghost_button(text: String, size: int = F_BODY) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size.y = TAP_MIN
	b.add_theme_font_size_override("font_size", size)
	b.add_theme_color_override("font_color", Palette.TEXT_DIM)
	b.add_theme_color_override("font_hover_color", Palette.TEXT)
	# A visible edge, because a fully transparent "button" sitting on a card reads
	# as a caption and nobody taps it.
	b.add_theme_stylebox_override("normal", skin("ghost", Palette.PANEL_HIGH))
	b.add_theme_stylebox_override("hover", skin("panel_gold", Palette.PANEL_HIGH))
	b.add_theme_stylebox_override("pressed", skin("ghost_press", Palette.PANEL))
	b.add_theme_stylebox_override("disabled", skin("disabled", Palette.BG))
	b.add_theme_color_override("font_disabled_color", Palette.TEXT_FAINT)
	b.focus_mode = Control.FOCUS_NONE
	return b


static func line_edit(placeholder: String, secret: bool = false) -> LineEdit:
	var e := LineEdit.new()
	e.placeholder_text = placeholder
	e.secret = secret
	e.custom_minimum_size.y = TAP_PRIMARY
	e.add_theme_font_size_override("font_size", F_H2)
	e.add_theme_color_override("font_color", Palette.TEXT)
	e.add_theme_color_override("font_placeholder_color", Palette.TEXT_FAINT)
	e.add_theme_stylebox_override("normal", panel_box(Palette.PANEL, Palette.LINE))
	e.add_theme_stylebox_override("focus", panel_box(Palette.PANEL, Palette.GOLD_DEEP))
	return e


static func spacer(height: int) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, height)
	return c


## Formats a number the way a game should: thousands separated below 100k, then
## compact so a seven-figure balance never breaks the layout.
static func number(v: int) -> String:
	if v < 100000:
		return grouped(v)
	const UNITS := ["", "K", "M", "B", "T", "Q"]
	var f := float(v)
	var i := 0
	while f >= 1000.0 and i < UNITS.size() - 1:
		f /= 1000.0
		i += 1
	return ("%.2f" % f).trim_suffix("0").trim_suffix("0").trim_suffix(".") + UNITS[i]


static func grouped(v: int) -> String:
	var s := str(absi(v))
	var out := ""
	var c := 0
	for i in range(s.length() - 1, -1, -1):
		out = s[i] + out
		c += 1
		if c % 3 == 0 and i > 0:
			out = "," + out
	return ("-" if v < 0 else "") + out


## A countdown that has to fit beside a number and be read at a glance: "0:23",
## "4:07", "1:02:30". duration() is for spans you plan around, this is for spans
## you wait out.
static func short_duration(seconds: int) -> String:
	var s := maxi(seconds, 0)
	if s >= 3600:
		return "%d:%02d:%02d" % [s / 3600, (s % 3600) / 60, s % 60]
	return "%d:%02d" % [s / 60, s % 60]


static func duration(seconds: int) -> String:
	if seconds <= 0:
		return "full"
	var h := seconds / 3600
	var m := (seconds % 3600) / 60
	var s := seconds % 60
	if h > 0:
		return "%dh %02dm" % [h, m]
	if m > 0:
		return "%dm %02ds" % [m, s]
	return "%ds" % s
