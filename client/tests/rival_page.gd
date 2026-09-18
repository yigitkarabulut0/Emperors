extends SceneTree
## A RIVAL'S PAGE (scenes/pages/rival_page.gd) is rival.png, and what it says
## about another lord is exactly what the realm sent.
##
## What must hold, on both canvases and with the notch, for a lord who has
## everything and one who has nothing:
##  - it is a PaintedPage, drawn whole, with nothing off the screen, nothing
##    under the notch, every figure inside its box and every button a thumb's;
##  - the five rings: the soldier's own painting is drawn UNDER that ring's own
##    crop (rival/ring_1..5) and inside it, so a square painting shows round;
##    the sheet's numeral is on the diamond of a slot that is filled and off one
##    that is empty; an empty ring wears the plainest soldier, drawn down;
##  - the three gear windows are covered edge to edge -- the tier's velvet under
##    the piece, the plain cloth and a ghost under an empty slot -- so no part of
##    the painter's own sword is left showing whatever the rival carries;
##  - the patron's seal is shown only for a patron, and the name is given the
##    plate only as far as the seal;
##  - the numbers the spyglass buys are shown ONLY while a report is live: no
##    chips on a free page, a chip on every soldier of a scouted one, and the
##    hour left where the price was;
##  - what the plates may do: ADD FRIEND off for a friend, ATTACK off for a
##    shielded lord, SPY off when a report is live or the day's are spent.
##
## Run: godot --headless --path client --script tests/rival_page.gd

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
			await _rich(tag, canvas, inset)
			await _bare(tag, canvas, inset)
			await _scouted(tag, canvas, inset)
	if _checked < 12:
		_fail("only %d of 12 pages were measured: a page did not open as a painted page" % _checked)
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  %d rival pages hold, round in their rings and silent about what was not bought" % _checked)
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


func _open(host: Control, inset: float, v: Dictionary, what: String) -> Control:
	var page: Variant = load("res://scenes/pages/rival_page.gd").open(host,
		{"player_id": str(v.get("player_id", "")), "offline": true, "inset": inset})
	var s: Script = (page as Object).get_script() if page is Object else null
	if s == null or not s.resource_path.ends_with("scripts/ui/painted_page.gd"):
		_fail("%s is not a painted page" % what)
		return null
	load("res://scenes/pages/rival_page.gd").paint(page, v)
	await create_timer(0.4).timeout
	return page


## A lord who has everything: the longest name the realm allows, a patron's
## seal, a worn title, every slot filled with the longest-named piece, and more
## soldiers than the painting has rings.
func _rich(tag: String, canvas: Vector2i, inset: float) -> void:
	var host := _host(canvas)
	var what := "a lord with everything, " + tag
	var p: Control = await _open(host, inset, _lord(), what)
	if p == null:
		host.get_parent().queue_free()
		return
	_measure(p, what, canvas, inset)
	_rings(p, what, 5, false)
	_gear(p, what, true)
	if not _shown(p, "vip"):
		_fail("%s: the patron's seal is not on the plate" % what)
	var name_l := p.call("node", "name") as Label
	var seal := (p.call("node", "vip") as Control).position.x
	if name_l != null and name_l.position.x + float(name_l.get_meta("box_w", name_l.size.x)) > seal + 1.0:
		_fail("%s: the name is given the plate under the seal" % what)
	if _shown(p, "scouted"):
		_fail("%s: the SCOUTED seal is on a page nobody has scouted" % what)
	_button(p, what, "add_friend", false)   # already a friend
	_button(p, what, "attack", false)       # under a shield
	_button(p, what, "spy", true)
	_says(p, what, "spy_cost", "gold")
	await _closes(p, what)
	host.get_parent().queue_free()
	await process_frame


## A lord with nothing: no kingdom, no title, no seal, no gear, no army.
func _bare(tag: String, canvas: Vector2i, inset: float) -> void:
	var host := _host(canvas)
	var what := "a lord with nothing, " + tag
	var v := _lord()
	v.merge({"name": "Ada", "look": {"worn": {}, "vip_seal": false}, "kingdom": "", "kingdom_tag": "",
		"gear": [{"slot": "weapon", "empty": true}, {"slot": "armor", "empty": true},
			{"slot": "horse", "empty": true}],
		"army": [], "might": 0, "is_friend": false, "requested": false, "shielded": false,
		"can_attack": true, "online": true}, true)
	var p: Control = await _open(host, inset, v, what)
	if p == null:
		host.get_parent().queue_free()
		return
	_measure(p, what, canvas, inset)
	_rings(p, what, 0, false)
	_gear(p, what, false)
	if _shown(p, "vip"):
		_fail("%s: a lord with no Favour wears its seal" % what)
	var title := p.call("node", "title") as Label
	if title != null and title.visible and title.text != "":
		_fail("%s: a lord with no title wears \"%s\"" % [what, title.text])
	_says(p, what, "kingdom", "No kingdom")
	_says(p, what, "seen", "here now")
	_button(p, what, "add_friend", true)
	_button(p, what, "attack", true)
	await _closes(p, what)
	host.get_parent().queue_free()
	await process_frame


