extends SceneTree
## Losing the connection holds the player in place; it never signs them out.
##
## The failure this pins is the one that made the owner re-enter a password on a
## train: a dropped connection ended at the sign-in screen. The session was never
## invalid -- the refresh token was on disk and the server never rejected it.
##
## Also pinned: the overlay waits out a GRACE period first. Below that a dropped
## packet is invisible, and flashing an alarm at every lost packet makes a working
## game look broken.


func _fail(msg: String) -> void:
	print("FAIL  ", msg)
	quit(1)


func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame
	var env: Node = root.get_node_or_null("/root/Env")
	var api: Node = root.get_node_or_null("/root/Api")
	var session: Node = root.get_node_or_null("/root/Session")

	session.call("sign_out")
	var user := "rec%d" % (Time.get_ticks_usec() % 900000)
	var err: String = await session.call("register", user, "battery horse staple")
	if err != "":
		_fail("could not register: %s" % err)
		return

	var overlay: CanvasLayer = load("res://scenes/shell/reconnect.gd").new()
	root.add_child(overlay)
	await process_frame

	var offline_seen := [0]
	var online_seen := [0]
	api.connect("offline", func() -> void: offline_seen[0] += 1)
	api.connect("online", func() -> void: online_seen[0] += 1)

	# --- a single dropped request must not put anything on screen ------------
	var real: String = env.get("api_base_url")
	env.set("api_base_url", "http://192.0.2.1:8080")
	var res = await api.call("get_json", "/v1/ping", false, 2.0)
	if res.ok:
		_fail("the blackhole answered")
		return
	if offline_seen[0] == 0:
		_fail("a transport failure did not report the connection as lost")
		return
	if overlay.visible:
		_fail("one dropped request put a 'connection lost' panel on screen")
		return

	# --- but a sustained outage must ---------------------------------------
	overlay.set("_since_ms", Time.get_ticks_msec() - int(overlay.get("GRACE_SECONDS") * 1000.0) - 100)
	res = await api.call("get_json", "/v1/ping", false, 2.0)
	await process_frame
	if not overlay.visible:
		_fail("a sustained outage never told the player anything")
		return

	if not bool(session.call("is_signed_in")):
		_fail("the outage signed the player out")
		return

	# --- and it must clear itself when the realm comes back -----------------
	env.set("api_base_url", real)
	var waited := 0.0
	while overlay.visible and waited < 20.0:
		await create_timer(0.25).timeout
		waited += 0.25
	if overlay.visible:
		_fail("the panel never cleared after the connection came back")
		return
	if not bool(session.call("is_signed_in")):
		_fail("recovering signed the player out")
		return

	print("PASS  held through the outage, recovered in %.1fs, never signed out" % waited)
	quit(0)
