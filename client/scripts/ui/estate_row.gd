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
var _col: VBoxContainer

var _icon_dir := ""

const ICON_SIZE := UI.ICON_LG

## Name, up to two lines of blurb, and -- once you own one -- a line saying what
## it currently earns.
##
## The height is MEASURED from the content rather than fixed. It used to be a
## constant, and the constant did not allow for the effect line, so the moment you
## bought an estate the sentence telling you what it pays was sliced in half by
## the row below. It is not circular to measure: the blurb is capped at two lines
## with an explicit minimum height, so the column's minimum is deterministic.
const ROW_MIN_H := 118
const PAD_V := 10
const BLURB_LINES := 2


func _init(p_id: String, p_icon_dir: String = "") -> void:
	id = p_id
	_icon_dir = p_icon_dir
	custom_minimum_size = Vector2(0, ROW_MIN_H)
	focus_mode = Control.FOCUS_NONE


func _ready() -> void:
	var margin := MarginContainer.new()
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right"]:
		margin.add_theme_constant_override("margin_" + side, 12)
	for side in ["top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, PAD_V)
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

	_col = VBoxContainer.new()
	var col := _col
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

	_cost = UI.label("", UI.F_BODY, Palette.GOLD_INK, HORIZONTAL_ALIGNMENT_RIGHT)
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
	# Grow to fit whatever is actually shown. Without this the effect line, which
	# only appears once the estate is owned, is cut off by the next row.
	custom_minimum_size.y = maxf(ROW_MIN_H,
		_col.get_combined_minimum_size().y + PAD_V * 2)

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
		_cost.add_theme_color_override("font_color", Palette.GOLD_INK if affordable else Palette.DANGER)

	add_theme_stylebox_override("normal", UI.card_box(selected, locked))
	add_theme_stylebox_override("hover", UI.card_box(true, locked))
	add_theme_stylebox_override("pressed", UI.skin("ghost_press", Palette.PANEL, 14, 10))
	# A locked or maxed row is disabled, and without its own box it would fall
	# back to the engine default and vanish.
	add_theme_stylebox_override("disabled", UI.card_box(false, true))
	disabled = locked or maxed
