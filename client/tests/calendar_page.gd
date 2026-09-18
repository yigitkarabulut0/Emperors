extends SceneTree
## The day's reward is its painting: DAILY REWARDS, twenty-eight squares and
## this week's chests, on the painted pages' host.
##
## It was a Sheet of seven diamond squares and a paragraph. Now every square is
## the server's calendar drawn on art/reference/calendar.png's own kit. What
## must hold, on 941x1672 and 941x2040, with and without a Dynamic Island, for
## a new lord's day one, day six of a thirty-three-day streak, day twenty-eight
## taken, a streak broken with no pardon and too few diamonds, one broken with
## two pardons, and a crown square to take today:
##  - the page is a PaintedPage whose painting is drawn whole, nothing leaves
##    the screen or goes under the notch, every figure fits its box and every
##    button takes a thumb;
##  - the 28 squares are the 28 days in order, the plain ones in the painting's
##    rows and the crowns standing on those same rows; today's wears the glowing
##    square and its light; a taken one its seal over a darkened picture; every
##    picture is its kind's, and each crown wears its prize's -- the title's
##    crown, the frame, the chest, the crest; the plates say the amounts;
##  - the header says the day and the streak, or when to come back;
##  - a broken streak shows the BROKEN row: RESTORE with its price (red when the
##    purse is short), USE PARDON off without a pardon (and no count), on with
##    them (and their count in the bubble, on the plate's corner on every
##    canvas), START ANEW; CLAIM gives way to CLOSE; unbroken, the row says how
##    many pardons are held; the ribbon keys clean off the page, no haze;
##  - THIS WEEK's fill ends on the painted markers at the thresholds and fills
##    the channel at the week's last point; a chest not reached is dim and off,
##    one ready is bright and on, one taken sealed and off.
##
## Run: godot --headless --path client --script tests/calendar_page.gd

const CANVASES := [Vector2i(941, 1672), Vector2i(941, 2040)]
const INSETS := [0.0, 141.0]
const MIN_H := 95.0

var _fails := 0
var _checked := 0
var _fx: GDScript
var _page: GDScript


func _initialize() -> void:
	await process_frame
	root.get_node("Env").set("api_base_url", "http://127.0.0.1:9")
	root.get_node("GameState").set("snapshot", {"player": {"username": "Wwwwwwwwwwwwwwww", "avatar": "knight",
		"level": 30, "gold": "987654321", "treasury": "0", "diamonds": 12}, "energy": {"current": 185, "max": 236}})
	_fx = load("res://tests/fixtures/calendar_fixture.gd")
	_page = load("res://scenes/pages/daily_page.gd")
	_statics()
	for canvas in CANVASES:
		for inset in INSETS:
			var tag := "%dx%d inset %d" % [canvas.x, canvas.y, int(inset)]
			await _case("new " + tag, canvas, inset, _fx.daily(1, true, 0), _fx.weekly(0))
			await _case("mid " + tag, canvas, inset, _fx.daily(6, true, 33), _fx.weekly(120))
			await _case("day 28 " + tag, canvas, inset, _fx.daily(28, false, 55), _fx.weekly(240, [0, 1, 2]))
			await _case("broken " + tag, canvas, inset, _fx.daily(9, true, 8, _fx.broken(2, false), 0, 12), _fx.weekly(170, [0]))
			await _case("pardon " + tag, canvas, inset, _fx.daily(15, true, 14, _fx.broken(1, true), 2, 400), _fx.weekly(80))
			await _case("crown " + tag, canvas, inset, _fx.daily(14, true, 13), _fx.weekly(160, [0]))
			await _case("last day " + tag, canvas, inset, _fx.daily(28, true, 999), _fx.weekly(239, [0, 1]))
	if _checked < 28:
		_fail("only %d of 28 calendars were measured: the page did not open as a painted page" % _checked)
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  %d calendars: the painting's squares, crowns, broken row and chests, on both canvases, under the notch" % _checked)
	quit()


