extends SceneTree
## THE TAX CART is chests.png's page, each part saying what the cart does.
##
## Checked:
##  - the view exists and is hosted as a Court view (Shell.VIEWS);
##  - its bands are the painting's, laid edge to edge 16 units higher than
##    painted (the painting's pills sit 16 under the chrome's), the foot pinned
##    to the screen's foot and reaching the cards, on 1672 and 2040;
##  - the yard shows one place per `cap`, lit for each cart waiting and grey for
##    each empty one, at the painting's places for three, inside the panel for
##    more;
##  - every line -- the header's interval, the hourglass, the three cards --
##    says the case: carts and writs waiting, a full yard, an empty one, below
##    the cart's level; the countdown runs from the answer's moment;
##  - OPEN is lit only when it can open, and its refusal says why;
##  - the longest line each plate can hold fits it at a size that reads;
##  - a prize's gold, experience and unrolled gear are shown in the prize's
##    own painting, and rolled gear and tokens keep theirs;
##  - opening plays the cart's ceremony: the opened chest's card with the
##    prize's name in its plate, and the prize's lines.
##
## Run: godot --headless --path client --script tests/chests_view_fit.gd

const PLACES := [214.5, 285.5, 356.5]
const DIMMED := Color(0.55, 0.55, 0.55)
const BASE := {"unlocked": true, "unlock_level": 2, "cap": 3, "interval": 14400, "odds": []}

var _fails := 0


func _initialize() -> void:
	await process_frame
	var gs := root.get_node("GameState")
	gs.set("snapshot", {"player": {"username": "Wwwwwwwwwwwwwwww", "level": 30, "gold": "0", "diamonds": 0,
		"action_seq": 1}, "energy": {"current": 1, "max": 2}, "sections": []})
	if not ResourceLoader.exists("res://scenes/court/chests_view.gd") or not FileAccess.file_exists("res://layout/chests.json"):
		_fail("there is no Tax Cart view (scenes/court/chests_view.gd, layout/chests.json)")
		_done()
		return
	var shell: GDScript = load("res://scenes/shell/shell.gd")
	_expect(str((shell.get_script_constant_map()["VIEWS"] as Dictionary).get("chests", "")).ends_with("chests_view.gd"),
		"the shell does not host the Tax Cart as a Court view")
	var script: GDScript = load("res://scenes/court/chests_view.gd")
	_words(script)
	await _page(script, 1672.0)
	await _page(script, 2040.0)
	await _ceremony()
	_done()


## Every line, straight from the view's rules.
func _words(s: GDScript) -> void:
	_expect(str(s.call("subtitle_for", 14400)) == "The crown's cart returns every four hours.",
		"the header says %s" % s.call("subtitle_for", 14400))
	for c in [[3600, "every hour"], [7200, "every two hours"], [1800, "every 30 minutes"], [5400, "every 1h 30m"],
			[86400 * 2, "every 48 hours"]]:
		_expect(str(s.call("every", c[0])) == c[1], "%d seconds is \"%s\", not \"%s\"" % [c[0], s.call("every", c[0]), c[1]])
	var two := _cart({"stock": 2, "tokens": 1, "next_in": 5400, "can_open": true, "opened": 57})
	var full := _cart({"stock": 3, "tokens": 0, "next_in": 0, "can_open": true, "opened": 1234})
	var empty := _cart({"stock": 0, "tokens": 0, "next_in": 13000, "can_open": false, "opened": 0})
	var writ := _cart({"stock": 0, "tokens": 2, "next_in": 600, "can_open": true, "opened": 1})
	var locked := _cart({"unlocked": false, "stock": 0, "tokens": 0, "next_in": 0, "can_open": false, "opened": 0})
	var cases := [
		# cart, age, waiting, road, opened, timer, open_state
		[two, 0, "2 waiting · 1 writ", "Next in 1h 30m", "57 opened", "1h 30m", "ok"],
		[two, 1800, "2 waiting · 1 writ", "Next in 1h 00m", "57 opened", "1h 00m", "ok"],
		[full, 0, "3 carts waiting", "The yard is full", "1,234 opened", "Full", "ok"],
		[empty, 0, "None waiting", "Next in 3h 36m", "None opened yet", "3h 36m", "empty"],
		[writ, 0, "2 writs held", "Next in 10m 00s", "1 opened", "10m 00s", "ok"],
		[locked, 0, "None waiting", "Opens at level 2", "None opened yet", "Level 2", "locked"],
	]
	for c in cases:
		var cart: Dictionary = c[0]
		var got := [str(s.call("waiting_words", cart)), str(s.call("road_words", cart, c[1])),
			str(s.call("opened_words", cart)), str(s.call("timer_words", cart, c[1])), str(s.call("open_state", cart))]
		var want := [c[2], c[3], c[4], c[5], c[6]]
		_expect(got == want, "%s %ds on reads %s, not %s" % [cart, c[1], got, want])
	# Why OPEN will not open.
	_expect(str((s.call("refusal", empty, 0) as Dictionary).get("body", "")).contains("3h 36m"),
		"an empty yard's refusal does not say when the next cart comes")
	_expect(str((s.call("refusal", locked, 0) as Dictionary).get("body", "")).contains("level 2"),
		"a locked cart's refusal does not say its level")
	_expect((s.call("refusal", two, 0) as Dictionary).is_empty(), "a cart that can open is refused")
	# The prize in its own painting; rolled gear and tokens keep theirs.
	var shown: Array = s.call("dressed_lines", "heavy_purse", [{"kind": "gold", "amount": 7200, "text": "7,200 gold", "icon": "gold"}])
	_expect(str(shown[0]["icon"]) == "rewards/purse_heavy" and str(shown[0]["text"]) == "7,200 gold",
		"a heavy purse's gold is shown as %s" % shown[0])
	shown = s.call("dressed_lines", "scroll", [{"kind": "xp", "amount": 960, "text": "960 experience", "icon": "xp"}])
	_expect(str(shown[0]["icon"]) == "rewards/xp_scroll", "the scroll's experience is shown as %s" % shown[0])
	shown = s.call("dressed_lines", "gear", [{"kind": "item", "icon": "item:uncommon", "tier": "uncommon", "text": "Uncommon gear"}])
	_expect(str(shown[0]["icon"]) == "rewards/gear_chest", "gear not yet rolled is shown as %s" % shown[0])
	shown = s.call("dressed_lines", "gear", [{"kind": "item", "icon": "items/painted/weapon_05", "tier": "uncommon", "text": "A sword"}])
	_expect(str(shown[0]["icon"]) == "items/painted/weapon_05", "rolled gear lost its own painting: %s" % shown[0])
	shown = s.call("dressed_lines", "flask", [{"kind": "token", "id": "flask_small", "icon": "flask_small", "text": "Small Flask"}])
	_expect(str(shown[0]["icon"]) == "flask_small", "a flask lost its own picture: %s" % shown[0])
	# Places: the painting's three, and more spread inside the panel.
	_expect(s.call("cart_places", 3) == PLACES, "three places are not the painting's: %s" % [s.call("cart_places", 3)])
	var five: Array = s.call("cart_places", 5)
	_expect(five.size() == 5 and float(five[0]) >= 168.0 and float(five[4]) <= 398.0,
		"five places run outside the stock panel: %s" % [five])


