extends SceneTree
## THE CONQUEST CAMPAIGN (scenes/attack/campaign_view.gd) draws the server's
## road and measures none of it.
##
## What must hold:
##  - every node stands where the MEASUREMENT puts it (client/layout/
##    campaign_nodes.json, seamed off the paintings by scripts/campaign-road.py)
##    plus the map's own corner, and nowhere else;
##  - a node is hung on the middle of its painted RING, so the glowing one --
##    a bigger picture of the same ring -- lands exactly where the plain one did;
##  - each mile wears the picture its state asks for: shut, open, the one the
##    lord stands in front of, or walked; and a boss wears the boss's;
##  - a boss's crown is never covered by the mile above it;
##  - every tap target is a thumb's 95 units, though the ring is 96 across;
##  - the chapter plates say which chapter is which, and the lit one does not
##    shove its neighbours along;
##  - the chests say what they are waiting for, and TAKEN once taken;
##  - nothing on the page works out a number: no energy, no stars, no Might.
##
## Run: godot --headless --path client --script tests/campaign_map.gd

const CANVASES := [Vector2(941, 1672), Vector2(941, 2040)]
const MAP := Vector2(160, 566)
## Apple's 44 pt on the 941-unit grid.
const THUMB := 95.0
## balance/campaign.json's own names.
const CHAPTER_NAMES := ["The Vale", "The Millwaters", "The Timberwood", "The Ravine",
	"The Cinder Waste", "The Frozen Coast", "The Golden Sands", "The Cloudbreak Peaks",
	"The Drowned City", "The Emperor's Road"]

var _fails := 0
var _checked := 0


func _initialize() -> void:
	await process_frame
	root.get_node("Env").set("api_base_url", "http://127.0.0.1:9")
	_measured_places()
	_ring_centres_are_the_art()
	_no_arithmetic()
	for canvas in CANVASES:
		await _screen(canvas)
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  %d checks: the road is the painting's, measured and not placed" % _checked)
	quit()


func _expect(ok: bool, what: String) -> void:
	_checked += 1
	if not ok:
		_fails += 1
		print("  FAIL  " + what)


## The measurement exists, covers every map, and reads as twelve points on a
## 776x1030 painting -- the shape of the file the view trusts.
func _measured_places() -> void:
	var path := "res://layout/campaign_nodes.json"
	_expect(FileAccess.file_exists(path), "the measured road points are missing")
	if not FileAccess.file_exists(path):
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	_expect(parsed is Dictionary, "the road points are not a map of chapters")
	var d: Dictionary = parsed
	_expect(d.size() >= 10, "only %d maps are measured" % d.size())
	for key in d:
		var pts: Array = d[key]
		_expect(pts.size() == 12, "map %s has %d points" % [key, pts.size()])
		var last_y := 99999
		for p in pts:
			var x := int((p as Array)[0])
			var y := int((p as Array)[1])
			_expect(x > 40 and x < 736, "map %s has a node at x %d, off the painting" % [key, x])
			_expect(y > 0 and y < 1030, "map %s has a node at y %d, off the painting" % [key, y])
			_expect(y < last_y, "map %s walks downhill: %d after %d" % [key, y, last_y])
			last_y = y


## Every node's recorded `centre` is its painted RING, measured off the crop
## itself and not copied from the file the view reads.
##
## The dark disc inside the ring is opaque on purpose (art/slices/campaign.json
## names it in `solid`), and it is the only large dark opaque area in any of
## these crops -- the laurel is green, the banners red, the crown gold. Its
## middle is therefore the ring's middle, whatever else the picture carries.
func _ring_centres_are_the_art() -> void:
	var LO: GDScript = load("res://scripts/ui/layout.gd")
	for id in ["node_shut", "node_open", "node_now", "node_done",
			"boss_shut", "boss_open", "boss_now", "boss_done"]:
		var e: Dictionary = LO.call("element", "campaign", id)
		var parts: Array = e.get("parts", [])
		var asset := str((parts[0] as Dictionary).get("asset", ""))
		var tex: Texture2D = root.get_node("Art").call("tex", asset)
		if tex == null:
			_expect(false, "%s has no picture" % id)
			continue
		var img := tex.get_image()
		var rect: Array = e.get("rect", [0, 0, 1, 1])
		var sx := float(rect[2]) / float(img.get_width())
		var sy := float(rect[3]) / float(img.get_height())
		var sum_x := 0.0
		var sum_y := 0.0
		var n := 0
		for y in img.get_height():
			for x in img.get_width():
				var c := img.get_pixel(x, y)
				if c.a > 0.9 and c.get_luminance() < 0.22:
					sum_x += x
					sum_y += y
					n += 1
		_expect(n > 200, "%s: no ring interior found in the picture (%d pixels)" % [id, n])
		if n <= 200:
			continue
		var got := Vector2(sum_x / n * sx, sum_y / n * sy)
		var centre: Array = e.get("centre", [0, 0])
		var said := Vector2(float(centre[0]), float(centre[1]))
		# Eight units on a node 118 tall: enough room for the dark the crown and
		# the banners carry with them, and nowhere near enough to hide a node
		# hung by its corner, which is fifty units out.
		_expect(got.distance_to(said) <= 8.0,
			"%s: the layout hangs it at %s and its painted ring is at %s" % [id, said, got])


