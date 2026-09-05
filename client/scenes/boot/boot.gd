extends Control
## Decides where the player lands: straight into the game if a session survives,
## otherwise the sign-in screen.

@onready var _status: Label = %Status
@onready var _motto: Label = %Motto
@onready var _detail: Label = %Detail
@onready var _retry: Button = %Retry

## The sign-in screen, while it is up. Boot outlives it deliberately.
var _auth: Node = null

func _ready() -> void:
	_retry.pressed.connect(_start)
	_start()


func _start() -> void:
	_retry.visible = false
	_status.text = "Reaching the realm…"
	_status.modulate = Color(0.85, 0.80, 0.65)
	_motto.text = ""
	_detail.text = Env.api_base_url

	var res: Api.Response = await Api.get_json("/v1/ping", false)
	if not res.ok:
		print("[boot] FAILED: ", res.error)
		_status.text = "No answer"
		_status.modulate = Color(0.86, 0.35, 0.30)
		_motto.text = res.error
		_retry.visible = true
		return

	_motto.text = str(res.data.get("motto", ""))

	# Checked BEFORE the saved session: a proof capture must land on the account
	# it names, not on whoever signed in last on this machine.
	var dev := _dev_login_args()
	if not dev.is_empty():
		_status.text = "Signing in…"
		Session.sign_out()
		var err := await Session.login(dev[0], dev[1])
		if err != "":
			err = await Session.register(dev[0], dev[1])
		if err == "":
			_enter_game()
			return
		print("[boot] dev login failed: ", err)

	if Session.is_signed_in():
		_status.text = "Restoring your realm…"
		if await Session.try_refresh():
			_enter_game()
			return

	_status.text = ""
	_enter_auth()


## Shows the sign-in screen. Boot stays ALIVE behind it, just hidden.
##
## It used to _swap() here, and _swap frees this node. Godot then dropped the
## authenticated -> _enter_game connection, because a connection to a freed
## object is not a connection -- so signing in did nothing at all. The server
## returned 200, the client never asked for state, and pressing the button again
## just signed in again. Every screenshot in development looked fine because
## --dev-login calls _enter_game directly and never goes near this screen.
##
## Boot owns the whole handoff now and does not let go until the shell is up.
func _enter_auth() -> void:
	_auth = preload("res://scenes/auth/auth.tscn").instantiate()
	_auth.authenticated.connect(_enter_game)
	get_tree().root.add_child(_auth)
	get_tree().current_scene = _auth
	visible = false


func _enter_game() -> void:
	print("[boot] entering game")
	await GameState.refresh()
	await _dev_collect()

	var shell := preload("res://scenes/shell/shell.tscn").instantiate()
	get_tree().root.add_child(shell)
	get_tree().current_scene = shell
	if _auth != null and is_instance_valid(_auth):
		_auth.queue_free()
	# Last statement: nothing may touch self after this.
	queue_free()


## Dev-only: performs N collects so a proof capture can show a played state
## rather than a fresh account. Goes through GameState, so it exercises the real
## optimistic queue rather than a shortcut.
func _dev_collect() -> void:
	var n := 0
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		if args[i] == "--dev-collect" and i + 1 < args.size():
			n = int(args[i + 1])
	if n <= 0 or OS.has_feature("release"):
		return

	var jobs := GameState.jobs()
	for i in n:
		var best := {}
		for j in jobs:
			if bool(j.get("unlocked", false)) and GameState.display_energy() >= int(j.get("energy_cost", 0)):
				best = j
		if best.is_empty() or not GameState.collect(best):
			break
		await get_tree().create_timer(0.05).timeout
		jobs = GameState.jobs()
	print("[boot] dev-collect done: gold=", GameState.display_gold(),
		" energy=", GameState.display_energy(), " pending=", GameState.pending_count())



## Reads `--dev-login <username> <password>` from the command line.
## Release builds simply never receive these arguments.
func _dev_login_args() -> Array:
	if OS.has_feature("release"):
		return []
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		if args[i] == "--dev-login" and i + 2 < args.size():
			return [args[i + 1], args[i + 2]]
	return []
