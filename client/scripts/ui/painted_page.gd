class_name PaintedPage
extends Control
## A page painted whole: the owner's full-screen painting of it, framed, with
## its scenic header, its title and its own CLOSE, laid over the game.
##
## The pages the game grew after the seven paintings were Sheets -- the
## dialogs' plate as tall as the phone, a title in type and rows of kit parts.
## As each is painted it moves here, and every painted page opens, fits the
## phone, scrolls, and leaves the same way:
##
##  - It is built from its layout, client/layout/<id>.json, measured off the
##    painting like the tabs' (Layout's kinds, parts by id, live text set by
##    the page). Its "page" element is the painting itself, with the plates for
##    live text erased; its buttons are their own crops, so one can be dimmed,
##    or hidden where the painting's own copy of it is erased.
##  - It sits on the pages' layer (60, the Sheets'), under the notch, with the
##    painting's own ground carried up behind the notch.
##  - On a canvas taller than the painting (941x2040) the extra height goes to
##    the layout's "stretch" bands -- rows of the painting that are the same
##    all the way down: a gap between panels, the middle of a list panel -- so
##    the frame runs the whole screen and a list shows more rows. Everything
##    below a band moves down with it; a scroll region across one grows. On a
##    canvas too short for the painting (a Dynamic Island on the short phone)
##    the bands give back what they can and the page is drawn down to fit the
##    rest, never up.
##  - It closes by its painted CLOSE (any button whose layout action is
##    "close"), by the phone's back and by Escape, with one motion in and one
##    out, and it ignores taps for the quarter second after it opens so the tap
##    that opened it cannot press something on it.
##
## A page script builds on it like this:
##
##	var p := PaintedPage.open(host, "treasury")
##	p.set_text("on_hand", UI.grouped(gold))
##	p.on("deposit", func() -> void: ...)
##	p.closed.connect(...)

signal closed

const DESIGN := Vector2(941, 1672)
const LAYER := 60
const ARM_DELAY := 0.25
const OPEN_TIME := 0.24
const CLOSE_TIME := 0.16
const RISE := 36.0
## A band gives back at most this share of itself before the page is drawn
## down instead: a gap closed further would put two panels edge to edge.
const BAND_MIN := 0.4

var id := ""
## Every top-level element's node by id, as Layout.build returns them.
var parts: Dictionary = {}
var canvas := Vector2(941, 1672)
## The notch's height in canvas units: the page starts under it.
var inset := 0.0
## How much taller (or shorter) the page is drawn than its painting, and the
## scale it is drawn at (1 unless the canvas is too short for it).
var extra := 0.0
var page_scale := 1.0

var _layer: CanvasLayer
var _back: ColorRect
var _body: Control
var _bands: Array = []     # [{y, h, draw}] in the painting's units
var _armed := false
var _closing := false
var _ground := Color("#09151e")
var _slices := 0


## Opens page `page_id` over the game. `host` is any node of the screen opening
## it, used to find the canvas. `opts`: "screen" names it for analytics
## (default "page:<id>"); "inset" sets the notch's height instead of the
## phone's (a test's); "instant" opens it with no motion, for a page taking a
## sibling's place under the same tabs (swap).
static func open(host: Node, page_id: String, opts: Dictionary = {}) -> PaintedPage:
	var p: PaintedPage = load("res://scripts/ui/painted_page.gd").new()
	p._build(host, page_id, opts)
	Api.track("screen", {"name": str(opts.get("screen", "page:" + page_id))})
	return p


func _build(host: Node, page_id: String, opts: Dictionary) -> void:
	id = page_id
	canvas = UI.canvas_size(host)
	inset = float(opts.get("inset", UI.safe_top(canvas)))
	_layer = CanvasLayer.new()
	_layer.layer = LAYER
	Nav.overlay_parent().add_child(_layer)

	# The painting's own ground, dark around its frame: what shows beside a
	# page drawn down, and under the notch.
	_back = ColorRect.new()
	_back.color = Color(0.02, 0.035, 0.05, 0.0)
	_back.set_anchors_preset(Control.PRESET_FULL_RECT)
	_back.mouse_filter = Control.MOUSE_FILTER_STOP
	_layer.add_child(_back)

	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_layer.add_child(self)

	_body = Control.new()
	_body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_body)
	parts = Layout.build(id, _body)
	_fit()
	for b in _buttons(_body):
		if str(b.get_meta("action", "")) == "close":
			b.pressed.connect(func() -> void:
				if _armed:
					close())

	get_tree().create_timer(ARM_DELAY).timeout.connect(func() -> void: _armed = true)
	if bool(opts.get("instant", false)):
		# A sibling taking this one's place under the same tabs (swap): already
		# there, as a tab's page is when its tab is lit.
		_back.color.a = 0.96
		return
	var tw := create_tween().set_parallel(true)
	tw.tween_property(_back, "color:a", 0.96, OPEN_TIME)
	_body.modulate.a = 0.0
	var at := _body.position.y
	_body.position.y = at + RISE
	tw.tween_property(_body, "modulate:a", 1.0, OPEN_TIME)
	tw.tween_property(_body, "position:y", at, OPEN_TIME).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)


