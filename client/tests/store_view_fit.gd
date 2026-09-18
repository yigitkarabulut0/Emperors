extends SceneTree
## The Royal Store lays its paintings' sections out whole, and every word on it
## stays on its plate.
##
## - Every section it shows fits the page (x 155..941) at 941x1672 and 941x2040,
##   the sections stack in the paintings' order 10 units apart, and none
##   overlaps the next.
## - Every live text is inside its plate: fitted, or cut with an ellipsis --
##   the longest offer title, "₺1.799,99", a patron's time left.
## - Prices are the App Store's (Billing.price), never the balance's cents; a
##   plate whose price is not known is dimmed, and without StoreKit every buy
##   plate is dimmed and the note says Billing.unavailable_reason().
## - A section with nothing to show is left out: no offer card without a live
##   offer, no Herald's Tidings while the server has it off.
## - The deals: a sold-out cosmetic slot says so; a claimed slot is dimmed; the
##   cosmetic slot draws the cosmetic's own picture.
##
## Run: godot --headless --path client --script tests/store_view_fit.gd

var _fails := 0
var _checked := 0


class FakeProduct extends Object:
	var product_id := ""
	var display_price := ""

	func _init(id: String, price: String) -> void:
		product_id = id
		display_price = price


class FakeKit extends Object:
	signal products_request_completed(products: Array, status: int)
	signal purchase_completed(transaction: Object, status: int, error_message: String)
	signal transaction_updated(transaction: Object)
	signal unverified_transaction_updated(transaction: Object, verification_error: int)
	signal restore_completed(status: int, error_message: String)
	func start() -> void: pass
	func request_products(_ids: PackedStringArray) -> void: pass
	func purchase_with_options(_p: Object, _o: Array) -> void: pass
	func restore_purchases() -> void: pass
	func fetch_current_entitlements() -> void: pass
	func fetch_unfinished_transactions() -> void: pass


