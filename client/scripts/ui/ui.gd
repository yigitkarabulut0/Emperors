class_name UI
extends RefCounted
## Fonts, text and the small helpers every screen uses.
##
## The reference paintings set the type: Cinzel for anything in flared capitals
## (titles, nav labels, card names), EB Garamond for sentences and numbers. Sizes
## are recorded per element in the layout files, measured off the paintings.

const TITLE_FONT := "res://assets/fonts/Cinzel-Variable.ttf"
const BODY_FONT := "res://assets/fonts/EBGaramond[wght].ttf"

const INK := Color("#F1E9DA")          ## the parchment-white of body text
const GOLD := Color("#E9C46A")         ## gold titles
const GOLD_DIM := Color("#C9A24E")
const DIM := Color("#B8AE9C")          ## secondary text
const GREEN := Color("#6EE07A")
const RED := Color("#F0524F")
const GROUND := Color("#09151E")       ## the navy behind everything

static var _fonts: Dictionary = {}


static func font(role: String = "body", weight: int = 500) -> Font:
	var key := "%s:%d" % [role, weight]
	if _fonts.has(key):
		return _fonts[key]
	var base: Font = load(TITLE_FONT if role == "title" else BODY_FONT)
	var fv := FontVariation.new()
	fv.base_font = base
	var tag := TextServerManager.get_primary_interface().name_to_tag("wght")
	fv.variation_opentype = {tag: weight}
	_fonts[key] = fv
	return fv


## The paintings' type is one step heavier than the layouts' nominal weights
## read as, so every weight is lifted by 100 (Cinzel tops out at 900).
static func settings(size: int, color: Color, role: String = "body", weight: int = 500, shadow: bool = true) -> LabelSettings:
	var s := LabelSettings.new()
	s.font = font(role, mini(weight + 100, 900 if role == "title" else 800))
	s.font_size = size
	s.font_color = color
	if shadow:
		s.shadow_color = Color(0, 0, 0, 0.55)
		s.shadow_offset = Vector2(0, 2)
		s.shadow_size = 2
	return s


static func label(text: String, size: int, color: Color = INK, role: String = "body", weight: int = 500,
		align: int = HORIZONTAL_ALIGNMENT_LEFT) -> Label:
	var l := Label.new()
	l.text = text
	l.label_settings = settings(size, color, role, weight)
	l.horizontal_alignment = align
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


static func image(asset: String, rect: Rect2) -> TextureRect:
	var t := TextureRect.new()
	t.texture = Art.tex(asset)
	t.position = rect.position
	t.size = rect.size
	t.stretch_mode = TextureRect.STRETCH_SCALE
	t.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return t


static func place(node: Control, rect: Rect2) -> void:
	node.position = rect.position
	node.size = rect.size
	# A Label grows to its text, so the intended width is kept for fitting.
	node.set_meta("box_w", rect.size.x)


## A tappable painted button: the crop is the whole look; pressing dims it.
static func tex_button(asset: String, rect: Rect2) -> TextureButton:
	var b := TextureButton.new()
	b.texture_normal = Art.tex(asset)
	b.ignore_texture_size = true
	b.stretch_mode = TextureButton.STRETCH_SCALE
	place(b, rect)
	b.button_down.connect(func() -> void: b.modulate = Color(0.75, 0.75, 0.75))
	b.button_up.connect(func() -> void: b.modulate = Color.WHITE)
	b.mouse_exited.connect(func() -> void: b.modulate = Color.WHITE)
	return b


## An invisible tap target over a baked-in control (the "+" on a pill).
static func hotspot(rect: Rect2) -> Button:
	var b := Button.new()
	b.flat = true
	b.focus_mode = Control.FOCUS_NONE
	place(b, rect)
	b.add_theme_stylebox_override("normal", StyleBoxEmpty.new())
	b.add_theme_stylebox_override("hover", StyleBoxEmpty.new())
	b.add_theme_stylebox_override("pressed", StyleBoxEmpty.new())
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	return b


## Shrinks a label's font until its text fits its width (never below min_size).
static func fit_label(l: Label, max_size: int, min_size: int = 14) -> void:
	var s := l.label_settings
	var box: float = float(l.get_meta("box_w", l.size.x))
	var size := max_size
	while size > min_size:
		var w := s.font.get_string_size(l.text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
		if w <= box:
			break
		size -= 1
	s.font_size = size


# --- number formatting -----------------------------------------------------------

static func grouped(v: int) -> String:
	var s := str(absi(v))
	var out := ""
	var n := 0
	for i in range(s.length() - 1, -1, -1):
		out = s[i] + out
		n += 1
		if n % 3 == 0 and i > 0:
			out = "," + out
	return ("-" if v < 0 else "") + out


## 493.48M / 12.0M / 600K / 1,420 — the way the paintings write money.
static func short_number(v: int) -> String:
	var a := absi(v)
	var sign := "-" if v < 0 else ""
	if a >= 1_000_000_000:
		return sign + _trim("%.2f" % (a / 1_000_000_000.0)) + "B"
	if a >= 1_000_000:
		return sign + _trim("%.2f" % (a / 1_000_000.0)) + "M"
	if a >= 100_000:
		return sign + str(int(a / 1000.0)) + "K"
	return sign + grouped(a)


static func _trim(s: String) -> String:
	if s.contains("."):
		s = s.rstrip("0").rstrip(".")
	return s


static func duration(seconds: int) -> String:
	var h := seconds / 3600
	var m := (seconds % 3600) / 60
	var s := seconds % 60
	return "%02d:%02d:%02d" % [h, m, s]


static func short_duration(seconds: int) -> String:
	if seconds >= 3600:
		return "%dh %02dm" % [seconds / 3600, (seconds % 3600) / 60]
	if seconds >= 60:
		return "%dm %02ds" % [seconds / 60, seconds % 60]
	return "%ds" % seconds


static func ago(seconds: int) -> String:
	if seconds < 60:
		return "just now"
	if seconds < 3600:
		return "%dm ago" % (seconds / 60)
	if seconds < 86400:
		return "%dh ago" % (seconds / 3600)
	return "%dd ago" % (seconds / 86400)
