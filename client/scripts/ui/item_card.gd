class_name ItemCard
extends Button
## One item, drawn the same way everywhere it appears.
##
## Tier is signalled three ways at once — frame colour, the tier name, and a pip
## count — because roughly 8% of a male-skewed audience cannot reliably separate
## the gray/green/blue/violet/gold/magenta/red ladder by hue.

const PIPS := {"common": 1, "uncommon": 2, "rare": 3, "epic": 4, "legendary": 5, "mystic": 6, "special": 7}

var item: Dictionary

var _icon: TextureRect
var _name: Label
var _tier: Label
var _stats: Label
var _foot: Label


func _init(p_item: Dictionary) -> void:
	item = p_item
	custom_minimum_size = Vector2(0, UI.TAP_ROW)
	focus_mode = Control.FOCUS_NONE


func _ready() -> void:
	var margin := MarginContainer.new()
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right"]:
		margin.add_theme_constant_override("margin_" + side, 10)
	add_child(margin)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	margin.add_child(row)

	_icon = TextureRect.new()
	_icon.custom_minimum_size = Vector2(64, 64)
	_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(_icon)

	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override("separation", 1)
	row.add_child(col)

	_name = UI.label("", UI.F_BODY, Palette.TEXT)
	col.add_child(_name)
	_tier = UI.label("", UI.F_MICRO, Palette.TEXT_DIM)
	col.add_child(_tier)
	_stats = UI.label("", UI.F_CAPTION, Palette.TEXT_DIM)
	col.add_child(_stats)

	_foot = UI.label("", UI.F_CAPTION, Palette.GOLD, HORIZONTAL_ALIGNMENT_RIGHT)
	_foot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(_foot)

	refresh(item)


func refresh(p_item: Dictionary) -> void:
	item = p_item
	var tier := str(item.get("tier", "common"))
	var colour := Palette.tier(tier)

	_icon.texture = ArtRegistry.item_icon(str(item.get("art", "")), tier)
	_name.text = str(item.get("name", ""))

	var pips := "*".repeat(PIPS.get(tier, 1))
	var extra := "  MASTERWORK" if bool(item.get("masterwork", false)) else ""
	_tier.text = "%s %s   ilvl %d   q%d%%%s" % [
		tier.to_upper(), pips, int(item.get("ilvl", 0)), int(item.get("quality_pct", 100)), extra]
	_tier.add_theme_color_override("font_color", colour)

	var parts: Array[String] = []
	if int(item.get("attack", 0)) > 0:
		parts.append("ATK %d" % int(item.get("attack", 0)))
	if int(item.get("defense", 0)) > 0:
		parts.append("DEF %d" % int(item.get("defense", 0)))
	if int(item.get("speed", 0)) > 0:
		parts.append("SPD %d" % int(item.get("speed", 0)))
	_stats.text = "   ".join(parts)

	var border := colour
	var bg := Palette.PANEL
	if bool(item.get("equipped", false)):
		bg = Palette.PANEL_HIGH
	add_theme_stylebox_override("normal", UI.panel_box(bg, border))
	add_theme_stylebox_override("hover", UI.panel_box(Palette.PANEL_HIGH, border))
	add_theme_stylebox_override("pressed", UI.panel_box(Palette.PANEL, border))


## Sets the right-hand text — a price in the shop, a sell value in the armory.
func set_footer(text: String, colour: Color) -> void:
	_foot.text = text
	_foot.add_theme_color_override("font_color", colour)
