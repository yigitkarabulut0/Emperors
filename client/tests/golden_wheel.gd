extends SceneTree
## The Golden Hour's wheel on the Collect header (collect_events.png): hidden
## below its level, its cells lit as the meter fills, burnt back as the hour
## runs out, and its plate saying what it is doing -- its name while it fills,
## the time left and the energy it still doubles while it burns, the rest
## before the next, or the day's all used. A collect answer the hour touched
## rises from it as "+1,234" in grouped digits, and lights the words GOLDEN HOUR
## when it starts it.
##
## Before Wave 3 the tab had no wheel: snapshot.frenzy was read by nothing, and
## the gold a Golden Hour added would have arrived without a word -- the shape
## of "a response field nothing read".
##
## Run: godot --headless --path client --script tests/golden_wheel.gd

var _fails := 0


func _frenzy(extra: Dictionary) -> Dictionary:
	var f := {"unlocked": true, "unlock_level": 5, "meter": 0.0, "active": false, "ends_in": 0,
		"energy_left": 0, "used": 0, "per_day": 3, "ready_in": 0, "window": 20, "bp": 10000,
		"duration": 60, "drains_in": 0, "cooldown": 1800}
	f.merge(extra, true)
	return f


func _initialize() -> void:
	await process_frame
	var gs: Node = root.get_node("GameState")
	var host := Control.new()
	host.size = Vector2(941, 1672)
	root.add_child(host)
	var screen: Control = (load("res://scenes/tabs/collect.gd") as GDScript).new()
	screen.size = Vector2(941, 1672)
	host.add_child(screen)
	for i in 3:
		await process_frame
	var ui: Dictionary = screen.get("_ui")
	if not ui.has("golden") or not screen.has_method("paint_golden"):
		_fail("the Collect tab has no Golden Hour wheel")
		_done()
		return
	var golden: Control = ui["golden"]
	var parts: Dictionary = golden.get_meta("parts")
	var wheel: TextureProgressBar = screen.get("_wheel")
	var state: Label = parts["state"]
	var energy: Label = parts["energy"]
	var bolt: Control = parts["bolt"]
	var plate: Control = parts["plate"]

	# Below its level, or on a server that does not send it: no wheel.
	gs.call("adopt", {"player": {"level": 3}, "frenzy": _frenzy({"unlocked": false})})
	screen.call("paint_golden")
	_expect(not golden.visible, "the wheel shows below the Golden Hour's level")
	gs.call("adopt", {"player": {"level": 30}})
	screen.call("paint_golden")
	_expect(not golden.visible, "the wheel shows with no frenzy in the snapshot")

	# Filling: its name, and the cells to the meter.
	gs.call("adopt", {"player": {"level": 30}, "frenzy": _frenzy({"meter": 0.62, "drains_in": 14})})
	screen.call("paint_golden")
	_expect(golden.visible, "the wheel is hidden while it fills")
	_expect(is_equal_approx(wheel.value, 0.62), "the wheel is lit to %.2f, not the meter's 0.62" % wheel.value)
	_expect(state.text == "Golden Hour", "the filling wheel's plate says \"%s\"" % state.text)
	_expect(not energy.visible and not bolt.visible, "the filling wheel's plate shows an energy figure")
	_expect(wheel.fill_mode == TextureProgressBar.FILL_COUNTER_CLOCKWISE, "the cells do not light counter-clockwise from the top, as the painting's half-lit wheel does")

	# Burning: a second left of sixty, and the energy it still doubles, on the plate.
	gs.call("adopt", {"player": {"level": 30}, "frenzy": _frenzy({"active": true, "ends_in": 1, "energy_left": 1234567, "used": 1})})
	screen.call("paint_golden")
	_expect(is_equal_approx(wheel.value, 1.0 / 60.0), "at 1 s of 60 the wheel is lit to %.3f" % wheel.value)
	_expect(state.text == "0:01", "the burning wheel's time reads \"%s\"" % state.text)
	_expect(energy.visible and bolt.visible and energy.text == "1,234,567", "the burning wheel's energy reads \"%s\"" % energy.text)
	var left := state.position.x
	var right := energy.position.x + energy.label_settings.font.get_string_size(energy.text, HORIZONTAL_ALIGNMENT_LEFT, -1, energy.label_settings.font_size).x
	_expect(left >= plate.position.x + 6.0 and right <= plate.position.x + plate.size.x - 6.0,
		"the burning plate's line runs %.0f..%.0f on a plate %.0f..%.0f" % [left, right, plate.position.x, plate.position.x + plate.size.x])
	_expect((parts["glow"] as CanvasItem).visible, "the burning wheel has no light behind it")

	# Resting between hours, and every hour of the day used.
	gs.call("adopt", {"player": {"level": 30}, "frenzy": _frenzy({"used": 1, "ready_in": 1450})})
	screen.call("paint_golden")
	_expect(state.text == "Ready in 24m 10s", "the resting wheel says \"%s\"" % state.text)
	gs.call("adopt", {"player": {"level": 30}, "frenzy": _frenzy({"used": 3})})
	screen.call("paint_golden")
	_expect(state.text == "3 of 3 used", "the spent wheel says \"%s\"" % state.text)
	_expect(not (parts["glow"] as CanvasItem).visible, "a spent wheel keeps its light")

	# The clocks count down from the snapshot, and a meter left alone drains.
	var collect: GDScript = load("res://scenes/tabs/collect.gd")
	var later: Dictionary = collect.golden_now(_frenzy({"meter": 0.5, "drains_in": 5, "ready_in": 100}), 7)
	_expect(float(later["meter"]) == 0.0 and int(later["ready_in"]) == 93, "seven seconds on, the meter reads %s and the rest %s" % [str(later["meter"]), str(later["ready_in"])])
	var burning: Dictionary = collect.golden_now(_frenzy({"active": true, "ends_in": 3}), 4)
	_expect(not bool(burning["active"]), "an hour past its end still burns")

	# The gold it added, rising in grouped digits; the words when it lights.
	gs.call("adopt", {"player": {"level": 30}, "frenzy": _frenzy({"active": true, "ends_in": 59, "energy_left": 40})})
	screen.visible = true
	gs.emit_signal("golden_hour", 9999999, true)
	await process_frame
	var gain: Label = parts["gain"]
	var flare: Label = parts["flare"]
	_expect(gain.visible and gain.text == "+9,999,999", "the burst reads \"%s\"" % gain.text)
	var gw := gain.label_settings.font.get_string_size(gain.text, HORIZONTAL_ALIGNMENT_LEFT, -1, gain.label_settings.font_size).x
	_expect(gw <= gain.size.x + 0.5, "the burst is %.0f wide in its %.0f box" % [gw, gain.size.x])
	_expect(flare.visible and flare.text == "GOLDEN HOUR", "the hour lit without its words")
	var fw := flare.label_settings.font.get_string_size(flare.text, HORIZONTAL_ALIGNMENT_LEFT, -1, flare.label_settings.font_size).x
	# The header's baked words: COLLECT TASKS (x 188..552, y 105..151) and its
	# subtitle (x 188..722, y 158..183). The words stand clear of both.
	var ink := Rect2(golden.position.x + flare.position.x + flare.size.x - fw, golden.position.y + flare.position.y + 8.0,
		fw, flare.size.y - 16.0)
	for baked in [Rect2(188, 105, 364, 46), Rect2(188, 158, 534, 25)]:
		_expect(not ink.intersects(baked), "GOLDEN HOUR (%s) stands on the header's words %s" % [str(ink), str(baked)])

	# Its rules, in the server's numbers.
	var rules: String = collect.golden_rules(_frenzy({}))
	_expect(rules.contains("20 seconds") and rules.contains("60 seconds") and rules.contains("100%") and rules.contains("3 a day")
		and rules.contains("30 minutes"), "the wheel's rules say: %s" % rules)
	_done()


func _expect(ok: bool, msg: String) -> void:
	if not ok:
		_fail(msg)


func _fail(msg: String) -> void:
	_fails += 1
	print("  FAIL  " + msg)


func _done() -> void:
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  the Golden Hour's wheel fills, burns, rests and says so from the snapshot alone")
	quit()
