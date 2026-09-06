extends CanvasLayer
## The sections the rail cannot carry.
##
## The rail is drawn at the reference's proportions -- a 152-unit column of
## 112-unit plates -- and at that size exactly six fit above the fold on the
## shortest device we ship to. This is where the other three live. They are the
## three you visit deliberately rather than flick between, and they are one tap
## away rather than zero.
##
## A CanvasLayer, not a Control parented to the shell: a Control does not
## reliably inherit the window rect, and an earlier full-screen overlay in this
## project ended up drawn in a corner because of it.

signal chose(id: String)

const ROW_H := 112

## The section entries themselves, handed in by the shell. Reaching back through
## get_parent() for the shell's SECTIONS const does not work -- a const is not a
## property, so Object.get() returns null for it.
var _sections: Array = []


func _init(p_sections: Array) -> void:
	_sections = p_sections


func _ready() -> void:
	layer = 20

	var dim := ColorRect.new()
	dim.color = Color(Palette.BG.r * 0.4, Palette.BG.g * 0.4, Palette.BG.b * 0.4, 0.93)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	# Tapping the backdrop closes, which is the gesture people try first.
	dim.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and e.pressed:
			_close())
	add_child(dim)

	var centre := CenterContainer.new()
	centre.mouse_filter = Control.MOUSE_FILTER_IGNORE
	SafeArea.wrap(self, Vector4(16, 16, 16, 16)).add_child(centre)

	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", UI.skin("panel_gold", Palette.PANEL, 22, 20))
	card.custom_minimum_size = Vector2(460, 0)
	centre.add_child(card)

	var pad := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		pad.add_theme_constant_override("margin_" + side, 18)
	card.add_child(pad)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", UI.GAP_S)
	pad.add_child(col)

	col.add_child(UI.screen_title("More"))
	col.add_child(UI.spacer(UI.GAP_XS))

	for sec in _sections:
		col.add_child(_row(sec))

	col.add_child(UI.spacer(UI.GAP_S))
	var close := UI.ghost_button("Close", UI.F_BODY)
	close.custom_minimum_size = Vector2(0, UI.TAP_PRIMARY)
	close.pressed.connect(_close)
	col.add_child(close)


## One section, drawn as the rail draws them: icon, then the word.
func _row(sec: Dictionary) -> Control:
	var id := str(sec.get("id", ""))
	var b := Button.new()
	b.custom_minimum_size = Vector2(0, ROW_H)
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_stylebox_override("normal", UI.skin("nav", Palette.RAIL, 14, 8))
	b.add_theme_stylebox_override("hover", UI.skin("nav_active", Palette.BANNER, 14, 8))
	b.add_theme_stylebox_override("pressed", UI.skin("nav_active", Palette.BANNER, 14, 8))
	b.pressed.connect(func() -> void:
		chose.emit(id)
		_close())

	var margin := MarginContainer.new()
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right"]:
		margin.add_theme_constant_override("margin_" + side, 22)
	b.add_child(margin)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", UI.GAP_L)
	margin.add_child(row)

	var icon := TextureRect.new()
	icon.texture = ArtRegistry.ui_icon(str(sec.get("icon", "")))
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.custom_minimum_size = Vector2(UI.ICON_LG, UI.ICON_LG)
	icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	icon.modulate = Palette.TEXT_DIM
	row.add_child(icon)

	var word := UI.label(str(sec.get("label", id)), UI.F_H2, Palette.TEXT)
	word.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	word.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(word)

	return b


func _close() -> void:
	queue_free()
