extends SceneTree
## A Collect row's top line holds a job name on the left and the collect counter
## on the right, with the COLLECT button after both. A Label grows to its text,
## so a name or a count wider than its box walks right into its neighbour: the
## counter sat on the button once "20 / 25" became "100 / MAX". Checked here for
## every job name the balance ships and every shape the counter can take.
##
## Run: godot --headless --path client --script tests/collect_row_fit.gd

const COUNTERS := ["0 / 25", "99 / 100", "499 / 500", "999 / 1000", "1500 / MAX", "9999 / MAX", "LV 12"]

var _fails: int = 0
var _L: GDScript
var _U: GDScript
var _C: GDScript


func _initialize() -> void:
	await process_frame
	_L = load("res://scripts/ui/layout.gd")
	_U = load("res://scripts/ui/ui.gd")
	_C = load("res://scenes/tabs/collect.gd")
	var row: Dictionary = _L.find("collect", "job_row")
	if row.is_empty():
		_fail("collect layout has no job_row template")
	else:
		_check_row(row)
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  every job name and counter stays in its box, clear of the button")
	quit()


func _fail(msg: String) -> void:
	_fails += 1
	print("  FAIL  " + msg)


func _check_row(row: Dictionary) -> void:
	var built: Dictionary = _L.instantiate(row)
	var parts: Dictionary = built["parts"]
	var name: Label = parts["name"]
	var counter: Label = parts["counter"]
	var button: Control = parts["collect"]
	var name_right := name.position.x + float(name.get_meta("box_w"))
	var counter_left := counter.position.x
	var counter_right := counter_left + float(counter.get_meta("box_w"))

	# The boxes themselves: name, then counter, then a clear gap, then the button.
	if name_right > counter_left:
		_fail("the name box (ends %.0f) runs under the counter box (starts %.0f)" % [name_right, counter_left])
	if counter_right > button.position.x - 30:
		_fail("the counter box ends at %.0f, less than 30 units clear of the button at %.0f" % [counter_right, button.position.x])

	# Every name the balance ships, fitted the way the screen fits it.
	var jobs: Array = _jobs()
	if jobs.is_empty():
		_fail("could not read balance/jobs.json")
	for j in jobs:
		name.text = str(j.get("name", "")).to_upper()
		_U.fit_label(name, _C.NAME_FIT.x, _C.NAME_FIT.y)
		var w := _width(name)
		if name.position.x + w > counter_left:
			_fail("%s at %dpx is %.0f wide and reaches %.0f, into the counter" % [name.text, name.label_settings.font_size, w, name.position.x + w])

	# Every shape the counter takes, fitted the way the screen fits it.
	for s in COUNTERS:
		counter.text = s
		_U.fit_label(counter, _C.COUNTER_FIT.x, _C.COUNTER_FIT.y)
		var w := _width(counter)
		if w > float(counter.get_meta("box_w")):
			_fail("counter %s at %dpx is %.0f wide, over its %.0f box -- it would grow onto the button" % [s, counter.label_settings.font_size, w, counter.get_meta("box_w")])
	built["node"].free()


func _width(l: Label) -> float:
	return l.label_settings.font.get_string_size(l.text, HORIZONTAL_ALIGNMENT_LEFT, -1, l.label_settings.font_size).x


func _jobs() -> Array:
	var f := FileAccess.open("res://../balance/jobs.json", FileAccess.READ)
	if f == null:
		return []
	var d: Variant = JSON.parse_string(f.get_as_text())
	if d is Dictionary:
		return d.get("jobs", [])
	return d if d is Array else []
