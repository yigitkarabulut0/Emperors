class_name Sheet
extends Control
## A page over the game: the dialogs' chamfered plate, as tall as the phone,
## with a title, a body that scrolls, and a foot with its buttons.
##
## Every page the game grew after the seven paintings -- the daily calendar,
## the battle history, the rankings, the Collection, the profile -- is one of
## these, so they share one frame, one way out, and one set of rows rather than
## each inventing a panel. The frame, the plates and the slots are the painted
## ones the dialogs and fields already use.
##
## Mounts under Nav.overlay_parent() on its own CanvasLayer, sized to the
## canvas the game is laid out on and clear of the notch.
##
## A page may carry a painted header (art/reference/page_headers_sheet.png): a
## scene across the top of the plate, inside its frame, above the title, fading
## into the plate as the paintings' headers fade into the navy. A page without
## one is laid out exactly as before there were any.

signal closed

const MARGIN_X := 30.0
const PAD := 34.0
const GAP := 14.0
const BUTTON_H := 96.0
const ARM_DELAY := 0.25
## The plate's frame (inventory/card_frame: steel, slate, a dark line): a header
## starts inside it.
const HEADER_INSET := 8.0
## How far the title rises into the header's painted fade.
const HEADER_OVERLAP := 26.0

var body: VBoxContainer
var foot: HBoxContainer
var inner_w := 0.0

var _layer: CanvasLayer
var _plate: NinePatchRect
var _title: Label
var _subtitle: Label
var _scroll: ScrollContainer
var _armed := false
var _canvas := Vector2(941, 1672)


## Opens a sheet over the game. `host` is any node of the screen opening it,
## used to find the canvas. `screen` names the page for the game's analytics;
## empty, it is the title's words ("THE DAILY REWARD" -> page:the_daily_reward).
## A page whose title is not fixed copy -- a letter's -- names itself.
## `header` is a painted header scene's asset (pages/header_*), or empty.
static func open(host: Node, title: String, subtitle: String = "", layer: int = 60, screen: String = "",
		header: String = "") -> Sheet:
	var s: Sheet = load("res://scripts/ui/sheet.gd").new()
	s._build(host, title, subtitle, layer, header)
	Api.track("screen", {"name": screen if screen != "" else screen_id(title)})
	return s


