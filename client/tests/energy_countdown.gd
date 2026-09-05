extends SceneTree
## The energy readout counts down to the NEXT point, and rolls over.
##
## It used to show time-to-full, which is the answer to a question nobody asks:
## with a partly drained pool it reads "1h 04m" when what decides whether you
## wait is "23 seconds". A countdown that runs to zero once and stops would be
## just as wrong -- it has to reset every time a point lands.


func _fail(msg: String) -> void:
	print("FAIL  ", msg)
	quit(1)


func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame
	var gs: Node = root.get_node_or_null("/root/GameState")
	if gs == null:
		_fail("GameState missing")
		return

	var period := 400
	gs.set("snapshot", {
		"player": {"gold": "0", "level": 1, "xp": 0, "xp_to_next": 10},
		"energy": {"current": 0, "max": 10, "regen_period_ms": period,
			"seconds_to_full": 10 * period / 1000},
	})
	gs.set("_energy_at_ms", Time.get_ticks_msec())

	# Sample across three periods and record the countdown.
	var seen: Array[int] = []
	var deadline := Time.get_ticks_msec() + period * 3
	while Time.get_ticks_msec() < deadline:
		seen.append(int(gs.call("display_seconds_to_next")))
		await create_timer(0.05).timeout

	if seen.is_empty():
		_fail("no samples")
		return
	for v in seen:
		if v <= 0 or v > int(ceil(period / 1000.0)) + 1:
			_fail("countdown left its period: saw %d in %s" % [v, str(seen)])
			return

	# A full pool has nothing to count down to.
	gs.set("snapshot", {
		"player": {"gold": "0", "level": 1, "xp": 0, "xp_to_next": 10},
		"energy": {"current": 10, "max": 10, "regen_period_ms": period,
			"seconds_to_full": 0},
	})
	gs.set("_energy_at_ms", Time.get_ticks_msec())
	if int(gs.call("display_seconds_to_next")) != 0:
		_fail("a full pool still claimed a point was coming")
		return

	if UI.short_duration(23) != "0:23" or UI.short_duration(247) != "4:07":
		_fail("short_duration formatted wrong: %s / %s" % [
			UI.short_duration(23), UI.short_duration(247)])
		return

	print("PASS  countdown stayed inside its period across %d samples" % seen.size())
	quit(0)