func _fail(msg: String) -> void:
	_fails += 1
	print("  FAIL  " + msg)


## The pure parts: the plates' words, the crown's prize, the header, the bar.
func _statics() -> void:
	var sq := {"day": 3, "kind": "purse", "amount": 9876543, "state": "ahead", "lines": []}
	_want(_page.plate_text(sq), "9.88M", "a purse's plate")
	_want(_page.plate_text({"kind": "diamonds", "amount": 1234}), "1,234", "a diamond square's plate")
	_want(_page.plate_text({"kind": "flask", "amount": 2}), "×2", "a flask square's plate")
	for day in [7, 14, 21, 28]:
		var lines: Array = _fx.lines_for(day, "crown")
		var want: String = {7: "title", 14: "frame", 21: "gear", 28: "crest"}[day]
		_want(_page.crown_of({"lines": lines}), want, "day %d's crown picture" % day)
		_want(_page.plate_text({"kind": "crown", "lines": lines}), "+%d" % int(_fx.DIAMONDS[day]), "day %d's plate" % day)
	_want(_page.plate_text({"kind": "crown", "lines": [{"kind": "item", "tier": "rare", "text": "Rare gear"}]}), "RARE",
		"a crown of gear alone")
	_want(_page.header(_fx.daily(6, true, 33)), "DAY 6 OF 28 · 33 DAYS IN A ROW", "the header, mid-streak")
	_want(_page.header(_fx.daily(1, true, 0)), "DAY 1 OF 28", "the header, day one")
	_want(_page.header(_fx.daily(28, false, 55)), "COME BACK TOMORROW FOR DAY 1", "the header after day 28")
	_want(_page.header(_fx.daily(9, true, 8, _fx.broken(2, false))), "THE STREAK IS BROKEN · 2 DAYS MISSED", "the header, broken")
	_want(_page.detail(_fx.daily(14, true, 13)["squares"][13]), "Day 14, today: 30 diamonds, Loyal Vassal (frame)", "a crown square's tap")
	# The BROKEN ribbon keys clean off the page: its crop's outer rows and
	# columns are clear, not a haze of the painting's grain. At a floor of 5 the
	# grain keyed to alpha 6-45 over 57% of that ring -- a box of texture round
	# the ribbon wherever the tall canvas moved it.
	var ribbon: Image = (root.get_node("Art").call("tex", "calendar/broken") as Texture2D).get_image()
	if ribbon.is_compressed():
		ribbon.decompress()
	var ring := 0
	var haze := 0
	for y in ribbon.get_height():
		for x in ribbon.get_width():
			if x >= 4 and x < ribbon.get_width() - 4 and y >= 4 and y < ribbon.get_height() - 4:
				continue
			ring += 1
			var a := ribbon.get_pixel(x, y).a8
			if a > 0 and a < 64:
				haze += 1
	if float(haze) / float(ring) > 0.05:
		_fail("the BROKEN ribbon carries a haze of the page round it: %d of %d edge pixels faintly opaque" % [haze, ring])
	var chests: Array = _fx.weekly(0)["chests"]
	for c in [[0, 0.0], [80, (451.0 - 201.0) / 624.0], [160, (637.0 - 201.0) / 624.0], [120, (544.0 - 201.0) / 624.0],
			[240, 1.0], [300, 1.0]]:
		var got: float = _page.bar_fraction(int(c[0]), 240, chests)
		if absf(got - float(c[1])) > 0.002:
			_fail("the bar at %d points ends at %.3f of the channel, want %.3f" % [c[0], got, c[1]])


func _want(got: Variant, want: Variant, what: String) -> void:
	if str(got) != str(want):
		_fail("%s: \"%s\", want \"%s\"" % [what, got, want])


func _host(canvas: Vector2i) -> Control:
	var vp := SubViewport.new()
	vp.size = canvas
	root.add_child(vp)
	root.get_node("Nav").set("host", vp)
	var host := Control.new()
	host.size = Vector2(canvas)
	vp.add_child(host)
	return host


