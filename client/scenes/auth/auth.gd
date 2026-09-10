extends Control
## Sign in / create account.
##
## Set on the splash painting -- the EMPERORS crest over the castle and the red
## carpet, the picture iOS shows before the game runs -- with the form in the
## dialogs' own plate below the crest. It used to be the only screen with no
## painting at all: a navy ground, two flat boxes and two flat-coloured buttons.
##
## The form sits low, under the crest, and a phone's keyboard rises over the
## bottom half of the screen; so while a field has the keyboard the plate lifts
## to sit just above it, and settles back when the keyboard goes.

const ART := Vector2(860.0, 1864.0)       ## branding/launch@2x
const W := 941.0
const PANEL_W := 760.0
const PAD := 34.0
const FIELD_H := 86.0
const BUTTON_H := 96.0
const GAP := 16.0

var _art: TextureRect
var _veil: TextureRect
var _foot: ColorRect
var _panel: NinePatchRect
var _column: VBoxContainer
var _user: LineEdit
var _pass: LineEdit
var _msg: Label
var _busy := false
var _rest_y := 0.0


func _ready() -> void:
	var bg := ColorRect.new()
	bg.color = UI.GROUND
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	_art = UI.image("branding/launch@2x", Rect2())
	add_child(_art)
	# The carpet darkens toward the form, so the plate reads against it.
	_veil = TextureRect.new()
	var g := Gradient.new()
	g.set_color(0, Color(UI.GROUND, 0.0))
	g.set_color(1, Color(UI.GROUND, 0.96))
	var gt := GradientTexture2D.new()
	gt.gradient = g
	gt.fill_from = Vector2(0, 0)
	gt.fill_to = Vector2(0, 1)
	gt.width = 4
	gt.height = 128
	_veil.texture = gt
	_veil.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_veil.stretch_mode = TextureRect.STRETCH_SCALE
	_veil.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_veil)
	_foot = ColorRect.new()
	_foot.color = Color(UI.GROUND, 0.96)
	_foot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_foot)

	_panel = NinePatchRect.new()
	_panel.texture = Art.tex(Dialog.PLATE)
	for m in ["left", "top", "right", "bottom"]:
		_panel.set("patch_margin_" + m, Dialog.PLATE_MARGIN)
	add_child(_panel)
	_column = VBoxContainer.new()
	_column.add_theme_constant_override("separation", int(GAP))
	_panel.add_child(_column)

	var title := UI.label("ENTER THE REALM", 34, UI.GOLD, "title", 700, HORIZONTAL_ALIGNMENT_CENTER)
	_column.add_child(title)
	_user = UI.field("Username", 30)
	_user.max_length = 16
	_user.custom_minimum_size.y = FIELD_H
	_column.add_child(_user)
	_pass = UI.field("Password", 30, true)
	_pass.custom_minimum_size.y = FIELD_H
	_column.add_child(_pass)
	_user.text_submitted.connect(func(_t: String) -> void: _pass.grab_focus())
	_pass.text_submitted.connect(func(_t: String) -> void: _sign_in())

	var sign_in := _button("SIGN IN", Dialog.CONFIRM_PLATE, Color("#F3FBF3"))
	sign_in.pressed.connect(_sign_in)
	_column.add_child(sign_in)
	var create := _button("CREATE ACCOUNT", Dialog.QUIET_PLATE, UI.INK)
	create.pressed.connect(_create)
	_column.add_child(create)

	_msg = UI.label("", 25, UI.RED, "body", 500, HORIZONTAL_ALIGNMENT_CENTER)
	_msg.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_msg.custom_minimum_size = Vector2(PANEL_W - PAD * 2.0, 64)
	_column.add_child(_msg)
	# Arriving here because the server ended the session: say so, rather than
	# dropping a player who was mid-game onto an empty form.
	if Session.ended_reason != "":
		_msg.text = Session.ended_reason
		_msg.label_settings.font_color = UI.GOLD

	resized.connect(_lay_out)
	_lay_out.call_deferred()


func _button(word: String, plate: String, col: Color) -> Button:
	var b := UI.plate_face(plate, 16)
	b.text = word
	b.custom_minimum_size = Vector2(0, BUTTON_H)
	b.add_theme_font_override("font", UI.font("title", 700))
	b.add_theme_font_size_override("font_size", 30)
	for c in ["font_color", "font_hover_color", "font_pressed_color"]:
		b.add_theme_color_override(c, col)
	b.add_theme_constant_override("outline_size", 0)
	return b


## The painting covers the screen with its foot on the screen's foot, so a
## shorter phone loses sky rather than the crest; the plate sits under the
## crest, over the carpet.
func _lay_out() -> void:
	var h := size.y if size.y > 1.0 else 1672.0
	var s := maxf(W / ART.x, h / ART.y)
	var art := ART * s
	UI.place(_art, Rect2((W - art.x) / 2.0, h - art.y, art.x, art.y))
	var ph := _column.get_combined_minimum_size().y + PAD * 2.0
	_rest_y = h - 44.0 - ph
	UI.place(_panel, Rect2((W - PANEL_W) / 2.0, _rest_y, PANEL_W, ph))
	_column.position = Vector2(PAD, PAD)
	_column.size = Vector2(PANEL_W - PAD * 2.0, ph - PAD * 2.0)
	# Dark by the time it reaches the plate, so the studio mark under the crest
	# does not show its first word over the form.
	UI.place(_veil, Rect2(0, _rest_y - 190.0, W, 210.0))
	UI.place(_foot, Rect2(0, _rest_y + 20.0, W, h - _rest_y))


## Keeps the plate above the keyboard while one is up.
func _process(_dt: float) -> void:
	if _panel == null:
		return
	var kb := 0.0
	if _user.has_focus() or _pass.has_focus():
		var win := DisplayServer.window_get_size()
		if win.x > 0:
			kb = float(DisplayServer.virtual_keyboard_get_height()) * W / float(win.x)
	var want := _rest_y
	if kb > 0.0:
		want = minf(_rest_y, size.y - kb - _panel.size.y - 16.0)
	if absf(_panel.position.y - want) > 0.5:
		_panel.position.y = lerpf(_panel.position.y, want, 0.35)


func _sign_in() -> void:
	await _submit(false)


func _create() -> void:
	await _submit(true)


func _submit(create: bool) -> void:
	if _busy:
		return
	_busy = true
	_msg.text = ""
	_msg.label_settings.font_color = UI.RED
	var err: String
	if create:
		err = await Session.register(_user.text.strip_edges(), _pass.text)
	else:
		err = await Session.login(_user.text.strip_edges(), _pass.text)
	if err != "":
		_msg.text = err
		_busy = false
		return
	_msg.label_settings.font_color = UI.GOLD
	_msg.text = "Entering the realm..."
	await GameState.refresh()
	_busy = false
	if GameState.has_state():
		Nav.go("res://scenes/shell/shell.tscn")
	else:
		_msg.label_settings.font_color = UI.RED
		_msg.text = "Signed in, but the realm did not answer. Try again in a moment."