## A lord with a live report: the numbers, and the hour left.
func _scouted(tag: String, canvas: Vector2i, inset: float) -> void:
	var host := _host(canvas)
	var what := "a scouted lord, " + tag
	var v := _lord()
	v["scouted"] = true
	v["scouted_for"] = 2820
	var army: Array = v["army"]
	for i in army.size():
		(army[i] as Dictionary)["might"] = 1240 + i * 7
	var p: Control = await _open(host, inset, v, what)
	if p == null:
		host.get_parent().queue_free()
		return
	_measure(p, what, canvas, inset)
	_rings(p, what, 5, true)
	if not _shown(p, "scouted"):
		_fail("%s: the SCOUTED seal is not on the frame" % what)
	# The words on the plate under the portrait move in behind the seal.
	var seen := p.call("node", "seen") as Label
	var stamp := p.call("node", "scouted") as Control
	if seen != null and stamp != null and seen.position.x < stamp.position.x + stamp.size.x - 1.0:
		_fail("%s: the plate's words are under the SCOUTED seal (x %.0f)" % [what, seen.position.x])
	_button(p, what, "spy", false)
	_says(p, what, "spy_cost", "left")
	await _closes(p, what)
	host.get_parent().queue_free()
	await process_frame


## The realm's answer for a lord who has everything.
func _lord() -> Dictionary:
	var army: Array = []
	for i in 10:
		army.append({"type": ["peasant", "mercenary", "gladiator"][i % 3], "name": "Gladiator",
			"tier": ["common", "uncommon", "rare", "epic", "legendary", "mystic", "special"][i % 7]})
	return {
		"player_id": "8f14e45f-ceea-467a-9575-8a0f1b2c3d4e",
		"name": "Wwwwwwwwwwwwwwww", "username": "wwwwwwwwwwwwwwww", "avatar": "knight",
		"level": 60, "might": 9999999,
		"look": {"worn": {"title": "the Drillmaster", "color": "#E8C46A", "crest": "icons/crest_wolf"},
			"vip_seal": true},
		"kingdom": "Wwwwwwwwwwwwwwwwwwww", "kingdom_tag": "WWWW",
		"online": false, "seen_ago": 10800,
		"gear": [
			{"slot": "weapon", "name": "Silvered Arming Sword", "tier": "rare", "art": "weapon_08"},
			{"slot": "armor", "name": "The Unbroken Breastplate", "tier": "mystic", "art": "armor_18"},
			{"slot": "horse", "name": "The Ninth Siege Warhorse", "tier": "legendary", "art": "horse_13"},
		],
		"army": army,
		"scouted": false, "spy_cost": 2280, "spy_left": 3,
		"is_friend": true, "requested": false, "shielded": true, "can_attack": true, "is_me": false,
	}


