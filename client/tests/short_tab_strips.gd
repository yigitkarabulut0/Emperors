extends SceneTree
## The short tab plates (art/reference/tabs_sheet_c.png) are what strips of
## three and four draw.
##
## Four abreast, tabs_sheet_a's 4:1 plates shrank to 0.54 and the Kingdom's
## words went thinner than kingdom.png paints them; the battle history set its
## three words in type over two borrowed plates, because history.png's middle
## plate is spelled MY RADS. The owner painted short (about 3:1) plates for
## every word a strip of three or four needs, and TabStrip draws them:
##
## - every short plate is cut at one size, lit and unlit, for all fifteen words;
## - a strip takes them when it has three or more tabs and every word has one
##   (the Kingdom, the history, and the strips of four still to come), never a
##   strip of two, one whose words have none, nor a mix;
## - the Kingdom's REALM / LORDS / WORKS / RANKS stand on kingdom.png's gold
##   rule (y 615) at its tabs' size, their words no smaller than its 16;
## - the history's ALL / MY RAIDS / ON ME stand on history.png's floor (the
##   crop's foot at 595), their words the painting's 18, the tap areas 96 tall,
##   the painting's own plates lifted from under them; a tap sorts the list.
##
## Run: godot --headless --path client --script tests/short_tab_strips.gd

const WORDS := ["raid", "arena", "campaign", "bounties", "realm", "lords", "works", "ranks",
	"chat", "boss", "war", "help", "all", "my_raids", "on_me"]
const CANVASES := [Vector2(941, 1672), Vector2(941, 2040)]
## The painted words' cap height, measured off the paintings (the ivory ink
## inside each plate): kingdom.png's REALM is 16 tall, history.png's ALL 18.
const KINGDOM_WORD := 15.5
const HISTORY_WORD := 17.5
## kingdom.png's tabs: 54 tall from their rim to the gold rule at 615.
const KINGDOM_FLOOR := 615.0
const KINGDOM_TAB_H := 54.0
## history.png's plates were 58 tall on a foot at 593 (the crop's at 595).
const HISTORY_FLOOR := 595.0

var TS: GDScript
var _fails := 0
var _checked := 0


func _initialize() -> void:
	await process_frame
	TS = load("res://scripts/ui/tab_strip.gd")
	_plates()
	_which_strips()
	_strips_of_four_to_come()
	for canvas in CANVASES:
		await _kingdom(canvas)
		for inset in [0.0, 141.0]:
			await _history(canvas, inset)
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  %d checks: strips of three and four draw the short plates, at their paintings' size" % _checked)
	quit()


func _plates() -> void:
	var size := Vector2.ZERO
	for w in WORDS:
		for suffix in ["", "_lit"]:
			var name := "tabs/short_%s%s" % [w, suffix]
			_checked += 1
			if not ResourceLoader.exists("res://assets/%s.png" % name):
				_fail("%s is not cut" % name)
				continue
			var t: Texture2D = load("res://assets/%s.png" % name)
			if size == Vector2.ZERO:
				size = t.get_size()
			_expect(t.get_size() == size, "%s is %s, the others %s" % [name, t.get_size(), size])
			_expect(_word(t).size.y >= 18.0, "no painted word found on %s" % name)


func _which_strips() -> void:
	var cases := [
		[["realm", "lords", "works", "ranks"], true, "the Kingdom"],
		[["all", "my_raids", "on_me"], true, "the battle history"],
		[["chat", "boss", "war", "help"], true, "the Kingdom's second row"],
		[["revenge", "targets"], false, "a strip of two"],
		[["might", "level", "wealth"], false, "the rankings, whose words have no short plate"],
		[["realm", "lords", "might"], false, "a strip that would mix the two"],
	]
	for c in cases:
		_checked += 1
		_expect(bool(TS.takes_short(c[0])) == bool(c[1]), "%s %s the short plates" % [c[2], "misses" if c[1] else "takes"])


## Attack's RAID / ARENA / CAMPAIGN / BOUNTIES (Wave 5) is one call away.
func _strips_of_four_to_come() -> void:
	var ids := ["raid", "arena", "campaign", "bounties"]
	var rect := Rect2(183, 258, 738, 95)
	var s: Control = TS.make(ids, rect, "raid")
	root.add_child(s)
	_checked += 1
	_expect(bool(s.get("short")), "a RAID / ARENA / CAMPAIGN / BOUNTIES strip does not draw the short plates")
	for id in ids:
		var p: TextureRect = s.plate(id)
		_expect(p.texture.resource_path.ends_with("tabs/short_%s%s.png" % [id, "_lit" if id == "raid" else ""]),
			"the Attack strip's %s wears %s" % [id, p.texture.resource_path])
		_expect(absf(p.position.y + p.size.y - rect.size.y) <= 0.5, "the Attack strip's %s is not on its floor" % id)
	s.queue_free()


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
	if s == null:
		_fail("%s: no tab strip" % tag)
	else:
		_checked += 1
		_expect(bool(s.get("short")), "%s: the strip draws the long plates" % tag)
		var scale := float(s.plate_size.y) / float(s.plate("realm").texture.get_height())
		for id in s.ids:
			var p: TextureRect = s.plate(id)
			_expect(p.texture.resource_path.find("tabs/short_%s" % id) >= 0, "%s: %s wears %s" % [tag, id, p.texture.resource_path])
			var box := Rect2(s.position + p.position, p.size)
			var ink := _plate(p.texture)
			var foot := box.position.y + ink.end.y * scale
			var top := box.position.y + ink.position.y * scale
			_expect(absf(foot - KINGDOM_FLOOR) <= 3.0, "%s: %s's foot is at %.1f, the painted rule at %.0f" % [tag, id, foot, KINGDOM_FLOOR])
			_expect(foot - top >= KINGDOM_TAB_H - 2.0 and foot - top <= KINGDOM_TAB_H + 4.0,
				"%s: %s is %.1f tall, the painted tabs %.0f" % [tag, id, foot - top, KINGDOM_TAB_H])
			_expect(_word(p.texture).size.y * scale >= KINGDOM_WORD,
				"%s: %s's word is %.1f tall, the painting's 16" % [tag, id, _word(p.texture).size.y * scale])
	host.queue_free()
	await process_frame


