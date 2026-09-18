extends SceneTree
## THE CROWN'S FAVOUR holds on every phone, says what App Review asks of a
## subscription, and shows the lord's Royal Favour as the server counts it.
##
## The page is its painting (art/reference/favour.png) on the painted pages'
## host. For the hard cases -- a lord at level 4 with a gift waiting and the
## App Store's price known; a patron at the top level, 23 days left; a new lord
## with no favour, no seal, a long price in a long currency and five perks, one
## long; the App Store not answering -- on 941x1672 and 941x2040, with and
## without a Dynamic Island:
##  - the page is a PaintedPage, drawn whole and on the screen under the notch;
##  - every word fits its plate, and the red plate's words sit on its middle
##    (the status line was measured into a rect taller than its type and landed
##    ten units high);
##  - the disclosure near SUBSCRIBE carries the title, the length, the App
##    Store's price, that it renews until cancelled in Settings, and the Terms
##    and Privacy links, inside its plate;
##  - SUBSCRIBE says SUBSCRIBE, or how long a patronage has left and stays lit
##    (it opens the App Store's subscriptions), and is dark with no price;
##  - ten shields, lit to the level, a pin over each lit one, the bar's end
##    between the pins as far as the favour has come; the seal veiled without
##    one; the gift's plate only while a gift waits; CLOSE closes.
##
## Run: godot --headless --path client --script tests/favour_view_fit.gd

const CANVASES := [Vector2i(941, 1672), Vector2i(941, 2040)]
const INSETS := [0.0, 141.0]
const PATRON_ID := "com.emperors.game.patronage.month"
const VIEW := "res://scenes/court/favour_view.gd"
## The red plate's inner field, measured off the painting (y 892..940, 20
## rows higher on the page as it is drawn: art/slices/favour.json).
const PLATE_MID := 896.0
## The disclosure's plate between its steel rims, on the page as drawn (the
## painted plate, x 83..858, drawn 40 rows taller: y 1056..1164).
const PLATE := Rect2(84, 1057, 774, 106)
const DISCLOSURE_FLOOR := 22
const LINK_WORDS := ["Terms of Use", "Privacy Policy"]
const LINK_GAP := "   ·   "
const SLACK := 3.0
const PTS := [99, 499, 999, 1999, 4999, 9999, 19999, 49999, 99999, 199999]


class FakeProduct extends Object:
	var product_id := ""
	var display_price := ""
	func _init(id: String, price: String) -> void:
		product_id = id
		display_price = price


## Loaded, not named: a test script compiles before the autoloads the UI
## scripts use exist.
var _L: GDScript
var _U: GDScript
var _fails := 0
var _checked := 0
var _F: GDScript


func _initialize() -> void:
	await process_frame
	root.get_node("Env").set("api_base_url", "http://127.0.0.1:9")
	_L = load("res://scripts/ui/layout.gd")
	_U = load("res://scripts/ui/ui.gd")
	_F = load(VIEW)
	if _F == null or not _F.get_script_constant_map().has("PAGE"):
		print("FAIL  favour_view.gd is not a painted page")
		quit(1)
		return
	_bar_rule()
	var billing: Node = root.get_node("Billing")
	billing.set("available", true)
	for canvas in CANVASES:
		for inset in INSETS:
			var tag := "%dx%d inset %d" % [canvas.x, canvas.y, int(inset)]
			_price("US$6.99")
			_player(true)
			await _case("level 4, a gift waiting, %s" % tag, canvas, inset,
				_store(2600, 4, true, false, 0, 5), {"level": 4, "status": "US$6.99 A MONTH",
				"subscribe": "SUBSCRIBE", "enabled": true, "gift": "CLAIM +5", "price": "US$6.99", "seal": true})
			await _case("a patron at level 10, %s" % tag, canvas, inset,
				_store(250000, 10, false, true, 23 * 86400 + 3600, 5), {"level": 10,
				"status": "A PATRON OF THE CROWN", "subscribe": "23 DAYS LEFT", "enabled": true, "gift": "",
				"price": "US$6.99", "seal": true})
			_price("₺1.799,99")
			_player(false)
			await _case("a new lord, a long price, six perks, %s" % tag, canvas, inset,
				_store(0, 0, false, false, 0, 6), {"level": 0, "status": "₺1.799,99 A MONTH",
				"subscribe": "SUBSCRIBE", "enabled": true, "gift": "", "price": "₺1.799,99", "seal": false})
	# The App Store has not answered: no price, and nothing to press.
	billing.set("_products", {})
	await _case("no price from the App Store", CANVASES[0], 0.0, _store(0, 0, false, false, 0, 4),
		{"level": 0, "status": "ONE MONTH", "subscribe": "SUBSCRIBE", "enabled": false, "gift": "",
		"price": "", "seal": false})
	if _checked < 13:
		_fail("only %d of 13 pages were measured" % _checked)
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  %d Crown's Favour pages hold on both canvases, under the notch, with their disclosure" % _checked)
	quit()


