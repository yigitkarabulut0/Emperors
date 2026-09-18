extends SceneTree
## The Kingdom hall is its painting (art/reference/kingdom_hall.png).
##
## JOIN A KINGDOM: the vista and title over a search box, the invitation cards
## with ACCEPT / DECLINE, the kingdom cards with a name plate, the lords, the
## laurel and JOIN, OR, and RAISE YOUR OWN BANNER. It was dialog plates with
## the lion on every row.
##
## - The page draws the painted header, and the hall its painted rows.
## - Each kingdom wears its own crest (Art.crest by kingdom id), in the
##   painted shield's place.
## - Every card's button is the one its action names, with its plate where the
##   painting has it and a thumb's tap area; ACCEPT and DECLINE do not share one.
## - Five invitations stack without touching; no suggestions says so; the
##   longest names (24 letters) stay on their plates; the founding reason
##   stays on its plate.
## - All of it inside the painting's content, at 941x1672 and 941x2040.
##
## Run: godot --headless --path client --script tests/kingdom_hall_painted.gd

const CANVASES := [Vector2(941, 1672), Vector2(941, 2040)]
const CONTENT := Vector2(183, 923)
const LONG := "Wwwwwwwwwwwwwwwwwwwwwwww"

var _fails := 0
var _checked := 0


func _initialize() -> void:
	await process_frame
	for canvas in CANVASES:
		await _page(canvas)
		await _hall(canvas, _data(5, 5), "five invitations")
		await _hall(canvas, _data(0, 0), "no suggestions")
		# Every string the founding plate can carry: the cost at the balance's
		# figures and at late-game ones, and the one reason the server sends.
		for found in [{"can_found": true, "found_cost": 250000, "found_level": 20},
				{"can_found": true, "found_cost": 9999999, "found_level": 99},
				{"can_found": false, "found_reason": "Reach level 20 to found a kingdom.", "found_level": 20}]:
			var d := _data(1, 1)
			d.merge(found, true)
			await _hall(canvas, d, "founding %s" % str(found.get("found_reason", found.get("found_cost"))))
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  %d checks: the hall is its painting, every card its kingdom's, every button its action's" % _checked)
	quit()


func _card(i: int, action: String) -> Dictionary:
	return {"id": "kingdom-%d" % i, "name": LONG if i % 2 == 0 else "The Everlasting Dominion",
		"tag": "WWWW", "level": 120, "members": 19, "member_cap": 20, "reputation": 1234567890,
		"join_policy": "request" if action.begins_with("request") else "open", "king": "Aldric",
		"action": action}


func _data(invites: int, suggested: int) -> Dictionary:
	var inv: Array = []
	for i in invites:
		inv.append(_card(i, "accept" if i < invites - 1 else "cooldown"))
	var rec: Array = []
	var acts := ["join", "request", "requested", "full", "cooldown"]
	for i in suggested:
		rec.append(_card(10 + i, acts[i % acts.size()]))
	return {"in_kingdom": false, "kingdom": null, "members": [], "upgrades": [], "me": null,
		"invites": inv, "recommended": rec, "leaderboard": [], "requests": [],
		"found_cost": 250000, "found_level": 20, "rejoin_in": 0,
		"can_found": suggested > 0, "found_reason": "Reach level 20 to found a kingdom.",
		"max_requests": 5}


## The Kingdom page with no kingdom: its header is the painting's.
func _page(canvas: Vector2) -> void:
	var tag := "page %dx%d" % [int(canvas.x), int(canvas.y)]
	var host := Control.new()
	host.size = canvas
	root.add_child(host)
	var page: Control = (load("res://scenes/tabs/kingdom.gd") as GDScript).new()
	page.set_anchors_preset(Control.PRESET_FULL_RECT)
	host.add_child(page)
	for i in 3:
		await process_frame
	page.set("_data", _data(1, 3))
	page.set("_loaded_once", true)
	page.call("_apply")
	for i in 4:
		await process_frame
	var header := _find_tex(page, "hall/header")
	_expect(header != null and header.is_visible_in_tree(), "%s: the painted header is not drawn" % tag)
	var hall: Control = page.get("_hall")
	_expect(hall != null and absf(hall.position.y - 462.0) < 0.5 and absf(hall.position.x) < 0.5,
		"%s: the hall is not where the painting starts its search row" % tag)
	host.queue_free()
	await process_frame