## The five rings. `filled` is how many of them have a soldier in them.
func _rings(p: Control, what: String, filled: int, scouted: bool) -> void:
	var rings: Array = (p.get("parts") as Dictionary).get("soldier", [])
	if rings.size() != 5:
		_fail("%s: the painting has 5 rings and the page built %d" % [what, rings.size()])
		return
	for i in rings.size():
		var parts: Dictionary = rings[i]["parts"]
		var face := parts.get("face") as TextureRect
		var ring := parts.get("ring") as TextureRect
		var numeral := parts.get("tier") as TextureRect
		var chip := parts.get("might_chip") as Control
		if face == null or ring == null or numeral == null or chip == null:
			_fail("%s: ring %d is missing its face, its ring, its diamond or its chip" % [what, i + 1])
			continue
		# The ring is drawn over the face, and covers it: a soldier's painting
		# is a square, and what must show is the round window.
		if ring.get_index() < face.get_index():
			_fail("%s: ring %d is drawn under the soldier" % [what, i + 1])
		if not Rect2(ring.position, ring.size).encloses(Rect2(face.position, face.size)):
			_fail("%s: ring %d does not cover the soldier's square" % [what, i + 1])
		var want: Texture2D = root.get_node("Art").call("tex", "rival/ring_%d" % (i + 1))
		if ring.texture != want:
			_fail("%s: ring %d wears another ring's crop" % [what, i + 1])
		# The face is a band off the TOP of the soldier's card, the window's own
		# shape: drawn whole it is squashed, and centred it loses the helmet.
		if face.texture is AtlasTexture:
			var region: Rect2 = (face.texture as AtlasTexture).region
			if region.position != Vector2.ZERO:
				_fail("%s: ring %d takes the soldier's card from %s, not its head" % [what, i + 1, region.position])
		else:
			_fail("%s: ring %d draws the whole card" % [what, i + 1])
		var full := i < filled
		if numeral.visible != full:
			_fail("%s: ring %d's diamond is %s" % [what, i + 1, "empty and numbered" if numeral.visible else "filled and bare"])
		if full and numeral.texture == null:
			_fail("%s: ring %d has no numeral" % [what, i + 1])
		if chip.visible != (full and scouted):
			_fail("%s: ring %d's Might chip is %s" % [what, i + 1,
				"shown on a page nobody paid for" if chip.visible else "missing from a scouted page"])


## The three gear windows: covered edge to edge, whatever is in them.
func _gear(p: Control, what: String, filled: bool) -> void:
	var frames: Array = (p.get("parts") as Dictionary).get("gear", [])
	if frames.size() != 3:
		_fail("%s: the painting has 3 gear frames and the page built %d" % [what, frames.size()])
		return
	for i in frames.size():
		var parts: Dictionary = frames[i]["parts"]
		var pic := parts.get("item") as TextureRect
		var words := parts.get("name") as Label
		if pic == null or words == null:
			_fail("%s: gear %d is missing its window or its plate" % [what, i + 1])
			continue
		if not pic.has_meta("ground_node"):
			_fail("%s: gear %d has no cloth under it, so the painter's own piece shows" % [what, i + 1])
			continue
		var ground := pic.get_meta("ground_node") as Control
		if not ground.visible or not Rect2(ground.position, ground.size).encloses(Rect2(pic.position, pic.size)):
			_fail("%s: gear %d's cloth does not fill its window" % [what, i + 1])
		if filled:
			if not pic.visible or pic.texture == null:
				_fail("%s: gear %d is empty on a lord who carries one" % [what, i + 1])
			if words.text.is_empty():
				_fail("%s: gear %d's plate is blank" % [what, i + 1])
		else:
			if pic.visible:
				_fail("%s: gear %d draws a piece a lord does not carry" % [what, i + 1])
			if words.text != ["WEAPON", "ARMOR", "HORSE"][i]:
				_fail("%s: an empty gear %d says \"%s\"" % [what, i + 1, words.text])


func _shown(p: Control, id: String) -> bool:
	var n := p.call("node", id) as Control
	return n != null and n.visible


func _says(p: Control, what: String, id: String, word: String) -> void:
	var l := p.call("node", id) as Label
	if l == null or not l.text.contains(word):
		_fail("%s: %s says \"%s\", not %s" % [what, id, l.text if l != null else "", word])


func _button(p: Control, what: String, action: String, on: bool) -> void:
	var b := p.call("node", action) as BaseButton
	if b == null:
		_fail("%s: there is no %s" % [what, action])
		return
	if b.disabled == on:
		_fail("%s: %s is %s" % [what, action, "off" if b.disabled else "on"])


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
		if r.position.x < -0.5 or r.end.x > W + 0.5 or r.position.y < inset - 0.5 or r.end.y > H + 0.5:
			_fail("%s: %s is at %s, off the screen or under the notch" % [what, c.get_class(), r])
		if c is Label and (c as Label).text != "":
			var l := c as Label
			var s := l.label_settings
			var box := float(l.get_meta("box_w", l.size.x))
			if s.font.get_string_size(l.text, HORIZONTAL_ALIGNMENT_LEFT, -1, s.font_size).x > box + 1.0:
				_fail("%s: \"%s\" is wider than its %d box" % [what, l.text, int(box)])
		if c is BaseButton and scale >= 1.0 and r.size.y < MIN_H:
			_fail("%s: a button is %.0f tall, under a thumb" % [what, r.size.y])


func _all(n: Node) -> Array:
	var out: Array = [n]
	for c in n.get_children():
		out.append_array(_all(c))
	return out