func _fail(msg: String) -> void:
	_fails += 1
	print("  FAIL  " + msg)


func _price(p: String) -> void:
	var billing: Node = root.get_node("Billing")
	billing.set("_products", {})
	billing.call("_on_products", [FakeProduct.new(PATRON_ID, p)], OK)


func _player(sealed: bool) -> void:
	root.get_node("GameState").set("snapshot", {"player": {"username": "Wwwwwwwwwwwwwwww", "level": 30,
		"gold": "987654321", "diamonds": 1240, "action_seq": 1, "vip_seal": sealed,
		"vip_level": 4 if sealed else 0}, "energy": {"current": 185, "max": 236}})


func _store(points: int, level: int, gift: bool, patron: bool, seconds: int, lines: int) -> Dictionary:
	var daily := [2, 3, 4, 5, 6, 8, 10, 12, 15, 20]
	var bag := [0, 5, 5, 10, 10, 15, 15, 20, 25, 30]
	var tiers: Array = []
	for i in 10:
		var cos: Array = []
		if i + 1 == 5:
			cos = [{"kind": "cosmetic", "text": "Gilded Laurel (frame)", "icon": "frames/laurel_gilded"}]
		tiers.append({"level": i + 1, "points": PTS[i], "daily_diamonds": daily[i], "bag_bonus": bag[i],
			"cosmetics": cos})
	var all := [
		{"kind": "diamonds", "amount": 60, "text": "60 diamonds each month", "icon": "diamond"},
		{"kind": "patronage", "amount": 1, "text": "1 free energy refill each day", "icon": "energy_potion"},
		{"kind": "patronage", "amount": 25, "text": "+25 bag slots", "icon": "quartermaster"},
		{"kind": "patronage", "amount": 1, "text": "The Steward keeps your house", "icon": "steward"},
		{"kind": "cosmetic", "amount": 1, "text": "Patron's Frame and Patron's Gold name colour, while it lasts",
			"icon": "frames/patron", "color": "#E8C46A"},
		{"kind": "patronage", "amount": 1, "text": "A sixth thing a catalogue to come might give", "icon": "steward"}]
	return {"products": [{"id": "patronage", "store_id": PATRON_ID, "kind": "subscription", "title": "Crown Patronage",
		"available": not patron, "lines": all.slice(0, lines)}],
		"vip": {"level": level, "points": points, "next_level": mini(level + 1, 10),
			"next_points": PTS[mini(level, 9)], "gift_diamonds": daily[maxi(level - 1, 0)] if level > 0 else 0,
			"gift_claimable": gift, "tiers": tiers},
		"patronage": {"active": patron, "seconds": seconds}}


func _host(canvas: Vector2i) -> Control:
	var vp := SubViewport.new()
	vp.size = canvas
	root.add_child(vp)
	root.get_node("Nav").set("host", vp)
	var host := Control.new()
	host.size = Vector2(canvas)
	vp.add_child(host)
	return host