## "THE DAILY REWARD" -> "page:the_daily_reward": lower case, words joined by
## underscores, anything else dropped, as short as the server's ids allow.
static func screen_id(title: String) -> String:
	var out := ""
	for ch in title.to_lower().strip_edges():
		if (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9"):
			out += ch
		elif (ch == " " or ch == "-" or ch == "_") and not out.ends_with("_"):
			out += "_"
	return ("page:" + out.trim_suffix("_")).left(48)


## A painted scene across the top of a plate `plate_w` wide, inside its frame,
## at its own proportions and at the width it was cut for (pages/header_* are
## cut to the frame's inside, so they draw 1:1). Its bottom rows are the
## painting's own fade into the navy, which is the plate's colour. Returns
## where it ends. The reroll panel's plate wears one too.
static func header_art(plate: Control, asset: String, plate_w: float) -> float:
	var tex: Texture2D = Art.tex(asset)
	var w := plate_w - HEADER_INSET * 2.0
	var h := roundf(w * float(tex.get_height()) / float(tex.get_width()))
	var art := UI.image(asset, Rect2(HEADER_INSET, HEADER_INSET, w, h))
	art.name = "Header"
	plate.add_child(art)
	return HEADER_INSET + h


func _build(host: Node, title: String, subtitle: String, layer_index: int, header: String = "") -> void:
	_layer = CanvasLayer.new()
	_layer.layer = layer_index
	Nav.overlay_parent().add_child(_layer)
	var back := ColorRect.new()
	back.color = Color(0, 0, 0, 0.8)
	back.set_anchors_preset(Control.PRESET_FULL_RECT)
	back.mouse_filter = Control.MOUSE_FILTER_STOP
	_layer.add_child(back)

	_canvas = UI.canvas_size(host)

	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_layer.add_child(self)

	var y0 := UI.safe_top(_canvas) + 34.0
	var rect := Rect2(MARGIN_X, y0, _canvas.x - MARGIN_X * 2.0, _canvas.y - y0 - 30.0)
	_plate = NinePatchRect.new()
	_plate.texture = Art.tex(Dialog.PLATE)
	for m in ["left", "top", "right", "bottom"]:
		_plate.set("patch_margin_" + m, Dialog.PLATE_MARGIN)
	UI.place(_plate, rect)
	add_child(_plate)
	inner_w = rect.size.x - PAD * 2.0

	var y := PAD - 4.0
	if header != "":
		y = header_art(_plate, header, rect.size.x) - HEADER_OVERLAP
	_title = UI.label(title, 40, UI.GOLD, "title", 700, HORIZONTAL_ALIGNMENT_CENTER)
	UI.place(_title, Rect2(PAD, y, inner_w, 56))
	UI.fit_label(_title, 40, 26)
	_plate.add_child(_title)
	y += 56.0
	if subtitle != "":
		_subtitle = UI.label(subtitle, 24, UI.DIM, "body", 500, HORIZONTAL_ALIGNMENT_CENTER)
		_subtitle.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		UI.place(_subtitle, Rect2(PAD, y, inner_w, 34))
		_plate.add_child(_subtitle)
		y += _subtitle.get_minimum_size().y + 4.0
	var rule := ColorRect.new()
	rule.color = Color(UI.GOLD_DIM, 0.45)
	UI.place(rule, Rect2(PAD, y + 6.0, inner_w, 2))
	_plate.add_child(rule)
	y += 20.0

	foot = HBoxContainer.new()
	foot.add_theme_constant_override("separation", int(GAP))
	foot.alignment = BoxContainer.ALIGNMENT_CENTER
	UI.place(foot, Rect2(PAD, rect.size.y - PAD - BUTTON_H + 6.0, inner_w, BUTTON_H))
	_plate.add_child(foot)

	_scroll = ScrollContainer.new()
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	_scroll.scroll_deadzone = 14
	UI.place(_scroll, Rect2(PAD, y, inner_w, rect.size.y - y - PAD - BUTTON_H - GAP))
	_plate.add_child(_scroll)
	body = VBoxContainer.new()
	body.add_theme_constant_override("separation", int(GAP))
	body.custom_minimum_size = Vector2(inner_w, 0)
	_scroll.add_child(body)

	get_tree().create_timer(ARM_DELAY).timeout.connect(func() -> void: _armed = true)


## The height the body scrolls within.
func body_height() -> float:
	return _scroll.size.y


func set_title(text: String) -> void:
	_title.text = text
	UI.fit_label(_title, 40, 26)


## Removes everything in the body, for a sheet that repaints.
func clear_body() -> void:
	for c in body.get_children():
		c.queue_free()


## A button in the foot. `kind` is "confirm", "danger" or "quiet".
func add_button(word: String, kind: String, action: Callable) -> Button:
	var plate: String = {"confirm": Dialog.CONFIRM_PLATE, "danger": Dialog.DANGER_PLATE}.get(kind, Dialog.QUIET_PLATE)
	var col: Color = UI.DIM if kind == "quiet" else Color("#F3FBF3")
	var b := button(word, plate, col)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.pressed.connect(func() -> void:
		if _armed:
			action.call())
	foot.add_child(b)
	return b


## The foot's CLOSE.
func add_close(word: String = "CLOSE") -> Button:
	return add_button(word, "quiet", close)


func close() -> void:
	if not is_instance_valid(_layer):
		return
	closed.emit()
	_layer.queue_free()


# --- the parts a page is built from ------------------------------------------------

## A plate button, a thumb tall, word in type.
static func button(word: String, plate: String, col: Color, height: float = BUTTON_H, size: int = 28) -> Button:
	var b := UI.plate_face(plate, Dialog.PLATE_EDGE)
	b.text = word
	b.custom_minimum_size = Vector2(0, height)
	b.add_theme_font_override("font", UI.font("title", 700))
	b.add_theme_font_size_override("font_size", size)
	for c in ["font_color", "font_hover_color", "font_pressed_color"]:
		b.add_theme_color_override(c, col)
	b.add_theme_color_override("font_disabled_color", Color(col, 0.45))
	b.add_theme_constant_override("outline_size", 0)
	b.clip_text = true
	return b


## A section heading: gold capitals with a thin rule under them.
func heading(text: String) -> Label:
	var l := UI.label(text, 26, UI.GOLD, "title", 700)
	l.custom_minimum_size = Vector2(inner_w, 40)
	body.add_child(l)
	return l


## A paragraph, wrapped to the page.
func paragraph(text: String, size: int = 24, col: Color = UI.INK, align: int = HORIZONTAL_ALIGNMENT_LEFT) -> Label:
	var l := UI.label(text, size, col, "body", 500, align)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	l.custom_minimum_size = Vector2(inner_w, 0)
	body.add_child(l)
	return l


## A row slot -- the painted copper-edged slot the fields use -- the width of
## the page, `height` tall, for the page to fill. Returns the slot to add to.
func slot(height: float) -> NinePatchRect:
	var r := NinePatchRect.new()
	r.texture = Art.tex(UI.FIELD_PLATE)
	for m in ["left", "top", "right", "bottom"]:
		r.set("patch_margin_" + m, 14)
	r.custom_minimum_size = Vector2(inner_w, height)
	r.mouse_filter = Control.MOUSE_FILTER_PASS
	body.add_child(r)
	return r


## A label placed inside a row.
static func put(row: Control, text: String, rect: Rect2, size: int = 24, col: Color = UI.INK,
		role: String = "body", weight: int = 600, align: int = HORIZONTAL_ALIGNMENT_LEFT) -> Label:
	var l := UI.label(text, size, col, role, weight, align)
	UI.place(l, rect)
	UI.fit_label(l, size, maxi(14, size - 8))
	row.add_child(l)
	return l
