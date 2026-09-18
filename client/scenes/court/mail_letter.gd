extends CanvasLayer
## One letter, read on the painted letter card of art/reference/mail.png.
##
## The card is the painting's own, whole: the red seal on its golden rule at the
## top, three reward tiles and CLAIM at the foot. It is nine-patched so that
## only the plain parchment between the seal and the tiles grows with the
## letter -- its width is the painting's, so the seal is never stretched. The
## words are set in ink on the parchment: the title, who sent it and when, the
## letter itself (it scrolls when it is longer than the screen allows), what it
## carries, and how long there is to claim it.
##
## Up to three rewards sit in the painted tiles, and a bubble says how many more
## the list above them names. A letter with nothing left to claim wears THROW
## AWAY over the painted CLAIM. CLOSE is under the card, where a dialog's
## second button is.
##
## Built from the layout's "letter" template (client/layout/mail.json): the
## parts named *_b are measured in the card's painted 447x431 and follow its
## foot as it grows.

signal claim_pressed
signal throw_pressed
signal closed

const SCREEN := "mail"
const CARD := Vector2(447, 431)
## The card's nine-patch margins (left, top, right, bottom): the seal in the top,
## the tiles and CLAIM in the bottom, the frame and the torn edge at the sides.
const MARGINS := [30, 101, 30, 210]
## Where the words start and end on the parchment: under the seal, and 14 above
## the bottom margin's painted tiles.
const WORDS_TOP := 104.0
const WORDS_GAP := 14.0
const GAP := 8.0
const BUTTON_H := 96.0
const ARM_DELAY := 0.25
## The painted CLAIM, in the card's painted space: covered by THROW AWAY when
## there is nothing to claim.
const CLAIM_PAINT := Rect2(98, 333, 244, 78)
const SOON := 2 * 86400
## The crimson of the card's own seal: the deadline of a letter going soon, in
## ink the parchment can carry (the navy screens' red is too light on it).
const SEAL_RED := Color("#8E1B1E")
const NBSP := "\u00a0"

var _m: Dictionary = {}
var _host: Node
var _canvas := Vector2(941, 1672)
var _card: NinePatchRect
var _parts: Dictionary = {}
var _armed := false


func setup(m: Dictionary, host: Node) -> void:
	_m = m
	_host = host


func _ready() -> void:
	layer = 66
	_canvas = UI.canvas_size(_host) if _host != null else _canvas
	var back := ColorRect.new()
	back.color = Color(0, 0, 0, 0.8)
	back.set_anchors_preset(Control.PRESET_FULL_RECT)
	back.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(back)

	_card = NinePatchRect.new()
	_card.texture = Art.tex("mail/letter_card")
	_card.patch_margin_left = MARGINS[0]
	_card.patch_margin_top = MARGINS[1]
	_card.patch_margin_right = MARGINS[2]
	_card.patch_margin_bottom = MARGINS[3]
	_card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_card)

	var built := Layout.instantiate(Layout.element(SCREEN, "letter"))
	_parts = built["parts"]
	for id in _parts:
		var n: Control = _parts[id]
		n.get_parent().remove_child(n)
		_card.add_child(n)
	built["node"].queue_free()
	_fill()
	_lay_out()
	get_tree().create_timer(ARM_DELAY).timeout.connect(func() -> void: _armed = true)


func _fill() -> void:
	var p := _parts
	p["title"].text = str(_m.get("title", ""))
	p["meta"].text = "From %s  ·  %s" % [str(_m.get("sender", "")),
		UI.ago(_seconds_since(str(_m.get("created_at", ""))))]
	p["body"].text = str(_m.get("body", ""))
	var lines: Array = _m.get("lines", [])
	var words: Array[String] = []
	for l in lines:
		# One reward is never broken across two lines ("2 Energy / Potions").
		words.append(str(l.get("text", "")).replace(" ", NBSP))
	var claimable := bool(_m.get("claimable", false))
	# The dot stays with the reward before it, so a line never starts with one.
	var enclosed := (NBSP + NBSP + "·  ").join(words)
	if lines.is_empty():
		enclosed = "Nothing enclosed."
	elif bool(_m.get("claimed", false)):
		enclosed = "It carried " + enclosed
	p["enclosed"].text = enclosed
	# Until when, on its own line: red for a letter going soon, and only it.
	var left := int(_m.get("expires_in", 0))
	var deadline: Label = p["deadline"]
	deadline.visible = claimable and left > 0
	deadline.text = "Claim it within %s, or it is gone." % UI.time_left(left) if deadline.visible else ""
	if deadline.visible and left < SOON:
		deadline.label_settings.font_color = SEAL_RED
	for i in 3:
		var ic: TextureRect = p["icon_%d_b" % (i + 1)]
		ic.visible = i < lines.size()
		var g := ItemGround.for_line(ic, lines[i] if ic.visible else {},
			ItemGround.inset(Rect2(ic.position, ic.size), -6.0))
		if ic.visible:
			ic.texture = Art.reward_line_icon(lines[i])
			ic.modulate = Color.WHITE if claimable else Color(0.55, 0.55, 0.57)
			g.modulate = ic.modulate
	var extra := lines.size() - 3
	p["more_b"].visible = extra > 0
	p["more_text_b"].visible = extra > 0
	p["more_text_b"].text = "+%d" % extra