func _case(what: String, canvas: Vector2i, inset: float, store: Dictionary, want: Dictionary) -> void:
	var host := _host(canvas)
	var p: Control = _F.call("open", host, {"inset": inset, "offline": true})
	var s: Script = p.get_script() if p != null else null
	if s == null or not s.resource_path.ends_with("scripts/ui/painted_page.gd"):
		_fail("%s: the page is not a PaintedPage" % what)
		host.get_parent().queue_free()
		return
	var v: Node = _F.call("of", p)
	v.call("paint", store)
	await create_timer(0.4).timeout
	_checked += 1
	_on_screen(p, what, Vector2(canvas), inset)
	_status(p, what, str(want["status"]))
	_subscribe(p, what, str(want["subscribe"]), bool(want["enabled"]))
	_disclosure(v, p, what, str(want["price"]))
	_levels(v, p, what, int(want["level"]), store["vip"])
	_perks(v, p, what, store)
	var seal := p.call("node", "vip_seal") as CanvasItem
	var veiled := seal != null and seal.modulate.a > 0.1
	if seal == null or veiled == bool(want["seal"]):
		_fail("%s: the seal is %s for a lord %s one" % [what, "veiled" if veiled else "clear",
			"with" if bool(want["seal"]) else "without"])
	var gift := p.call("node", "gift") as Button
	var green: Texture2D = root.get_node("Art").call("tex", "plates/green_xs")
	var sb := gift.get_theme_stylebox("normal") as StyleBoxTexture if gift != null else null
	if sb == null or sb.texture != green or int(sb.texture_margin_left) != 24:
		_fail("%s: the gift's plate is not the painted family's green (plates/green_xs, edge 24)" % what)
	if gift != null and gift.visible:
		# Its words and diamond stay off the plate's rim and chamfers: kept the
		# family's edge in from each side, and fitting between.
		for state in ["normal", "disabled"]:
			var s2 := gift.get_theme_stylebox(state)
			if s2 == null or s2.get_margin(SIDE_LEFT) < 24.0 or s2.get_margin(SIDE_RIGHT) < 24.0:
				_fail("%s: the gift's %s plate lets its words onto the rim" % [what, state])
		var gf := gift.get_theme_font("font")
		var gw := gf.get_string_size(gift.text, HORIZONTAL_ALIGNMENT_LEFT, -1, gift.get_theme_font_size("font_size")).x \
			+ float(gift.get_theme_constant("icon_max_width")) + float(gift.get_theme_constant("h_separation"))
		if gw > _paint_rect("gift").size.x - 48.0 + 0.5:
			_fail("%s: the gift's \"%s\" and its diamond are %.0f wide on a %.0f plate" % [what, gift.text, gw,
				_paint_rect("gift").size.x])
	var gift_word := str(want["gift"])
	if gift == null or gift.visible != (gift_word != "") or (gift_word != "" and gift.text != gift_word):
		_fail("%s: the gift's plate is %s (\"%s\"), not %s" % [what, "shown" if gift != null and gift.visible
			else "hidden", gift.text if gift != null else "", gift_word if gift_word != "" else "hidden"])
	# CLOSE closes.
	(p.call("node", "close") as BaseButton).pressed.emit()
	await create_timer(0.3).timeout
	for c in host.get_parent().get_children():
		if c is CanvasLayer and not c.is_queued_for_deletion():
			_fail("%s: CLOSE left the page open" % what)
			break
	host.get_parent().queue_free()
	await process_frame


## Every button, word and shield is on the screen, under the notch.
func _on_screen(p: Control, what: String, canvas: Vector2, inset: float) -> void:
	for n in _all(p):
		if not (n is Button or n is Label or n is RichTextLabel or n is TextureButton):
			continue
		var c := n as Control
		if not c.is_visible_in_tree():
			continue
		var r := c.get_global_rect()
		if r.position.y < inset - 0.5 or r.end.y > canvas.y + 0.5 or r.position.x < -0.5 or r.end.x > canvas.x + 0.5:
			_fail("%s: %s is at %s, off the screen or under the notch" % [what, c.name, r])


func _status(p: Control, what: String, want: String) -> void:
	var st := p.call("node", "status") as Label
	if st == null or st.text != want:
		_fail("%s: the red plate says \"%s\", not \"%s\"" % [what, st.text if st != null else "", want])
		return
	_fits(st, what + ": the red plate")
	var mid: float = (p.call("map_rect", Rect2(0, PLATE_MID, 1, 0)) as Rect2).position.y
	var got := st.position.y + st.get_minimum_size().y / 2.0
	if absf(got - mid) > SLACK:
		_fail("%s: the red plate's words sit %.0f units off its middle" % [what, got - mid])


