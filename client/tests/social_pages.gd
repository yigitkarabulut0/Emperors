extends SceneTree
## THE ROLL OF FRIENDS and SETTINGS, the two pages Wave 6 built on YOUR
## LORDSHIP's own page.
##
## Both are drawn from the painted kit -- the friend's row, its ring, its boxes,
## its GIFT plate, the hub's row plate and the painting's own switch -- so what
## must hold is what holds for every painted page, plus what each says:
##
##  - FRIENDS: a row per lord, the asks first; an ask wears YES and NO where a
##    friend wears GIFT, and says nothing in the gold box, because two plates of
##    a thumb's width need its room; GIFT is dark for a lord who has had today's
##    draught and for a lord with none left to give; the roll's own line counts
##    the lords and the draughts; an empty roll says how to fill it; the level
##    gate says the level.
##  - SETTINGS: every yes-or-no is the painting's switch, thrown or at rest as
##    the realm says; a row that opens something says its value instead; the
##    blocked count and the crown's address are the realm's words, not the
##    page's.
##  - Both: nothing off the screen or under the notch, every figure inside its
##    box, every row and plate a thumb's, on both canvases.
##
## Run: godot --headless --path client --script tests/social_pages.gd

const CANVASES := [Vector2i(941, 1672), Vector2i(941, 2040)]
const INSETS := [0.0, 141.0]
const MIN_H := 95.0

var _fails := 0
var _checked := 0


func _initialize() -> void:
	await process_frame
	root.get_node("Env").set("api_base_url", "http://127.0.0.1:9")
	for canvas in CANVASES:
		for inset in INSETS:
			var tag := "%dx%d inset %d" % [canvas.x, canvas.y, int(inset)]
			await _friends(tag, canvas, inset)
			await _friends_empty(tag, canvas, inset)
			await _settings(tag, canvas, inset)
	if _checked < 12:
		_fail("only %d of 12 pages were measured" % _checked)
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  %d checks: the roll and the settings are their painted pieces, and say what the realm said"
		% _checked)
	quit()


func _fail(msg: String) -> void:
	_fails += 1
	print("  FAIL  " + msg)


func _host(canvas: Vector2i) -> Control:
	var vp := SubViewport.new()
	vp.size = canvas
	root.add_child(vp)
	root.get_node("Nav").set("host", vp)
	var host := Control.new()
	host.size = Vector2(canvas)
	vp.add_child(host)
	return host


func _open(path: String, host: Control, inset: float, view: Dictionary, what: String) -> Control:
	var page: Variant = load(path).open(host, {"inset": inset, "view": view})
	var s: Script = (page as Object).get_script() if page is Object else null
	if s == null or not s.resource_path.ends_with("scripts/ui/painted_page.gd"):
		_fail("%s is not a painted page" % what)
		return null
	await create_timer(0.4).timeout
	return page