## Stacks the words on the parchment and sizes the card to them, as tall as the
## screen allows; the letter's own text scrolls past that.
func _lay_out() -> void:
	var p := _parts
	var w := float(p["title"].get_meta("box_w", p["title"].size.x))
	var y := _stack(p["title"], WORDS_TOP, w) + 2.0
	y = _stack(p["meta"], y, w) + GAP + 4.0

	# Under the letter: what it carries, and until when.
	var enclosed: Label = p["enclosed"]
	var deadline: Label = p["deadline"]
	var enclosed_h := _wrapped_height(enclosed, w)
	var deadline_h := _wrapped_height(deadline, w) if deadline.visible else 0.0
	var under := enclosed_h + (deadline_h + 2.0 if deadline_h > 0.0 else 0.0)
	var body: Label = p["body"]
	var body_h := _wrapped_height(body, w)
	var close_h := BUTTON_H + 16.0
	var max_card := _canvas.y - UI.safe_top(_canvas) - 60.0 - close_h
	var fixed := y + GAP + under + WORDS_GAP + float(MARGINS[3])
	var room := maxf(80.0, max_card - fixed)
	var shown := body_h
	if body_h > room:
		# Whole lines only, so the last line shown is never cut through.
		var s := body.label_settings
		var pitch := s.font.get_height(s.font_size) + s.line_spacing
		shown = maxf(1.0, floorf((room + s.line_spacing) / pitch)) * pitch - s.line_spacing

	# The letter scrolls inside the parchment when it is longer than the room.
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	scroll.scroll_deadzone = 14
	UI.place(scroll, Rect2(body.position.x, y, w, shown))
	_card.add_child(scroll)
	body.get_parent().remove_child(body)
	scroll.add_child(body)
	body.position = Vector2.ZERO
	body.custom_minimum_size = Vector2(w, body_h)
	body.size = Vector2(w, body_h)
	scroll.name = "BodyScroll"
	y += shown + (GAP if shown > 0.0 else 0.0)
	enclosed.position.y = y
	enclosed.size = Vector2(w, enclosed_h)
	y += enclosed_h
	if deadline_h > 0.0:
		deadline.position.y = y + 2.0
		deadline.size = Vector2(w, deadline_h)
		y += deadline_h + 2.0
	y += WORDS_GAP

	var h := maxf(CARD.y, y + float(MARGINS[3]))
	var x := 155.0 + (_canvas.x - 155.0 - CARD.x) / 2.0
	var top := UI.safe_top(_canvas) + maxf(20.0, (_canvas.y - UI.safe_top(_canvas) - h - close_h) / 2.0)
	UI.place(_card, Rect2(x, top, CARD.x, h))

	# The bottom margin's parts follow the card's foot.
	var drop := h - CARD.y
	for id in p:
		if str(id).ends_with("_b"):
			(p[id] as Control).position.y += drop

	var claim: BaseButton = p["claim_b"]
	if bool(_m.get("claimable", false)):
		claim.pressed.connect(func() -> void:
			if _armed:
				claim_pressed.emit())
	else:
		claim.visible = false
		var cover := CLAIM_PAINT
		cover.position.y += drop
		var throw := Sheet.button("THROW AWAY", Dialog.QUIET_PLATE, UI.INK, cover.size.y, 24)
		var inset := (BUTTON_H - cover.size.y) / 2.0
		UI.place(throw, Rect2(cover.position.x, cover.position.y - inset, cover.size.x, BUTTON_H))
		# The plate covers the painted CLAIM and no more -- drawn at the full
		# target's height it sat on the tiles' rims and the card's edge -- while
		# the target round it stays a thumb's.
		for state in ["normal", "pressed", "disabled"]:
			var sb := throw.get_theme_stylebox(state)
			sb.expand_margin_top = -inset
			sb.expand_margin_bottom = -inset
		throw.name = "ThrowAway"
		throw.pressed.connect(func() -> void:
			if _armed:
				throw_pressed.emit())
		_card.add_child(throw)

	var close_b := Sheet.button("CLOSE", Dialog.QUIET_PLATE, UI.DIM)
	UI.place(close_b, Rect2(x + CARD.x / 2.0 - 160.0, top + h + 16.0, 320.0, BUTTON_H))
	close_b.name = "Close"
	close_b.pressed.connect(func() -> void:
		if _armed:
			close())
	add_child(close_b)


## Puts a block of words at y, as tall as its wrapped lines; returns its foot.
func _stack(l: Label, y: float, w: float) -> float:
	var h := _wrapped_height(l, w)
	l.position.y = y
	l.size = Vector2(w, h)
	return y + h


## A wrapping label's height at width w, as the label itself lays it out: its
## lines and the spacing between them. (Measuring the string with the font
## leaves out the spacing between wrapped lines -- a four-line title came out
## three spacings short and ran into the line under it.)
func _wrapped_height(l: Label, w: float) -> float:
	if l.text == "":
		return 0.0
	l.size = Vector2(w, 0.0)
	return l.get_minimum_size().y


func close() -> void:
	if not is_inside_tree():
		return
	closed.emit()
	queue_free()


static func _seconds_since(iso: String) -> int:
	if iso == "":
		return 0
	var then := Time.get_unix_time_from_datetime_string(iso.trim_suffix("Z"))
	return maxi(0, int(Time.get_unix_time_from_system()) - int(then))
