extends SceneTree
## Every tab row is the one component, drawing the painted plates.
##
## The game had three kinds of tab: Attack's two painted plates with a label set
## over the unlit one, the Kingdom's four chips nine-patched to four widths with
## word crops laid over them, and the rankings' three dialog buttons -- green
## for the one chosen. The owner painted every tab word as a plate, unlit and
## lit (art/reference/tabs_sheet_a.png, tabs_sheet_b.png), and TabStrip
## (scripts/ui/tab_strip.gd) is the only thing that draws them.
##
## - layout(): one size for every plate in a row, never drawn up, the outer two
##   on the rect's edges, the same space between each pair, all standing on the
##   rect's floor, inside the rect at both canvases.
## - A tap lights that plate and sends `changed` once; a tab that is off is
##   dimmed and does not answer; a count rides in the rail's bubble.
## - Lighting a tab moves neither its plate nor its word by more than a unit
##   and a half as drawn.
## - Attack switches REVENGE/TARGETS through it, the Kingdom its four sections,
##   and the rankings its three boards.
##
## Run: godot --headless --path client --script tests/tab_strip.gd

const CANVASES := [Vector2(941, 1672), Vector2(941, 2040)]
## The rows the screens draw, with the rect each measured off its painting.
const ROWS := {
	# The Attack tab carries TWO rows since Wave 5: the four sub-tabs in the
	# painted band, and RAID's own REVENGE / TARGETS directly under it.
	"attack": [["raid", "arena", "campaign", "bounties"], Rect2(183, 258, 738, 95)],
	"attack_raid": [["revenge", "targets"], Rect2(183, 357, 738, 95)],
	"kingdom": [["realm", "lords", "works", "ranks"], Rect2(151, 520, 780, 95)],
	# The Kingdom carries TWO rows since Wave 6: its four sections, and the
	# hall, the boss, the war and the kingdom's help directly under them.
	"kingdom_2": [["chat", "boss", "war", "help"], Rect2(151, 621, 780, 63)],
	"rankings": [["might", "level", "wealth"], Rect2(81, 312, 777, 60)],
	"periods": [["this_week", "season", "all_time"], Rect2(150, 389, 641, 46)],
}
const MAX_WORD_SHIFT := 1.5

var _fails := 0
var _checked := 0
## Loaded once the autoloads are up: compiling the class with this script would
## meet Art before it exists.
var TS: GDScript


func _initialize() -> void:
	await process_frame
	# No realm: the pages here are read as they are BUILT, before anything is
	# answered. With a dev API up on 8080 the rankings' boards arrived between
	# the first canvas and the second, and the periods a fresh realm must keep
	# shut were open on the second one alone.
	root.get_node("Env").set("api_base_url", "http://127.0.0.1:9")
	TS = load("res://scripts/ui/tab_strip.gd")
	_layouts()
	_words_stay_put()
	await _taps()
	for canvas in CANVASES:
		await _attack(canvas)
		await _kingdom(canvas)
		await _rankings(canvas)
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  %d checks: every tab row is TabStrip, one size, even, lit in place" % _checked)
	quit()


## The static layout, for every row the game draws and for rows of one to five.
func _layouts() -> void:
	var cases: Array = []
	for k in ROWS:
		cases.append([k, ROWS[k][0], ROWS[k][1]])
	cases.append(["one", ["help"], Rect2(0, 0, 500, 95)])
	cases.append(["five", ["frames", "titles", "colours", "crests", "portraits"], Rect2(160, 0, 781, 95)])
	cases.append(["mixed", ["deeds", "raid", "today"], Rect2(0, 0, 813, 95)])
	for c in cases:
		var lay: Dictionary = TS.layout(c[1], (c[2] as Rect2).size)
		_row_is_even(str(c[0]), c[1], lay, Rect2(Vector2.ZERO, (c[2] as Rect2).size))