func _case(what: String, canvas: Vector2i, inset: float, d: Dictionary, w: Dictionary) -> void:
	var host := _host(canvas)
	var opened: Variant = _page.open(host, d, Callable(), {"inset": inset, "weekly": w})
	var s: Script = (opened as Object).get_script() if opened is Object else null
	if s == null or not s.resource_path.ends_with("scripts/ui/painted_page.gd"):
		_fail("%s: the page is not a painted page (%s)" % [what, s.resource_path if s != null else "nothing"])
		host.get_parent().queue_free()
		await process_frame
		return
	var p: Control = opened
	await create_timer(0.4).timeout
	_measure(p, what, canvas, inset)
	_squares(p, what, d)
	_row(p, what, d)
	_week(p, what, w)
	p.call("close")
	await create_timer(0.3).timeout
	host.get_parent().queue_free()
	await process_frame


func _squares(p: Control, what: String, d: Dictionary) -> void:
	var parts: Dictionary = p.get("parts")
	var plain: Array = parts.get("square", [])
	var crowns: Array = parts.get("crown", [])
	if plain.size() != 24 or crowns.size() != 4:
		_fail("%s: %d plain squares and %d crowns, want 24 and 4" % [what, plain.size(), crowns.size()])
		return
	var squares: Array = d["squares"]
	# Each row's crown on its plain squares' row, however the page stretched.
	for r in 4:
		var py: float = (plain[r * 6]["node"] as Control).position.y
		var cy: float = (crowns[r]["node"] as Control).position.y
		if absf(py - cy) > 0.5:
			_fail("%s: row %d's crown is at %.1f, its squares at %.1f" % [what, r + 1, cy, py])
	for i in 28:
		var sq: Dictionary = squares[i]
		var state := str(sq["state"])
		var ps: Dictionary = crowns[i / 7]["parts"] if i % 7 == 6 else plain[(i / 7) * 6 + i % 7]["parts"]
		var day := i + 1
		var seal: Control = ps["seal"]
		if seal.visible != (state == "claimed"):
			_fail("%s: day %d is %s and its seal is %s" % [what, day, state, "shown" if seal.visible else "hidden"])
		var glow: Control = ps["glow"]
		if glow.visible != (state == "today"):
			_fail("%s: day %d is %s and its glow is %s" % [what, day, state, "shown" if glow.visible else "hidden"])
		var amount: Label = ps["amount"]
		if amount.text != _page.plate_text(sq) or amount.text == "":
			_fail("%s: day %d's plate says \"%s\"" % [what, day, amount.text])
		var hit: Control = ps["hit"]
		if not hit.has_meta("square") or int((hit.get_meta("square") as Dictionary).get("day", 0)) != day:
			_fail("%s: the square in day %d's place taps as another day" % [what, day])
		if i % 7 == 6:
			var art := str(_page.CROWN_ART[{7: "title", 14: "frame", 21: "gear", 28: "crest"}[day]])
			var frame: TextureRect = ps["frame"]
			if frame.texture == null or not frame.texture.resource_path.contains(art):
				_fail("%s: day %d's crown wears %s, want %s" % [what, day,
					frame.texture.resource_path if frame.texture != null else "nothing", art])
		else:
			var frame: TextureRect = ps["frame"]
			var want_sq := "calendar/square_today" if state == "today" else "calendar/square."
			if frame.texture == null or not frame.texture.resource_path.contains(want_sq):
				_fail("%s: day %d (%s) wears %s" % [what, day, state, frame.texture.resource_path if frame.texture != null else "nothing"])
			var icon: TextureRect = ps["icon"]
			var want_icon := str(_page.KIND_ICON[str(sq["kind"])])
			if icon.texture == null or not icon.texture.resource_path.contains(want_icon):
				_fail("%s: day %d's picture is %s, want %s" % [what, day,
					icon.texture.resource_path if icon.texture != null else "nothing", want_icon])
			var dimmed := icon.modulate.r < 0.9
			if dimmed != (state == "claimed"):
				_fail("%s: day %d is %s and its picture is %s" % [what, day, state, "darkened" if dimmed else "bright"])


