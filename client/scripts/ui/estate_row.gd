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
var _icon: TextureRect

var _icon_dir := ""

const ICON_SIZE := UI.ICON_LG

## Name, up to two lines of blurb, and the effect line. Fixed rather than sized to
## content: the blurb autowraps, and a wrapping label's minimum height depends on
## the width it is given, which depends on the row -- so letting the row follow the
## text is circular. Two lines is enough for every blurb we ship, and the height
## being predictable is what keeps a list of them from jittering as it loads.
const ROW_H := 124
const BLURB_LINES := 2


func _init(p_id: String, p_icon_dir: String = "") -> void:
	id = p_id
	_icon_dir = p_icon_dir
	custom_minimum_size = Vector2(0, ROW_H)
	focus_mode = Control.FOCUS_NONE


func _ready() -> void:
	var margin := MarginContainer.new()
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right"]:
		margin.add_theme_constant_override("margin_" + side, 12)
	for side in ["top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 10)
	add_child(margin)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	margin.add_child(row)

	# The same row serves Keep upgrades and Territory holdings, so the caller says
	# which family of art to draw from. Both are lists of otherwise identical rows.
	if _icon_dir != "":
		_icon = TextureRect.new()
		_icon.texture = ArtRegistry.ui_icon(_icon_dir + "/" + id)
		_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		_icon.custom_minimum_size = Vector2(ICON_SIZE, ICON_SIZE)
		_icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(_icon)

	_level = UI.label("", UI.F_CAPTION, Palette.GOLD_DEEP)
	_level.custom_minimum_size = Vector2(64, 0)
	_level.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(_level)

	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override("separation", 1)
	row.add_child(col)

	_name = UI.label("", UI.F_BODY, Palette.TEXT)
	col.add_child(_name)
	_blurb = UI.label("", UI.F_CAPTION, Palette.TEXT_DIM)
	_blurb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	# Without a line cap a long blurb silently grew past the row and printed over
	# the next one; with it, the overflow becomes an ellipsis.
	_blurb.max_lines_visible = BLURB_LINES
	_blurb.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_blurb.custom_minimum_size = Vector2(0, UI.F_CAPTION * BLURB_LINES * 1.35)
	col.add_child(_blurb)
	_effect = UI.label("", UI.F_CAPTION, Palette.SUCCESS)
	col.add_child(_effect)

	_cost = UI.label("", UI.F_BODY, Palette.GOLD, HORIZONTAL_ALIGNMENT_RIGHT)
	_cost.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_cost.custom_minimum_size = Vector2(110, 0)
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

	if _icon != null:
		if locked:
			_icon.modulate = Palette.TEXT_FAINT
		elif selected:
			_icon.modulate = Palette.GOLD
		else:
			_icon.modulate = Palette.TEXT

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

	add_theme_stylebox_override("normal", UI.card_box(selected, locked))
	add_theme_stylebox_override("hover", UI.card_box(true, locked))
	add_theme_stylebox_override("pressed", UI.skin("ghost_press", Palette.PANEL, 14, 10))
	# A locked or maxed row is disabled, and without its own box it would fall
	# back to the engine default and vanish.
	add_theme_stylebox_override("disabled", UI.card_box(false, true))
	disabled = locked or maxed
