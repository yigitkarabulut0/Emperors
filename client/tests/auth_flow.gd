extends SceneTree
## Signing in through the actual sign-in screen reaches the game.
##
## The bug this pins: boot used to free ITSELF when it showed the sign-in screen,
## so Godot dropped the authenticated -> _enter_game connection and pressing the
## button did nothing. The server answered 200 every time and the client never
## asked for state. It survived all of development because --dev-login calls
## _enter_game directly and never touches this screen -- so the only path a real
## player takes was the one path nothing exercised.

var _user := ""


func _fail(msg: String) -> void:
	print("FAIL  ", msg)
	quit(1)


func _initialize() -> void:
	_user = "flow%d" % (Time.get_ticks_usec() % 900000)
	_run()


func _run() -> void:
	# Start signed out. With a session on disk boot restores it and goes straight
	# into the game, which is a different path and not the one under test.
	#
	# The file is removed directly rather than through Session.sign_out(): this
	# runs before the tree is active, so autoloads are not reachable by path yet,
	# and --script does not resolve them by name either.
	# One frame first: autoloads have run _ready() and loaded any saved tokens
	# into memory by then, so deleting the file alone would not sign us out.
	await process_frame
	var session: Node = root.get_node_or_null("/root/Session")
	if session == null:
		_fail("Session autoload is missing")
		return
	session.call("sign_out")
	if bool(session.call("is_signed_in")):
		_fail("still signed in after sign_out")
		return

	var boot: Node = load("res://scenes/boot/boot.tscn").instantiate()
	root.add_child(boot)
	current_scene = boot

	# Boot pings, finds no saved session, and puts the sign-in screen up.
	var auth: Node = null
	for i in 600:
		await process_frame
		if not is_instance_valid(boot):
			_fail("boot freed itself before the sign-in screen appeared")
			return
		if boot.get("_auth") != null:
			auth = boot.get("_auth")
			break
	if auth == null:
		_fail("the sign-in screen never appeared (is the server reachable?)")
		return

	# Boot must still be alive: it owns the handoff into the game. This is the
	# whole point of the test -- it used to free itself here, which silently
	# dropped the authenticated -> _enter_game connection.
	if not is_instance_valid(boot):
		_fail("boot freed itself while showing the sign-in screen")
		return

	auth.set("_username", auth.get("_username"))
	auth.get("_username").text = _user
	auth.get("_password").text = "battery horse staple"
	auth.call("_submit_pressed")

	# The shell is the game. Give registration and the first state load time.
	for i in 900:
		await process_frame
		for child in root.get_children():
			if child.get_script() != null and str(child.get_script().resource_path).ends_with("shell.gd"):
				print("PASS  signing in through the real screen reaches the game")
				quit(0)
				return
	_fail("signed in, but the game never opened")
