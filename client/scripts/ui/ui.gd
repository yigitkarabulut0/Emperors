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
const F_DISPLAY := 72
const F_H1 := 48
const F_H2 := 36
const F_NUMBER := 34
const F_BODY := 30
const F_CAPTION := 24
const F_MICRO := 22

## Touch targets. 88 units clears Apple's 44 pt minimum on every device we ship
## to -- 45.8 pt on an iPhone SE, which is the binding case, and more everywhere
## else. Nothing interactive may be shorter than TAP_MIN.
const TAP_MIN := 88
const TAP_ROW := 132
const TAP_ROW_TIGHT := 112
const TAP_PRIMARY := 116

const ICON_SM := 28
const ICON_MD := 48
const ICON_LG := 64
const ICON_XL := 96

## Spacing on a 4-unit grid.
const GAP_XS := 4
const GAP_S := 8
const GAP_M := 16
const GAP_L := 24
const GAP_XL := 32
const GUTTER := 24


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
	b.add_theme_stylebox_override("normal", panel_box(Palette.GOLD))
	b.add_theme_stylebox_override("hover", panel_box(Color("#F0D793")))
	b.add_theme_stylebox_override("pressed", panel_box(Palette.GOLD_DEEP))
	b.add_theme_stylebox_override("disabled", panel_box(Palette.PANEL_HIGH))
	b.focus_mode = Control.FOCUS_NONE
	return b


## A commit button for something irreversible. Same shape as button(), in the
## danger colour, so "sell this" and "buy this" never look like the same tap.
static func danger_button(text: String, size: int = F_H2) -> Button:
	var b := button(text, size)
	b.add_theme_stylebox_override("normal", panel_box(Palette.DANGER))
	b.add_theme_stylebox_override("hover", panel_box(Color("#E4726A")))
	b.add_theme_stylebox_override("pressed", panel_box(Color("#B2483E")))
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
	b.add_theme_stylebox_override("normal", panel_box(Palette.PANEL_HIGH, Palette.LINE))
	b.add_theme_stylebox_override("hover", panel_box(Palette.PANEL_HIGH, Palette.GOLD_DEEP))
	b.add_theme_stylebox_override("pressed", panel_box(Palette.PANEL, Palette.GOLD))
	b.add_theme_stylebox_override("disabled", panel_box(Palette.BG, Palette.LINE))
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
