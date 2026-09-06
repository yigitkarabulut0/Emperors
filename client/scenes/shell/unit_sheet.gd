extends CanvasLayer
## Everything you can do to one unit: see it, gear it, and let it go.
##
## Idle Mafia's shape, and the right one: gear lives on the crew member you are
## looking at, not in a separate screen you have to hold in your head. Before
## this, Barracks could show that a soldier was naked but gave you no way to
## dress them -- equipping meant leaving for the Armory and remembering who you
## were shopping for.
##
## A CanvasLayer, not a Control: a Control parented to the scene does not
## reliably inherit the window rect.

signal changed

const SLOTS := ["weapon", "armor", "horse"]
const SLOT_NAMES := {"weapon": "Weapon", "armor": "Armor", "horse": "Mount"}

var _unit: Dictionary = {}
var _is_hero := false
var _busy := false
var _body: VBoxContainer


func _init(p_unit: Dictionary, p_is_hero: bool) -> void:
	_unit = p_unit
	_is_hero = p_is_hero


func _ready() -> void:
	layer = 18

	# Nearly opaque. At 0.72 the whole screen stayed legible behind the card, so
	# the sheet read as a small box sitting on the barracks rather than as the
	# thing you are now looking at.
	var dim := ColorRect.new()
	dim.color = Color(Palette.BG.r * 0.4, Palette.BG.g * 0.4, Palette.BG.b * 0.4, 0.93)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and e.pressed and not _busy:
			queue_free())
	add_child(dim)

	# Inside a safe-area container, so a tall card cannot reach the notch or the
	# home indicator on the way to being centred.
	var centre := CenterContainer.new()
	centre.mouse_filter = Control.MOUSE_FILTER_IGNORE
	SafeArea.wrap(self, Vector4(16, 16, 16, 16)).add_child(centre)

	# 620 of the 720 the screen guarantees. At 330 this was a desktop dialog
	# dropped onto a phone: a narrow box in the middle of a large empty screen,
	# with everything inside it cramped to match.
	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(620, 0)
	card.add_theme_stylebox_override("panel", UI.skin("panel_gold", Palette.PANEL, 22, 20))
	centre.add_child(card)

	_body = VBoxContainer.new()
	_body.add_theme_constant_override("separation", UI.GAP_M)
	card.add_child(_body)

	_render()

	# Dev-only: a capture run disables input, so open a chooser on request.
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		if args[i] == "--dev-slot" and i + 1 < args.size():
			_choose_for(args[i + 1])


func _render() -> void:
	for c in _body.get_children():
		c.queue_free()

	var tier := str(_unit.get("tier", ""))
	var title := str(_unit.get("name", "Unit"))

	# --- who ----------------------------------------------------------------
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", UI.GAP_M)
	_body.add_child(head)

	var face := TextureRect.new()
	face.custom_minimum_size = Vector2(UI.ICON_XL, UI.ICON_XL)
	face.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	face.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	face.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	face.texture = ArtRegistry.portrait(str(GameState.player().get("avatar", "knight"))) \
		if _is_hero else ArtRegistry.ui_icon("barracks")
	if not _is_hero and tier != "":
		face.modulate = Palette.tier(tier)
	head.add_child(face)

	var who := VBoxContainer.new()
	who.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	who.alignment = BoxContainer.ALIGNMENT_CENTER
	who.add_theme_constant_override("separation", UI.GAP_XS)
	head.add_child(who)
	who.add_child(UI.label(title, UI.F_H1, Palette.TEXT))
	var sub := "Level %d" % int(_unit.get("level", 1))
	if tier != "":
		sub = "%s   ·   %s" % [tier.capitalize(), sub]
	who.add_child(UI.label(sub, UI.F_CAPTION,
		Palette.tier(tier) if tier != "" else Palette.TEXT_DIM))

	# --- what it is worth ----------------------------------------------------
	#
	# Four chips rather than one run-on line. A row reading
	# "ATK 22 DEF 22 SPD 0 HP 266" is four facts the eye has to separate for
	# itself; four labelled boxes are four facts already separated.
	var stats := HBoxContainer.new()
	stats.add_theme_constant_override("separation", UI.GAP_S)
	_body.add_child(stats)
	for pair in [["ATK", int(_unit.get("attack", 0)), Palette.DANGER],
			["DEF", int(_unit.get("defense", 0)), Palette.DIAMOND],
			["SPD", int(_unit.get("speed", 0)), Palette.SUCCESS],
			["HP", int(_unit.get("hp", 0)), Palette.GOLD_INK]]:
		stats.add_child(_stat_chip(str(pair[0]), int(pair[1]), pair[2]))

	var equipped: Dictionary = _unit.get("equipped", {})
	for slot in SLOTS:
		_body.add_child(_slot_row(slot, equipped.get(slot)))

	if not _is_hero:
		var note := UI.label(
			"Dismissing frees the slot and refunds a quarter of the recruit price. Gear goes back to your armory.",
			UI.F_CAPTION, Palette.TEXT_DIM, HORIZONTAL_ALIGNMENT_CENTER)
		note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_body.add_child(note)

	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", UI.GAP_M)
	_body.add_child(actions)

	var close := UI.ghost_button("Close", UI.F_BODY)
	close.custom_minimum_size = Vector2(0, UI.TAP_PRIMARY)
	close.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	close.pressed.connect(func() -> void: queue_free())
	actions.add_child(close)

	if not _is_hero:
		var danger := UI.danger_button("Dismiss", UI.F_BODY)
		danger.custom_minimum_size = Vector2(0, UI.TAP_PRIMARY)
		danger.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		danger.pressed.connect(_dismiss)
		actions.add_child(danger)


