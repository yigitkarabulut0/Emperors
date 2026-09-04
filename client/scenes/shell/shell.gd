extends Control
## The game shell: left icon rail, top status bar, content area, bottom action.
##
## The rail is always visible and one tap from anywhere, which is what the
## reference game does too. The bottom strip is deliberately reserved for the
## primary action of the current section — it is the only part of a tall phone
## the thumb reaches comfortably, and this game is mostly one repeated tap.

const SECTIONS := [
	{"id": "family",    "glyph": "K", "label": "Keep",     "milestone": "M5"},
	{"id": "collect",   "glyph": "F", "label": "Fields",   "milestone": ""},
	{"id": "inventory", "glyph": "A", "label": "Armory",   "milestone": ""},
	{"id": "shop",      "glyph": "M", "label": "Market",   "milestone": ""},
	{"id": "soldiers",  "glyph": "B", "label": "Barracks", "milestone": ""},
	{"id": "attack",    "glyph": "W", "label": "War Gate", "milestone": "M4"},
	{"id": "territory", "glyph": "T", "label": "Map",      "milestone": "M5"},
]

const RAIL_WIDTH := 88

var _current := "collect"
var _rail_buttons: Dictionary = {}
var _content: Control
var _action_host: Control
var _toast: Label

# top bar
var _level: Label
var _gold: Label
var _energy: Label
var _energy_bar: ProgressBar


func _ready() -> void:
	var bg := ColorRect.new()
	bg.color = Palette.BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 0)
	add_child(root)

	root.add_child(_build_top_bar())

	var middle := HBoxContainer.new()
	middle.size_flags_vertical = Control.SIZE_EXPAND_FILL
	middle.add_theme_constant_override("separation", 0)
	root.add_child(middle)

	middle.add_child(_build_rail())

	_content = MarginContainer.new()
	_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	for side in ["left", "right", "top", "bottom"]:
		(_content as MarginContainer).add_theme_constant_override("margin_" + side, 10)
	middle.add_child(_content)

	_toast = UI.label("", 15, Palette.DANGER, HORIZONTAL_ALIGNMENT_CENTER)
	_toast.custom_minimum_size = Vector2(0, 22)
	root.add_child(_toast)

	_action_host = MarginContainer.new()
	_action_host.custom_minimum_size = Vector2(0, 78)
	for side in ["left", "right"]:
		(_action_host as MarginContainer).add_theme_constant_override("margin_" + side, 12)
	(_action_host as MarginContainer).add_theme_constant_override("margin_bottom", 12)
	root.add_child(_action_host)

	GameState.changed.connect(_on_state_changed)
	GameState.action_failed.connect(_on_action_failed)
	GameState.level_up.connect(func(lv: int) -> void: _flash("Level %d!" % lv, Palette.GOLD))

	# Dev-only: open a specific section for a proof capture.
	for i in OS.get_cmdline_user_args().size():
		var a := OS.get_cmdline_user_args()
		if a[i] == "--dev-tab" and i + 1 < a.size():
			_current = a[i + 1]

	_open(_current)
	_on_state_changed()

	# A 4 Hz tick drives only the two numbers that move on their own (the energy
	# bar and its countdown). Everything else redraws on `changed`, so no node
	# polls state per frame.
	var t := Timer.new()
	t.wait_time = 0.25
	t.autostart = true
	t.timeout.connect(_tick)
	add_child(t)


func _build_top_bar() -> Control:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UI.panel_box(Palette.RAIL, Color.TRANSPARENT, 0))
	panel.custom_minimum_size = Vector2(0, 78)

	var pad := MarginContainer.new()
	for side in ["left", "right"]:
		pad.add_theme_constant_override("margin_" + side, 14)
	pad.add_theme_constant_override("margin_top", 10)
	pad.add_theme_constant_override("margin_bottom", 10)
	panel.add_child(pad)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)
	pad.add_child(col)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	col.add_child(row)

	_level = UI.label("Lv 1", 17, Palette.TEXT)
	row.add_child(_level)

	var grow := Control.new()
	grow.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(grow)

	_gold = UI.label("0", 19, Palette.GOLD, HORIZONTAL_ALIGNMENT_RIGHT)
	row.add_child(_gold)

	var erow := HBoxContainer.new()
	erow.add_theme_constant_override("separation", 8)
	col.add_child(erow)

	_energy_bar = ProgressBar.new()
	_energy_bar.show_percentage = false
	_energy_bar.custom_minimum_size = Vector2(0, 10)
	_energy_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_energy_bar.add_theme_stylebox_override("background", UI.panel_box(Palette.PANEL, Color.TRANSPARENT, 5))
	_energy_bar.add_theme_stylebox_override("fill", UI.panel_box(Palette.ENERGY, Color.TRANSPARENT, 5))
	erow.add_child(_energy_bar)

	_energy = UI.label("0/0", 15, Palette.ENERGY, HORIZONTAL_ALIGNMENT_RIGHT)
	_energy.custom_minimum_size = Vector2(120, 0)
	erow.add_child(_energy)

	return panel