func _row(p: Control, what: String, d: Dictionary) -> void:
	var broken: Variant = d.get("broken", null)
	var is_broken := broken is Dictionary
	for id in ["broken", "restore", "pardon", "anew", "restore_price"]:
		var n := p.call("node", id) as Control
		if n == null or n.visible != is_broken:
			_fail("%s: %s is %s" % [what, id, "missing" if n == null else ("shown" if n.visible else "hidden")])
	var claim := p.call("node", "claim") as Control
	var close := p.call("node", "close") as Control
	var can_claim := bool(d["claimable"]) and not is_broken
	if claim == null or claim.visible != can_claim or close == null or close.visible == can_claim:
		_fail("%s: CLAIM %s and CLOSE %s, a plain claim %s" % [what, "shown" if claim != null and claim.visible else "hidden",
			"shown" if close != null and close.visible else "hidden", "possible" if can_claim else "not possible"])
	var pardons := int(d.get("pardons", 0))
	if is_broken:
		var b: Dictionary = broken
		var price := p.call("node", "restore_price") as Label
		var short := int(d["diamonds"]) < int(b["restore_diamonds"])
		if price == null or price.text != str(int(b["restore_diamonds"])):
			_fail("%s: RESTORE says \"%s\"" % [what, price.text if price != null else ""])
		elif (price.label_settings.font_color.g < 0.5) != short:
			_fail("%s: RESTORE's price is %s with %d diamonds for %d" % [what,
				"red" if price.label_settings.font_color.g < 0.5 else "plain", int(d["diamonds"]), int(b["restore_diamonds"])])
		var pardon := p.call("node", "pardon") as BaseButton
		var want_on := bool(b["can_pardon"]) and pardons > 0
		if pardon.disabled == want_on:
			_fail("%s: USE PARDON is %s with %d pardons" % [what, "off" if pardon.disabled else "on", pardons])
		var bubble := p.call("node", "pardon_bubble") as Control
		if bubble.visible != (pardons > 0):
			_fail("%s: the pardons' bubble is %s with %d" % [what, "shown" if bubble.visible else "hidden", pardons])
		elif pardons > 0 and (p.call("node", "pardon_count") as Label).text != str(pardons):
			_fail("%s: the bubble counts %s pardons, want %d" % [what, (p.call("node", "pardon_count") as Label).text, pardons])
		# The bubble rides USE PARDON's top right corner on every canvas: it once
		# started inside the stretch band above the row, and on 941x2040 the band
		# carried the row ~90 below it, so the count floated in the empty page.
		if pardons > 0:
			var plate := pardon.get_global_rect()
			var c := bubble.get_global_rect().get_center()
			var corner := Vector2(plate.end.x, plate.position.y)
			if absf(c.x - corner.x) > 26.0 or c.y < corner.y - 12.0 or c.y > corner.y + 26.0:
				_fail("%s: the pardons' bubble is centred at %s, off USE PARDON's corner %s" % [what, c.round(), corner.round()])
			var count := (p.call("node", "pardon_count") as Control).get_global_rect().get_center()
			if count.distance_to(c) > 6.0:
				_fail("%s: the pardons' count stands at %s, off its bubble at %s" % [what, count.round(), c.round()])
	else:
		var t := p.call("node", "row_title") as Label
		var want := "ROYAL PARDONS  %d OF %d" % [pardons, int(d["pardons_max"])]
		if t == null or not t.visible or t.text != want:
			_fail("%s: the pardons row says \"%s\"" % [what, t.text if t != null else ""])