func _initialize() -> void:
	await process_frame
	root.get_node("GameState").set("snapshot", {"player": {"username": "Wwwwwwwwwwwwwwww", "level": 30,
		"gold": "1", "diamonds": 12, "action_seq": 1}, "energy": {"current": 1, "max": 2}, "sections": []})
	var billing: Node = root.get_node("Billing")

	# Without StoreKit (this machine): dimmed, and the note says why.
	for h in [1672, 2040]:
		var v := await _view(Vector2(941, h))
		v.call("paint", _store(false))
		await _frames(3)
		_checked += 1
		var why: String = (load("res://scripts/autoload/billing.gd") as GDScript).unavailable_reason()
		_expect(_texts(v).has(why + "\nThe prices shown are in US dollars."), "at %d the note does not say the prices are in dollars" % h)
		# Every paid plate is dimmed the way a disabled painted plate is, and
		# carries the catalogue's reference price in the muted ink -- never a
		# bright, empty green bar.
		var ui: GDScript = load("res://scripts/ui/ui.gd")
		var off: Color = (ui.plate_face("shop/buy_plate") as Button).get_theme_stylebox("disabled").modulate_color
		for e in v.get("_buys"):
			var p: Dictionary = e["product"]
			var label: Label = e["label"]
			var b: CanvasItem = e["button"]
			_checked += 1
			_expect(b.modulate == off, "at %d %s's plate is dimmed %s, a disabled plate %s" % [h, p["id"], b.modulate, off])
			if bool(p.get("owned", false)) or (str(p.get("kind", "")) == "subscription" and bool(_store(false)["patronage"]["active"])):
				continue
			var want := "$%d.%02d" % [int(p["usd_cents"]) / 100, int(p["usd_cents"]) % 100]
			_expect(label.text.begins_with(want), "at %d %s says \"%s\" with no StoreKit, want %s" % [h, p["id"], label.text, want])
			_expect(label.label_settings.font_color == Color("#B8AE9C"), "at %d %s's reference price is not in the muted ink" % [h, p["id"]])
		_layout_checks(v, h, false)
		v.get_parent().queue_free()
		await _frames(2)

	# With a stand-in StoreKit that has not answered yet: "…" on every plate.
	var kit := FakeKit.new()
	billing.call("use_kit", kit)
	var store := _store(true)
	var early := await _view(Vector2(941, 1672))
	early.call("paint", store)
	await _frames(2)
	for e in early.get("_buys"):
		var p: Dictionary = e["product"]
		if bool(p.get("owned", false)) or str(p.get("kind", "")) == "subscription":
			continue
		_checked += 1
		_expect((e["label"] as Label).text == "…", "%s says \"%s\" before the App Store answered" % [p["id"], (e["label"] as Label).text])
	_expect(not _texts(early).has(why_of()), "the note says purchases are closed on a phone with StoreKit")
	early.get_parent().queue_free()
	await _frames(2)

	# The App Store names every price.
	var prices := {}
	var list: Array = []
	for p in store["products"]:
		var sid := str(p["store_id"])
		prices[sid] = "₺1.799,99" if sid.ends_with("gems.4000") else ("US$99.99" if sid.ends_with("gems.8500") else "₺199,99")
		list.append(FakeProduct.new(sid, prices[sid]))
	kit.products_request_completed.emit(list, 0)
	for h in [1672, 2040]:
		var v := await _view(Vector2(941, h))
		v.call("paint", store)
		await _frames(3)
		_layout_checks(v, h, true)
		# Every lit plate says the App Store's price; nothing says usd_cents.
		var buys: Array = v.get("_buys")
		for e in buys:
			var p: Dictionary = e["product"]
			var label: Label = e["label"]
			var want: String = str(prices[str(p["store_id"])])
			_checked += 1
			if bool(p.get("owned", false)):
				_expect(label.text == "OWNED", "%s is owned and its plate says %s" % [p["id"], label.text])
			elif str(p.get("kind", "")) == "subscription" and bool(store["patronage"]["active"]):
				_expect(label.text.ends_with(" left"), "a patron's plate says %s, not the time left" % label.text)
			else:
				_expect(label.text.begins_with(want), "%s says %s, the App Store says %s" % [p["id"], label.text, want])
			_expect(not label.text.begins_with("$"), "%s shows the catalogue's dollars where the App Store named a price" % p["id"])
		# The Baron's Treasury holds a frame: shown as worn, round the lord's face.
		var framed := 0
		var st: Array = [v]
		while not st.is_empty():
			var n: Node = st.pop_back()
			for c in n.get_children():
				st.append(c)
			if n.has_meta("framed_face") and n is TextureRect and (n as TextureRect).texture != null:
				framed += 1
		_checked += 1
		_expect(framed >= 1, "at %d the offer's frame is drawn round no face" % h)
		# Herald's Tidings off: no WATCH anywhere.
		_expect(not _has_asset(v, "store/herald_watch"), "Herald's Tidings is shown while the server has it off")
		# The deals: slot 3 sold out, slot 1 claimed (dimmed), the gift still to take.
		var t := _texts(v)
		_expect(t.has("SOLD OUT"), "a missing cosmetic slot does not say SOLD OUT")
		_expect(t.has("BOUGHT"), "a claimed deal does not say BOUGHT")
		v.get_parent().queue_free()
		await _frames(2)

	# No live offer: no offer card. Herald on: its section is there.
	var quiet := _store(false)
	quiet["herald"] = {"enabled": true}
	var q := await _view(Vector2(941, 1672))
	q.call("paint", quiet)
	await _frames(3)
	_checked += 1
	_expect(not _has_asset(q, "store/offer_card"), "an offer card is shown with no offer live")
	_expect(_has_asset(q, "store/herald_watch"), "Herald's Tidings is hidden while the server has it on")
	# The cosmetic slot draws the crest it sells.
	_expect(_has_asset(q, "icons/crest_dragon"), "the cosmetic deal does not draw the crest it sells")
	q.get_parent().queue_free()
	await _frames(2)

	await _herald_states()

	# Every icon a store line names is its own picture, never the fallback crown:
	# the five lasting goods (rewards/steward ... stipend) and the rest the
	# store's lines use. A title or a name colour has no picture of its own, and
	# the crown is theirs by design.
	var art: Node = root.get_node("Art")
	var keys := {"steward": true, "quartermaster": true, "largesse": true, "patronage": true, "stipend": true,
		"diamond": true, "energy_potion": true, "city_shield": true, "xp": true}
	for p in _store(true)["products"] + _store(false)["products"]:
		for l in p.get("lines", []):
			var k := str(l.get("icon", ""))
			if not k.begins_with("title:") and not k.begins_with("name_color:"):
				keys[k] = true
	for k in keys:
		var t: Texture2D = art.call("reward_icon", k)
		_checked += 1
		_expect(t != null and t.resource_path != "" and not t.resource_path.ends_with("icons/reward_crown.png"),
			"the reward line icon \"%s\" has no picture of its own (%s)" % [k, t.resource_path if t else "nothing"])
	for k in ["steward", "quartermaster", "largesse", "patronage", "stipend"]:
		var t: Texture2D = art.call("reward_icon", k)
		_expect(t.resource_path == "res://assets/rewards/%s.png" % k, "\"%s\" is drawn with %s" % [k, t.resource_path])
		_expect(t.get_width() == t.get_height() and t.get_width() >= 102, "rewards/%s is not a square cut big enough for the popup's tiles" % k)

	# The pure parts.
	var sv: GDScript = load("res://scenes/court/store_view.gd")
	_checked += 1
	var sp: GDScript = load("res://scripts/ui/store_price.gd")
	_expect(str(sp.words({"owned": true}, true, "₺9", true)["text"]) == "OWNED", "an owned product's plate")
	_expect(str(sp.words({"available": false}, true, "₺9", true)["text"]) == "₺9", "a product that cannot be bought now hides its price")
	_expect(str(sp.words({}, true, "", true)["text"]) == "", "a price the App Store does not sell here is made up")
	_expect(str(sp.words({}, true, "", false)["text"]) == "…", "a price still loading does not say so")
	_expect(str(sp.words({"usd_cents": 499}, false, "", false)["text"]) == "$4.99", "no StoreKit: the reference price")
	_expect(str(sp.words({"usd_cents": 9999}, false, "", false, " a month")["text"]) == "$99.99 a month", "the patron's reference price")
	_expect(str(sp.words({}, false, "", false)["text"]) == "", "no reference price is made up")
	_expect(not sv.buyable({}, true, "", false), "a plate with no price is buyable")
	_expect(not sv.buyable({}, true, "₺9", true), "a plate is buyable while a purchase is in flight")
	_expect(not sv.buyable({}, false, "₺9", false), "a plate is buyable without StoreKit")
	_expect(sv.buyable({"available": true}, true, "₺9", false), "a plate with everything is not buyable")
	var arts: Array = sv.pack_arts([{"badge": ""}, {"badge": ""}, {"badge": "best_value"}, {"badge": ""},
		{"badge": "most_popular"}, {"badge": ""}])
	_expect(arts[2] == "store/pack_6" and arts[4] == "store/pack_3", "a ribbon does not follow its badge: %s" % [arts])
	_expect(arts[0] == "store/pack_1" and arts[1] == "store/pack_2" and arts[3] == "store/pack_4" and arts[5] == "store/pack_5",
		"the plain packs lost their order: %s" % [arts])
	_expect(sv.perk_rows([{"text": "a"}, {"text": "b"}, {"text": "c"}, {"text": "d"}])[2] == "and 2 more",
		"the patron card's third row does not say how many more")

	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  %d store checks: sections whole, words on their plates, the App Store's prices" % _checked)
	quit()


