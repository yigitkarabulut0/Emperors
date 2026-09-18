extends SceneTree
## Every job wears its own painting, whole, in the frame its row gives it.
##
## Fifteen jobs used to share six paintings by their place in the list: Tend the
## Orchard showed a pile of logs, Fish the River a cart of gold, and the Dragon's
## Hoard the grapes. What must hold now:
##  - every job in balance/jobs.json resolves to its own painting, collect/job_<id>,
##    and no two jobs share one;
##  - every painting is exactly the size the row draws it, and was cut at that
##    shape (never stretched to it: crop and draw agree to within 1%);
##  - the frame laid over it is opaque around its window and clear inside it, and
##    the painting runs past the window on every side, so no painting's edge and
##    none of the grapes baked into the row frame can show;
##  - the layout draws the painting under the frame.
##
## Run: godot --headless --path client --script tests/job_paintings.gd

var _fails := 0
var _checked := 0


func _initialize() -> void:
	await process_frame
	var collect: GDScript = load("res://scenes/tabs/collect.gd")
	var consts := collect.get_script_constant_map()
	if not (consts.has("JOB_FRAME") and consts.has("JOB_PAINTING_RECT")):
		print("FAIL  the Collect tab lays no frame over a job's own painting (no JOB_FRAME / JOB_PAINTING_RECT)")
		quit(1)
		return
	var jobs := _jobs()
	if jobs.is_empty():
		_fail("could not read balance/jobs.json")
	var seen := {}
	for i in jobs.size():
		var id := str(jobs[i].get("id", ""))
		var art: String = collect.painting_for(jobs[i], i)
		_checked += 1
		if art != "collect/job_%s" % id:
			_fail("%s is drawn with %s, not its own painting" % [id, art])
		if seen.has(art):
			_fail("%s and %s share %s" % [seen[art], id, art])
		seen[art] = id
		var tex := load("res://assets/%s.png" % art) as Texture2D if ResourceLoader.exists("res://assets/%s.png" % art) else null
		if tex == null:
			_fail("%s has no painting on disk (%s)" % [id, art])
			continue
		var want: Vector2 = collect.JOB_PAINTING_RECT.size
		if tex.get_size() != want:
			_fail("%s is %s, drawn at %s" % [art, tex.get_size(), want])
	_check_cuts()
	_check_frame(collect)
	_check_layout()

	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  all %d jobs wear their own painting, whole, under one frame (%d checks)" % [jobs.size(), _checked])
	quit()


func _fail(msg: String) -> void:
	_fails += 1
	print("  FAIL  " + msg)


func _jobs() -> Array:
	var f := FileAccess.open("res://../balance/jobs.json", FileAccess.READ)
	if f == null:
		return []
	var d: Variant = JSON.parse_string(f.get_as_text())
	if d is Dictionary:
		return d.get("jobs", [])
	return d if d is Array else []


## Every job painting's crop was cut at the shape it is drawn at.
func _check_cuts() -> void:
	var found := 0
	for m in ["collect", "collect_jobs_a", "collect_jobs_b"]:
		var f := FileAccess.open("res://../art/slices/%s.json" % m, FileAccess.READ)
		if f == null:
			_fail("art/slices/%s.json is missing" % m)
			continue
		for c in JSON.parse_string(f.get_as_text()).get("crops", []):
			var name := str(c.get("name", ""))
			if not name.begins_with("collect/job_") or name in ["collect/job_row", "collect/job_frame"]:
				continue
			found += 1
			var r: Array = c["rect"]
			var s: Array = c.get("scale", [r[2], r[3]])
			var stretch := absf((float(r[2]) / float(r[3])) / (float(s[0]) / float(s[1])) - 1.0)
			_checked += 1
			if stretch > 0.01:
				_fail("%s is cut %dx%d and drawn %dx%d: stretched %.1f%%" % [name, r[2], r[3], s[0], s[1], stretch * 100.0])
			if float(s[0]) > float(r[2]) + 0.5:
				_fail("%s is drawn larger than it was painted (%d from %d)" % [name, s[0], r[2]])
	if found < 15:
		_fail("only %d job paintings are cut, want 15" % found)


## The frame covers everything but its window, and the painting covers the window.
func _check_frame(collect: GDScript) -> void:
	var img := Image.load_from_file("res://assets/%s.png" % collect.JOB_FRAME)
	if img == null:
		_fail("the job frame is missing")
		return
	img.convert(Image.FORMAT_RGBA8)
	if Vector2(img.get_size()) != collect.JOB_FRAME_SIZE:
		_fail("the job frame is %s, drawn at %s" % [img.get_size(), collect.JOB_FRAME_SIZE])
		return
	# Inside the window, clear (the chamfered corner aside); outside, solid.
	var window := Rect2i(11, 12, 161, 137)
	var holes := 0
	var blocked := 0
	for y in img.get_height():
		for x in img.get_width():
			var a := img.get_pixel(x, y).a
			var inside := window.has_point(Vector2i(x, y)) and x + y > 31
			if inside and a > 0.02:
				blocked += 1
			elif not window.has_point(Vector2i(x, y)) and a < 0.98:
				holes += 1
	_checked += 1
	if blocked > 0:
		_fail("the frame covers %d pixels of its window" % blocked)
	if holes > 0:
		_fail("the frame is see-through in %d pixels outside its window" % holes)
	var paint: Rect2 = collect.JOB_PAINTING_RECT
	if not paint.encloses(Rect2(window)):
		_fail("the painting %s does not cover the frame's window %s" % [paint, window])
	elif paint.position.x > window.position.x - 1 or paint.end.x < window.end.x + 1 \
			or paint.position.y > window.position.y - 1 or paint.end.y < window.end.y + 1:
		_fail("the painting %s ends flush with the window %s: a unit's slip would show its edge" % [paint, window])


## The row draws the painting, then the frame over it.
func _check_layout() -> void:
	var L: GDScript = load("res://scripts/ui/layout.gd")
	var row: Dictionary = L.find("collect", "job_row")
	var order := []
	var frame_asset := ""
	var painting_rect := Rect2()
	for q in row.get("parts", []):
		order.append(str(q.get("id", "")))
		if str(q.get("id", "")) == "tile":
			frame_asset = str(q.get("asset", ""))
		if str(q.get("id", "")) == "painting":
			painting_rect = L.rect_of(q)
	_checked += 1
	if not ("painting" in order and "tile" in order and order.find("painting") < order.find("tile")):
		_fail("the row does not draw a painting part under its tile part: %s" % str(order))
	if frame_asset != "collect/job_frame":
		_fail("the row's tile part is %s, not the frame" % frame_asset)
	# The painting sits where the frame's window is: the tile part is at [2, -2].
	if painting_rect != Rect2(11, 8, 165, 141):
		_fail("the painting part is at %s, want [11, 8, 165, 141] (the frame's window, two units to spare)" % painting_rect)