# --- what a page script uses --------------------------------------------------------------

## The node built for element or part `part_id` (a part inside a group,
## template or scroll region is found by its own id).
func node(part_id: String) -> Control:
	if parts.has(part_id) and parts[part_id] is Control:
		return parts[part_id]
	return _find(_body, part_id)


## Sets a text part's words, shrinking the type to fit its box down to
## `min_size` -- its painted size is the most it may be. A part the layout
## wraps fits its box's lines; any other its width. Returns the label, for a
## colour that depends on the figure.
func set_text(part_id: String, text: String, min_size: int = 14) -> Label:
	var l := node(part_id) as Label
	if l == null:
		push_warning("[painted_page] %s has no text part %s" % [id, part_id])
		return null
	# The size the layout gives it is the most it may be; a shorter word
	# after a long one grows back to it.
	var painted := int(l.get_meta("painted_size", l.label_settings.font_size))
	l.set_meta("painted_size", painted)
	l.label_settings.font_size = painted
	l.text = text
	if l.autowrap_mode != TextServer.AUTOWRAP_OFF:
		# A wrapped part fits its whole box, lines and all -- and then its lines
		# are evened, so no sentence ends on one word alone under a full line.
		UI.fit_wrapped(l, painted, mini(min_size, painted))
		UI.balance_lines(l)
	else:
		UI.fit_label(l, painted, mini(min_size, painted))
		# Back to its box's width: a Label built around a wider sample kept that
		# width, and a centred word sat off its plate's middle.
		if l.has_meta("box_w"):
			l.size.x = maxf(float(l.get_meta("box_w")), l.get_minimum_size().x)
	return l


## Whether a tap should be answered: not in the quarter second after the page
## opens, nor while it closes. For buttons a page builds itself (a list's
## rows), which `on` never sees.
func armed() -> bool:
	return _armed and not _closing


## Runs `fn` when any button whose layout action is `action` is pressed --
## not in the quarter second after the page opens, nor while it closes.
func on(action: String, fn: Callable) -> void:
	for b in _buttons(_body):
		if str(b.get_meta("action", "")) == action:
			b.pressed.connect(func() -> void:
				if _armed and not _closing:
					fn.call())


## Dims a button and stops it taking taps, or restores it. By its action or
## its part id.
func set_enabled(action_or_id: String, enabled: bool) -> void:
	var hit: Array = []
	var own := node(action_or_id) as BaseButton
	if own != null:
		hit.append(own)
	for b in _buttons(_body):
		if str(b.get_meta("action", "")) == action_or_id and not b in hit:
			hit.append(b)
	for b in hit:
		b.disabled = not enabled
		# self_modulate: the painted buttons use modulate for their pressed look.
		b.self_modulate = Color.WHITE if enabled else Color(0.5, 0.5, 0.5, 0.85)


## Shows or hides a part (a button the painting has only sometimes: its
## copy in the painting is erased, so hiding it leaves the panel bare).
func set_shown(part_id: String, shown: bool) -> void:
	var n := node(part_id)
	if n != null:
		n.visible = shown


## Adds a live node over the painting at `rect`, in the painting's units; it
## moves with the stretch bands like the layout's own parts.
func place(n: Control, rect: Rect2) -> void:
	UI.place(n, map_rect(rect))
	_body.add_child(n)


## A rect in the painting's units, where it is drawn on this canvas (before
## the page's scale, which applies to everything on it).
func map_rect(r: Rect2) -> Rect2:
	var top := _map_y(r.position.y)
	return Rect2(r.position.x, top, r.size.x, _map_y(r.end.y) - top)


## A scroll region's content, for a page that lists: rows added to it scroll
## within the region, which grows with the page on a tall canvas. With no id,
## the page's first scroll region.
func content(scroll_id: String = "") -> Control:
	var sc: ScrollContainer = null
	if scroll_id != "":
		sc = node(scroll_id) as ScrollContainer
	else:
		for n in _all(_body):
			if n is ScrollContainer:
				sc = n
				break
	if sc == null:
		return null
	return sc.get_meta("content") as Control