func _cart(over: Dictionary) -> Dictionary:
	var c := BASE.duplicate()
	c.merge(over, true)
	return c


func _page(script: GDScript, h: float) -> void:
	var host := Control.new()
	host.size = Vector2(941, h)
	root.add_child(host)
	var v: Control = script.new()
	v.set_anchors_preset(Control.PRESET_FULL_RECT)
	host.add_child(v)
	await process_frame
	var ui: Dictionary = v.get("_ui")
	var tag := "%.0f" % h
	# The bands, edge to edge, 16 higher than painted.
	var bands := [["header", "chests/header", 0.0, 388.0], ["scene", "chests/scene", 388.0, 1030.0],
		["controls", "chests/controls", 1030.0, 1161.0], ["cards", "chests/cards", 1161.0, 1500.0]]
	for b in bands:
		var n: TextureRect = ui.get(b[0])
		if n == null:
			_fail("%s: no %s band" % [tag, b[0]])
			continue
		_expect(n.texture != null and n.texture.resource_path.ends_with(str(b[1]) + ".png"),
			"%s: %s wears %s" % [tag, b[0], n.texture.resource_path if n.texture else "nothing"])
		_expect(absf(n.position.y - float(b[2])) < 0.5 and absf(n.position.y + n.size.y - float(b[3])) < 0.5,
			"%s: %s runs %.0f..%.0f, not %.0f..%.0f" % [tag, b[0], n.position.y, n.position.y + n.size.y, b[2], b[3]])
	var foot: Control = ui["footer"]
	_expect(absf(foot.position.y + foot.size.y - h) < 0.5, "%s: the foot ends at %.0f" % [tag, foot.position.y + foot.size.y])
	# On the design canvas the foot reaches up to the cards; on a taller one it
	# keeps to the screen's foot, as every Court page's does.
	if h <= 1672.0:
		_expect(foot.position.y >= 1498.5 and foot.position.y <= 1500.5,
			"%s: the foot starts at %.0f, not at the cards' foot" % [tag, foot.position.y])
	# A yard of two carts and a writ.
	v.call("paint", _cart({"stock": 2, "tokens": 1, "next_in": 5400, "can_open": true, "opened": 57}))
	await process_frame
	var places: Array = v.get("_places")
	_expect(places.size() == 3, "%s: %d places for a yard of three" % [tag, places.size()])
	for i in places.size():
		var p: Dictionary = places[i]
		var node: Control = p["node"]
		var lit := (p["parts"]["lit"] as CanvasItem).visible
		var dim := (p["parts"]["dim"] as CanvasItem).visible
		_expect(lit == (i < 2) and dim == (i >= 2), "%s: place %d is lit %s, grey %s" % [tag, i, lit, dim])
		var centre := node.position + node.size / 2.0
		_expect(absf(centre.x - float(PLACES[i])) < 0.6 and absf(centre.y - 1099.5) < 0.6,
			"%s: place %d stands at %s" % [tag, i, centre])
	_expect((ui["open"] as CanvasItem).modulate == Color.WHITE, "%s: OPEN is dimmed with carts waiting" % tag)
	_expect((ui["caption_waiting"] as Label).text == "2 waiting · 1 writ", "%s: the yard's card says %s" % [tag, (ui["caption_waiting"] as Label).text])
	_expect((ui["subtitle"] as Label).text == "The crown's cart returns every four hours.", "%s: the header says %s" % [tag, (ui["subtitle"] as Label).text])
	# An empty yard: every place grey, OPEN dimmed.
	v.call("paint", _cart({"stock": 0, "tokens": 0, "next_in": 13000, "can_open": false, "opened": 0}))
	await process_frame
	for p in places:
		_expect(not (p["parts"]["lit"] as CanvasItem).visible, "%s: an empty yard shows a cart" % tag)
	_expect((ui["open"] as CanvasItem).modulate == DIMMED, "%s: OPEN is lit with nothing to open" % tag)
	# A yard of five: five places inside the panel.
	v.call("paint", _cart({"cap": 5, "stock": 4, "tokens": 0, "next_in": 60, "can_open": true, "opened": 0}))
	await process_frame
	places = v.get("_places")
	var shown := 0
	for p in places:
		var node: Control = p["node"]
		if not node.visible:
			continue
		shown += 1
		var r := Rect2(node.position + node.size / 2.0 - node.size * node.scale / 2.0, node.size * node.scale)
		_expect(r.position.x >= 164.0 and r.end.x <= 403.0, "%s: a place of five runs out of the panel: %s" % [tag, r])
	_expect(shown == 5, "%s: %d places for a yard of five" % [tag, shown])
	# The longest line each plate holds, at a size that reads.
	var longest := {"caption_waiting": "12 waiting · 12 writs", "caption_road": "Opens at level 20",
		"caption_opened": "1,234,567 opened", "timer": "23h 59m"}
	for id in longest:
		var l: Label = ui[id]
		l.text = longest[id]
		(load("res://scripts/ui/ui.gd") as GDScript).call("fit_line", l, l.label_settings.font_size, 17)
		var st := l.label_settings
		var w := st.font.get_string_size(l.text, HORIZONTAL_ALIGNMENT_LEFT, -1, st.font_size).x
		var box := float(l.get_meta("box_w", l.size.x))
		_expect(w <= box + 0.5 and st.font_size >= 20, "%s: \"%s\" is %.0f wide at %d, its plate %.0f" % [tag, l.text, w, st.font_size, box])
	host.queue_free()
	await process_frame


