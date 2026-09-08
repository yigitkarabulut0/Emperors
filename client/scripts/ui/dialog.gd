class_name Dialog
extends RefCounted
## Modal confirmations, choices and amount prompts.
##
## No reference painting exists for dialogs, so they are set in the game's own
## type and colours on a dark plate. The buttons arm after ARM_DELAY so a
## double-tap on the row underneath cannot resolve a spend; the backdrop does
## not dismiss. Dialogs attach to the tree root, not the caller, because opening
## a tab hides the outgoing one.

const ARM_DELAY := 0.25


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


class _Modal:
	extends RefCounted
	signal finished(result: String)
	var value: int = 0
	var text_value: String = ""
	var _layer: CanvasLayer
	var _plate: PanelContainer
	var _armed := false
	var _input: LineEdit

	func _init(host: Node, cfg: Dictionary, mode: String) -> void:
		_layer = CanvasLayer.new()
		_layer.layer = 50
		Nav.overlay_parent().add_child(_layer)

		var back := ColorRect.new()
		back.color = Color(0, 0, 0, 0.72)
		back.set_anchors_preset(Control.PRESET_FULL_RECT)
		back.mouse_filter = Control.MOUSE_FILTER_STOP
		_layer.add_child(back)

		var plate := PanelContainer.new()
		_plate = plate
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color("#0E1A26")
		sb.border_color = UI.GOLD_DIM
		sb.set_border_width_all(3)
		sb.set_corner_radius_all(8)
		sb.set_content_margin_all(30)
		plate.add_theme_stylebox_override("panel", sb)
		# The width is fixed; only the height follows the content (see _settle).
		plate.custom_minimum_size = Vector2(660, 0)
		plate.size = Vector2(660, 0)
		_layer.add_child(plate)
		# The plate grows to its content, so it is centred once it has a size --
		# and re-centred if the content changes -- in the canvas the game is laid
		# out on: the topmost Control above the caller, which is the shell filling
		# the viewport (941 wide, 1672 tall or more on a tall phone). Not in
		# get_viewport_rect(): on a stretched desktop window that is the window's
		# pixel size, and centring on it put the plate off the top-left corner
		# with the backdrop still swallowing every tap.
		var top: Control = host as Control
		while top != null and top.get_parent() is Control:
			top = top.get_parent()
		var canvas: Vector2 = top.size if top != null and top.size.x > 0 else Vector2(941, 1672)
		var centre := func() -> void:
			plate.position = ((canvas - plate.size) / 2.0).floor()
		plate.resized.connect(centre)
		centre.call()

		var col := VBoxContainer.new()
		col.add_theme_constant_override("separation", 18)
		plate.add_child(col)

		# An autowrapped Label measures its height at its current width, and a
		# fresh Label is 0 wide: one word per line, a plate thousands of units
		# tall that never shrinks back. Each gets the column's width first.
		var title := UI.label(str(cfg.get("title", "")), 34, UI.GOLD, "title", 700, HORIZONTAL_ALIGNMENT_CENTER)
		title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		title.size.x = 600
		col.add_child(title)
		if cfg.has("body") and str(cfg["body"]) != "":
			var body := UI.label(str(cfg["body"]), 26, UI.INK, "body", 500, HORIZONTAL_ALIGNMENT_CENTER)
			body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			body.size.x = 600
			col.add_child(body)

		if mode == "amount" or mode == "text":
			_input = LineEdit.new()
			_input.placeholder_text = str(cfg.get("placeholder", "Amount" if mode == "amount" else ""))
			if cfg.has("max_length"):
				_input.max_length = int(cfg["max_length"])
			_input.custom_minimum_size = Vector2(0, 72)
			_input.add_theme_font_override("font", UI.font("body", 600))
			_input.add_theme_font_size_override("font_size", 32)
			_input.add_theme_color_override("font_color", UI.INK)
			_input.alignment = HORIZONTAL_ALIGNMENT_CENTER
			var isb := StyleBoxFlat.new()
			isb.bg_color = Color("#09141D")
			isb.border_color = UI.GOLD_DIM
			isb.set_border_width_all(2)
			isb.set_corner_radius_all(6)
			_input.add_theme_stylebox_override("normal", isb)
			_input.add_theme_stylebox_override("focus", isb)
			col.add_child(_input)
			if cfg.has("preset"):
				_input.text = str(cfg["preset"])
			if mode == "text":
				# Typing is the whole point of this dialog, so the keyboard comes
				# up with it rather than after a second tap on the field.
				_input.call_deferred("grab_focus")

		var buttons := VBoxContainer.new()
		buttons.add_theme_constant_override("separation", 12)
		col.add_child(buttons)
		if mode == "choose":
			for o in cfg.get("options", []):
				var label := str(o.get("label", ""))
				if o.has("sub") and str(o["sub"]) != "":
					label += "\n" + str(o["sub"])
				buttons.add_child(_button(label, Color("#1E3A55"), str(o.get("id", ""))))
		else:
			buttons.add_child(_button(str(cfg.get("confirm_text", "Confirm")),
				Color("#7A1F1F") if bool(cfg.get("danger", false)) else Color("#1F7A2E"), "confirm"))
			if mode == "amount" and cfg.has("second_text"):
				buttons.add_child(_button(str(cfg["second_text"]), Color("#1E3A55"), "second"))
		buttons.add_child(_button(str(cfg.get("cancel_text", "Cancel")), Color("#22303D"), ""))

		host.get_tree().create_timer(ARM_DELAY).timeout.connect(func() -> void: _armed = true)
		_layer.visible = false
		_settle()

	## An autowrapped Label reports a one-word-per-line height until it has a
	## width, so the plate's first size is absurd (3000-odd units) and, being a
	## plain Control, it never shrinks back on its own. Two layout passes give
	## the labels their width; then the plate is reset to its real content size,
	## which re-centres it, and only then is it shown.
	func _settle() -> void:
		var tree := _layer.get_tree()
		await tree.process_frame
		await tree.process_frame
		if not is_instance_valid(_plate):
			return
		_plate.size = Vector2(660.0, _plate.get_combined_minimum_size().y)
		await tree.process_frame
		if not is_instance_valid(_plate):
			return
		_plate.size = Vector2(660.0, _plate.get_combined_minimum_size().y)
		_layer.visible = true

	func _button(text: String, color: Color, result: String) -> Button:
		var b := Button.new()
		b.text = text
		b.custom_minimum_size = Vector2(0, 76)
		b.add_theme_font_override("font", UI.font("title", 700))
		b.add_theme_font_size_override("font_size", 26)
		b.add_theme_color_override("font_color", UI.INK)
		var sb := StyleBoxFlat.new()
		sb.bg_color = color
		sb.border_color = UI.GOLD_DIM
		sb.set_border_width_all(2)
		sb.set_corner_radius_all(6)
		b.add_theme_stylebox_override("normal", sb)
		b.add_theme_stylebox_override("hover", sb)
		var pressed := sb.duplicate()
		pressed.bg_color = color.darkened(0.3)
		b.add_theme_stylebox_override("pressed", pressed)
		b.pressed.connect(func() -> void: _resolve(result))
		return b

	func _resolve(result: String) -> void:
		if not _armed:
			return
		if _input != null:
			text_value = _input.text.strip_edges()
			value = int(text_value.replace(",", "").replace(".", ""))
		_layer.queue_free()
		finished.emit(result)