func _week(p: Control, what: String, w: Dictionary) -> void:
	var fill := p.call("node", "week_fill") as Control
	var points := int(w["points"])
	if points == 0:
		if fill.visible:
			_fail("%s: the bar shows a fill at 0 points" % what)
	else:
		var want_end: float = 201.0 + 624.0 * float(_page.bar_fraction(points, int(w["points_max"]), w["chests"]))
		var end := fill.position.x + fill.size.x
		if not fill.visible or absf(end - want_end) > 1.0:
			_fail("%s: at %d points the fill ends at %.1f, want %.1f" % [what, points, end, want_end])
	var pts := p.call("node", "points") as Label
	if pts.text != "%d/240" % points:
		_fail("%s: the points plate says \"%s\"" % [what, pts.text])
	for i in 3:
		var c: Dictionary = w["chests"][i]
		var taken := bool(c["claimed"])
		var ready := bool(c["ready"]) and not taken
		var chest := p.call("node", "chest_%d" % i) as Control
		var bright := chest.modulate.r > 0.95
		if bright != ready:
			_fail("%s: chest %d (%s) is %s" % [what, i, "taken" if taken else ("ready" if ready else "waiting"),
				"bright" if bright else "dim"])
		if (p.call("node", "chest_%d_seal" % i) as Control).visible != taken:
			_fail("%s: chest %d's seal disagrees with its being taken" % [what, i])
		if (p.call("node", "chest_%d_hit" % i) as BaseButton).disabled == ready:
			_fail("%s: chest %d can%s be taken" % [what, i, "not" if ready else ""])
		if (p.call("node", "chest_%d_at" % i) as Label).text != str(int(c["at"])):
			_fail("%s: chest %d's plate says \"%s\"" % [what, i, (p.call("node", "chest_%d_at" % i) as Label).text])


## Everything on the screen and under the notch; the painting whole; figures
## in their boxes; buttons a thumb tall.
func _measure(p: Control, what: String, canvas: Vector2i, inset: float) -> void:
	_checked += 1
	var W := float(canvas.x)
	var H := float(canvas.y)
	var scale: float = p.get("page_scale")
	var slices: Array = []
	for n in _all(p):
		var c := n as Control
		if c == null or not c.is_visible_in_tree():
			continue
		if c.has_meta("page_slice"):
			slices.append(c)
		if c is ColorRect or (c is TextureRect and (c as TextureRect).texture is GradientTexture2D):
			continue
		if c == p or c.get_parent() == p:
			continue
		var r := c.get_global_rect()
		if r.position.x < -0.5 or r.end.x > W + 0.5 or r.position.y < inset - 0.5 or r.end.y > H + 0.5:
			_fail("%s: %s is at %s, off the screen or under the notch" % [what, c.get_class(), r])
		if c is Label and (c as Label).text != "":
			var l := c as Label
			var s := l.label_settings
			var box := float(l.get_meta("box_w", l.size.x))
			if l.autowrap_mode != TextServer.AUTOWRAP_OFF:
				var m := s.font.get_multiline_string_size(l.text, HORIZONTAL_ALIGNMENT_LEFT, box, s.font_size)
				if m.y > l.size.y + 1.0:
					_fail("%s: \"%s\" runs %d tall in a %d box" % [what, l.text, int(m.y), int(l.size.y)])
			elif s.font.get_string_size(l.text, HORIZONTAL_ALIGNMENT_LEFT, -1, s.font_size).x > box + 1.0:
				_fail("%s: \"%s\" is wider than its %d box" % [what, l.text, int(box)])
		if c is BaseButton and scale >= 1.0 and r.size.y < MIN_H:
			_fail("%s: a button is %.0f tall, under a thumb" % [what, r.size.y])
	slices.sort_custom(func(a: Control, b: Control) -> bool: return a.position.y < b.position.y)
	var y := 0.0
	for s in slices:
		if s.position.y > y + 0.01:
			_fail("%s: the painting has a gap from %.1f to %.1f" % [what, y, s.position.y])
		y = maxf(y, s.position.y + s.size.y)
	var want_h := 1672.0 + float(p.get("extra"))
	if slices.is_empty() or absf(y - want_h) > 1.01:
		_fail("%s: the painting runs to %.1f of %.1f" % [what, y, want_h])


func _all(n: Node) -> Array:
	var out: Array = [n]
	for c in n.get_children():
		out.append_array(_all(c))
	return out
