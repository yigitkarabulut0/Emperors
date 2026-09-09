class_name Dialog
extends RefCounted
## Modal confirmations, choices and prompts, dressed in the game's own paint.
##
## They used to be a flat rectangle with flat-coloured buttons on it -- a
## StyleBoxFlat plate and four hex colours -- which is the one thing on the
## screen that was not cut from a painting, and it showed. They are built from
## the game's parts now: the plate is inventory/card_frame, the chamfered plate
## the item cards stand on, nine-patched to whatever size the content needs; the
## buttons wear the painted plates with their words baked out
## (tools/make_button_plates.gd), so a dialog's Confirm is the same object as
## the shop's BUY.
##
## Three things beyond the look:
##
##  - Every button is 96 units tall, which is 45 pt on the phone. They were 76
##    -- 35 pt -- against the 44 pt a thumb needs.
##  - The content scrolls. A choice of twelve Kingdom Works is 12 x 108 units
##    of buttons, and the battle history is however many lines the server sent;
##    both used to grow the plate until it ran off the screen, taking its
##    buttons with it.
##  - The plate never exceeds the screen, and the buttons live outside the
##    scrolling part, so Cancel is always where the thumb left it.
##
## The buttons arm after ARM_DELAY so a double-tap on the row underneath cannot
## resolve a spend; the backdrop does not dismiss. Dialogs attach to the tree
## root, not the caller, because opening a tab hides the outgoing one.

const ARM_DELAY := 0.25
const WIDTH := 720.0
const PAD := 34.0
const BUTTON_H := 96.0            ## 45 pt on the phone
const GAP := 14.0
const CANVAS := Vector2(941, 1672)

## The painted parts a dialog is made of.
const PLATE := "inventory/card_frame"
const PLATE_MARGIN := 26
const CONFIRM_PLATE := "shop/buy_plate"
const DANGER_PLATE := "shop/danger_plate"
const QUIET_PLATE := "inventory/btn_sell_plate"


## {title, body, confirm_text, cancel_text, danger} -> true when confirmed.
static func ask(host: Node, cfg: Dictionary) -> bool:
	var d := _Modal.new(host, cfg, "confirm")
	return await d.finished == "confirm"


## {title, body, options: [{id, label, sub}], cancel_text} -> chosen id or "".
static func choose(host: Node, cfg: Dictionary) -> String:
	var d := _Modal.new(host, cfg, "choose")
	return await d.finished


## {title, body, placeholder, confirm_text, second_text} -> {"action": "confirm"|"second"|"", "value": int}
static func prompt_amount(host: Node, cfg: Dictionary) -> Dictionary:
	var d := _Modal.new(host, cfg, "amount")
	var action: String = await d.finished
	return {"action": action, "value": d.value}


## {title, body, placeholder, preset, max_length, confirm_text} -> {"action": "confirm"|"", "text": String}
## The text is trimmed, never validated: the server holds the rules for what a
## name may be and answers with the one that was broken.
static func prompt_text(host: Node, cfg: Dictionary) -> Dictionary:
	var d := _Modal.new(host, cfg, "text")
	var action: String = await d.finished
	return {"action": action, "text": d.text_value}


## Builds a dialog without waiting on it, so a test can measure one rather than
## answer it. Nothing in the game calls this.
static func build_for_test(host: Node, cfg: Dictionary, mode: String) -> RefCounted:
	return _Modal.new(host, cfg, mode)