## The opening's moment: the opened chest's card, the prize named in its plate.
func _ceremony() -> void:
	var host := Control.new()
	host.size = Vector2(941, 1672)
	root.add_child(host)
	var cer: GDScript = load("res://scenes/pages/ceremony.gd")
	cer.call("cart", host, {"prize": "heavy_purse", "name": "Heavy Purse",
		"lines": [{"kind": "gold", "amount": 7200, "text": "7,200 gold", "icon": "rewards/purse_heavy"}]})
	for i in 6:
		await process_frame
	var layer: Node = null
	for c in host.get_children():
		if c is CanvasLayer:
			layer = c
	if layer == null:
		_fail("opening a cart plays no ceremony")
		host.queue_free()
		return
	var prize: Label = layer.find_child("Prize", true, false)
	_expect(prize != null and prize.text == "HEAVY PURSE", "the ceremony names the prize %s" % (prize.text if prize else "nowhere"))
	var emblem: Control = layer.find_child("Emblem", true, false)
	var card: TextureRect = null
	if emblem != null:
		for c in emblem.get_children():
			if c is TextureRect:
				card = c
				break
	_expect(card != null and card.texture != null and card.texture.resource_path.ends_with("chests/card_opened.png"),
		"the ceremony's emblem is not the opened chest's card")
	var tiles: Control = layer.find_child("Tiles", true, false)
	var row: Label = layer.find_child("Row0", true, false)
	_expect(tiles != null and row != null and row.text == "7,200 gold", "the ceremony does not list the prize's lines")
	# Nothing brought, no moment.
	var before := host.get_child_count()
	cer.call("cart", host, {"prize": "purse", "name": "Purse of Gold", "lines": []})
	await process_frame
	_expect(host.get_child_count() == before, "a cart that brought nothing played a ceremony")
	host.queue_free()
	await process_frame


func _done() -> void:
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  the Tax Cart is chests.png's page: bands, yard, lines, OPEN and the opening, on 1672 and 2040")
	quit()


func _expect(ok: bool, why: String) -> void:
	if not ok:
		_fail(why)


func _fail(why: String) -> void:
	_fails += 1
	printerr("  ", why)