## The client works nothing out: not the stars, not the energy, not the Might.
func _no_arithmetic() -> void:
	var src := FileAccess.get_file_as_string("res://scenes/attack/campaign_view.gd")
	for word in ["two_at_hp", "three_at_hp", "first_clear_wages", "repeat_bp", "might *", "energy *"]:
		_expect(not src.contains(word),
			"campaign_view.gd works out %s: every number on the map is the server's" % word)


func _chapter(id: String, n: int, open: bool) -> Dictionary:
	# The shipped names, so the longest unbreakable words -- MILLWATERS,
	# TIMBERWOOD, CLOUDBREAK -- are the ones the boards are tested with.
	return {"id": id, "name": CHAPTER_NAMES[(n - 1) % CHAPTER_NAMES.size()], "blurb": "A road.",
		"art": "campaign/map_%02d" % n, "level": 6 + n, "stars": 14 if open else 0,
		"max_stars": 36, "open": open, "cleared": 5 if open else 0, "stages": 12,
		"chests": [
			{"index": 0, "stars": 12, "lines": ["20 gold"], "open": open, "claimed": open},
			{"index": 1, "stars": 24, "lines": ["a common piece"], "open": false, "claimed": false},
			{"index": 2, "stars": 36, "lines": ["10 diamonds"], "open": false, "claimed": false},
		]}


func _map() -> Dictionary:
	var chapters: Array = []
	for i in 10:
		chapters.append(_chapter("ch%d" % (i + 1), i + 1, i == 0))
	return {"unlocked": true, "unlock_level": 6, "chapter_id": "ch1", "stage": 6,
		"stars": 14, "max_stars": 360, "chapters": chapters}


## One chapter: five walked, the sixth (a boss) the one they stand in front of,
## the rest shut.
func _stages() -> Dictionary:
	var stages: Array = []
	for i in 12:
		var n := i + 1
		var boss := n == 6 or n == 12
		stages.append({"stage": n, "kind": "boss" if boss else "field", "level": 6 + i,
			"energy": 7, "might": 270 + 40 * i, "enemy": "Reaver", "soldiers": 3,
			"stars": 3 if n <= 5 else 0, "open": n <= 6, "cleared": n <= 5,
			"lines": ["21 gold", "21 xp"],
			"first_item_tier": "common" if boss else ""})
	return {"id": "ch1", "name": "The Chapter Of 1", "art": "campaign/map_01", "stars": 14,
		"stages": stages, "chests": (_chapter("ch1", 1, true))["chests"]}