## A text field over a painted box (the text part `part_id` gives its rect and
## type): the painting is its plate, so the field draws none of its own.
func field(part_id: String, placeholder: String, numeric: bool = false) -> LineEdit:
	var l := node(part_id) as Label
	var e := LineEdit.new()
	e.placeholder_text = placeholder
	e.alignment = l.horizontal_alignment if l != null else HORIZONTAL_ALIGNMENT_LEFT
	var s: LabelSettings = l.label_settings if l != null else UI.settings(30, UI.INK)
	e.add_theme_font_override("font", s.font)
	e.add_theme_font_size_override("font_size", s.font_size)
	e.add_theme_color_override("font_color", s.font_color)
	e.add_theme_color_override("font_placeholder_color", Color(UI.DIM, 0.7))
	e.add_theme_color_override("caret_color", UI.GOLD)
	e.add_theme_color_override("selection_color", Color(UI.GOLD_DIM, 0.45))
	for st in ["normal", "focus", "read_only"]:
		e.add_theme_stylebox_override(st, StyleBoxEmpty.new())
	if numeric:
		e.virtual_keyboard_type = LineEdit.KEYBOARD_TYPE_NUMBER
	if l != null:
		# The part's rect is its line of type; the field takes a thumb's
		# height round it (it draws nothing, so only its tap area grows).
		var h := maxf(l.size.y, 96.0)
		e.position = Vector2(l.position.x, l.position.y + (l.size.y - h) / 2.0)
		e.size = Vector2(float(l.get_meta("box_w", l.size.x)), h)
		l.get_parent().add_child(e)
		l.visible = false
	return e


## Gives this page's place to a sibling under the same tabs -- the Deeds and
## the Victory Road -- in place: `open_other` opens it (with {"instant": true})
## and returns it; it goes on over this one, which leaves with no motion and
## without saying it closed, and whoever waits for this page to close waits
## for the one that took its place. Returns the new page.
func swap(open_other: Callable) -> PaintedPage:
	var listeners := get_signal_connection_list("closed")
	_closing = true
	var other: PaintedPage = open_other.call()
	if other != null:
		for c in listeners:
			var fn: Callable = c["callable"]
			if not other.closed.is_connected(fn):
				other.closed.connect(fn)
	if is_instance_valid(_layer):
		_layer.queue_free()
	return other


func close() -> void:
	if _closing or not is_instance_valid(_layer):
		return
	_closing = true
	closed.emit()
	var tw := create_tween().set_parallel(true)
	tw.tween_property(_back, "color:a", 0.0, CLOSE_TIME)
	tw.tween_property(_body, "modulate:a", 0.0, CLOSE_TIME)
	tw.tween_property(_body, "position:y", _body.position.y + RISE * 0.5, CLOSE_TIME)
	tw.chain().tween_callback(func() -> void:
		if is_instance_valid(_layer):
			_layer.queue_free())


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel") and _is_top():
		get_viewport().set_input_as_handled()
		close()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST and _is_top():
		close()


# --- fitting the painting to the phone --------------------------------------------------