func _subscribe(p: Control, what: String, want: String, enabled: bool) -> void:
	var b := p.call("node", "subscribe") as Button
	if b == null or b.text != want:
		_fail("%s: SUBSCRIBE says \"%s\", not \"%s\"" % [what, b.text if b != null else "", want])
		return
	if b.disabled == enabled:
		_fail("%s: SUBSCRIBE is %s" % [what, "dark" if b.disabled else "lit"])
	# The word stays inside the painted plate (the tap area round it is larger).
	var plate := _paint_rect("subscribe")
	var f: Font = b.get_theme_font("font")
	var w := f.get_string_size(b.text, HORIZONTAL_ALIGNMENT_LEFT, -1, b.get_theme_font_size("font_size")).x
	if w > plate.size.x - 32.0:
		_fail("%s: SUBSCRIBE's \"%s\" is %.0f wide on a %.0f plate" % [what, b.text, w, plate.size.x])


func _disclosure(v: Node, p: Control, what: String, price: String) -> void:
	var d := v.get("_disclosure") as Label
	var links := v.get("_links") as RichTextLabel
	if d == null or links == null:
		_fail("%s: there is no disclosure" % what)
		return
	for part in ["Crown Patronage", "one month", "Apple ID", "Renews monthly", "until cancelled", "Settings"]:
		if not d.text.contains(part):
			_fail("%s: the disclosure lacks \"%s\"" % [what, part])
	if price != "" and not d.text.contains(price):
		_fail("%s: the disclosure does not give the App Store's price %s" % [what, price])
	if price == "" and not d.text.contains("the App Store's price"):
		_fail("%s: with no price the disclosure does not say the price is the App Store's" % what)
	for part in ["[url=terms]", "Terms of Use", "[url=privacy]", "Privacy Policy"]:
		if not links.text.contains(part):
			_fail("%s: the links lack \"%s\"" % [what, part])
	# Legible: 22 units is about 9 pt on a 393 pt phone. At the old 13..17 it
	# was 5.4..7.1 pt, which App Review does not call clearly displayed.
	var size_pt := d.label_settings.font_size
	var link_pt := links.get_theme_font_size("normal_font_size")
	if size_pt < DISCLOSURE_FLOOR or link_pt < DISCLOSURE_FLOOR:
		_fail("%s: the disclosure is set at %d and its links at %d, under %d" % [what, size_pt, link_pt, DISCLOSURE_FLOOR])
	# Wholly inside the painted plate, words and links.
	var plate: Rect2 = p.call("map_rect", PLATE)
	var m := d.label_settings.font.get_multiline_string_size(d.text, HORIZONTAL_ALIGNMENT_LEFT,
		float(d.get_meta("box_w", d.size.x)), size_pt)
	var words := Rect2(d.position, Vector2(m.x, maxf(m.y, float(d.get_line_count()) * d.get_line_height())))
	if not plate.encloses(words) or not plate.encloses(Rect2(links.position, links.size)):
		_fail("%s: the disclosure %s and its links %s leave the plate %s" % [what, words,
			Rect2(links.position, links.size), plate])
	if words.end.y > links.position.y + 0.5:
		_fail("%s: the disclosure's words run under its links (%d lines)" % [what, d.get_line_count()])
	# Each link under its own thumb: 95 units or more each way, over its
	# words, the two apart, and clear of every other button.
	var hits: Array = v.get("_link_hits")
	if hits.size() != 2:
		_fail("%s: %d link targets, not two" % [what, hits.size()])
		return
	var f := links.get_theme_font("normal_font")
	var x := links.position.x
	var spans := []
	for i in 2:
		var w := f.get_string_size(LINK_WORDS[i], HORIZONTAL_ALIGNMENT_LEFT, -1, link_pt).x
		spans.append(Rect2(x, links.position.y, w, links.size.y))
		x += w + f.get_string_size(LINK_GAP, HORIZONTAL_ALIGNMENT_LEFT, -1, link_pt).x
	var others: Array = []
	for id in ["subscribe", "manage", "gift", "close"]:
		var b := p.call("node", id) as Control
		if b != null and b.visible:
			others.append([id, Rect2(b.position, b.size)])
	for i in 2:
		var h := hits[i] as Control
		var r := Rect2(h.position, h.size)
		if r.size.x < 95.0 or r.size.y < 95.0:
			_fail("%s: the %s target is %.0fx%.0f, under a thumb" % [what, LINK_WORDS[i], r.size.x, r.size.y])
		if not r.encloses(spans[i]):
			_fail("%s: the %s target %s does not cover its words %s" % [what, LINK_WORDS[i], r, spans[i]])
		if (h as BaseButton).pressed.get_connections().is_empty():
			_fail("%s: the %s target does nothing" % [what, LINK_WORDS[i]])
		for o in others:
			if r.intersects(o[1]):
				_fail("%s: the %s target overlaps %s" % [what, LINK_WORDS[i], o[0]])
	if Rect2((hits[0] as Control).position, (hits[0] as Control).size).intersects(
			Rect2((hits[1] as Control).position, (hits[1] as Control).size)):
		_fail("%s: the two links' targets overlap" % what)
	# Near SUBSCRIBE: its plate is the next thing under the buttons.
	var sub := _paint_rect("subscribe")
	if PLATE.position.y - sub.end.y > 30.0:
		_fail("%s: the disclosure's plate is %.0f units under SUBSCRIBE" % [what, PLATE.position.y - sub.end.y])
	for meta in ["terms", "privacy"]:
		# The links go where the page says they go.
		var url := str(_F.get_script_constant_map()["TERMS_URL" if meta == "terms" else "PRIVACY_URL"])
		if not url.begins_with("https://") or not url.ends_with("/legal/" + meta):
			_fail("%s: the %s link is %s" % [what, meta, url])