## The layout the sections must keep, and every live text's box.

## HERALD'S TIDINGS, in every state the server can hand it in.
##
## The plate is the painting's own two boxes and a WATCH: what one is worth, and
## either how many are left, when the next may be watched, or the level it opens
## at. WATCH is lit for exactly one of them -- an advert to watch, now -- because
## a lit WATCH that plays nothing is the thing this section was written to avoid.
func _herald_states() -> void:
	# What one is worth is said in all four, so the first box is never empty.
	var worth := ["2 diamonds"]
	var states := [
		{"why": "too young", "herald": {"enabled": true, "unlocked": false, "unlock_level": 3,
			"diamonds": 2, "lines": worth, "per_day": 5, "left": 0},
			"says": "Level 3", "lit": false},
		{"why": "five to watch", "herald": {"enabled": true, "unlocked": true, "unlock_level": 3,
			"diamonds": 2, "lines": worth, "per_day": 5, "left": 5, "unit": "ca-app-pub/1"},
			"says": "5 left today", "lit": true},
		{"why": "catching his breath", "herald": {"enabled": true, "unlocked": true, "unlock_level": 3,
			"diamonds": 2, "lines": worth, "per_day": 5, "left": 4, "next_in": 245, "unit": "ca-app-pub/1"},
			"says": "In 4m 05s", "lit": false},
		{"why": "none left today", "herald": {"enabled": true, "unlocked": true, "unlock_level": 3,
			"diamonds": 2, "lines": worth, "per_day": 5, "left": 0, "unit": "ca-app-pub/1"},
			"says": "None left today", "lit": false},
	]
	for st in states:
		var data := _store(false)
		data["herald"] = st["herald"]
		var v := await _view(Vector2(941, 1672))
		v.call("paint", data)
		await _frames(3)
		# Every word on the page still stays on its plate with the herald on.
		_layout_checks(v, 1672, false)
		var t := _texts(v)
		_checked += 1
		_expect(t.has(", ".join(PackedStringArray(worth))),
			"the herald (%s) does not say what one is worth: %s" % [st["why"], str(t)])
		_checked += 1
		_expect(t.has(st["says"]), "the herald (%s) does not say \"%s\": %s" % [st["why"], st["says"], str(t)])
		var watch := _watch(v)
		_checked += 1
		_expect(watch != null, "the herald (%s) draws no WATCH" % st["why"])
		if watch != null:
			_expect(not watch.disabled == bool(st["lit"]),
				"the herald (%s) has WATCH %s" % [st["why"], "off" if watch.disabled else "lit"])
			_expect((watch.modulate == Color.WHITE) == bool(st["lit"]),
				"the herald (%s) paints WATCH %s" % [st["why"], str(watch.modulate)])
		v.get_parent().queue_free()
		await _frames(2)