class _Modal:
	extends RefCounted
	signal finished(result: String)
	var value: int = 0
	var text_value: String = ""
	var _layer: CanvasLayer
	var _plate: NinePatchRect
	var _column: VBoxContainer
	var _scroll: ScrollContainer
	var _scrolled: VBoxContainer
	var _buttons: VBoxContainer
	var _armed := false
	var _input: LineEdit
	var _canvas: Vector2

	func _init(host: Node, cfg: Dictionary, mode: String) -> void:
		_layer = CanvasLayer.new()
		_layer.layer = 50
		Nav.overlay_parent().add_child(_layer)

		var back := ColorRect.new()
		back.color = Color(0, 0, 0, 0.74)
		back.set_anchors_preset(Control.PRESET_FULL_RECT)
		back.mouse_filter = Control.MOUSE_FILTER_STOP
		_layer.add_child(back)

		# The canvas the game is laid out on: the topmost Control above the
		# caller, which is the shell filling the viewport. Not
		# get_viewport_rect() -- on a stretched desktop window that is the
		# window's pixel size, and centring on it put the plate off the top-left
		# corner with the backdrop still swallowing every tap.
		var top: Control = host as Control
		while top != null and top.get_parent() is Control:
			top = top.get_parent()
		_canvas = top.size if top != null and top.size.x > 0 else Dialog.CANVAS

		_plate = NinePatchRect.new()
		_plate.texture = Art.tex(Dialog.PLATE)
		var m := Dialog.PLATE_MARGIN
		_plate.patch_margin_left = m; _plate.patch_margin_top = m
		_plate.patch_margin_right = m; _plate.patch_margin_bottom = m
		_layer.add_child(_plate)

		_column = VBoxContainer.new()
		_column.add_theme_constant_override("separation", int(Dialog.GAP))
		_plate.add_child(_column)

		var title := UI.label(str(cfg.get("title", "")), 36, UI.GOLD, "title", 700,
			HORIZONTAL_ALIGNMENT_CENTER)
		title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		title.custom_minimum_size.x = Dialog.WIDTH - Dialog.PAD * 2
		_column.add_child(title)

		var rule := ColorRect.new()
		rule.color = Color(UI.GOLD_DIM, 0.45)
		rule.custom_minimum_size = Vector2(0, 2)
		_column.add_child(rule)

		# What can grow lives in here; the buttons do not, so Cancel stays put
		# however long the body or the list is.
		_scroll = ScrollContainer.new()
		_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
		_scroll.scroll_deadzone = 14
		_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
		_column.add_child(_scroll)
		_scrolled = VBoxContainer.new()
		_scrolled.add_theme_constant_override("separation", int(Dialog.GAP))
		_scrolled.custom_minimum_size.x = Dialog.WIDTH - Dialog.PAD * 2
		_scroll.add_child(_scrolled)

		if cfg.has("body") and str(cfg["body"]) != "":
			var body := UI.label(str(cfg["body"]), 27, UI.INK, "body", 500,
				HORIZONTAL_ALIGNMENT_CENTER)
			body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			body.custom_minimum_size.x = Dialog.WIDTH - Dialog.PAD * 2
			_scrolled.add_child(body)

		if mode == "amount" or mode == "text":
			_scrolled.add_child(_field(cfg, mode))

		if mode == "choose":
			for o in cfg.get("options", []):
				_scrolled.add_child(_option(o))

		_buttons = VBoxContainer.new()
		_buttons.add_theme_constant_override("separation", int(Dialog.GAP))
		_column.add_child(_buttons)
		if mode != "choose":
			_buttons.add_child(_button(str(cfg.get("confirm_text", "Confirm")),
				Dialog.DANGER_PLATE if bool(cfg.get("danger", false)) else Dialog.CONFIRM_PLATE,
				Color("#F3FBF3"), "confirm"))
			if mode == "amount" and cfg.has("second_text"):
				_buttons.add_child(_button(str(cfg["second_text"]), Dialog.QUIET_PLATE,
					UI.INK, "second"))
		# A notice has one way out, and calling it Cancel makes it look like a
		# decision. cancel_text says so, or the confirm word does.
		if not _is_notice(cfg, mode):
			_buttons.add_child(_button(str(cfg.get("cancel_text", "Cancel")),
				Dialog.QUIET_PLATE, UI.DIM, ""))

		host.get_tree().create_timer(Dialog.ARM_DELAY).timeout.connect(
			func() -> void: _armed = true)
		_layer.visible = false
		_settle()

	func _is_notice(cfg: Dictionary, mode: String) -> bool:
		if mode != "confirm" or cfg.has("cancel_text"):
			return false
		return str(cfg.get("confirm_text", "")) in ["OK", "Close", "Done"]

	func _field(cfg: Dictionary, mode: String) -> LineEdit:
		_input = LineEdit.new()
		_input.placeholder_text = str(cfg.get("placeholder", "Amount" if mode == "amount" else ""))
		if cfg.has("max_length"):
			_input.max_length = int(cfg["max_length"])
		_input.custom_minimum_size = Vector2(0, 84)
		_input.add_theme_font_override("font", UI.font("body", 600))
		_input.add_theme_font_size_override("font_size", 34)
		_input.add_theme_color_override("font_color", UI.INK)
		_input.alignment = HORIZONTAL_ALIGNMENT_CENTER
		var isb := StyleBoxFlat.new()
		isb.bg_color = Color("#08121A")
		isb.border_color = UI.GOLD_DIM
		isb.set_border_width_all(2)
		isb.set_corner_radius_all(6)
		isb.set_content_margin_all(12)
		_input.add_theme_stylebox_override("normal", isb)
		_input.add_theme_stylebox_override("focus", isb)
		if cfg.has("preset"):
			_input.text = str(cfg["preset"])
		if mode == "text":
			# Typing is the whole point of this dialog, so the keyboard comes up
			# with it rather than after a second tap on the field.
			_input.call_deferred("grab_focus")
		return _input

	## An option carries a name and, often, what it costs. They were one string
	## with a newline in it, set in the button's own face at one size, so the
	## price shouted as loudly as the name. The name is the button's word; the
	## aside is quieter type under it, inside the same plate.
	func _option(o: Dictionary) -> Button:
		var b := _button(str(o.get("label", "")), Dialog.QUIET_PLATE, UI.INK,
			str(o.get("id", "")))
		var sub := str(o.get("sub", ""))
		if sub == "":
			return b
		b.custom_minimum_size.y = Dialog.BUTTON_H + 26.0
		# The name sits in the upper half, the aside in the lower.
		b.alignment = HORIZONTAL_ALIGNMENT_CENTER
		b.vertical_icon_alignment = VERTICAL_ALIGNMENT_TOP
		b.add_theme_constant_override("align_to_largest_stylebox", 0)
		var lift := Control.new()
		lift.set_anchors_preset(Control.PRESET_FULL_RECT)
		lift.mouse_filter = Control.MOUSE_FILTER_IGNORE
		b.add_child(lift)
		var l := UI.label(sub, 23, UI.DIM, "body", 500, HORIZONTAL_ALIGNMENT_CENTER)
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		l.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
		l.offset_top = -46
		l.offset_bottom = -14
		lift.add_child(l)
		# Godot centres a Button's text in the whole face; nudging the face's
		# bottom margin up moves the name off the aside without moving the plate.
		var sb: StyleBoxTexture = b.get_theme_stylebox("normal")
		var lifted := sb.duplicate()
		lifted.content_margin_bottom = 46
		for state in ["normal", "hover", "focus", "pressed", "disabled"]:
			var cur: StyleBox = b.get_theme_stylebox(state)
			var d := cur.duplicate()
			d.content_margin_bottom = 46
			b.add_theme_stylebox_override(state, d)
		return b


	func _button(text: String, plate: String, col: Color, result: String) -> Button:
		var b := UI.plate_face(plate, 16)
		b.text = text
		b.custom_minimum_size = Vector2(0, Dialog.BUTTON_H)
		b.add_theme_font_override("font", UI.font("title", 700))
		b.add_theme_font_size_override("font_size", 28)
		for c in ["font_color", "font_hover_color", "font_pressed_color"]:
			b.add_theme_color_override(c, col)
		b.add_theme_constant_override("outline_size", 0)
		b.pressed.connect(func() -> void: _resolve(result))
		return b

	## An autowrapped Label reports a one-word-per-line height until it has a
	## width, so the plate's first size is absurd and, being a plain Control, it
	## never shrinks back on its own. Two layout passes give the labels their
	## width; then the plate is sized to its real content, capped at the screen,
	## centred, and only then shown.
	func _settle() -> void:
		var tree := _layer.get_tree()
		for i in 3:
			await tree.process_frame
			if not is_instance_valid(_plate):
				return
			_fit()
		_layer.visible = true

	func _fit() -> void:
		var pad := Dialog.PAD
		var max_h := _canvas.y - 120.0
		var fixed := _column.get_theme_constant("separation") * 3.0 \
			+ _child_height(_column, 0) + 2.0 + _buttons.get_combined_minimum_size().y
		var want := _scrolled.get_combined_minimum_size().y
		var room := maxf(120.0, max_h - fixed - pad * 2.0)
		var content := minf(want, room)
		_scroll.custom_minimum_size.y = content
		var h := fixed + content + pad * 2.0
		_plate.size = Vector2(Dialog.WIDTH, h)
		_plate.position = ((_canvas - _plate.size) / 2.0).floor()
		_column.position = Vector2(pad, pad)
		_column.size = Vector2(Dialog.WIDTH - pad * 2.0, h - pad * 2.0)

	func _child_height(box: VBoxContainer, index: int) -> float:
		var c: Control = box.get_child(index) as Control
		return c.get_combined_minimum_size().y if c != null else 0.0

	func _resolve(result: String) -> void:
		if not _armed:
			return
		if _input != null:
			text_value = _input.text.strip_edges()
			value = int(text_value.replace(",", "").replace(".", ""))
		_layer.queue_free()
		finished.emit(result)
