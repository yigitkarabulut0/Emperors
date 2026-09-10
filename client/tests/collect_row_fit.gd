extends SceneTree
## A Collect row's top line holds a job name on the left and the collect counter
## on the right, with the COLLECT button after both. A Label grows to its text,
## so a name or a count wider than its box walks right into its neighbour: the
## counter sat on the button once "20 / 25" became "100 / MAX". Checked here for
## every job name the balance ships and every shape the counter can take.
##
## The second line holds the payouts -- bolt, coin, crown, each with its figure.
## At the painting's places "1,250" ran into the crown; each pair now stands a
## gap after the figure before it, and the three shrink together before they
## reach the button. Checked with the largest figures a late job can show.
##
## Run: godot --headless --path client --script tests/collect_row_fit.gd

const COUNTERS := ["0 / 25", "99 / 100", "499 / 500", "999 / 1000", "1500 / MAX", "9999 / MAX", "LV 12"]
## energy, gold, xp -- as the row prints them (UI.short_number above 99,999).
const PAYOUTS := [["1", "2", "10"], ["12", "1,250", "1,820"], ["55", "99,999", "9,999"], ["99", "999K", "99,999"]]
## What a figure must keep clear of the next icon, and of the button.
const MIN_GAP := 12.0

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
	print("PASS  every job name, counter and payout stays clear of the next, and of the button")
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

	# The longest name beside the widest count, the way the screen fits the
	# two: the name ends a clear gap short of the count's first figure.
	var longest := ""
	for j in jobs:
		if str(j.get("name", "")).length() > longest.length():
			longest = str(j.get("name", "")).to_upper()
	for s in COUNTERS:
		name.text = longest
		counter.text = s
		_C.fit_top_line(parts)
		var count_left := counter.position.x + float(counter.get_meta("box_w")) - _width(counter)
		var name_end := name.position.x + _width(name)
		if name_end > count_left - MIN_GAP:
			_fail("%s beside %s ends at %.0f, %.0f units from the count" % [longest, s, name_end, count_left - name_end])
		if name.label_settings.font_size < _C.NAME_ONE_LINE_MIN:
			_fail("%s beside %s is set at %d, under the %d a name is allowed" % [longest, s, name.label_settings.font_size, _C.NAME_ONE_LINE_MIN])
		# On two lines its ink stays over the payout icons, not on them.
		var f := name.label_settings.font
		var fs := name.label_settings.font_size
		var lines := name.text.split("\n").size()
		var ink_bottom := name.position.y + f.get_ascent(fs) + (lines - 1) * (f.get_height(fs) + name.label_settings.line_spacing)
		var icon_top: float = (parts["energy_icon"] as Control).position.y
		if lines > 1 and ink_bottom > icon_top:
			_fail("%s on two lines reaches %.0f, onto the payout icons at %.0f" % [longest, ink_bottom, icon_top])

	# The payouts, from the painting's to the largest a late job shows.
	var pairs := [["energy_icon", "energy"], ["gold_icon", "gold"], ["xp_icon", "xp"]]
	for pay in PAYOUTS:
		for i in 3:
			(parts[pairs[i][1]] as Label).text = pay[i]
		_C.flow_payouts(parts)
		for i in 3:
			var label: Label = parts[pairs[i][1]]
			var end := label.position.x + _width(label)
			var next_x: float = (parts[pairs[i + 1][0]] as Control).position.x if i < 2 else button.position.x
			if end > next_x - MIN_GAP:
				_fail("payouts %s: %s ends at %.0f, %.0f units from what follows at %.0f"
					% [pay, pay[i], end, next_x - end, next_x])
		if pay == PAYOUTS[0]:
			for pr in pairs:
				var icon: Control = parts[pr[0]]
				if not is_equal_approx(icon.position.x, float(icon.get_meta("home_x"))):
					_fail("payouts %s: the %s moved off the painting's place though nothing pushed it" % [pay, pr[0]])
	built["node"].free()


## The widest line of a label's text (a long job name may be set on two).
func _width(l: Label) -> float:
	var w := 0.0
	for line in l.text.split("\n"):
		w = maxf(w, l.label_settings.font.get_string_size(line, HORIZONTAL_ALIGNMENT_LEFT, -1, l.label_settings.font_size).x)
	return w


func _jobs() -> Array:
	var f := FileAccess.open("res://../balance/jobs.json", FileAccess.READ)
	if f == null:
		return []
	var d: Variant = JSON.parse_string(f.get_as_text())
	if d is Dictionary:
		return d.get("jobs", [])
	return d if d is Array else []