func _fit() -> void:
	var spec := Layout.spec(id)
	var avail := canvas.y - inset
	var grow := avail - DESIGN.y
	for b in spec.get("stretch", []):
		# [y, h] or [y, h, weight]: a band takes its weight's share of the extra
		# height (its height, by default), so a page can give most of it to the
		# gap above its buttons and little to the gap between two cards.
		_bands.append({"y": float(b[0]), "h": float(b[1]), "draw": float(b[1]),
			"w": float(b[2]) if b.size() > 2 else float(b[1])})
	var total := 0.0
	var weights := 0.0
	for b in _bands:
		total += b["h"]
		weights += b["w"]
	if total > 0.0 and (grow >= 0.0 or -grow <= total * (1.0 - BAND_MIN)):
		# Whole units: a band ending on a fraction left a line of the ground
		# showing between it and the next slice, across the frame's gold. A
		# page too short gives back from every band in proportion to its height.
		var given := 0.0
		for i in _bands.size():
			var b: Dictionary = _bands[i]
			var part: float = (b["w"] / weights) if grow >= 0.0 else (b["h"] / total)
			var share := roundf(grow * part) if i < _bands.size() - 1 else grow - given
			b["draw"] = b["h"] + share
			given += share
		extra = grow
	elif grow < 0.0:
		page_scale = avail / DESIGN.y
	_ground = Color(str(spec.get("ground", "#09151e")))
	var drawn_h := DESIGN.y + extra
	_body.size = Vector2(DESIGN.x, drawn_h)
	_body.scale = Vector2.ONE * page_scale
	_body.position = Vector2((canvas.x - DESIGN.x * page_scale) / 2.0, inset)
	if total == 0.0 and grow > 0.0:
		# Nothing in the painting may stretch: the page sits in the middle of
		# the height it has, on its own ground.
		_body.position.y = inset + grow / 2.0
	_back.color = Color(_ground, 0.0)

	# The painting in slices, bands drawn to their new height; then every
	# other part moved down past the bands above it.
	var page := parts.get("page") as TextureRect
	if page != null:
		_slice(page)
	for e in spec.get("elements", []):
		var eid := str(e.get("id", ""))
		if eid == "page" or not parts.has(eid):
			continue
		var r := Layout.rect_of(e)
		var dy := _map_y(r.position.y) - r.position.y
		var nodes: Array = []
		if parts[eid] is Array:
			for inst in parts[eid]:
				nodes.append(inst["node"])
		else:
			nodes.append(parts[eid])
		for n in nodes:
			var c := n as Control
			if c == null:
				continue
			if parts[eid] is Array:
				c.position.y = _map_y(c.position.y)
				continue
			c.position.y += dy
			var grown := (_map_y(r.end.y) - _map_y(r.position.y)) - r.size.y
			if grown != 0.0 and (c is ScrollContainer or str(e.get("grow", "")) == "band"):
				c.size.y += grown

	# Behind the notch, the painting's own ground (the layout's "ground", the
	# colour of the blurred dark round its frame), fading into the painting's
	# top so the two meet without an edge. A strip of the painting stretched up
	# there ran its blur into streaks.
	if inset > 0.0 and page_scale == 1.0:
		var cap := ColorRect.new()
		cap.color = _ground
		cap.mouse_filter = Control.MOUSE_FILTER_IGNORE
		cap.position = Vector2(0, -inset)
		cap.size = Vector2(DESIGN.x, inset)
		_body.add_child(cap)
		_body.move_child(cap, 0)
		var g := Gradient.new()
		g.set_color(0, Color(_ground, 1.0))
		g.set_color(1, Color(_ground, 0.0))
		var gt := GradientTexture2D.new()
		gt.gradient = g
		gt.fill_from = Vector2(0, 0)
		gt.fill_to = Vector2(0, 1)
		gt.width = 4
		gt.height = 64
		var fade := TextureRect.new()
		fade.texture = gt
		fade.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		fade.stretch_mode = TextureRect.STRETCH_SCALE
		fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
		fade.position = Vector2.ZERO
		fade.size = Vector2(DESIGN.x, 18)
		_body.add_child(fade)
		_body.move_child(fade, cap.get_index() + 1 + _slices)


## Draws the painting as horizontal slices: rows outside the bands as painted,
## each band scaled to its drawn height (a band is the same all the way down,
## so drawing it taller changes nothing but its height).
func _slice(page: TextureRect) -> void:
	var tex := page.texture
	var cuts: Array = []
	var y := 0.0
	for b in _bands:
		if b["y"] > y:
			cuts.append([y, b["y"] - y, b["y"] - y])
		cuts.append([b["y"], b["h"], b["draw"]])
		y = b["y"] + b["h"]
	if y < DESIGN.y:
		cuts.append([y, DESIGN.y - y, DESIGN.y - y])
	var at_y := 0.0
	var index := page.get_index()
	for c in cuts:
		var t := TextureRect.new()
		var a := AtlasTexture.new()
		a.atlas = tex
		a.region = Rect2(0, c[0], DESIGN.x, c[1])
		t.texture = a
		t.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		t.stretch_mode = TextureRect.STRETCH_SCALE
		t.mouse_filter = Control.MOUSE_FILTER_IGNORE
		t.position = Vector2(0, at_y)
		# Each slice runs a unit under the next, so no row of the ground can
		# show between them however the page is scaled.
		t.size = Vector2(DESIGN.x, float(c[2]) + (1.0 if c != cuts[-1] else 0.0))
		t.name = "PageSlice"
		t.set_meta("page_slice", true)
		_body.add_child(t)
		_body.move_child(t, index)
		index += 1
		_slices += 1
		at_y += float(c[2])
	page.queue_free()
	parts.erase("page")


func _map_y(y: float) -> float:
	var out := y
	for b in _bands:
		var top: float = b["y"]
		var h: float = b["h"]
		if y >= top + h:
			out += b["draw"] - h
		elif y > top:
			out += (y - top) * (b["draw"] / h - 1.0)
	return out


func _is_top() -> bool:
	if _closing or not is_instance_valid(_layer):
		return false
	for c in _layer.get_parent().get_children():
		if c is CanvasLayer and c != _layer and (c as CanvasLayer).layer >= _layer.layer \
				and c.get_index() > _layer.get_index():
			return false
	return true


static func _buttons(root: Node) -> Array:
	var out: Array = []
	for n in _all(root):
		if n is BaseButton:
			out.append(n)
	return out


static func _find(root: Node, part_id: String) -> Control:
	for n in _all(root):
		if n.has_meta("parts"):
			var ps: Dictionary = n.get_meta("parts")
			if ps.has(part_id):
				return ps[part_id]
	return null


static func _all(n: Node) -> Array:
	var out: Array = [n]
	for c in n.get_children():
		out.append_array(_all(c))
	return out