## The herald's WATCH: the painted button, wherever the section put it.
func _watch(n: Node) -> TextureButton:
	var stack: Array = [n]
	while not stack.is_empty():
		var c: Node = stack.pop_back()
		for k in c.get_children():
			stack.append(k)
		if c is TextureButton and (c as TextureButton).texture_normal != null \
				and (c as TextureButton).texture_normal.resource_path == "res://assets/store/herald_watch.png":
			return c as TextureButton
	return null


func _layout_checks(v: Control, h: int, priced: bool) -> void:
	var sc: ScrollContainer = v.get("_ui")["list"]
	var content: Control = sc.get_meta("content")
	var nodes: Array = v.get("_nodes")
	_checked += 1
	_expect(nodes.size() >= 8, "at %d only %d sections were laid" % [h, nodes.size()])
	var last_bottom := -1.0
	for n in nodes:
		var c: Control = n
		var r := Rect2(c.position, c.size)
		_expect(r.position.x >= 0.0 and r.end.x <= content.size.x + 0.5, "at %d a section runs off the page: %s" % [h, r])
		if last_bottom >= 0.0:
			_expect(r.position.y >= last_bottom - 0.5, "at %d a section overlaps the one above (%.0f < %.0f)" % [h, r.position.y, last_bottom])
			_expect(r.position.y - last_bottom <= 10.5, "at %d two sections are %.0f apart, not 10" % [h, r.position.y - last_bottom])
		last_bottom = r.end.y
	_expect(content.custom_minimum_size.y >= last_bottom, "at %d the page ends before its last section" % h)
	_expect(sc.position.y + sc.size.y <= float(h) + 0.5, "at %d the list runs past the screen" % h)
	# Every visible live text stays in its box (fitted, or cut with an ellipsis).
	for node in _labels(v):
		var l: Label = node
		if not l.is_visible_in_tree() or l.text == "":
			continue
		var box: float = float(l.get_meta("box_w", l.size.x))
		var s: LabelSettings = l.label_settings
		var wide := 0.0
		for line in l.text.split("\n"):
			wide = maxf(wide, s.font.get_string_size(line, HORIZONTAL_ALIGNMENT_LEFT, -1, s.font_size).x)
		var fits: bool = wide <= box + 1.0 or l.clip_text or l.autowrap_mode != TextServer.AUTOWRAP_OFF
		_checked += 1
		_expect(fits, "at %d \"%s\" is %.0f wide in a %.0f box" % [h, l.text, wide, box])
		if l.autowrap_mode != TextServer.AUTOWRAP_OFF:
			var m: Vector2 = s.font.get_multiline_string_size(l.text, HORIZONTAL_ALIGNMENT_LEFT, box, s.font_size)
			_expect(m.y <= l.size.y + 2.0, "at %d \"%s\" runs %.0f tall in a %.0f box" % [h, l.text.replace("\n", " / "), m.y, l.size.y])


