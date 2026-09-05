extends SceneTree
## A button gated on energy must re-arm itself as energy regenerates.
##
## The bug this pins: regeneration is a pure projection computed on read, so the
## snapshot never changes and `changed` never fires. Collect's action button wrote
## `disabled` only from `changed`, so it stayed disabled while the energy to
## afford the job was visibly arriving in the top bar -- and reselecting the job
## "fixed" it, because reselecting was the only thing that re-ran the check.
##
## GameState.tick_projection() now emits `energy_changed` when the projected whole
## number moves, and only then.


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

	# A snapshot with an empty pool and a fast regen period, so a point lands
	# within the test rather than in a minute.
	var period := 300
	gs.set("snapshot", {
		"player": {"gold": "0", "level": 1, "xp": 0, "xp_to_next": 10},
		"energy": {"current": 0, "max": 10, "regen_period_ms": period,
			"seconds_to_full": 10 * period / 1000},
	})
	gs.set("_energy_at_ms", Time.get_ticks_msec())

	var seen: Array[int] = []
	gs.connect("energy_changed", func(v: int) -> void: seen.append(v))

	if int(gs.call("display_energy")) != 0:
		_fail("the pool did not start empty")
		return

	# Tick at 4 Hz, the way the shell does, across three regen periods.
	var deadline := Time.get_ticks_msec() + period * 3 + 200
	var ticks := 0
	while Time.get_ticks_msec() < deadline:
		gs.call("tick_projection")
		ticks += 1
		await create_timer(0.05).timeout

	if seen.is_empty():
		_fail("energy regenerated across %d ticks and the signal never fired" % ticks)
		return
	if seen.size() > 6:
		_fail("the signal fired %d times for at most 3 points: it is not deduplicated"
			% seen.size())
		return
	for i in range(1, seen.size()):
		if seen[i] <= seen[i - 1]:
			_fail("energy went backwards while regenerating: %s" % str(seen))
			return

	print("PASS  regenerating energy announced %s across %d ticks" % [str(seen), ticks])
	quit(0)