func _levels(v: Node, p: Control, what: String, level: int, vip: Dictionary) -> void:
	var shields: Array = v.get("_shields")
	var pins: Array = v.get("_pins")
	if shields.size() != 10 or pins.size() != 10:
		_fail("%s: %d shields and %d pins, not ten" % [what, shields.size(), pins.size()])
		return
	var lit_tex: Texture2D = root.get_node("Art").call("tex", str(_L.element("favour", "shield").get("lit", "")))
	var lit := 0
	var pinned := 0
	for k in 10:
		if (shields[k] as TextureRect).texture == lit_tex:
			lit += 1
			if k >= level:
				_fail("%s: shield %d is lit at level %d" % [what, k + 1, level])
		if (pins[k] as CanvasItem).visible:
			pinned += 1
	if lit != level or pinned != level:
		_fail("%s: %d shields lit and %d pins, at level %d" % [what, lit, pinned, level])
	var fill := p.call("node", "bar_fill") as Control
	var want: float = _F.call("fill_ratio", vip)
	var full: Vector2 = fill.get_meta("full", Vector2.ZERO) if fill != null else Vector2.ZERO
	var got := (fill.size.x / full.x if fill.visible else 0.0) if full.x > 0.0 else -1.0
	if full.x <= 0.0 or absf(got - want) * full.x > 1.5:
		_fail("%s: the bar is filled to %.3f, not %.3f" % [what, got, want])
	for id in ["level_title", "level_text"]:
		var l := p.call("node", id) as Label
		if l == null or l.text == "":
			_fail("%s: the level plate's %s is empty" % [what, id])
		else:
			_fits(l, "%s: the level plate's %s" % [what, id])


