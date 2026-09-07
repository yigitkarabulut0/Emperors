extends SceneTree
## The mastery track under a Collect row is painted into the row frame: a bar
## with three gold diamonds. Its fill and its three marker parts are drawn over
## that painting, so they must sit exactly where the painting has them, or a
## lit marker draws beside a baked one. Measured here from the reference and
## compared with the layout; then the fill's arithmetic is checked on the
## user's own case, 213 collects on a 100 / 250 / 500 stretch.
##
## Run: godot --headless --path client --script tests/mastery_track.gd

var _fails: int = 0
var _L: GDScript
var _C: GDScript


func _initialize() -> void:
	await process_frame
	_L = load("res://scripts/ui/layout.gd")
	_C = load("res://scenes/tabs/collect.gd")
	var row: Dictionary = _L.find("collect", "job_row")
	if row.is_empty():
		_fail("collect layout has no job_row")
	else:
		_markers_and_fill_sit_on_the_painting(row)
		_fill_fraction_places_the_count_between_the_markers(row)
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  the mastery track's parts sit on the painting and the fill lands between the markers")
	quit()


func _fail(msg: String) -> void:
	_fails += 1
	print("  FAIL  " + msg)


func _part(row: Dictionary, id: String) -> Dictionary:
	for p in row.get("parts", []):
		if str(p.get("id", "")) == id:
			return p
	return {}


func _markers_and_fill_sit_on_the_painting(row: Dictionary) -> void:
	var img := Image.load_from_file("res://../art/reference/collect.png")
	if img == null:
		_fail("could not read art/reference/collect.png")
		return
	var origin: Vector2 = _L.rect_of(row).position
	# The diamonds are the warm-gold columns in the band of the first row's
	# track: gold (r well above b) for six rows or more, where the track's own
	# edge lines are neutral grey and only one row thick.
	var band := Rect2i(515, 618, 410, 24)
	var centres: Array = []
	var run_start := -1
	for x in range(band.position.x, band.end.x + 1):
		var gold_rows := 0
		if x < band.end.x:
			for y in range(band.position.y, band.end.y):
				var c := img.get_pixel(x, y)
				if c.r > 0.45 and c.r > c.b + 0.2:
					gold_rows += 1
		var is_marker := gold_rows >= 6
		if is_marker and run_start < 0:
			run_start = x
		elif not is_marker and run_start >= 0:
			if x - run_start >= 5:
				centres.append((run_start + x - 1) / 2.0)
			run_start = -1
	if centres.size() != 3:
		_fail("expected 3 diamonds on the painted track, found %d at %s" % [centres.size(), str(centres)])
		return
	for i in 3:
		var m := _part(row, "mastery_marker_%d" % (i + 1))
		if m.is_empty():
			_fail("layout has no mastery_marker_%d" % (i + 1))
			continue
		var r: Rect2 = _L.rect_of(m, origin)
		var cx := r.position.x + r.size.x / 2.0
		if absf(cx - centres[i]) > 1.5:
			_fail("marker %d is centred at %.1f, the painted diamond at %.1f" % [i + 1, cx, centres[i]])
	# The fill lies inside the track's interior rows and spans from before the first
	# diamond to the track's end.
	var f := _part(row, "mastery_fill")
	if f.is_empty():
		_fail("layout has no mastery_fill")
		return
	var fr: Rect2 = _L.rect_of(f, origin)
	var top := _track_edge(img, 750, 618, 632)
	var bottom := _track_edge(img, 750, 645, 632)
	if top < 0 or bottom < 0:
		_fail("could not find the track's edge lines at x 750")
	elif fr.position.y <= top or fr.end.y > bottom:
		_fail("fill rows %.0f..%.0f are not inside the track's interior %d..%d" % [fr.position.y, fr.end.y, top + 1, bottom])
	if fr.position.x > centres[0] or fr.end.x < centres[2] + 60:
		_fail("fill spans %.0f..%.0f; it must start before the first diamond (%.0f) and run well past the third (%.0f)" % [fr.position.x, fr.end.x, centres[0], centres[2]])
	if str(f.get("fill", "")) != "left":
		_fail("mastery_fill must be a left fill")


## Walks from y toward `toward` at column x and returns the first bright row (an edge line).
func _track_edge(img: Image, x: int, from_y: int, toward: int) -> int:
	var step := 1 if toward > from_y else -1
	var y := from_y
	while y != toward:
		var c := img.get_pixel(x, y)
		if (c.r + c.g + c.b) / 3.0 > 0.25:
			return y
		y += step
	return -1


func _fill_fraction_places_the_count_between_the_markers(row: Dictionary) -> void:
	var built: Dictionary = _L.instantiate(row)
	var p: Dictionary = built["parts"]
	var fill: Control = p["mastery_fill"]
	var track_x: float = fill.position.x
	var track_w: float = float(fill.get_meta("full").x)
	var x1: float = p["mastery_marker_1"].position.x + 8.0
	var x2: float = p["mastery_marker_2"].position.x + 8.0
	var want_at := func(x: float) -> float: return (x - track_x) / track_w
	var cases := [
		# reached, next, collects, expected fill edge (x in the row)
		[100, 250, 213, x1 + (x2 - x1) * 113.0 / 150.0],  # the user's case: three quarters of the way
		[100, 250, 100, x1],                                # just reached: the fill stands on the first marker
		[100, 250, 250, x2],                                # about to roll over: on the second
		[0, 25, 0, x1],                                     # a fresh row
		[0, 25, 20, x1 + (x2 - x1) * 0.8],
	]
	for c in cases:
		var got: float = _C.mastery_fill_fraction(p, c[0], c[1], c[2])
		var want: float = want_at.call(c[3])
		if absf(got - want) > 0.002:
			_fail("reached %d next %d collects %d: fill %.3f, want %.3f" % [c[0], c[1], c[2], got, want])
	if not is_equal_approx(_C.mastery_fill_fraction(p, 1000, 0, 1400), 1.0):
		_fail("a finished ladder should fill the whole track")
	built["node"].free()