func _history(canvas: Vector2, inset: float) -> void:
	var tag := "history %dx%d/%d" % [int(canvas.x), int(canvas.y), int(inset)]
	var host := Control.new()
	host.size = canvas
	root.add_child(host)
	var script: GDScript = load("res://scenes/pages/history_page.gd")
	var entries := [{"battle_id": "a", "won": true, "raided": false}, {"battle_id": "b", "won": false, "raided": true}]
	var p: Control = script.open(host, entries, func(_e): pass, {"inset": inset})
	for i in 3:
		await process_frame
	var s: Control = script.call("tabs", p)
	if s == null:
		_fail("%s: the page has no tab strip" % tag)
	else:
		_checked += 1
		_expect(s.ids == ["all", "my_raids", "on_me"] and bool(s.get("short")), "%s: the strip is %s" % [tag, str(s.ids)])
		var want: Rect2 = p.call("map_rect", Rect2(142, 499, 657, 96))
		_expect(Rect2(s.position, s.size).is_equal_approx(want), "%s: the strip is at %s, the layout's %s" % [tag, Rect2(s.position, s.size), want])
		var floor_y: float = (p.call("map_rect", Rect2(0, HISTORY_FLOOR, 1, 0)) as Rect2).position.y
		var scale := float(s.plate_size.y) / float(s.plate("all").texture.get_height())
		var gaps: Array = []
		for i in s.ids.size():
			var id: String = s.ids[i]
			var pl: TextureRect = s.plate(id)
			_expect(absf(s.position.y + pl.position.y + pl.size.y - floor_y) <= 0.5, "%s: %s is not on the painted floor" % [tag, id])
			_expect(_word(pl.texture).size.y * scale >= HISTORY_WORD,
				"%s: %s's word is %.1f tall, the painting's 18" % [tag, id, _word(pl.texture).size.y * scale])
			var hit: Button = s.get("_hits")[id]
			_expect(hit.size.y >= 95.0, "%s: %s's tap area is %.0f tall" % [tag, id, hit.size.y])
			if i > 0:
				gaps.append(pl.position.x - (s.plate(s.ids[i - 1]) as TextureRect).position.x - pl.size.x)
		for g in gaps:
			_expect(absf(float(g) - 15.0) <= 1.0, "%s: the plates are %.1f apart, the painting's 15" % [tag, float(g)])
		# A tap sorts the list: ON ME lights, and the one raid on the player shows.
		(s.get("_hits")["on_me"] as Button).pressed.emit()
		await process_frame
		_expect(str(s.get("selected")) == "on_me", "%s: tapping ON ME did not light it" % tag)
		var shown := 0
		for c in (p.call("content", "list") as Control).get_children():
			if not c.is_queued_for_deletion():
				shown += 1
		_expect(shown == 1, "%s: ON ME shows %d rows, want the one raid on the player" % [tag, shown])
	# The painting's own plates are gone from under the strip: the page's
	# band between the subtitle and the list is its dark ground.
	var img := (load("res://assets/history/page.png") as Texture2D).get_image()
	img.decompress()
	var bright := 0
	for y in range(522, 594, 2):
		for x in range(60, 880, 3):
			var c := img.get_pixel(x, y)
			if maxf(c.r, maxf(c.g, c.b)) > 0.3:
				bright += 1
	_checked += 1
	_expect(bright == 0, "%s: %d bright pixels of the painted plates are left under the strip" % [tag, bright])
	p.call("close")
	host.queue_free()
	await process_frame


## Where a plate's opaque ink is.
func _plate(t: Texture2D) -> Rect2:
	var img := t.get_image()
	img.decompress()
	var r := Rect2i()
	for y in img.get_height():
		for x in img.get_width():
			if img.get_pixel(x, y).a >= 0.5:
				r = Rect2i(x, y, 1, 1) if r.size == Vector2i.ZERO else r.expand(Vector2i(x, y))
	return Rect2(r)


## Where the ivory word is inside a plate (its rim kept out).
func _word(t: Texture2D) -> Rect2:
	var img := t.get_image()
	img.decompress()
	var w := img.get_width()
	var h := img.get_height()
	var r := Rect2i()
	for y in range(16, h - 16):
		for x in range(24, w - 24):
			var c := img.get_pixel(x, y)
			if c.a < 0.5:
				continue
			var hi := maxf(c.r, maxf(c.g, c.b))
			var lo := minf(c.r, minf(c.g, c.b))
			if hi > 0.725 and hi - lo < 0.29:
				r = Rect2i(x, y, 1, 1) if r.size == Vector2i.ZERO else r.expand(Vector2i(x, y))
	return Rect2(r.position, r.size + Vector2i.ONE) if r.size != Vector2i.ZERO else Rect2()


func _expect(cond: bool, what: String) -> void:
	if not cond:
		_fail(what)


func _fail(what: String) -> void:
	_fails += 1
	print("  FAIL  " + what)
