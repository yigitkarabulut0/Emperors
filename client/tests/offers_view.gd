extends SceneTree
## ROYAL OFFERS -- the Court's own screen (scenes/court/offers_view.gd), built
## from the owner's painting (art/reference/offers.png).
##
## What must hold:
##  - the cards stand where the painting stands them: 762x345 from x 160 under a
##    502-tall header, 20 apart, and inside a card the three reward tiles, the
##    timer plate and the green price plate are on the painting's own rects;
##  - one card per offer the SERVER says is on sale, in its order, with its
##    title, its lines on the three tiles and its seconds on the timer;
##  - the BEST VALUE ribbon is hung on the offer the catalogue badges, and on
##    no other -- the painting hangs it on its first card, which is the
##    painting's choice and not the game's;
##  - the price is the App Store's (StorePrice) and the page works out none of
##    its own: the catalogue's usd_cents is never a price to show.
##
## Run: godot --headless --path client --script tests/offers_view.gd

const CARD := Rect2(5, 0, 762, 345)
const TILE_X := [313, 456, 600]
const TIMER := Rect2(569, 205, 163, 49)
const BUY := Rect2(498, 262, 237, 69)

var _fails := 0
var _checked := 0
var _lay: GDScript = null


func _initialize() -> void:
	await process_frame
	root.get_node("Env").set("api_base_url", "http://127.0.0.1:9")
	_lay = load("res://scripts/ui/layout.gd")
	_layout_is_the_painting()
	_no_pricing()
	await _cards()
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  %d checks: the offers are the painting's, and every figure on them is the server's" % _checked)
	quit()


func _expect(ok: bool, what: String) -> void:
	_checked += 1
	if not ok:
		_fails += 1
		print("  FAIL  " + what)


func _layout_is_the_painting() -> void:
	var head: Dictionary = _lay.call("element", "offers", "header")
	_expect(not head.is_empty() and (_lay.call("rect_of", head) as Rect2).is_equal_approx(Rect2(155, 0, 786, 502)),
		"the header is not the painting's 786x502 from x 155")
	var list: Dictionary = _lay.call("element", "offers", "list")
	_expect(not list.is_empty() and (_lay.call("rect_of", list) as Rect2).position.y == 502.0,
		"the cards do not start where the painting starts them")
	var tpl: Dictionary = _lay.call("element", "offers", "card")
	_expect(not tpl.is_empty(), "the offers layout has no card")
	if tpl.is_empty():
		return
	_expect((_lay.call("rect_of", tpl) as Rect2).is_equal_approx(CARD),
		"a card is %s, not the painting's %s" % [_lay.call("rect_of", tpl), CARD])
	var parts := {}
	for p in tpl.get("parts", []):
		parts[str((p as Dictionary).get("id", ""))] = p
	for id in ["frame", "bundle", "ribbon", "title", "timer", "buy", "price", "tiles_hit",
			"icon_1", "icon_2", "icon_3", "count_1", "count_2", "count_3"]:
		_expect(parts.has(id), "the card has no %s" % id)
	for i in 3:
		if not parts.has("icon_%d" % (i + 1)):
			continue
		var r: Rect2 = _lay.call("rect_of", parts["icon_%d" % (i + 1)])
		var tile := Rect2(int(TILE_X[i]), 73, 120, 112)
		_expect(tile.encloses(r), "tile %d's picture runs off its painted tile: %s outside %s" % [i + 1, r, tile])
	if parts.has("timer"):
		_expect((_lay.call("rect_of", parts["timer"]) as Rect2).is_equal_approx(TIMER),
			"the timer is not on the painting's plate")
	if parts.has("buy"):
		# The rect is the thumb's (fit-tap-targets grows every painted button to
		# 44 pt); paint_rect is where the painting has the plate, and that is
		# what must not move.
		var b: Dictionary = parts["buy"]
		var drawn: Rect2 = _lay.call("rect_of", {"rect": b.get("paint_rect", b.get("rect"))})
		_expect(drawn.is_equal_approx(BUY), "the price plate is not where the painting has it: %s" % drawn)
		_expect((_lay.call("rect_of", b) as Rect2).size.y >= 95.0,
			"the price plate does not take a thumb")


