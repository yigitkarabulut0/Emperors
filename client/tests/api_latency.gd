extends SceneTree
## Measures what a request costs, and proves connections are being reused.
##
## The old client wrapped HTTPRequest, which opens a new TCP connection and a new
## TLS handshake every call. Against the deployed server that is 80 ms where a
## reused connection is 25 ms, and on a phone the two extra round trips cost
## about 300 ms per tap. This is the number that decides whether the game feels
## like it answers.


func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame
	var env: Node = root.get_node_or_null("/root/Env")
	var api: Node = root.get_node_or_null("/root/Api")
	var target := "https://91-107-215-32.sslip.io"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--target="):
			target = a.substr("--target=".length())
	env.set("api_base_url", target)
	print("target ", target)

	var times: Array[int] = []
	for i in 12:
		var t0 := Time.get_ticks_msec()
		var res = await api.call("get_json", "/v1/ping", false)
		var dt := Time.get_ticks_msec() - t0
		if not res.ok:
			print("FAIL  request %d failed: %s" % [i, res.error])
			quit(1)
			return
		times.append(dt)

	var first: int = times[0]
	var rest: Array = times.slice(1)
	var total := 0
	for t in rest:
		total += t
	var mean := float(total) / float(rest.size())
	var best: int = rest.min()

	print("  first (connect + TLS + request) %4d ms" % first)
	print("  reused: mean %5.1f ms   best %d ms   all %s" % [mean, best, str(rest)])

	# A reused connection has to be materially cheaper than the first one, or the
	# socket is not actually being kept and this whole change bought nothing.
	if mean >= float(first) * 0.85:
		print("FAIL  reuse saved nothing: first %d ms, later calls average %.1f ms" % [first, mean])
		quit(1)
		return

	print("PASS  connections are reused: %.0f%% of the first call's cost" % (mean / float(first) * 100.0))
	quit(0)