## One labelled stat, boxed, so four numbers read as four numbers.
func _stat_chip(name: String, value: int, tint: Color) -> Control:
	var box := PanelContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_stylebox_override("panel", UI.skin("panel_sunk", Palette.RAIL, 8, 8))
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 0)
	box.add_child(col)
	col.add_child(UI.label(name, UI.F_MICRO, Palette.TEXT_DIM, HORIZONTAL_ALIGNMENT_CENTER))
	col.add_child(UI.label(UI.number(value), UI.F_H2, tint, HORIZONTAL_ALIGNMENT_CENTER))
	return box


## One equipment slot: what is in it, or the silhouette of what could be.
func _slot_row(slot: String, item: Variant) -> Control:
	var b := Button.new()
	b.custom_minimum_size = Vector2(0, UI.TAP_ROW_TIGHT)
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_stylebox_override("normal", UI.card_box())
	b.add_theme_stylebox_override("hover", UI.card_box(true))
	b.add_theme_stylebox_override("pressed", UI.skin("ghost_press", Palette.PANEL, 14, 10))
	b.pressed.connect(_choose_for.bind(slot))

	var pad := MarginContainer.new()
	pad.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pad.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right"]:
		pad.add_theme_constant_override("margin_" + side, 10)
	b.add_child(pad)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	pad.add_child(row)

	var icon := TextureRect.new()
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.custom_minimum_size = Vector2(UI.ICON_LG, UI.ICON_LG)
	icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(icon)

	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override("separation", 1)
	row.add_child(col)

	if item is Dictionary:
		icon.texture = ArtRegistry.item_icon(str(item.get("art", "")), str(item.get("tier", "common")))
		col.add_child(UI.label(str(item.get("name", "")), UI.F_BODY, Palette.TEXT))
		col.add_child(UI.label("ATK %d   DEF %d   SPD %d" % [
			int(item.get("attack", 0)), int(item.get("defense", 0)), int(item.get("speed", 0))],
			UI.F_CAPTION, Palette.tier(str(item.get("tier", "common")))))
	else:
		icon.texture = ArtRegistry.ui_icon("slots/" + slot)
		# EMPTY_SLOT on a raised panel was almost invisible: an empty slot has to
		# read as a silhouette waiting to be filled, not as nothing at all.
		icon.modulate = Palette.TEXT_DIM
		col.add_child(UI.label(str(SLOT_NAMES.get(slot, slot)), UI.F_BODY, Palette.TEXT_DIM))
		col.add_child(UI.label("empty — tap to equip", UI.F_CAPTION, Palette.TEXT_FAINT))

	var chev := UI.label("›", UI.F_H1, Palette.GOLD_DEEP)
	chev.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(chev)
	return b


func _choose_for(slot: String) -> void:
	if _busy:
		return
	var chooser: CanvasLayer = load("res://scenes/shell/item_chooser.gd").new(
		slot, str(_unit.get("id", "")), _is_hero)
	chooser.picked.connect(func() -> void:
		await _reload_unit()
		changed.emit())
	add_child(chooser)


## Pulls this unit back out of a fresh army view, so the sheet shows what the
## server now believes rather than what it was opened with.
func _reload_unit() -> void:
	var res: Api.Response = await Api.get_json("/v1/army")
	if not res.ok:
		return
	if _is_hero:
		_unit = res.data.get("hero", _unit)
	else:
		for s in res.data.get("slots", []):
			var u: Variant = s.get("soldier")
			if u is Dictionary and str(u.get("id", "")) == str(_unit.get("id", "")):
				_unit = u
	_render()


func _dismiss() -> void:
	if _busy:
		return
	if not await Confirm.ask(self, {
			"title": "Dismiss %s?" % str(_unit.get("name", "this soldier")),
			"body": "Their levels and their gear go with them. The slot stays yours.",
			"confirm_text": "Dismiss", "danger": true}):
		return
	_busy = true
	var res: Api.Response = await Api.post_json("/v1/army/dismiss", {
		"soldier_id": str(_unit.get("id", "")),
		"action_seq": int(GameState.player().get("action_seq", 0)) + 1})
	_busy = false
	if res.ok:
		await GameState.refresh()
		changed.emit()
		queue_free()
	else:
		GameState.action_failed.emit(res.error)