func _row_is_even(tag: String, ids: Array, lay: Dictionary, rect: Rect2) -> void:
	var rects: Array = lay.get("rects", [])
	_checked += 1
	_expect(rects.size() == ids.size(), "%s: %d plates laid out for %d tabs" % [tag, rects.size(), ids.size()])
	_expect(float(lay.get("scale", 9.0)) <= 1.0 + 1e-6, "%s: plates drawn up, x%.3f" % [tag, float(lay.get("scale", 0.0))])
	var gaps: Array = []
	for i in rects.size():
		var r: Rect2 = rects[i]
		_expect(r.size == (rects[0] as Rect2).size, "%s: plate %d is %s, plate 0 %s" % [tag, i, r.size, (rects[0] as Rect2).size])
		_expect(rect.grow(0.5).encloses(r), "%s: plate %d %s leaves the rect %s" % [tag, i, r, rect])
		_expect(absf(r.end.y - rect.end.y) <= 0.5, "%s: plate %d stands at %.1f, not on the floor %.1f" % [tag, i, r.end.y, rect.end.y])
		if i > 0:
			gaps.append(r.position.x - (rects[i - 1] as Rect2).end.x)
	if rects.size() > 1:
		_expect(absf((rects[0] as Rect2).position.x) <= 0.5 and absf((rects[-1] as Rect2).end.x - rect.end.x) <= 1.0,
			"%s: the outer plates are not on the rect's edges (%s .. %s)" % [tag, rects[0], rects[-1]])
		for g in gaps:
			_expect(absf(float(g) - float(gaps[0])) <= 1.0, "%s: gaps %s are not even" % [tag, str(gaps)])
			_expect(float(g) >= int(TS.get_script_constant_map()["MIN_GAP"]) - 1.0, "%s: plates %.1f apart, under %.0f" % [tag, float(g), int(TS.get_script_constant_map()["MIN_GAP"])])
	elif rects.size() == 1:
		var r: Rect2 = rects[0]
		_expect(absf(r.get_center().x - rect.get_center().x) <= 0.5, "%s: a lone plate is off centre" % tag)


## Each plate and its word sit in the same place lit and unlit, as drawn.
func _words_stay_put() -> void:
	for k in ROWS:
		var ids: Array = ROWS[k][0]
		var s := float(TS.layout(ids, (ROWS[k][1] as Rect2).size)["scale"])
		var short: bool = TS.takes_short(ids)
		for id in ids:
			var a := _ink(load("res://assets/%s.png" % TS.plate_name(id, short)))
			var b := _ink(load("res://assets/%s_lit.png" % TS.plate_name(id, short)))
			_checked += 1
			for part in ["plate", "word"]:
				var d: Vector2 = (b[part] as Rect2).get_center() - (a[part] as Rect2).get_center()
				_expect(d.length() * s <= MAX_WORD_SHIFT,
					"%s: %s's %s moves (%.1f, %.1f) as drawn when it lights" % [k, id, part, d.x * s, d.y * s])
			_expect((a["word"] as Rect2).size.x > 20.0, "%s: no word found on tabs/%s" % [k, id])


## Where a plate's opaque ink is, and where its ivory word is inside it.
func _ink(t: Texture2D) -> Dictionary:
	var img := t.get_image()
	img.decompress()
	var w := img.get_width()
	var h := img.get_height()
	var plate := Rect2i()
	var word := Rect2i()
	for y in h:
		for x in w:
			var c := img.get_pixel(x, y)
			if c.a < 0.5:
				continue
			plate = Rect2i(x, y, 1, 1) if plate.size == Vector2i.ZERO else plate.expand(Vector2i(x, y))
			if x < 30 or x >= w - 30 or y < 14 or y >= h - 14:
				continue
			var hi := maxf(c.r, maxf(c.g, c.b))
			var lo := minf(c.r, minf(c.g, c.b))
			if hi > 0.725 and hi - lo < 0.29:
				word = Rect2i(x, y, 1, 1) if word.size == Vector2i.ZERO else word.expand(Vector2i(x, y))
	return {"plate": Rect2(plate), "word": Rect2(word)}