func why_of() -> String:
	return (load("res://scripts/autoload/billing.gd") as GDScript).unavailable_reason()


func _view(canvas: Vector2) -> Control:
	var host := Control.new()
	host.size = canvas
	root.add_child(host)
	var v: Control = (load("res://scenes/court/store_view.gd") as GDScript).new()
	v.size = canvas
	host.add_child(v)
	await _frames(3)
	return v


func _store(with_offers: bool) -> Dictionary:
	var products: Array = []
	var gems := [["gems_60", "gems.60", 120, ""], ["gems_330", "gems.330", 660, ""], ["gems_700", "gems.700", 1400, "most_popular"],
		["gems_1500", "gems.1500", 3000, ""], ["gems_4000", "gems.4000", 8000, ""], ["gems_8500", "gems.8500", 17000, "best_value"]]
	for g in gems:
		products.append({"id": g[0], "store_id": "com.emperors.game." + g[1], "kind": "consumable", "shelf": "diamonds",
			"usd_cents": {"gems_60": 99, "gems_330": 499, "gems_700": 999, "gems_1500": 1999, "gems_4000": 4999, "gems_8500": 9999}[g[0]],
			"title": "%d Diamonds" % (g[2] / 2), "badge": g[3], "first_bonus": g[0] != "gems_700", "available": true,
			"lines": [{"kind": "diamonds", "amount": g[2] if g[0] != "gems_700" else 700, "text": "%d diamonds" % g[2], "icon": "diamond"}]})
	if with_offers:
		products.push_front({"id": "offer_l30", "usd_cents": 1999, "store_id": "com.emperors.game.offer.l30", "kind": "consumable", "shelf": "offers",
			"title": "The Baron's Treasury of the Western Marches", "available": true, "ends_in": 3400, "lines": [
				{"kind": "diamonds", "amount": 2800, "text": "2,800 diamonds", "icon": "diamond"},
				{"kind": "token", "amount": 8, "text": "8 Energy Potions", "icon": "energy_potion"},
				{"kind": "cosmetic", "amount": 1, "text": "Laurel (frame)", "icon": "frames/laurel"}]})
	products.append({"id": "stipend", "usd_cents": 499, "store_id": "com.emperors.game.stipend.30", "kind": "consumable", "shelf": "passes",
		"title": "Royal Stipend", "available": false, "note": "renews when 5 days are left", "lines": [
			{"kind": "diamonds", "amount": 300, "text": "300 diamonds", "icon": "diamond"},
			{"kind": "stipend", "amount": 60, "text": "then 60 diamonds a day for 30 days", "icon": "diamond"}]})
	products.append({"id": "patronage", "usd_cents": 699, "store_id": "com.emperors.game.patronage.month", "kind": "subscription",
		"shelf": "passes", "title": "Crown Patronage", "available": false, "note": "you are a patron", "lines": [
			{"kind": "diamonds", "amount": 60, "text": "60 diamonds each month", "icon": "diamond"},
			{"kind": "patronage", "amount": 1, "text": "1 free energy refill each day", "icon": "energy_potion"},
			{"kind": "patronage", "amount": 25, "text": "+25 bag slots", "icon": "quartermaster"},
			{"kind": "patronage", "amount": 1, "text": "The Steward keeps your house", "icon": "steward"}]})
	products.append({"id": "steward", "usd_cents": 499, "store_id": "com.emperors.game.comfort.steward", "kind": "non_consumable",
		"shelf": "comfort", "title": "The Steward", "available": false, "owned": true, "note": "yours for good",
		"lines": [{"kind": "steward", "amount": 1, "text": "The Steward now keeps your house", "icon": "steward"}]})
	products.append({"id": "quartermaster", "usd_cents": 499, "store_id": "com.emperors.game.comfort.quartermaster", "kind": "non_consumable",
		"shelf": "comfort", "title": "The Quartermaster", "available": true,
		"lines": [{"kind": "quartermaster", "amount": 50, "text": "+50 bag slots, for good", "icon": "quartermaster"}]})
	products.append({"id": "largesse", "usd_cents": 999, "store_id": "com.emperors.game.largesse", "kind": "consumable", "shelf": "kingdom",
		"title": "Royal Largesse", "available": true, "lines": [
			{"kind": "diamonds", "amount": 600, "text": "600 diamonds", "icon": "diamond"},
			{"kind": "cosmetic", "amount": 1, "text": "The Generous (title)", "icon": "title:title_generous"},
			{"kind": "largesse", "amount": 20, "text": "and 20 diamonds to every lord of your kingdom", "icon": "largesse"}]})
	var slots: Array = [
		{"slot": 0, "kind": "free", "title": "A Scholar's Purse", "claimed": false,
			"lines": [{"kind": "xp", "amount": 80, "text": "80 experience", "icon": "xp"}]},
		{"slot": 1, "kind": "diamonds", "title": "Three Energy Potions", "diamonds": 45, "was": 60, "claimed": true,
			"lines": [{"kind": "token", "amount": 3, "text": "3 Energy Potions", "icon": "energy_potion"}]},
		{"slot": 2, "kind": "diamonds", "title": "Two Protection Charters", "diamonds": 28, "was": 40, "claimed": false,
			"lines": [{"kind": "token", "amount": 2, "text": "2 Protection Charters", "icon": "city_shield"}]},
	]
	if not with_offers:
		slots.append({"slot": 3, "kind": "cosmetic", "title": "Dragon", "diamonds": 105, "was": 150, "claimed": false,
			"lines": [{"kind": "cosmetic", "amount": 1, "text": "Dragon (crest)", "icon": "icons/crest_dragon"}],
			"cosmetic": {"id": "crest_dragon", "kind": "crest", "name": "Dragon", "art": "icons/crest_dragon"}})
	return {"products": products, "vip": {}, "steward": true,
		"stipend": {"active": true, "days_left": 18, "claimable_today": true, "daily_diamonds": 60},
		"patronage": {"active": true, "seconds": 29 * 86400 + 23 * 3600},
		"deals": {"day": "2026-09-15", "resets_in": 79831, "slots": slots}, "herald": {"enabled": false}}


func _buy_buttons(v: Control) -> Array:
	var out: Array = []
	for e in v.get("_buys"):
		out.append(e["button"])
	return out


func _labels(n: Node) -> Array:
	var out: Array = []
	for c in n.get_children():
		if c is Label:
			out.append(c)
		out.append_array(_labels(c))
	return out


func _texts(n: Node) -> Array:
	var out: Array = []
	for l in _labels(n):
		if (l as Label).is_visible_in_tree():
			out.append((l as Label).text)
	return out


func _has_asset(n: Node, asset: String) -> bool:
	var want := "res://assets/%s.png" % asset
	var stack: Array = [n]
	while not stack.is_empty():
		var c: Node = stack.pop_back()
		for k in c.get_children():
			stack.append(k)
		if not (c is CanvasItem) or not (c as CanvasItem).is_visible_in_tree():
			continue
		var tex: Texture2D = null
		if c is TextureRect:
			tex = (c as TextureRect).texture
		elif c is TextureButton:
			tex = (c as TextureButton).texture_normal
		if tex != null and tex.resource_path == want:
			return true
	return false


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _expect(ok: bool, why: String) -> void:
	if not ok:
		_fails += 1
		printerr("  ", why)
