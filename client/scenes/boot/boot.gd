extends Control
## Splash and reachability, then sign-in or the shell.

var _status: Label


func _ready() -> void:
	var bg := ColorRect.new()
	bg.color = UI.GROUND
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	var title := UI.label("EMPERORS", 84, UI.GOLD, "title", 700, HORIZONTAL_ALIGNMENT_CENTER)
	title.set_anchors_preset(Control.PRESET_CENTER_TOP)
	title.position = Vector2(0, 640)
	title.size = Vector2(941, 120)
	add_child(title)
	_status = UI.label("Reaching the realm...", 28, UI.DIM, "body", 500, HORIZONTAL_ALIGNMENT_CENTER)
	_status.position = Vector2(0, 780)
	_status.size = Vector2(941, 40)
	add_child(_status)
	_boot.call_deferred()


func _boot() -> void:
	# Dev auto sign-in, so capture runs (which disable input) can reach a screen.
	if Env.args.has("dev_login"):
		var creds: Array = Env.args["dev_login"]
		Session.sign_out()
		var err: String = await Session.login(str(creds[0]), str(creds[1]))
		if err != "":
			err = await Session.register(str(creds[0]), str(creds[1]))
		if err != "":
			_status.text = err
			return
	if Session.is_signed_in():
		var ok: bool = await Session.try_refresh()
		if not ok and Session.refresh_failed_offline:
			_status.text = "Cannot reach the server. Retrying..."
			await get_tree().create_timer(3.0).timeout
			_boot()
			return
	if Session.is_signed_in():
		await GameState.refresh()
		if GameState.has_state():
			Nav.go("res://scenes/shell/shell.tscn")
			return
	Nav.go("res://scenes/auth/auth.tscn")