func _build_rail() -> Control:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UI.panel_box(Palette.RAIL, Color.TRANSPARENT, 0))
	panel.custom_minimum_size = Vector2(RAIL_WIDTH, 0)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 2)
	panel.add_child(col)

	for s in SECTIONS:
		var b := Button.new()
		b.custom_minimum_size = Vector2(0, 74)
		b.focus_mode = Control.FOCUS_NONE
		b.tooltip_text = str(s["label"])
		b.pressed.connect(_open.bind(str(s["id"])))

		var inner := VBoxContainer.new()
		inner.mouse_filter = Control.MOUSE_FILTER_IGNORE
		inner.set_anchors_preset(Control.PRESET_FULL_RECT)
		inner.alignment = BoxContainer.ALIGNMENT_CENTER
		inner.add_theme_constant_override("separation", 2)
		inner.add_child(UI.label(str(s["glyph"]), 24, Palette.TEXT_DIM, HORIZONTAL_ALIGNMENT_CENTER))
		inner.add_child(UI.label(str(s["label"]), 11, Palette.TEXT_FAINT, HORIZONTAL_ALIGNMENT_CENTER))
		b.add_child(inner)

		col.add_child(b)
		_rail_buttons[str(s["id"])] = b

	return panel


func _open(id: String) -> void:
	_current = id
	_style_rail()

	for c in _content.get_children():
		c.queue_free()
	for c in _action_host.get_children():
		c.queue_free()

	var section: Dictionary = {}
	for s in SECTIONS:
		if s["id"] == id:
			section = s

	const TABS := {
		"collect": "res://scenes/tabs/collect.gd",
		"shop": "res://scenes/tabs/shop.gd",
		"inventory": "res://scenes/tabs/inventory.gd",
		"soldiers": "res://scenes/tabs/barracks.gd",
	}
	if TABS.has(id):
		var tab: Node = load(TABS[id]).new()
		_content.add_child(tab)
		tab.mount_action_bar(_action_host)
		return

	_content.add_child(_placeholder(str(section.get("label", id)), str(section.get("milestone", ""))))


func _placeholder(title: String, milestone: String) -> Control:
	var col := VBoxContainer.new()
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override("separation", 10)
	col.add_child(UI.label(title.to_upper(), 28, Palette.TEXT_DIM, HORIZONTAL_ALIGNMENT_CENTER))
	col.add_child(UI.label("arrives in " + milestone, 15, Palette.TEXT_FAINT, HORIZONTAL_ALIGNMENT_CENTER))
	return col


func _style_rail() -> void:
	for id in _rail_buttons:
		var b: Button = _rail_buttons[id]
		var active: bool = id == _current
		var bg := Palette.PANEL if active else Color.TRANSPARENT
		b.add_theme_stylebox_override("normal", UI.panel_box(bg, Color.TRANSPARENT, 0))
		b.add_theme_stylebox_override("hover", UI.panel_box(Palette.PANEL_HIGH, Color.TRANSPARENT, 0))
		b.add_theme_stylebox_override("pressed", UI.panel_box(Palette.PANEL, Color.TRANSPARENT, 0))
		var inner := b.get_child(0)
		inner.get_child(0).add_theme_color_override("font_color", Palette.GOLD if active else Palette.TEXT_DIM)
		inner.get_child(1).add_theme_color_override("font_color", Palette.TEXT_DIM if active else Palette.TEXT_FAINT)


func _on_state_changed() -> void:
	if not GameState.has_state():
		return
	var p := GameState.player()
	_level.text = "Lv %d" % int(p.get("level", 1))
	_gold.text = UI.number(GameState.display_gold())
	_update_energy()


func _update_energy() -> void:
	if not GameState.has_state():
		return
	var cur := GameState.display_energy()
	var mx := GameState.max_energy()
	_energy_bar.max_value = maxf(float(mx), 1.0)
	_energy_bar.value = float(cur)
	var secs := int(GameState.snapshot.get("energy", {}).get("seconds_to_full", 0))
	_energy.text = "%d/%d  %s" % [cur, mx, UI.duration(secs)]


func _tick() -> void:
	_update_energy()


func _on_action_failed(message: String) -> void:
	_flash(message, Palette.DANGER)


func _flash(message: String, color: Color) -> void:
	_toast.add_theme_color_override("font_color", color)
	_toast.text = message
	var tween := create_tween()
	tween.tween_interval(2.2)
	tween.tween_callback(func() -> void: _toast.text = "")
