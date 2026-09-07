extends Control
## Sign in / create account. No reference painting exists for this screen, so it
## is set in the same type and colours as the rest, on the plain navy ground.

var _user: LineEdit
var _pass: LineEdit
var _msg: Label
var _busy := false


func _ready() -> void:
	var bg := ColorRect.new()
	bg.color = UI.GROUND
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var title := UI.label("EMPERORS", 84, UI.GOLD, "title", 700, HORIZONTAL_ALIGNMENT_CENTER)
	UI.place(title, Rect2(0, 420, 941, 120))
	add_child(title)
	var sub := UI.label("Rule your realm", 30, UI.DIM, "body", 500, HORIZONTAL_ALIGNMENT_CENTER)
	UI.place(sub, Rect2(0, 530, 941, 40))
	add_child(sub)

	_user = _field("Username", Rect2(220, 660, 500, 72), false)
	_pass = _field("Password", Rect2(220, 760, 500, 72), true)
	add_child(_user)
	add_child(_pass)

	add_child(_button("SIGN IN", Rect2(220, 880, 500, 84), Color("#1F7A2E"), _sign_in))
	add_child(_button("CREATE ACCOUNT", Rect2(220, 990, 500, 84), Color("#7A1F1F"), _create))

	_msg = UI.label("", 26, UI.RED, "body", 500, HORIZONTAL_ALIGNMENT_CENTER)
	UI.place(_msg, Rect2(120, 1100, 700, 60))
	_msg.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_msg)


func _field(placeholder: String, rect: Rect2, secret: bool) -> LineEdit:
	var e := LineEdit.new()
	e.placeholder_text = placeholder
	e.secret = secret
	UI.place(e, rect)
	e.add_theme_font_override("font", UI.font("body", 500))
	e.add_theme_font_size_override("font_size", 30)
	e.add_theme_color_override("font_color", UI.INK)
	e.add_theme_color_override("font_placeholder_color", UI.DIM)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color("#101C28")
	sb.border_color = UI.GOLD_DIM
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(6)
	sb.content_margin_left = 20
	e.add_theme_stylebox_override("normal", sb)
	e.add_theme_stylebox_override("focus", sb)
	return e


func _button(text: String, rect: Rect2, color: Color, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	UI.place(b, rect)
	b.add_theme_font_override("font", UI.font("title", 700))
	b.add_theme_font_size_override("font_size", 30)
	b.add_theme_color_override("font_color", UI.INK)
	var sb := StyleBoxFlat.new()
	sb.bg_color = color
	sb.border_color = UI.GOLD_DIM
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(6)
	b.add_theme_stylebox_override("normal", sb)
	var pressed := sb.duplicate()
	pressed.bg_color = color.darkened(0.25)
	b.add_theme_stylebox_override("pressed", pressed)
	b.add_theme_stylebox_override("hover", sb)
	b.pressed.connect(cb)
	return b


func _sign_in() -> void:
	await _submit(false)


func _create() -> void:
	await _submit(true)


func _submit(create: bool) -> void:
	if _busy:
		return
	_busy = true
	_msg.text = ""
	var err: String
	if create:
		err = await Session.register(_user.text.strip_edges(), _pass.text)
	else:
		err = await Session.login(_user.text.strip_edges(), _pass.text)
	if err != "":
		_msg.text = err
		_busy = false
		return
	await GameState.refresh()
	_busy = false
	if GameState.has_state():
		Nav.go("res://scenes/shell/shell.tscn")
	else:
		_msg.text = "Signed in, but the realm did not answer."