## The price is the App Store's. The catalogue's usd_cents is Royal Favour's
## arithmetic and never a price to show.
func _no_pricing() -> void:
	# The CODE, not the prose: the file's own notes name usd_cents to say that it
	# is never shown, and a check that read them would fail on its own comment.
	var src := ""
	for line in FileAccess.get_file_as_string("res://scenes/court/offers_view.gd").split("\n"):
		if not line.strip_edges().begins_with("#"):
			src += line + "\n"
	for word in ["usd_cents", "fallback_diamonds", "first_bonus_bp", "* 100", "/ 100.0"]:
		_expect(not src.contains(word), "the offers screen prices with %s itself" % word)


func _offer(id: String, title: String, ends: int, badge: String, lines: int) -> Dictionary:
	var ls: Array = []
	var kinds := [["diamond", 300], ["token", 3], ["cosmetic", 1], ["gold", 4000]]
	for i in lines:
		ls.append({"kind": str(kinds[i][0]), "amount": int(kinds[i][1]), "text": "a thing",
			"icon": "diamond" if i == 0 else "energy_potion"})
	var p := {"id": id, "store_id": "com.emperors.game." + id, "kind": "consumable",
		"shelf": "offers", "title": title, "usd_cents": 499, "lines": ls,
		"first_bonus": false, "available": true, "ends_in": ends}
	if badge != "":
		p["badge"] = badge
	return p


func _store() -> Dictionary:
	return {"products": [
		_offer("late", "The Baron's Treasury", 9000, "", 3),
		_offer("soon", "The Founder's Crate", 600, "best_value", 2),
		_offer("gone", "An Offer That Ended", 0, "", 3),
		{"id": "gems", "store_id": "x", "shelf": "diamonds", "title": "Diamonds",
		 "usd_cents": 499, "lines": [], "available": true},
	], "vip": {}, "stipend": {}, "patronage": {}, "deals": {}, "herald": {}}


func _cards() -> void:
	var host := Control.new()
	host.size = Vector2(941, 1672)
	root.add_child(host)
	var view: Control = (load("res://scenes/court/offers_view.gd") as GDScript).new()
	view.set_anchors_preset(Control.PRESET_FULL_RECT)
	host.add_child(view)
	await process_frame
	view.call("paint", _store())
	await process_frame

	var cards: Array = view.get("_cards")
	_expect(cards.size() == 2, "%d cards were laid, not the two offers still on sale" % cards.size())
	# Soonest to end first, as the Store lists them.
	var titles: Array = []
	var ribbons: Array = []
	for i in cards.size():
		var node: Control = cards[i]
		var labels: Array = []
		var textures: Array = []
		_walk(node, labels, textures)
		var words: Array = []
		for l in labels:
			words.append((l as Label).text)
		titles.append(words)
		_expect(node.position.y == 6.0 + i * 365.0,
			"card %d sits at y %.0f, not the painting's %.0f" % [i + 1, node.position.y, 6 + i * 365])
	_expect((titles[0] as Array).has("THE FOUNDER'S CRATE") or (titles[0] as Array).has("The Founder's Crate"),
		"the offer that ends first is not the first card: %s" % str(titles[0]))
	_expect((titles[0] as Array).has("10m") or str(titles[0]).contains("10m"),
		"the timer does not read the server's seconds: %s" % str(titles[0]))
	_expect(str(titles[0]).contains("300"), "the first tile does not count what the server sent: %s" % str(titles[0]))

	# The ribbon hangs on the badged offer and on no other.
	for i in cards.size():
		var node: Control = cards[i]
		var ribbon := _find_ribbon(node)
		_expect(ribbon != null, "card %d has no ribbon to hang" % [i + 1])
		if ribbon == null:
			continue
		var want := i == 0          # the badged offer is the one that ends first
		_expect(ribbon.visible == want,
			"card %d's ribbon is %s" % [i + 1, "hung" if ribbon.visible else "down"])
	view.queue_free()
	host.queue_free()
	await process_frame


func _find_ribbon(n: Node) -> CanvasItem:
	for c in n.get_children():
		if c is TextureRect and (c as TextureRect).texture != null \
				and str((c as TextureRect).texture.resource_path).contains("ribbon_best"):
			return c
		var deeper := _find_ribbon(c)
		if deeper != null:
			return deeper
	return null


func _walk(n: Node, labels: Array, textures: Array) -> void:
	for c in n.get_children():
		if c is Label and (c as Label).text != "":
			labels.append(c)
		if c is TextureRect:
			textures.append(c)
		_walk(c, labels, textures)
