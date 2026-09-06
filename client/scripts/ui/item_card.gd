class_name ItemCard
extends Button
## One item, drawn the same way everywhere it appears.
##
## Tier is signalled by the frame colour AND by the tier name in words, because
## roughly 8% of a male-skewed audience cannot reliably separate the
## gray/green/blue/violet/gold/magenta/red ladder by hue. The design's rule is
## "never colour alone"; the pips used to be a third channel, but they only ever
## repeated what the word already said, and the line read as line noise.
##
## ilvl and quality are gone from the card too. Quality already moves ATK and DEF,
## which are right there -- printing the multiplier as well was showing the
## working rather than the answer.

var item: Dictionary

var _icon: TextureRect
var _stripe: ColorRect
var _name: Label
var _tier: Label
var _stats: Label
var _foot: Label


func _init(p_item: Dictionary) -> void:
	item = p_item
	custom_minimum_size = Vector2(0, UI.TAP_ROW)
	focus_mode = Control.FOCUS_NONE


func _ready() -> void:
	# The tier as a stripe down the leading edge instead of an outline round the
	# whole card. An outline in seven different colours makes a list look like a
	# box of highlighters; a stripe reads at a glance, leaves the card itself a
	# consistent surface, and still is not the ONLY signal -- the tier name is
	# spelled out two lines below it.
	_stripe = ColorRect.new()
	_stripe.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stripe.anchor_bottom = 1.0
	_stripe.offset_left = 6
	_stripe.offset_top = 10
	_stripe.offset_right = 12
	_stripe.offset_bottom = -10
	add_child(_stripe)

	var margin := MarginContainer.new()
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 22)
	margin.add_theme_constant_override("margin_right", 10)
	add_child(margin)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	margin.add_child(row)

	_icon = TextureRect.new()
	_icon.custom_minimum_size = Vector2(UI.ICON_XL, UI.ICON_XL)
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

	_foot = UI.label("", UI.F_CAPTION, Palette.GOLD_INK, HORIZONTAL_ALIGNMENT_RIGHT)
	_foot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(_foot)

	refresh(item)


func refresh(p_item: Dictionary) -> void:
	item = p_item
	var tier := str(item.get("tier", "common"))
	var colour := Palette.tier(tier)

	_icon.texture = ArtRegistry.item_icon(str(item.get("art", "")), tier)
	_name.text = str(item.get("name", ""))

	var extra := "   MASTERWORK" if bool(item.get("masterwork", false)) else ""
	_tier.text = tier.to_upper() + extra
	_tier.add_theme_color_override("font_color", colour)

	var parts: Array[String] = []
	if int(item.get("attack", 0)) > 0:
		parts.append("ATK %d" % int(item.get("attack", 0)))
	if int(item.get("defense", 0)) > 0:
		parts.append("DEF %d" % int(item.get("defense", 0)))
	if int(item.get("speed", 0)) > 0:
		parts.append("SPD %d" % int(item.get("speed", 0)))
	_stats.text = "   ".join(parts)

	_stripe.color = colour
	var equipped := bool(item.get("equipped", false))
	add_theme_stylebox_override("normal", UI.card_box(equipped))
	add_theme_stylebox_override("hover", UI.card_box(true))
	add_theme_stylebox_override("pressed", UI.skin("ghost_press", Palette.PANEL, 14, 10))
	# Without this a card you cannot afford falls back to the engine's default
	# disabled box, which on this theme is very nearly invisible -- so the
	# expensive half of the shop looked like it had no cards at all.
	add_theme_stylebox_override("disabled", UI.card_box(false, true))


## Sets the right-hand text — a price in the shop, a sell value in the armory.
func set_footer(text: String, colour: Color) -> void:
	_foot.text = text
	_foot.add_theme_color_override("font_color", colour)
