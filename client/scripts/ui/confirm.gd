class_name Confirm
extends CanvasLayer
## A modal that asks before something is spent or destroyed.
##
## Nothing in the game asked before this. /v1/army/dismiss and /v1/inventory/sell
## destroy a thing on one tap, and every purchase committed on one tap -- so a
## mis-tap on a list that has just reordered under your thumb cost a soldier.
##
## A CanvasLayer rather than a Control for the reason the other three overlays
## already document: a Control parented into a scene does not reliably inherit
## the window rect. The design specified this modal (sec 10, "our own; native
## AcceptDialog is desktop-shaped") and it was never built.
##
## Usage reads as a guard clause:
##
##     if not await Confirm.ask(self, {"title": "Sell this?", ...}):
##         return
##
## The caller must still be alive after the await. Tabs are never freed, and the
## two self-freeing overlays await this before they free themselves.

signal answered(yes: bool)

## Long enough that a double-tap on the row underneath cannot land on Confirm.
## Without it the dialog only moves the accident one frame later.
const ARM_DELAY := 0.25

var _cfg: Dictionary
var _confirm_btn: Button


func _init(p_cfg: Dictionary) -> void:
	_cfg = p_cfg


## Puts the question up and returns what the player said.
##
## The layer is added to the root, not to `host`: Shell._open() hides the
## outgoing tab, which would hide a dialog parented to it, and the item chooser
## and unit sheet free themselves.
static func ask(host: Node, cfg: Dictionary) -> bool:
	var dialog := Confirm.new(cfg)
	host.get_tree().root.add_child(dialog)
	var yes: bool = await dialog.answered
	dialog.queue_free()
	return yes


func _ready() -> void:
	layer = 30

	# The backdrop swallows input and deliberately does NOT close on a tap.
	# Tap-to-dismiss is right for the portrait picker and wrong here: an
	# accidental tap must never resolve a spend, in either direction.
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.82)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)

	var centre := CenterContainer.new()
	centre.mouse_filter = Control.MOUSE_FILTER_IGNORE
	SafeArea.wrap(self, Vector4(UI.GAP_L, UI.GAP_L, UI.GAP_L, UI.GAP_L)).add_child(centre)

	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(560, 0)
	card.add_theme_stylebox_override("panel", UI.panel_box(Palette.PANEL, Palette.GOLD_DEEP))
	centre.add_child(card)

	var pad := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		pad.add_theme_constant_override("margin_" + side, UI.GAP_L)
	card.add_child(pad)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", UI.GAP_M)
	pad.add_child(col)

	col.add_child(UI.label(
		str(_cfg.get("title", "Are you sure?")), UI.F_H1, Palette.TEXT,
		HORIZONTAL_ALIGNMENT_CENTER))

	var body := str(_cfg.get("body", ""))
	if body != "":
		var b := UI.label(body, UI.F_BODY, Palette.TEXT_DIM, HORIZONTAL_ALIGNMENT_CENTER)
		b.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		col.add_child(b)

	# The price, in the currency it is actually charged in, so nobody has to
	# remember which of three things the button was about to take.
	var cost: Dictionary = _cfg.get("cost", {})
	if not cost.is_empty():
		var line := HBoxContainer.new()
		line.alignment = BoxContainer.ALIGNMENT_CENTER
		line.add_theme_constant_override("separation", UI.GAP_S)
		var currency := str(cost.get("currency", "gold"))
		var tint := Palette.GOLD
		var icon := "coin"
		if currency == "gem":
			tint = Palette.DIAMOND
			icon = "gem"
		elif currency == "energy":
			tint = Palette.ENERGY
			icon = "bolt"
		var glyph := TextureRect.new()
		glyph.texture = ArtRegistry.ui_icon("currency/" + icon)
		glyph.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		glyph.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		glyph.custom_minimum_size = Vector2(UI.ICON_MD, UI.ICON_MD)
		glyph.modulate = tint
		line.add_child(glyph)
		line.add_child(UI.label(UI.number(int(cost.get("amount", 0))), UI.F_NUMBER, tint))
		col.add_child(line)

	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", UI.GAP_M)
	col.add_child(buttons)

	# Cancel left, commit right: the destructive answer is never the one your
	# thumb is already resting on.
	var cancel := UI.ghost_button(str(_cfg.get("cancel_text", "Cancel")), UI.F_BODY)
	cancel.custom_minimum_size = Vector2(0, UI.TAP_PRIMARY)
	cancel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cancel.pressed.connect(func() -> void: answered.emit(false))
	buttons.add_child(cancel)

	_confirm_btn = (UI.danger_button(str(_cfg.get("confirm_text", "Confirm")), UI.F_BODY)
		if bool(_cfg.get("danger", false))
		else UI.button(str(_cfg.get("confirm_text", "Confirm")), UI.F_BODY))
	_confirm_btn.custom_minimum_size = Vector2(0, UI.TAP_PRIMARY)
	_confirm_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_confirm_btn.disabled = true
	_confirm_btn.pressed.connect(func() -> void: answered.emit(true))
	buttons.add_child(_confirm_btn)

	await get_tree().create_timer(ARM_DELAY).timeout
	if is_instance_valid(_confirm_btn):
		_confirm_btn.disabled = false