## Taps, the dimmed tab and the count.
func _taps() -> void:
	var host := Control.new()
	host.size = Vector2(941, 1672)
	root.add_child(host)
	var s: Control = TS.make(["might", "level", "wealth"], Rect2(64, 300, 813, 95), "might")
	host.add_child(s)
	await process_frame
	var heard: Array = []
	s.changed.connect(func(id: String) -> void: heard.append(id))
	_expect(_lit(s, "might") and not _lit(s, "level"), "the first tab is not the lit one")
	(s.get("_hits")["level"] as Button).pressed.emit()
	_expect(heard == ["level"], "a tap on LEVEL said %s" % str(heard))
	_expect(_lit(s, "level") and not _lit(s, "might"), "LEVEL did not light when tapped")
	(s.get("_hits")["level"] as Button).pressed.emit()
	_expect(heard.size() == 1, "tapping the lit tab again said it changed")
	s.set_enabled("wealth", false)
	(s.get("_hits")["wealth"] as Button).pressed.emit()
	_expect(heard.size() == 1 and not _lit(s, "wealth"), "a tab that is off answered a tap")
	_expect(s.plate("wealth").modulate != Color.WHITE, "a tab that is off is not dimmed")
	for id in s.ids:
		var hit: Button = s.get("_hits")[id]
		_checked += 1
		_expect(hit.size.y >= 95.0, "%s's tap area is %.0f tall" % [id, hit.size.y])
		var p: TextureRect = s.plate(id)
		# Never stretched: drawn at the painting's own shape, and the box it is
		# drawn in is that shape to within a unit.
		var tex_aspect := p.texture.get_width() / float(p.texture.get_height())
		_expect(p.stretch_mode == TextureRect.STRETCH_KEEP_ASPECT_CENTERED and
			absf(p.size.x - p.size.y * tex_aspect) <= 1.5, "%s is drawn out of its painting's shape" % id)
	s.set_count("level", 3)
	var bubble: TextureRect = s.get("_bubbles").get("level")
	_expect(bubble != null and bubble.visible and (bubble.get_meta("count") as Label).text == "3", "a count of 3 is not in the bubble")
	s.set_count("level", 0)
	_expect(not bubble.visible, "a count of 0 leaves a bubble standing")
	host.queue_free()
	await process_frame


func _lit(s: Control, id: String) -> bool:
	return s.plate(id).texture.resource_path.ends_with("%s_lit.png" % TS.plate_name(id, bool(s.get("short"))))


## The Attack tab: its row is a TabStrip of REVENGE and TARGETS on the painted
## rule, and tapping TARGETS shows the targets.
func _attack(canvas: Vector2) -> void:
	var tag := "attack %dx%d" % [int(canvas.x), int(canvas.y)]
	var host := Control.new()
	host.size = canvas
	root.add_child(host)
	var tab: Control = (load("res://scenes/tabs/attack.gd") as GDScript).new()
	tab.set_anchors_preset(Control.PRESET_FULL_RECT)
	host.add_child(tab)
	for i in 3:
		await process_frame
	var subs: Control = tab.get("_subs")
	_expect(subs != null and subs.ids == ROWS["attack"][0],
		"%s: the sub-tab row is not RAID / ARENA / CAMPAIGN / BOUNTIES" % tag)
	if subs != null:
		_in_place(tag + " subs", subs, ROWS["attack"][1])
		_expect(bool(subs.get("short")), "%s: four sub-tabs do not draw the short plates" % tag)
	var s: Control = tab.get("_tabs")
	_expect(s != null and s.ids == ["revenge", "targets"], "%s: the row is not a TabStrip of REVENGE/TARGETS" % tag)
	if s != null:
		_in_place(tag, s, ROWS["attack_raid"][1])
		tab.set("_data", {"revenge": [{"player_id": "a"}, {"player_id": "b"}], "targets": []})
		tab.set("_loaded", true)
		(s.get("_hits")["targets"] as Button).pressed.emit()
		await process_frame
		_expect(str(tab.get("_view")) == "targets", "%s: tapping TARGETS left the view on %s" % [tag, tab.get("_view")])
		_expect(_lit(s, "targets") and not _lit(s, "revenge"), "%s: TARGETS did not light" % tag)
		var bubble: TextureRect = s.get("_bubbles").get("revenge")
		_expect(bubble != null and bubble.visible and (bubble.get_meta("count") as Label).text == "2",
			"%s: two scores waiting are not counted on REVENGE" % tag)
		(s.get("_hits")["revenge"] as Button).pressed.emit()
		await process_frame
		_expect(str(tab.get("_view")) == "revenge" and _lit(s, "revenge"), "%s: tapping REVENGE did not bring it back" % tag)
	host.queue_free()
	await process_frame


