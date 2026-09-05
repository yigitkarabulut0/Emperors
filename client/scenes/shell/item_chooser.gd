extends CanvasLayer
## Picks an item out of the armory for one equipment slot.
##
## Filtered to the slot, sorted by power, and it says what each item would do to
## the unit you are looking at -- the comparison is the whole point of the
## screen, and making a player hold two stat lines in their head between tabs is
## how gear systems become unreadable.

signal picked

var _slot := ""
var _owner_id := ""
var _is_hero := false
var _busy := false
var _list: VBoxContainer
var _scroll: ScrollContainer
var _equipped_power := 0
var _worn := ""


func _init(p_slot: String, p_owner_id: String, p_is_hero: bool) -> void:
	_slot = p_slot
	_owner_id = p_owner_id
	_is_hero = p_is_hero


func _ready() -> void:
	layer = 22

	var dim := ColorRect.new()
	dim.color = Color(Palette.BG.r * 0.4, Palette.BG.g * 0.4, Palette.BG.b * 0.4, 0.93)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and e.pressed and not _busy:
			queue_free())
	add_child(dim)

	# 48 units of top margin used to be the whole notch strategy, and on a phone
	# with a Dynamic Island the card ran about 50 units underneath it. A
	# CanvasLayer is not a Control and cannot inherit the shell's insets, so it
	# asks for them directly.
	var margin := SafeArea.wrap(self, Vector4(UI.GAP_L, UI.GAP_L, UI.GAP_L, UI.GAP_L))

	# Sized to what is in it, not to the screen. It used to stretch to every edge,
	# so choosing from an empty armory was a full-screen black box with two lines
	# of small text stranded at the top of it.
	var centre := CenterContainer.new()
	centre.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(centre)

	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(620, 0)
	card.add_theme_stylebox_override("panel", UI.skin("panel_gold", Palette.PANEL, 22, 20))
	centre.add_child(card)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", UI.GAP_M)
	card.add_child(col)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", UI.GAP_S)
	col.add_child(head)
	var glyph := TextureRect.new()
	glyph.texture = ArtRegistry.ui_icon("slots/" + _slot)
	glyph.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	glyph.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	glyph.custom_minimum_size = Vector2(UI.ICON_MD, UI.ICON_MD)
	glyph.modulate = Palette.GOLD
	glyph.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(glyph)
	var title := UI.label("Choose a " + _slot, UI.F_H1, Palette.TEXT)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)

	# A ceiling rather than a fill: the card grows with the list up to about half
	# the screen and scrolls past that, instead of always being full height.
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 0)
	scroll.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED

	# Lists follow your finger. Godot's own touch scrolling is gated behind

	# is_touchscreen_available() and is eaten by the buttons the list is made of.

	DragScroll.install(scroll)
	col.add_child(scroll)

	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 6)
	scroll.add_child(_list)

	_scroll = scroll

	var close := UI.ghost_button("Cancel", UI.F_BODY)
	close.custom_minimum_size = Vector2(0, UI.TAP_PRIMARY)
	close.pressed.connect(func() -> void: queue_free())
	col.add_child(close)

	_load()


func _load() -> void:
	var res: Api.Response = await Api.get_json("/v1/inventory")
	if not res.ok:
		_list.add_child(UI.label("Could not load your armory.", UI.F_CAPTION, Palette.DANGER))
		return

	# Anything already worn by someone else is not offered. Equipping it would
	# silently strip another unit, and a stat change you did not ask for is worse
	# than a shorter list.
	var me := "hero" if _is_hero else _owner_id
	var mine: Array = []
	for it in res.data.get("items", []):
		if str(it.get("slot", "")) != _slot:
			continue
		var on := str(it.get("equipped_on", ""))
		if on == me:
			_equipped_power = int(it.get("power", 0))
			_worn = str(it.get("id", ""))
			continue
		if on != "":
			continue
		mine.append(it)
	mine.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.get("power", 0)) > int(b.get("power", 0)))

	for c in _list.get_children():
		c.queue_free()
	if _equipped_power > 0:
		_list.add_child(_unequip_row())
	if mine.is_empty():
		# An empty state that says what to do about it, rather than reporting a
		# fact and leaving the player in a black box.
		var empty := VBoxContainer.new()
		empty.add_theme_constant_override("separation", UI.GAP_S)
		empty.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var mark := TextureRect.new()
		mark.texture = ArtRegistry.ui_icon("slots/" + _slot)
		mark.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		mark.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		mark.custom_minimum_size = Vector2(0, UI.ICON_XL)
		mark.modulate = Palette.EMPTY_SLOT
		empty.add_child(mark)
		empty.add_child(UI.label("Nothing in your armory fits this slot.",
			UI.F_BODY, Palette.TEXT_DIM, HORIZONTAL_ALIGNMENT_CENTER))
		empty.add_child(UI.label("The Market restocks every few minutes.",
			UI.F_CAPTION, Palette.TEXT_FAINT, HORIZONTAL_ALIGNMENT_CENTER))
		_list.add_child(empty)
		_fit_scroll()
		return
	for it in mine:
		_list.add_child(_row(it))
	_fit_scroll()


