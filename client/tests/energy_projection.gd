extends SceneTree
## Headless check that energy advances between polls.
##
## The bug this pins: display_energy() used to read the snapshot's whole number
## and nothing else, so the pool sat frozen on screen until the next request.

func _err(msg: String) -> void:
	push_error(msg)
	print("FAIL  ", msg)
	quit(1)


func _initialize() -> void:
	var gs: Node = load("res://scripts/autoload/game_state.gd").new()

	# 2/60, one minute a point, and the server says 3476s to full. Filling 58
	# points from empty would be 3480s, so 4s of the current point are banked.
	gs.snapshot = {"energy": {"current": 2, "max": 60, "regen_period_ms": 60000,
		"seconds_to_full": 3476}}

	gs._energy_at_ms = Time.get_ticks_msec()
	var at_poll: int = gs.display_energy()
	if at_poll != 2:
		_err("right after a poll energy should read what the server said, got %d" % at_poll)

	# 56s later the banked 4s completes the point: 2 -> 3, and not before.
	gs._energy_at_ms = Time.get_ticks_msec() - 55_000
	if gs.display_energy() != 2:
		_err("gained a point early at 55s (banked 4s + 55s < 60s)")
	gs._energy_at_ms = Time.get_ticks_msec() - 56_500
	if gs.display_energy() != 3:
		_err("did not gain a point at 56.5s, got %d" % gs.display_energy())

	# Ten minutes on, ten points, and the countdown has moved with it.
	gs._energy_at_ms = Time.get_ticks_msec() - 600_000
	if gs.display_energy() != 12:
		_err("expected 12 after ten minutes, got %d" % gs.display_energy())
	if gs.display_seconds_to_full() != 2876:
		_err("countdown did not track, got %d" % gs.display_seconds_to_full())

	# It must never run past the cap, however long the app was backgrounded.
	gs._energy_at_ms = Time.get_ticks_msec() - 86_400_000
	if gs.display_energy() != 60:
		_err("overflowed the pool after a day, got %d" % gs.display_energy())
	if gs.display_seconds_to_full() != 0:
		_err("countdown went negative, got %d" % gs.display_seconds_to_full())

	# A full pool must not be projected at all.
	gs.snapshot = {"energy": {"current": 60, "max": 60, "regen_period_ms": 60000,
		"seconds_to_full": 0}}
	gs._energy_at_ms = Time.get_ticks_msec() - 600_000
	if gs.display_energy() != 60:
		_err("a full pool drifted, got %d" % gs.display_energy())

	print("PASS  energy projects between polls, tracks the countdown, and caps")
	gs.free()
	quit(0)