## The roll: two asks and three friends, one of whom has had today's draught.
func _friends(tag: String, canvas: Vector2i, inset: float) -> void:
	var host := _host(canvas)
	var what := "the roll, " + tag
	var view := {
		"unlocked": true, "unlock_level": 3, "max_friends": 50,
		"gifts_left": 2, "gifts_per_day": 3, "gift_energy": 18,
		"requests": [_lord("Wwwwwwwwwwwwwwww", 60), _lord("Ada", 3)],
		"friends": [_lord("Aldric of Vale", 38), _lord("Bors", 12, true), _lord("Cai", 1)],
	}
	(view["friends"][2] as Dictionary)["gift_waiting"] = true
	var p: Control = await _open("res://scenes/pages/friends_page.gd", host, inset, view, what)
	if p == null:
		host.get_parent().queue_free()
		return
	_measure(p, what, canvas, inset)
	var rows := _rows(p, "list")
	if rows.size() != 5:
		_fail("%s: two asks and three friends built %d rows" % [what, rows.size()])
		host.get_parent().queue_free()
		return
	for i in 2:
		var parts: Dictionary = rows[i]["parts"]
		if not (parts["yes"] as Control).visible or not (parts["no"] as Control).visible:
			_fail("%s: an ask has no answer on it" % what)
		if (parts["gift"] as Control).visible:
			_fail("%s: an ask wears GIFT" % what)
		if (parts["small"] as Control).visible:
			_fail("%s: an ask writes in the gold box, where YES stands" % what)
	for i in range(2, 5):
		var parts: Dictionary = rows[i]["parts"]
		if not (parts["gift"] as Control).visible:
			_fail("%s: a friend has no GIFT" % what)
		if (parts["yes"] as Control).visible or (parts["no"] as Control).visible:
			_fail("%s: a friend is asked to be answered" % what)
	# The lord who has had today's draught: the plate is dark and deaf.
	var given := (rows[3]["parts"]["gift"] as BaseButton)
	if not given.disabled:
		_fail("%s: a lord already gifted today may be gifted again" % what)
	var fresh := (rows[2]["parts"]["gift"] as BaseButton)
	if fresh.disabled:
		_fail("%s: a friend who has had nothing cannot be gifted" % what)
	# What a draught is worth is the realm's figure, not a percentage.
	var worth := (rows[2]["parts"]["small"] as Label).text
	if not worth.contains("18"):
		_fail("%s: the gold box says \"%s\", not what the realm said a draught is worth" % [what, worth])
	if (rows[4]["parts"]["small"] as Label).text != "waiting":
		_fail("%s: a draught waiting from a friend is not said" % what)
	var line := (p.call("node", "subtitle") as Label).text
	if not line.contains("3 of 50") or not line.contains("2 draughts"):
		_fail("%s: the roll's line reads \"%s\"" % [what, line])
	await _closes(p, what)
	host.get_parent().queue_free()
	await process_frame


## An empty roll, and one that is not open yet.
func _friends_empty(tag: String, canvas: Vector2i, inset: float) -> void:
	var host := _host(canvas)
	var what := "an empty roll, " + tag
	var p: Control = await _open("res://scenes/pages/friends_page.gd", host, inset,
		{"unlocked": true, "unlock_level": 3, "max_friends": 50, "gifts_left": 3,
		"gift_energy": 12, "requests": [], "friends": []}, what)
	if p == null:
		host.get_parent().queue_free()
		return
	_measure(p, what, canvas, inset)
	if _rows(p, "list").size() != 0:
		_fail("%s: an empty roll built rows" % what)
	var empty := p.call("node", "empty") as Label
	if empty == null or not empty.visible or empty.text.is_empty():
		_fail("%s: an empty roll says nothing" % what)
	if (p.call("node", "heading") as Control).visible:
		_fail("%s: an empty roll keeps its heading" % what)
	# Before level 3 the ask is deaf and the line says the level.
	load("res://scenes/pages/friends_page.gd").paint(p,
		{"unlocked": false, "unlock_level": 3, "max_friends": 50, "requests": [], "friends": []})
	await process_frame
	if not (p.call("node", "ask") as BaseButton).disabled:
		_fail("%s: a lord below the gate may still ask" % what)
	if not (p.call("node", "subtitle") as Label).text.contains("3"):
		_fail("%s: the gate does not say its level" % what)
	await _closes(p, what)
	host.get_parent().queue_free()
	await process_frame


func _settings(tag: String, canvas: Vector2i, inset: float) -> void:
	var host := _host(canvas)
	var what := "the settings, " + tag
	var view := {
		"notify": {"raid": true, "chat": false, "mail": true, "events": false, "friends": true,
			"quiet_from": 22, "quiet_to": 8},
		"privacy": {"profile": "friends", "online": false, "requests": true},
		"blocked": [{"player_id": "1", "name": "A Lout", "username": "lout", "level": 9}],
		"rules": {"version": 1, "title": "Rules of the Hall", "lines": ["Speak well."],
			"support": "crown@example.com"},
		"support": "crown@example.com",
	}
	var p: Control = await _open("res://scenes/pages/settings_page.gd", host, inset, view, what)
	if p == null:
		host.get_parent().queue_free()
		return
	_measure(p, what, canvas, inset)
	var rows := _rows(p, "body")
	if rows.size() < 9:
		_fail("%s: only %d rows" % [what, rows.size()])
		host.get_parent().queue_free()
		return
	# Every switch is the painting's own, thrown or at rest as the realm says.
	var on: Texture2D = root.get_node("Art").call("tex", "profile/toggle_on")
	var off: Texture2D = root.get_node("Art").call("tex", "profile/toggle_off")
	var want := [true, false, true, false, true]
	for i in want.size():
		var sw := rows[i]["parts"]["switch"] as TextureRect
		if sw.texture != (on if want[i] else off):
			_fail("%s: row %d's switch is not %s" % [what, i, "thrown" if want[i] else "at rest"])
	# A row that opens something says its value where the switch would be.
	var quiet: Dictionary = rows[5]["parts"]
	if (quiet["switch"] as Control).visible:
		_fail("%s: quiet hours wear a switch" % what)
	if not (quiet["value"] as Label).text.contains("22:00"):
		_fail("%s: quiet hours read \"%s\"" % [what, (quiet["value"] as Label).text])
	var words: Array = []
	for r in rows:
		words.append((r["parts"]["value"] as Label).text)
	if not words.has("Friends only"):
		_fail("%s: who may look reads %s" % [what, str(words)])
	if not words.has("1"):
		_fail("%s: the blocked lords are not counted" % what)
	if not words.has("crown@example.com"):
		_fail("%s: the crown's address is not the realm's" % what)
	await _closes(p, what)
	host.get_parent().queue_free()
	await process_frame


