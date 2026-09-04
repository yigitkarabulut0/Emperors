extends Control
## Sign in / create account.
##
## Username and password, because the owner wants players to be able to recover
## an account from a new device on day one. iOS rotates identifierForVendor on
## reinstall, so a device-only account would silently lose everyone's progress.

signal authenticated

var _mode_register := true
var _username: LineEdit
var _password: LineEdit
var _submit: Button
var _switch: Button
var _error: Label
var _busy := false


func _ready() -> void:
	var bg := ColorRect.new()
	bg.color = Palette.BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right"]:
		margin.add_theme_constant_override("margin_" + side, 40)
	add_child(margin)

	var col := VBoxContainer.new()
	col.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	col.add_theme_constant_override("separation", 14)
	margin.add_child(col)

	col.add_child(UI.label("EMPERORS", 52, Palette.GOLD, HORIZONTAL_ALIGNMENT_CENTER))
	col.add_child(UI.label("Rise, and let the realm remember your name.", 15,
		Palette.TEXT_FAINT, HORIZONTAL_ALIGNMENT_CENTER))
	col.add_child(UI.spacer(24))

	_username = UI.line_edit("Username")
	_username.custom_minimum_size = Vector2(0, 56)
	col.add_child(_username)

	_password = UI.line_edit("Password", true)
	_password.custom_minimum_size = Vector2(0, 56)
	_password.text_submitted.connect(func(_t: String) -> void: _submit_pressed())
	col.add_child(_password)

	_error = UI.label("", 15, Palette.DANGER, HORIZONTAL_ALIGNMENT_CENTER)
	_error.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_error.custom_minimum_size = Vector2(0, 40)
	col.add_child(_error)

	_submit = UI.button("CREATE ACCOUNT", 20)
	_submit.custom_minimum_size = Vector2(0, 60)
	_submit.pressed.connect(_submit_pressed)
	col.add_child(_submit)

	_switch = UI.ghost_button("Already have an account? Sign in")
	_switch.pressed.connect(_toggle_mode)
	col.add_child(_switch)


func _toggle_mode() -> void:
	_mode_register = not _mode_register
	_submit.text = "CREATE ACCOUNT" if _mode_register else "SIGN IN"
	_switch.text = "Already have an account? Sign in" if _mode_register \
		else "New here? Create an account"
	_error.text = ""


func _submit_pressed() -> void:
	if _busy:
		return
	var user := _username.text.strip_edges()
	var pw := _password.text

	# Check locally first so the obvious mistakes cost no round trip, but the
	# server validates independently — this is convenience, never enforcement.
	if user.length() < 3:
		_error.text = "Username must be at least 3 characters."
		return
	if pw.length() < 8:
		_error.text = "Password must be at least 8 characters."
		return

	_set_busy(true)
	# Each branch needs its own await: GDScript cannot await a ternary whose
	# arms are coroutines.
	var err := ""
	if _mode_register:
		err = await Session.register(user, pw)
	else:
		err = await Session.login(user, pw)
	_set_busy(false)

	if err != "":
		_error.text = err
		return
	_error.text = ""
	authenticated.emit()


func _set_busy(busy: bool) -> void:
	_busy = busy
	_submit.disabled = busy
	_submit.text = "…" if busy else ("CREATE ACCOUNT" if _mode_register else "SIGN IN")