func _hall(canvas: Vector2, d: Dictionary, what: String) -> void:
	var tag := "%s %dx%d" % [what, int(canvas.x), int(canvas.y)]
	var host := Control.new()
	host.size = canvas
	root.add_child(host)
	var script: GDScript = load("res://scenes/kingdom/kingdom_hall.gd")
	var hall: Control = script.new()
	hall.setup("hall", d, {})
	hall.position = Vector2(0, 462)
	host.add_child(hall)
	for i in 4:
		await process_frame
	var rows: Array = []
	var list: Control = hall.get("_list")
	for r in list.get_children():
		rows.append(r)
	# The painted pieces.
	_expect(_find_tex(hall, "hall/search_field") != null, "%s: no painted search box" % tag)
	_expect(_find_tex(hall, "hall/or") != null and _find_tex(hall, "hall/card_found") != null,
		"%s: no OR or founding card" % tag)
	var invites: Array = d["invites"]
	var suggested: Array = d["recommended"]
	var invite_cards := _all_tex(hall, "hall/card_invite")
	var kingdom_cards := _all_tex(hall, "hall/card_kingdom")
	_expect(invite_cards.size() == invites.size(), "%s: %d invitation cards for %d invitations" % [tag, invite_cards.size(), invites.size()])
	_expect(kingdom_cards.size() == suggested.size(), "%s: %d kingdom cards for %d kingdoms" % [tag, kingdom_cards.size(), suggested.size()])
	if suggested.is_empty():
		var said := false
		for n in _all(hall):
			if n is Label and (n as Label).text.begins_with("No kingdom has a seat free"):
				said = true
		_expect(said, "%s: an empty list says nothing" % tag)
	# Cards stack without touching, inside the painting's content.
	var cards: Array = invite_cards + kingdom_cards
	cards.sort_custom(func(a, b): return a.global_position.y < b.global_position.y)
	for i in cards.size():
		var r := Rect2((cards[i] as Control).global_position, (cards[i] as Control).size)
		_checked += 1
		_expect(r.position.x >= CONTENT.x - 0.5 and r.end.x <= CONTENT.y + 0.5, "%s: a card leaves the painting's content (%s)" % [tag, r])
		if i > 0:
			var above: Control = cards[i - 1]
			_expect(r.position.y >= above.global_position.y + above.size.y - 0.5, "%s: card %d overlaps the one above" % [tag, i])
	# Each kingdom's own crest, and each card's button.
	for row in rows:
		var card := _find_tex(row, "hall/card_invite")
		if card == null:
			card = _find_tex(row, "hall/card_kingdom")
		if card == null:
			continue
		var crest: TextureRect = null
		for n in _all(row):
			if n is TextureRect and (n as TextureRect).texture != null and (n as TextureRect).texture.resource_path.contains("icons/crest_"):
				crest = n
		_expect(crest != null, "%s: a card has no crest" % tag)
		var buttons: Array = []
		for n in _all(row):
			if n is Button:
				buttons.append(n)
				_expect((n as Button).size.y >= 95.0, "%s: the %s button is %.0f tall" % [tag, (n as Button).text, (n as Button).size.y])
		var words: Array = []
		for b in buttons:
			words.append((b as Button).text)
		if card.texture.resource_path.contains("card_invite"):
			_expect(words.has("Decline") and buttons.size() == 2, "%s: an invitation shows %s" % [tag, str(words)])
			var a: Button = buttons[0]
			var b2: Button = buttons[1]
			_expect(not Rect2(a.global_position, a.size).intersects(Rect2(b2.global_position, b2.size)),
				"%s: the invitation's two buttons share a tap area" % tag)
		for b in buttons:
			var t := (b as Button).text
			var want_off := t in ["Full", "Wait"]
			_expect((b as Button).disabled == want_off, "%s: %s is %s" % [tag, t, "off" if (b as Button).disabled else "on"])
			_expect(t in ["Accept", "Decline", "Join", "Request", "Requested", "Full", "Wait"], "%s: a card's button says %s" % [tag, t])
		# The name stays on its plate.
		for n in _all(row):
			if n is Label and ((n as Label).text == LONG or (n as Label).text == "The Everlasting Dominion"):
				var l: Label = n
				_expect(l.size.x <= float(l.get_meta("box_w", l.size.x)) + 0.5 and l.label_settings.font_size >= 13,
					"%s: a long name runs off its plate" % tag)
	# Every plate's words inside its border, whole where they must be read whole.
	for n in _all(hall):
		if not (n is Label and (n as Label).has_meta("plate_rect")):
			continue
		var l: Label = n
		var plate: Rect2 = l.get_meta("plate_rect")
		var drawn := Rect2(l.position, Vector2(l.size.x, maxf(l.size.y, l.get_minimum_size().y)))
		_checked += 1
		_expect(plate.grow(0.5).encloses(drawn), "%s: \"%s\" runs past its plate (%s in %s)" % [tag, l.text, drawn, plate])
		_expect(l.label_settings.font_size >= 13, "%s: \"%s\" is set at %d" % [tag, l.text, l.label_settings.font_size])
		if l.has_meta("found_plate"):
			var f: Font = l.label_settings.font
			var one := f.get_string_size(l.text, HORIZONTAL_ALIGNMENT_LEFT, -1, l.label_settings.font_size).x
			var whole := one <= plate.size.x or (l.autowrap_mode != TextServer.AUTOWRAP_OFF and l.get_minimum_size().y <= plate.size.y)
			_expect(whole and l.text_overrun_behavior == TextServer.OVERRUN_NO_TRIMMING,
				"%s: the founding plate cuts \"%s\"" % [tag, l.text])
			_expect(l.label_settings.font_size >= 15, "%s: the founding plate is set at %d" % [tag, l.label_settings.font_size])
		if l.text.begins_with("Level ") and l.get_parent().get_child(0) is TextureRect \
				and (l.get_parent().get_child(0) as TextureRect).texture.resource_path.contains("card_kingdom"):
			_expect(l.text.ends_with("renown"), "%s: the laurel's line \"%s\" has no unit" % [tag, l.text])
	# The kingdoms wear different crests: one by each id.
	var art: Node = root.get_node("Art")
	for i in suggested.size():
		var want := str(art.call("crest", str(suggested[i]["id"])))
		var seen := false
		for n in _all(hall):
			if n is TextureRect and (n as TextureRect).texture != null and (n as TextureRect).texture.resource_path.ends_with(want + ".png"):
				seen = true
		_expect(seen, "%s: %s does not wear its crest %s" % [tag, suggested[i]["id"], want])
	hall.queue_free()
	host.queue_free()
	await process_frame


func _find_tex(n: Node, asset: String) -> TextureRect:
	for c in _all(n):
		if c is TextureRect and (c as TextureRect).texture != null \
				and (c as TextureRect).texture.resource_path.ends_with(asset + ".png"):
			return c
	return null


func _all_tex(n: Node, asset: String) -> Array:
	var out: Array = []
	for c in _all(n):
		if c is TextureRect and (c as TextureRect).texture != null \
				and (c as TextureRect).texture.resource_path.ends_with(asset + ".png"):
			out.append(c)
	return out


func _all(n: Node) -> Array:
	var out: Array = [n]
	for c in n.get_children():
		out.append_array(_all(c))
	return out


func _expect(cond: bool, what: String) -> void:
	if not cond:
		_fails += 1
		print("  FAIL  " + what)