func _lord(name: String, level: int, gave := false) -> Dictionary:
	return {"player_id": "id-" + name, "name": name, "username": name.to_lower(), "avatar": "knight",
		"level": level, "might": 1234, "online": level % 2 == 0, "gave_today": gave}


func _rows(p: Control, scroll_id: String) -> Array:
	var content := p.call("content", scroll_id) as Control
	var out: Array = []
	if content == null:
		return out
	for c in content.get_children():
		if c.has_meta("parts"):
			out.append({"node": c, "parts": c.get_meta("parts")})
	return out


func _closes(p: Control, what: String) -> void:
	var b := p.call("node", "close") as BaseButton
	if b == null:
		_fail("%s: there is no CLOSE" % what)
		return
	var closed := [false]
	p.connect("closed", func() -> void: closed[0] = true)
	b.pressed.emit()
	await create_timer(0.3).timeout
	if not closed[0]:
		_fail("%s: CLOSE did not close the page" % what)


func _measure(p: Control, what: String, canvas: Vector2i, inset: float) -> void:
	_checked += 1
	var W := float(canvas.x)
	var H := float(canvas.y)
	var scale: float = p.get("page_scale")
	for n in _all(p):
		var c := n as Control
		if c == null or not c.is_visible_in_tree():
			continue
		if c is ColorRect or (c is TextureRect and (c as TextureRect).texture is GradientTexture2D):
			continue
		if c == p or c.get_parent() == p:
			continue
		var r := c.get_global_rect()
		# A row inside a scroll is clipped by it, not off the screen.
		var scrolled := _in_scroll(c)
		if not scrolled and (r.position.x < -0.5 or r.end.x > W + 0.5
				or r.position.y < inset - 0.5 or r.end.y > H + 0.5):
			_fail("%s: %s is at %s, off the screen or under the notch" % [what, c.get_class(), r])
		if c is Label and (c as Label).text != "":
			var l := c as Label
			var s := l.label_settings
			var box := float(l.get_meta("box_w", l.size.x))
			if l.autowrap_mode != TextServer.AUTOWRAP_OFF:
				var m := s.font.get_multiline_string_size(l.text, HORIZONTAL_ALIGNMENT_LEFT, box, s.font_size)
				if m.y > l.size.y + 1.0:
					_fail("%s: \"%s\" runs %d tall in a %d box" % [what, l.text.substr(0, 20), int(m.y), int(l.size.y)])
			elif s.font.get_string_size(l.text, HORIZONTAL_ALIGNMENT_LEFT, -1, s.font_size).x > box + 1.0:
				_fail("%s: \"%s\" is wider than its %d box" % [what, l.text, int(box)])
		if c is BaseButton and scale >= 1.0 and r.size.y < MIN_H and c.visible:
			_fail("%s: a button is %.0f tall, under a thumb" % [what, r.size.y])


func _in_scroll(c: Control) -> bool:
	var n: Node = c.get_parent()
	while n != null:
		if n is ScrollContainer:
			return true
		n = n.get_parent()
	return false


func _all(n: Node) -> Array:
	var out: Array = [n]
	for c in n.get_children():
		out.append_array(_all(c))
	return out
