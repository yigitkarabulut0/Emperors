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
const TIER_PIPS := {"common": 1, "uncommon": 2, "rare": 3, "epic": 4,
	"legendary": 5, "mystic": 6, "special": 7}

var _unit: Dictionary = {}
var _is_hero := false
var _busy := false
var _body: VBoxContainer


func _init(p_unit: Dictionary, p_is_hero: bool) -> void:
	_unit = p_unit
	_is_hero = p_is_hero


func _ready() -> void:
	layer = 18

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.72)
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

	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(330, 0)
	card.add_theme_stylebox_override("panel", UI.panel_box(Palette.PANEL, Palette.GOLD_DEEP))
	centre.add_child(card)

	var pad := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		pad.add_theme_constant_override("margin_" + side, 16)
	card.add_child(pad)

	_body = VBoxContainer.new()
	_body.add_theme_constant_override("separation", 10)
	pad.add_child(_body)

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
	_body.add_child(UI.label(title, 19, Palette.TEXT, HORIZONTAL_ALIGNMENT_CENTER))

	var sub := "level %d" % int(_unit.get("level", 1))
	if tier != "":
		sub = "%s %s   ·   %s" % [tier.capitalize(), "•".repeat(int(TIER_PIPS.get(tier, 1))), sub]
	var sub_label := UI.label(sub, 12, Palette.tier(tier) if tier != "" else Palette.TEXT_FAINT,
		HORIZONTAL_ALIGNMENT_CENTER)
	_body.add_child(sub_label)

	_body.add_child(UI.label("ATK %d   DEF %d   SPD %d   HP %d" % [
		int(_unit.get("attack", 0)), int(_unit.get("defense", 0)),
		int(_unit.get("speed", 0)), int(_unit.get("hp", 0))],
		13, Palette.TEXT_DIM, HORIZONTAL_ALIGNMENT_CENTER))

	var equipped: Dictionary = _unit.get("equipped", {})
	for slot in SLOTS:
		_body.add_child(_slot_row(slot, equipped.get(slot)))

	if not _is_hero:
		var danger := Button.new()
		danger.text = "DISMISS"
		danger.focus_mode = Control.FOCUS_NONE
		danger.add_theme_stylebox_override("normal", UI.panel_box(Palette.BG, Palette.DANGER))
		danger.add_theme_stylebox_override("hover", UI.panel_box(Palette.DANGER, Palette.DANGER))
		danger.add_theme_color_override("font_color", Palette.DANGER)
		danger.pressed.connect(_dismiss)
		_body.add_child(danger)
		_body.add_child(UI.label(
			"Frees the slot and refunds a quarter of the recruit price. Gear goes back to your armory.",
			11, Palette.TEXT_FAINT, HORIZONTAL_ALIGNMENT_CENTER))

	var close := Button.new()
	close.text = "Close"
	close.focus_mode = Control.FOCUS_NONE
	close.pressed.connect(func() -> void: queue_free())
	_body.add_child(close)


## One equipment slot: what is in it, or the silhouette of what could be.
func _slot_row(slot: String, item: Variant) -> Control:
	var b := Button.new()
	b.custom_minimum_size = Vector2(0, 62)
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_stylebox_override("normal", UI.panel_box(Palette.PANEL_HIGH, Color.TRANSPARENT))
	b.add_theme_stylebox_override("hover", UI.panel_box(Palette.PANEL_HIGH, Palette.GOLD_DEEP))
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
	icon.custom_minimum_size = Vector2(44, 44)
	icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(icon)

	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override("separation", 1)
	row.add_child(col)

	if item is Dictionary:
		icon.texture = ArtRegistry.item_icon(str(item.get("art", "")), str(item.get("tier", "common")))
		col.add_child(UI.label(str(item.get("name", "")), 15, Palette.TEXT))
		col.add_child(UI.label("ATK %d   DEF %d   SPD %d" % [
			int(item.get("attack", 0)), int(item.get("defense", 0)), int(item.get("speed", 0))],
			11, Palette.tier(str(item.get("tier", "common")))))
	else:
		icon.texture = ArtRegistry.ui_icon("slots/" + slot)
		icon.modulate = Palette.EMPTY_SLOT
		col.add_child(UI.label(str(SLOT_NAMES.get(slot, slot)), 15, Palette.TEXT_FAINT))
		col.add_child(UI.label("empty — tap to equip", 11, Palette.TEXT_FAINT))

	row.add_child(UI.label(">", 15, Palette.TEXT_FAINT))
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