## Grows the scroll view to its content, up to a ceiling.
##
## A ScrollContainer has no intrinsic minimum height -- that is the whole point
## of one -- so with nothing else driving it the list collapsed to nothing and
## the card showed a title and a Cancel button with a void between them. This
## gives it the height it wants and caps it, so a short list makes a short card
## and a long one scrolls.
const MAX_LIST_H := 620.0

func _fit_scroll() -> void:
	if _scroll == null or not is_instance_valid(_scroll):
		return
	await get_tree().process_frame
	if not is_instance_valid(_scroll) or not is_instance_valid(_list):
		return
	_scroll.custom_minimum_size.y = minf(_list.get_combined_minimum_size().y, MAX_LIST_H)


func _row(item: Dictionary) -> Control:
	var b := Button.new()
	b.custom_minimum_size = Vector2(0, UI.TAP_ROW_TIGHT)
	b.focus_mode = Control.FOCUS_NONE
	var tier := str(item.get("tier", "common"))
	b.add_theme_stylebox_override("normal", UI.panel_box(Palette.PANEL_HIGH, Palette.tier(tier)))
	b.add_theme_stylebox_override("hover", UI.panel_box(Palette.PANEL_HIGH, Palette.GOLD))
	b.pressed.connect(_equip.bind(str(item.get("id", ""))))

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
	icon.texture = ArtRegistry.item_icon(str(item.get("art", "")), tier)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.custom_minimum_size = Vector2(46, 46)
	icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(icon)

	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override("separation", 1)
	col.add_child(UI.label(str(item.get("name", "")), UI.F_CAPTION, Palette.TEXT))
	col.add_child(UI.label("ATK %d   DEF %d   SPD %d" % [
		int(item.get("attack", 0)), int(item.get("defense", 0)), int(item.get("speed", 0))],
		UI.F_MICRO, Palette.tier(tier)))
	row.add_child(col)

	# The number that actually decides it: better or worse than what is worn.
	var delta := int(item.get("power", 0)) - _equipped_power
	var mark := "+%d" % delta if delta > 0 else str(delta)
	var tint := Palette.SUCCESS if delta > 0 else (Palette.DANGER if delta < 0 else Palette.TEXT_FAINT)
	var d := UI.label(mark, 16, tint, HORIZONTAL_ALIGNMENT_RIGHT)
	d.custom_minimum_size = Vector2(56, 0)
	d.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(d)
	return b


func _unequip_row() -> Control:
	var b := Button.new()
	b.custom_minimum_size = Vector2(0, UI.TAP_MIN)
	b.focus_mode = Control.FOCUS_NONE
	b.text = "Take off what is worn"
	b.add_theme_stylebox_override("normal", UI.panel_box(Palette.BG, Palette.TEXT_FAINT))
	b.pressed.connect(_unequip)
	return b


func _equip(item_id: String) -> void:
	if _busy:
		return
	_busy = true
	var seq := int(GameState.player().get("action_seq", 0)) + 1
	var res: Api.Response
	if _is_hero:
		res = await Api.post_json("/v1/inventory/equip", {"item_id": item_id, "action_seq": seq})
	else:
		res = await Api.post_json("/v1/army/equip",
			{"soldier_id": _owner_id, "item_id": item_id, "action_seq": seq})
	_finish(res)


func _unequip() -> void:
	if _busy:
		return
	_busy = true
	# One endpoint for both: from the player's side there is only ever the one
	# gesture, take this off, and the server clears whichever holder had it.
	var res: Api.Response = await Api.post_json("/v1/inventory/unequip",
		{"item_id": _worn, "action_seq": int(GameState.player().get("action_seq", 0)) + 1})
	_finish(res)


func _finish(res: Api.Response) -> void:
	_busy = false
	if res.ok:
		await GameState.refresh()
		picked.emit()
		queue_free()
	else:
		GameState.action_failed.emit(res.error)