func _perks(v: Node, p: Control, what: String, store: Dictionary) -> void:
	var lines: Array = store["products"][0]["lines"]
	var rows: Array = v.get("_rows")
	var want := mini(lines.size(), 5)
	if rows.size() != want:
		_fail("%s: %d perk rows for %d lines" % [what, rows.size(), lines.size()])
		return
	# Centred in the five painted rows' band, on the painting's pitch, and
	# never outside it, whatever the catalogue says.
	var tpl: Dictionary = _L.element("favour", "perk_row")
	var tpl_r: Rect2 = _L.rect_of(tpl)
	var band_top := tpl_r.position.y
	var band_end := band_top + 4.0 * 56.0 + tpl_r.size.y
	var band_mid := (band_top + band_end) / 2.0
	var first := (rows[0]["node"] as Control).position.y
	var last := (rows[-1]["node"] as Control).position.y + tpl_r.size.y
	var map := func(y: float) -> float: return (p.call("map_rect", Rect2(0, y, 1, 0)) as Rect2).position.y
	if absf((first + last) / 2.0 - float(map.call(band_mid))) > 1.5:
		_fail("%s: the perk rows are centred at %.0f, not the band's %.0f" % [what, (first + last) / 2.0,
			float(map.call(band_mid))])
	if first < float(map.call(band_top)) - 0.5 or last > float(map.call(band_end)) + 0.5:
		_fail("%s: the perk rows run %.0f..%.0f, outside the band" % [what, first, last])
	if lines.size() > 5:
		var more := (rows[-1]["parts"]["line"] as Label).text
		if more != "and %d more" % (lines.size() - 4):
			_fail("%s: with %d perks the last row says \"%s\"" % [what, lines.size(), more])
	var bare: Texture2D = root.get_node("Art").call("tex", str(tpl.get("bare", "")))
	for i in rows.size():
		var r: Dictionary = rows[i]
		_fits(r["parts"]["line"] as Label, "%s: a perk" % what)
		var line: Dictionary = lines[i] if i < 4 or lines.size() <= 5 else {}
		var icon := str(line.get("icon", ""))
		var row_tex := (r["parts"]["row"] as TextureRect).texture
		if icon.begins_with("frames/"):
			# The looks: the frame's own square, round the lord's face, in the
			# crown's place.
			var pic := r.get("icon") as Control
			var want_tex: Texture2D = root.get_node("Art").call("reward_icon", icon)
			var framed := false
			var faced := false
			if pic != null:
				for c in pic.get_children():
					if c is TextureRect and (c as TextureRect).texture == want_tex:
						framed = true
					elif c is TextureRect and (c as TextureRect).texture != null:
						faced = true
			if not framed or not faced or row_tex != bare:
				_fail("%s: the looks row does not show %s round a face in the crown's place" % [what, icon])
			elif not Rect2(Vector2.ZERO, tpl_r.size).encloses(Rect2(pic.position, pic.size)):
				_fail("%s: the looks row's frame %s leaves its row" % [what, Rect2(pic.position, pic.size)])
		elif r.has("icon") or row_tex == bare:
			_fail("%s: \"%s\" lost its crown" % [what, (r["parts"]["line"] as Label).text])


## A label's words fit its box at the size they were set at.
func _fits(l: Label, what: String) -> void:
	var box := float(l.get_meta("box_w", l.size.x))
	var s := l.label_settings
	var w := s.font.get_string_size(l.text, HORIZONTAL_ALIGNMENT_LEFT, -1, s.font_size).x
	if w > box + 0.5:
		_fail("%s \"%s\" is %.0f wide in a %.0f box: it is cut" % [what, l.text, w, box])


func _rect(id: String) -> Rect2:
	return _L.rect_of(_L.element("favour", id))


func _paint_rect(id: String) -> Rect2:
	var e: Dictionary = _L.element("favour", id)
	return _L.rect_of({"rect": e.get("paint_rect", e.get("rect"))})


## The bar's rule, without a page: from the tube's end toward the first pin at
## level 0, from pin to pin as the favour comes, full at the top.
func _bar_rule() -> void:
	var tiers: Array = []
	for i in 10:
		tiers.append({"level": i + 1, "points": PTS[i]})
	var at := func(vip: Dictionary) -> float:
		return float(_F.call("bar_ratio", vip, 100.0, 844.0, 118.5, 78.0, 98.0, 748.0)) * 748.0 + 98.0
	var cases := [
		[{"level": 0, "points": 0, "tiers": tiers}, 100.0, "a new lord's bar starts at the tube's end"],
		[{"level": 0, "points": 49, "tiers": tiers}, 100.0 + 18.5 * 49.0 / 99.0, "level 0 runs toward the first pin"],
		[{"level": 1, "points": 99, "tiers": tiers}, 118.5, "level 1 stands on the first pin"],
		[{"level": 4, "points": 3499, "tiers": tiers}, 118.5 + 78.0 * 3.5, "halfway to level 5 is halfway between the pins"],
		[{"level": 4, "points": 999999, "tiers": tiers}, 118.5 + 78.0 * 4.0, "a lord never runs past the next pin"],
		[{"level": 10, "points": 250000, "tiers": tiers}, 844.0, "level 10 fills the tube"],
	]
	for c in cases:
		var got: float = at.call(c[0])
		if absf(got - float(c[1])) > 0.01:
			_fail("%s: the bar ends at %.1f, not %.1f" % [c[2], got, float(c[1])])


static func _all(n: Node) -> Array:
	var out: Array = []
	for c in n.get_children():
		out.append(c)
		out.append_array(_all(c))
	return out