## The Kingdom: its four sections through the strip.
func _kingdom(canvas: Vector2) -> void:
	var tag := "kingdom %dx%d" % [int(canvas.x), int(canvas.y)]
	var host := Control.new()
	host.size = canvas
	root.add_child(host)
	var page: Control = (load("res://scenes/tabs/kingdom.gd") as GDScript).new()
	page.set_anchors_preset(Control.PRESET_FULL_RECT)
	host.add_child(page)
	for i in 3:
		await process_frame
	var s: Control = page.get("_tabs")
	_expect(s != null and s.ids == ["realm", "lords", "works", "ranks"], "%s: the row is not a TabStrip of the four" % tag)
	if s != null:
		_in_place(tag, s, ROWS["kingdom"][1])
		page.set("_data", {"kingdom": {"id": "k", "name": "Test", "level": 1}, "members": [], "upgrades": [], "me": {"role": "king"}, "in_kingdom": true})
		page.set("_loaded_once", true)
		page.call("_apply")
		await process_frame
		for id in ["lords", "works", "ranks", "realm"]:
			(s.get("_hits")[id] as Button).pressed.emit()
			for i in 2:
				await process_frame
			_checked += 1
			_expect(str(page.get("_view")) == id, "%s: tapping %s shows %s" % [tag, id.to_upper(), page.get("_view")])
			_expect(_lit(s, id), "%s: %s did not light" % [tag, id.to_upper()])
			_expect((page.get("_section") == null) == (id == "realm"), "%s: %s built the wrong page" % [tag, id.to_upper()])
	host.queue_free()
	await process_frame


## The rankings: three boards through the strip, over the painted board row;
## the periods through a second strip, ALL TIME lit and the other two off.
func _rankings(canvas: Vector2) -> void:
	var tag := "rankings %dx%d" % [int(canvas.x), int(canvas.y)]
	var host := Control.new()
	host.size = canvas
	root.add_child(host)
	var page: Control = (load("res://scenes/pages/leaderboard_page.gd") as GDScript).open(host)
	for i in 3:
		await process_frame
	var boards: Control = page.get_meta("boards") if page.has_meta("boards") else null
	var periods: Control = page.get_meta("periods") if page.has_meta("periods") else null
	_expect(boards != null and boards.ids == ["might", "level", "wealth"], "%s: the boards are not a TabStrip" % tag)
	_expect(periods != null and periods.ids == ["this_week", "season", "all_time"], "%s: the periods are not a TabStrip" % tag)
	if boards != null:
		for id in boards.ids:
			var p: TextureRect = boards.plate(id)
			_expect(Rect2(Vector2.ZERO, canvas).encloses(Rect2(p.global_position, p.size)), "%s: %s runs off the screen" % [tag, id])
		_row_is_even(tag, boards.ids, TS.layout(boards.ids, boards.size), Rect2(Vector2.ZERO, boards.size))
		(boards.get("_hits")["wealth"] as Button).pressed.emit()
		_expect(str(page.get_meta("board")) == "wealth", "%s: tapping WEALTH did not choose the board" % tag)
	if periods != null:
		_expect(_lit(periods, "all_time") and periods.is_enabled("all_time"), "%s: ALL TIME is not the lit, open period" % tag)
		for id in ["this_week", "season"]:
			_expect(not periods.is_enabled(id), "%s: %s answers before seasons exist" % [tag, id])
	page.call("close")
	host.queue_free()
	await process_frame


func _in_place(tag: String, s: Control, rect: Rect2) -> void:
	_expect(Rect2(s.position, s.size).is_equal_approx(rect), "%s: the row is at %s, not the painted %s" % [tag, Rect2(s.position, s.size), rect])
	_row_is_even(tag, s.ids, TS.layout(s.ids, s.size), Rect2(Vector2.ZERO, s.size))
	for id in s.ids:
		var p: TextureRect = s.plate(id)
		_expect(Rect2(Vector2.ZERO, s.size).grow(0.5).encloses(Rect2(p.position, p.size)), "%s: %s leaves its row" % [tag, id])


func _find_strip(n: Node) -> Control:
	if n.get_script() == TS:
		return n
	for c in n.get_children():
		var f: Control = _find_strip(c)
		if f != null:
			return f
	return null


func _expect(cond: bool, what: String) -> void:
	if not cond:
		_fails += 1
		print("  FAIL  " + what)
