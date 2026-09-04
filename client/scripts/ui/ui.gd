class_name UI
extends RefCounted
## Small builders for the widgets this game repeats everywhere.
##
## Built in code rather than as .tscn files because almost every screen is a
## data-driven list: the rows come from the server, so there is no fixed
## hierarchy for the editor to hold.

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


static func label(text: String, size: int, color: Color, align: int = HORIZONTAL_ALIGNMENT_LEFT) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.horizontal_alignment = align
	return l


static func button(text: String, size: int = 20) -> Button:
	var b := Button.new()
	b.text = text
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


static func ghost_button(text: String, size: int = 16) -> Button:
	var b := Button.new()
	b.text = text
	b.add_theme_font_size_override("font_size", size)
	b.add_theme_color_override("font_color", Palette.TEXT_DIM)
	b.add_theme_color_override("font_hover_color", Palette.TEXT)
	b.add_theme_stylebox_override("normal", panel_box(Color.TRANSPARENT))
	b.add_theme_stylebox_override("hover", panel_box(Palette.PANEL_HIGH))
	b.add_theme_stylebox_override("pressed", panel_box(Palette.PANEL))
	b.focus_mode = Control.FOCUS_NONE
	return b


static func line_edit(placeholder: String, secret: bool = false) -> LineEdit:
	var e := LineEdit.new()
	e.placeholder_text = placeholder
	e.secret = secret
	e.add_theme_font_size_override("font_size", 20)
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
