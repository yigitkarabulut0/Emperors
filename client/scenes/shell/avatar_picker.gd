extends CanvasLayer
## The portrait picker.
##
## A CanvasLayer, not a Control parented to the scene: a Control does not reliably
## inherit the window rect, and an earlier full-screen overlay in this project
## ended up drawn in a corner because of it.

signal chosen(avatar: String)

const COLUMNS := 4
const TILE := 96

var _current := ""
var _grid: GridContainer
var _busy := false


func _init(p_current: String) -> void:
	_current = p_current


func _ready() -> void:
	layer = 20

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.72)
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
	card.add_theme_stylebox_override("panel", UI.panel_box(Palette.PANEL, Palette.GOLD_DEEP))
	centre.add_child(card)

	var pad := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		pad.add_theme_constant_override("margin_" + side, 18)
	card.add_child(pad)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 12)
	pad.add_child(col)
	col.add_child(UI.label("Choose your portrait", UI.F_H2, Palette.TEXT, HORIZONTAL_ALIGNMENT_CENTER))

	_grid = GridContainer.new()
	_grid.columns = COLUMNS
	_grid.add_theme_constant_override("h_separation", 10)
	_grid.add_theme_constant_override("v_separation", 10)
	col.add_child(_grid)

	var close := Button.new()
	close.text = "Close"
	close.focus_mode = Control.FOCUS_NONE
	close.pressed.connect(_close)
	col.add_child(close)

	_load()


func _load() -> void:
	var res: Api.Response = await Api.get_json("/v1/avatars")
	if not res.ok:
		_grid.add_child(UI.label("Could not load portraits.", UI.F_CAPTION, Palette.DANGER))
		return
	for c in _grid.get_children():
		c.queue_free()
	for a in res.data.get("avatars", []):
		_grid.add_child(_tile(str(a.get("id", "")), bool(a.get("selected", false))))


func _tile(id: String, selected: bool) -> Control:
	var b := Button.new()
	b.custom_minimum_size = Vector2(TILE, TILE)
	b.focus_mode = Control.FOCUS_NONE
	b.tooltip_text = id
	var border := Palette.GOLD if selected else Color.TRANSPARENT
	b.add_theme_stylebox_override("normal", UI.panel_box(Palette.PANEL_HIGH, border))
	b.add_theme_stylebox_override("hover", UI.panel_box(Palette.PANEL_HIGH, Palette.GOLD_DEEP))
	b.add_theme_stylebox_override("pressed", UI.panel_box(Palette.PANEL, Palette.GOLD))
	b.pressed.connect(_pick.bind(id))

	var img := TextureRect.new()
	img.mouse_filter = Control.MOUSE_FILTER_IGNORE
	img.set_anchors_preset(Control.PRESET_FULL_RECT)
	img.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	img.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	img.texture = ArtRegistry.portrait(id)
	if not selected:
		img.modulate = Color(1, 1, 1, 0.82)
	b.add_child(img)
	return b


func _pick(id: String) -> void:
	# Single-flight: the picker writes through the action sequence, and a second
	# tap while the first is in the air would be rejected as stale anyway.
	if _busy or id == _current:
		_close()
		return
	_busy = true
	var res: Api.Response = await Api.post_json("/v1/avatar",
		{"avatar": id, "action_seq": int(GameState.player().get("action_seq", 0)) + 1})
	_busy = false
	if res.ok:
		GameState.adopt(res.data)
		GameState.changed.emit()
		chosen.emit(id)
	else:
		GameState.action_failed.emit(res.error)
	_close()


func _close() -> void:
	queue_free()