func _screen(canvas: Vector2) -> void:
	var tag := "%dx%d" % [int(canvas.x), int(canvas.y)]
	var host := Control.new()
	host.size = canvas
	root.add_child(host)
	var v: Control = (load("res://scenes/attack/campaign_view.gd") as GDScript).new()
	host.add_child(v)
	for i in 3:
		await process_frame
	v.call("paint", _map())
	v.call("paint_chapter", _stages())
	await process_frame

	var nodes: Array = v.get("_nodes")
	var stages: Array = (_stages())["stages"]
	_expect(nodes.size() == 12, "%s: %d miles are drawn, not twelve" % [tag, nodes.size()])

	# Where each node stands: the measurement, plus the map's corner, hung on
	# the middle of its own ring.
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://layout/campaign_nodes.json"))
	var points: Array = (parsed as Dictionary)["01"]
	var LO: GDScript = load("res://scripts/ui/layout.gd")
	for i in nodes.size():
		var built: Dictionary = nodes[i]
		var node: Control = built["node"]
		var s: Dictionary = stages[i]
		var want_id := _template_for(s)
		var e: Dictionary = LO.call("element", "campaign", want_id)
		var centre: Array = e.get("centre", [0, 0])
		var at := MAP + Vector2(float((points[i] as Array)[0]), float((points[i] as Array)[1]))
		var ring := node.position + Vector2(float(centre[0]), float(centre[1]))
		_expect(ring.distance_to(at) < 1.5,
			"%s: mile %d is hung at %s and the road is at %s" % [tag, i + 1, ring, at])
		# And its picture is the one its state asks for.
		var ring_tex: TextureRect = built["parts"]["ring"]
		_expect(ring_tex.texture != null, "%s: mile %d has no picture" % [tag, i + 1])
		# A thumb can reach it.
		var hit: Control = built["hit"]
		_expect(hit.size.x >= THUMB and hit.size.y >= THUMB,
			"%s: mile %d takes a %.0fx%.0f tap" % [tag, i + 1, hit.size.x, hit.size.y])

	# A boss stands in FRONT of the mile above it, or its crown is covered.
	var boss_i := 5
	var above_i := 6
	_expect(v.get_children().find((nodes[boss_i] as Dictionary)["node"])
			> v.get_children().find((nodes[above_i] as Dictionary)["node"]),
		"%s: the boss is drawn behind the mile above it, and its crown is covered" % tag)

	# The chapter plates.
	var plates: Array = v.get("_plates")
	_expect(plates.size() == 10, "%s: %d chapter plates" % [tag, plates.size()])
	var first: Dictionary = plates[0]
	var second: Dictionary = plates[1]
	_expect((first["parts"]["num"] as Label).text == "1", "%s: the first plate is not numbered 1" % tag)
	_expect((first["parts"]["name"] as Label).text != "", "%s: the first plate has no name" % tag)
	_expect((second["node"] as Control).position.x > (first["node"] as Control).position.x,
		"%s: the lit plate shoved its neighbour" % tag)
	# The name fits the board it is written on, AND is centred on it.
	#
	# The board is measured out of the PLATE PICTURE here, not taken from a
	# number the view could also get wrong: the three plates (gold, shut, lit)
	# carry their boards in three different places, the layout can record only
	# one rect, and for months every shut chapter's name sat six units right of
	# its board -- "THE MILLWATERS" left sixteen units of bare board on the left
	# and touched the frame on the right.
	for p in plates:
		var d: Dictionary = p
		var l: Label = d["parts"]["name"]
		if not (d["node"] as Control).visible:
			continue
		var box: float = float(l.get_meta("box_w", l.size.x))
		var m := l.label_settings.font.get_multiline_string_size(
			l.text.to_upper(), HORIZONTAL_ALIGNMENT_LEFT, box, l.label_settings.font_size)
		_checked += 1
		_expect(m.x <= box + 1.0 and m.y <= l.size.y + 1.0,
			"%s: %s runs off its board (%.0fx%.0f in %.0fx%.0f)" % [tag, l.text, m.x, m.y, box, l.size.y])
		var plate: TextureRect = d["parts"]["plate"]
		var field := _name_field(plate.texture)
		if field == Vector2.ZERO:
			continue
		# The plate is drawn at its own offset inside the node; the board rides
		# with it, and so must the words.
		var want := plate.position.x + field.x + field.y / 2.0
		var got := l.position.x + l.size.x / 2.0
		_checked += 1
		_expect(absf(got - want) <= 1.5,
			"%s: \"%s\" is centred at %.1f and its board at %.1f (%s)"
			% [tag, l.text, got, want, plate.texture.resource_path.get_file()])


	# The chests say what they wait for, and TAKEN once taken.
	var chests: Array = v.get("_chests")
	_expect(chests.size() >= 3, "%s: %d chests" % [tag, chests.size()])
	_expect(((chests[0] as Dictionary)["parts"]["need"] as Label).text == "TAKEN",
		"%s: a taken chest says %s" % [tag, ((chests[0] as Dictionary)["parts"]["need"] as Label).text])
	_expect(((chests[1] as Dictionary)["parts"]["need"] as Label).text.contains("24"),
		"%s: a shut chest does not say what it waits for" % tag)

	# Nothing runs off the page.
	for built in nodes:
		var node: Control = (built as Dictionary)["node"]
		_expect(node.position.x >= 155.0 and node.position.x + node.size.x <= 941.0,
			"%s: a mile stands off the page at x %.0f" % [tag, node.position.x])
	host.queue_free()
	await process_frame


func _template_for(s: Dictionary) -> String:
	var stem := "boss" if str(s.get("kind", "")) == "boss" else "node"
	if bool(s.get("cleared", false)):
		return stem + "_done"
	if not bool(s.get("open", false)):
		return stem + "_shut"
	# The one the lord stands in front of: the first open mile not yet walked.
	return stem + "_now"

## The name board's own field inside a plate picture: the wide dark run low down
## on it. Returned as (left, width) in the picture's own pixels.
func _name_field(tex: Texture2D) -> Vector2:
	if tex == null:
		return Vector2.ZERO
	var img := tex.get_image()
	if img == null:
		return Vector2.ZERO
	var w := img.get_width()
	var h := img.get_height()
	var best := Vector2.ZERO
	for y in range(int(h * 0.76), int(h * 0.95)):
		var run_start := -1
		var run := Vector2.ZERO
		for x in w:
			var c := img.get_pixel(x, y)
			var dark := c.a > 0.47 and (c.r + c.g + c.b) < 0.667
			if dark:
				if run_start < 0:
					run_start = x
			elif run_start >= 0:
				if x - run_start > run.y:
					run = Vector2(run_start, x - run_start)
				run_start = -1
		if run_start >= 0 and w - run_start > run.y:
			run = Vector2(run_start, w - run_start)
		if run.y > best.y:
			best = run
	return best if best.y > 60.0 else Vector2.ZERO
