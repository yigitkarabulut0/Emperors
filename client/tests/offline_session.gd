extends SceneTree
## A network failure must never sign the player out.
##
## The bug this pins: try_refresh() called sign_out() on ANY failed response, and
## Api._fail() returns status 0 for every transport error -- so one dropped
## packet during a refresh deleted user://session.dat and the player had to type
## their password again. On a phone that happens constantly, and it is why the
## owner reported having to sign in over and over.
##
## Only the server may end a session, by answering 401 to the refresh token.


func _fail(msg: String) -> void:
	print("FAIL  ", msg)
	quit(1)


func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame
	var env: Node = root.get_node_or_null("/root/Env")
	var session: Node = root.get_node_or_null("/root/Session")
	if env == null or session == null:
		_fail("autoloads missing")
		return

	# Register for real, so there is a genuine session to protect.
	session.call("sign_out")
	var user := "off%d" % (Time.get_ticks_usec() % 900000)
	var err: String = await session.call("register", user, "battery horse staple")
	if err != "":
		_fail("could not register against %s: %s" % [env.get("api_base_url"), err])
		return
	if not bool(session.call("is_signed_in")):
		_fail("registered but not signed in")
		return

	# Now break the network. A blackholed address gives a connect failure rather
	# than a refusal, which is the realistic phone case.
	var real: String = env.get("api_base_url")
	env.set("api_base_url", "http://192.0.2.1:8080")

	var ok: bool = await session.call("try_refresh")
	env.set("api_base_url", real)

	if ok:
		_fail("try_refresh reported success against an unreachable server")
		return
	if not bool(session.get("refresh_failed_offline")):
		_fail("the failure was not reported as a transport failure")
		return
	if not bool(session.call("is_signed_in")):
		_fail("a network failure signed the player out — the session was destroyed")
		return
	if not FileAccess.file_exists("user://session.dat"):
		_fail("a network failure deleted session.dat")
		return

	print("PASS  a network failure leaves the session intact")
	quit(0)
