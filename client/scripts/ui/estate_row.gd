class_name EstateRow
extends Button
## One upgradeable thing — a Family upgrade or a Territory holding.
##
## Both trees are the same shape (name, level, effect, next price), so they share
## a row rather than each growing their own near-identical copy.

var id := ""

var _name: Label
var _blurb: Label
var _effect: Label
var _cost: Label
var _level: Label


func _init(p_id: String) -> void:
	id = p_id
	custom_minimum_size = Vector2(0, 82)
	focus_mode = Control.FOCUS_NONE


func _ready() -> void:
	var margin := MarginContainer.new()
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right"]:
		margin.add_theme_constant_override("margin_" + side, 12)
	add_child(margin)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	margin.add_child(row)

	_level = UI.label("", 15, Palette.GOLD_DEEP)
	_level.custom_minimum_size = Vector2(46, 0)
	_level.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(_level)

	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override("separation", 1)
	row.add_child(col)

	_name = UI.label("", 17, Palette.TEXT)
	col.add_child(_name)
	_blurb = UI.label("", 12, Palette.TEXT_FAINT)
	_blurb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(_blurb)
	_effect = UI.label("", 13, Palette.SUCCESS)
	col.add_child(_effect)

	_cost = UI.label("", 16, Palette.GOLD, HORIZONTAL_ALIGNMENT_RIGHT)
	_cost.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_cost.custom_minimum_size = Vector2(72, 0)
	row.add_child(_cost)


## `effect` describes what the current level already does; `next` what the next
## level would add. Showing both is what makes an upgrade legible before buying.
func refresh(name: String, blurb: String, level: int, max_level: int,
		effect: String, cost: int, locked: bool, lock_reason: String,
		affordable: bool, selected: bool) -> void:
	_name.text = name
	_name.add_theme_color_override("font_color", Palette.TEXT if not locked else Palette.TEXT_FAINT)
	_blurb.text = blurb if not locked else lock_reason
	_level.text = "%d/%d" % [level, max_level]
	_effect.text = effect
	_effect.visible = effect != ""

	var maxed := level >= max_level
	if maxed:
		_cost.text = "MAX"
		_cost.add_theme_color_override("font_color", Palette.SUCCESS)
	elif locked:
		_cost.text = "—"
		_cost.add_theme_color_override("font_color", Palette.TEXT_FAINT)
	else:
		_cost.text = UI.number(cost)
		_cost.add_theme_color_override("font_color", Palette.GOLD if affordable else Palette.DANGER)

	var border := Palette.GOLD_DEEP if selected else Color.TRANSPARENT
	var bg := Palette.PANEL
	if locked:
		bg = Palette.BG
	elif selected:
		bg = Palette.PANEL_HIGH
	add_theme_stylebox_override("normal", UI.panel_box(bg, border))
	add_theme_stylebox_override("hover", UI.panel_box(Palette.PANEL_HIGH, border))
	add_theme_stylebox_override("pressed", UI.panel_box(Palette.PANEL, border))
	disabled = locked or maxed
