extends SceneTree
## The Family's STOREHOUSE card: the estates' income, waiting to be carried in.
##
## Wave 2 moved estate income out of the purse and into a storehouse that
## fills to a capacity and waits; the card is where a lord sees it and brings
## it home (family_storehouse.png). What must hold, on both canvases:
##  - the card heads the ledger, under the gear; the TALENTS / DEEDS / ROAD
##    strip follows it at the painting's gap, and the ledger the strip at its
##    own;
##  - its window wears the storehouse swept clean under a third full, sacks and
##    crates until full, and overflowing once full (or over its capacity);
##  - its figures fit: the gold waiting and what it holds on one baseline inside
##    the plate's ends for a new lord and a late one, how long it holds, the
##    countdown or "Full" in the warning red, the vault's fee;
##  - TO VAULT dims while the vault is shut, and a tap on it then says the level
##    it opens at without asking the server;
##  - COLLECT and TO VAULT send one carry at a time -- {to, action_seq}, the
##    player's next -- say what it moved ("+12,345 to the purse", "+11,110 to
##    the vault (1,235 fee)"), and say a refusal in the game's words, not the
##    server's.
## The carries are answered by a stub server in this test, held open to prove
## the single flight.
##
## Run: godot --headless --path client --script tests/family_storehouse_card.gd

const CARRY := "/v1/estates/storehouse/carry"
const RED := Color("#F0524F")

var _fails := 0
var _checked := 0
var _stub := Stub.new()
var _notices: Array = []
var _refusals: Array = []
var _gs: Node


## A one-port HTTP server that answers each request from a queue per path
## (200 {} when the queue is empty), and can hold the POSTs until told.
class Stub:
	var server := TCPServer.new()
	var peers: Array = []
	var bufs: Array = []
	var requests: Array = []
	var answers := {}
	var hold := false
	var held: Array = []

	func start() -> int:
		for i in 40:
			var port := 18600 + randi() % 1200
			if server.listen(port, "127.0.0.1") == OK:
				return port
		return 0

	func poll() -> void:
		while server.is_connection_available():
			peers.append(server.take_connection())
			bufs.append(PackedByteArray())
		for i in peers.size():
			var p: StreamPeerTCP = peers[i]
			p.poll()
			if p.get_status() != StreamPeerTCP.STATUS_CONNECTED:
				continue
			var n := p.get_available_bytes()
			var buf: PackedByteArray = bufs[i]
			if n > 0:
				buf.append_array(p.get_data(n)[1])
				bufs[i] = buf
			var text := buf.get_string_from_utf8()
			var head_end := text.find("\r\n\r\n")
			if head_end < 0:
				continue
			var head := text.substr(0, head_end)
			var length := 0
			for line in head.split("\r\n"):
				if line.to_lower().begins_with("content-length:"):
					length = int(line.split(":")[1].strip_edges())
			if buf.size() < head_end + 4 + length:
				continue
			var body := text.substr(head_end + 4, length)
			bufs[i] = buf.slice(head_end + 4 + length)
			var first := head.split("\r\n")[0].split(" ")
			var parsed: Variant = JSON.parse_string(body) if body != "" else {}
			var req := {"method": first[0], "path": first[1], "body": parsed if parsed is Dictionary else {}, "peer": p}
			requests.append(req)
			if hold and req["method"] == "POST":
				held.append(req)
			else:
				answer(req)

	func answer(req: Dictionary) -> void:
		var q: Array = answers.get(req["path"], [])
		var status := 200
		var data := {}
		if not q.is_empty():
			var a: Array = q.pop_front()
			status = a[0]
			data = a[1]
		var payload := JSON.stringify(data).to_utf8_buffer()
		var head := "HTTP/1.1 %d X\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: keep-alive\r\n\r\n" % [status, payload.size()]
		(req["peer"] as StreamPeerTCP).put_data(head.to_utf8_buffer() + payload)

	func release() -> void:
		hold = false
		for req in held:
			answer(req)
		held.clear()

	func posts() -> Array:
		return requests.filter(func(r: Dictionary) -> bool: return r["method"] == "POST")


func _initialize() -> void:
	await process_frame
	_gs = root.get_node("GameState")
	var family: GDScript = load("res://scenes/tabs/family.gd")
	if not _gs.has_method("storehouse") or not family.has_method("storehouse_state"):
		print("FAIL  there is no storehouse card: estate income has nowhere to be seen or carried in")
		quit(1)
		return
	var port := _stub.start()
	if port == 0:
		print("FAIL  the test could not open its stub server")
		quit(1)
		return
	root.get_node("Env").set("api_base_url", "http://127.0.0.1:%d" % port)
	_gs.connect("notice", func(m: String) -> void: _notices.append(m))
	_gs.connect("action_failed", func(m: String) -> void: _refusals.append(m))
	_states_by_fill(family)
	for canvas in [Vector2i(941, 1672), Vector2i(941, 2040)]:
		await _card(family, canvas)
	await _carries(family)
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  %d checks: the storehouse card heads the ledger, shows its fill, fits its figures and carries one at a time" % _checked)
	quit()


func _fail(msg: String) -> void:
	_fails += 1
	print("  FAIL  " + msg)


func _check(ok: bool, msg: String) -> void:
	_checked += 1
	if not ok:
		_fail(msg)


func _snap(level: int, sh: Dictionary, seq: int = 41) -> Dictionary:
	return {"player": {"username": "Wwwwwwwwwwwwwwww", "level": level, "gold": "1000", "action_seq": seq,
		"xp": 0, "xp_to_next": 100, "tax_milli_per_hour": 0},
		"energy": {"current": 10, "max": 10},
		"sections": [{"id": "bank", "unlock_level": 8, "unlocked": level >= 8}],
		"storehouse": sh}


## A new lord's storehouse (42.2 gold an hour, eight hours) or a late lord's
## (thousands an hour, twelve hours and more).
func _sh(milli: int, cap_milli: int, rate: int, hours: float, open: bool) -> Dictionary:
	var full := cap_milli > 0 and milli >= cap_milli
	var full_in := 0 if full or rate <= 0 else int(ceil(float(cap_milli - milli) * 3600.0 / float(rate)))
	return {"gold": milli / 1000, "milli": milli, "cap": cap_milli / 1000, "cap_milli": cap_milli,
		"per_hour_milli": rate, "hours": hours, "full_in": full_in, "full": full,
		"treasury_fee_bp": 1000, "treasury_open": open}


func _states_by_fill(family: GDScript) -> void:
	for row in [[0, 337600, "empty"], [112000, 337600, "empty"], [112534, 337600, "half"],
			[337599, 337600, "half"], [337600, 337600, "full"], [500000, 337600, "full"], [0, 0, "empty"]]:
		var got: String = family.call("storehouse_state", row[0], row[1])
		_check(got == row[2], "%d of %d milli reads \"%s\", not \"%s\"" % [row[0], row[1], got, row[2]])
	for row in [[8.0, "8h"], [8.2, "8h 12m"], [9.6, "9h 36m"], [12.0, "12h"]]:
		var got: String = family.call("hours_words", row[0])
		_check(got == row[1], "%s hours read \"%s\"" % [row[0], got])
	var purse: String = family.call("carry_words", {"to": "purse", "carried": 12345})
	var vault: String = family.call("carry_words", {"to": "treasury", "carried": 12345, "fee": 1235, "banked": 11110})
	_check(purse == "+12,345 to the purse", "a carry to the purse says \"%s\"" % purse)
	_check(vault == "+11,110 to the vault (1,235 fee)", "a carry to the vault says \"%s\"" % vault)


func _new_tab(family: GDScript, canvas: Vector2i) -> Array:
	var vp := SubViewport.new()
	vp.size = canvas
	root.add_child(vp)
	root.get_node("Nav").set("host", vp)
	var tab: Control = family.new()
	tab.size = Vector2(canvas)
	vp.add_child(tab)
	await process_frame
	return [vp, tab]


func _card(family: GDScript, canvas: Vector2i) -> void:
	var built: Array = await _new_tab(family, canvas)
	var vp: SubViewport = built[0]
	var tab: Control = built[1]
	var tag := "%dx%d" % [canvas.x, canvas.y]
	var store: Variant = tab.get("_store")
	if not (store is Dictionary) or (store as Dictionary).is_empty():
		_fail("%s: the Family has no storehouse card" % tag)
		vp.queue_free()
		return
	var node: Control = store["node"]
	var p: Dictionary = store["parts"]
	# Where it sits: the ledger's first card, the ledger after it.
	_gs.call("adopt", _snap(1, _sh(0, 337600, 42200, 8.0, false)))
	tab.set("_estates", {"upgrades": [{"id": "granary", "name": "Granary", "bucket": "collect_income_bp",
		"level": 0, "max_level": 20, "per_level": 300, "effect_now": 0, "next_cost": 400}], "upgrades_unlocked": true,
		"holdings": [], "treasury": {"vault": "0", "deposit_fee_bp": 1000, "unlock_level": 8, "unlocked": false}})
	tab.call("_paint_all")
	await process_frame
	var gear: Control = (tab.get("_ui") as Dictionary)["gear"][0]["node"]
	var cards: Array = tab.get("_cards")
	var card := Rect2(node.position, node.size)
	_check(card.position.y >= gear.position.y + gear.size.y and card.position.y - (gear.position.y + gear.size.y) < 12.0,
		"%s: the storehouse card is at %s, not under the gear panel (ending %.0f)" % [tag, card, gear.position.y + gear.size.y])
	_check(card.position.x >= 170.0 and card.end.x <= 926.0, "%s: the card runs outside the page's column: %s" % [tag, card])
	# Under it the ROYAL TREASURY card, then the TALENTS / DEEDS / ROAD strip,
	# each at the painting's gap (family_storehouse.png's 11 under the
	# storehouse, or family_treasury.png's 9 and 7 with the treasury between:
	# its hairlines 11 apart), and the ledger under the strip at its own.
	var honours: Dictionary = tab.get("_honours")
	var bank: Dictionary = tab.get("_treasury")
	var under := card.end.y
	var strip_gap := 11.0
	if not bank.is_empty():
		var vault: Control = bank["node"]
		_check(absf(vault.position.y - card.end.y - 9.0) < 0.5,
			"%s: the treasury card starts at %.0f, not 9 under the storehouse (%.0f)" % [tag, vault.position.y, card.end.y])
		under = vault.position.y + vault.size.y
		strip_gap = 7.0
	if not honours.is_empty():
		var strip: Control = honours["node"]
		_check(absf(strip.position.y - under - strip_gap) < 0.5,
			"%s: the strip starts at %.0f, not the painting's %.0f under the card above it (%.0f)" % [tag, strip.position.y, strip_gap, under])
		under = strip.position.y + strip.size.y
	if not cards.is_empty():
		var first: Control = cards[0]["node"]
		_check(absf(first.position.y - under - 9.0) < 0.5,
			"%s: the ledger's first card starts at %.0f, not the ledger's gap under what is above it (%.0f)" % [tag, first.position.y, under])

	# The painting by fill, and the bar with it.
	for row in [[0, "empty"], [112000, "empty"], [200000, "half"], [337600, "full"], [400000, "full"]]:
		_gs.call("adopt", _snap(1, _sh(row[0], 337600, 42200, 8.0, false)))
		tab.call("_paint_storehouse", true)
		var tex: Texture2D = (p["picture"] as TextureRect).texture
		var want := "res://assets/family/storehouse_%s.png" % row[1]
		_check(tex != null and tex.resource_path == want, "%s: %d of 337,600 milli wears %s, not %s" % [tag, row[0],
			tex.resource_path if tex != null else "nothing", want])
		var fill: Control = p["fill"]
		var frac := minf(1.0, float(row[0]) / 337600.0)
		var full_w: float = (fill.get_meta("full") as Vector2).x
		var shown := fill.size.x if fill.visible else 0.0
		_check(absf(shown - (full_w * frac if full_w * frac >= 1.0 else 0.0)) < 1.01,
			"%s: at %.0f%% the bar is %.0f of %.0f" % [tag, frac * 100.0, shown, full_w])

	# The vault shut: dimmed, and its fee still said.
	_gs.call("adopt", _snap(1, _sh(40000, 337600, 42200, 8.0, false)))
	tab.call("_paint_storehouse", true)
	var vault: Control = p["to_vault"]
	var fee: Label = p["vault_fee"]
	_check(vault.modulate.v < 0.7 and fee.modulate.v < 0.7, "%s: TO VAULT is not dimmed below the vault's level" % tag)
	_check(fee.text == "10% FEE", "%s: the vault's plate says \"%s\", not its fee" % [tag, fee.text])
	_gs.call("adopt", _snap(12, _sh(40000, 337600, 42200, 8.0, true)))
	tab.call("_paint_storehouse", true)
	_check(vault.modulate.is_equal_approx(Color.WHITE) and fee.modulate.is_equal_approx(Color.WHITE),
		"%s: TO VAULT stays dimmed once the vault is open" % tag)

	# Figures that fit: a new lord's, a late lord's, one past anything the
	# balance reaches, full and filling.
	for row in [[0, 337600, 42200, 8.0], [41905920, 41905920, 3492160, 12.0], [12345678000, 30000000000, 2500000000, 12.2],
			[99999999000, 99999999000, 9999999000, 99.8]]:
		_gs.call("adopt", _snap(60, _sh(row[0], row[1], row[2], row[3], true)))
		tab.call("_paint_storehouse", true)
		_fits(tag, p)
	# Full says so in red; filling says how long.
	_gs.call("adopt", _snap(60, _sh(41905920, 41905920, 3492160, 12.0, true)))
	tab.call("_paint_storehouse", true)
	var timer: Label = p["full_in"]
	_check(timer.text == "Full" and timer.label_settings.font_color.is_equal_approx(RED),
		"%s: a full storehouse says \"%s\" in %s" % [tag, timer.text, timer.label_settings.font_color])
	_gs.call("adopt", _snap(60, _sh(0, 41905920, 3492160, 12.0, true)))
	tab.call("_paint_storehouse", true)
	_check(timer.text == "Full in 12h 00m" and not timer.label_settings.font_color.is_equal_approx(RED),
		"%s: an empty late storehouse says \"%s\"" % [tag, timer.text])
	_check((p["holds"] as Label).text == "HOLDS 12H", "%s: the storehouse says it holds \"%s\"" % [tag, (p["holds"] as Label).text])
	vp.queue_free()
	await process_frame


func _width(l: Label) -> float:
	var s := l.label_settings
	return s.font.get_string_size(l.text, HORIZONTAL_ALIGNMENT_LEFT, -1, s.font_size).x


func _fits(tag: String, p: Dictionary) -> void:
	var amount: Label = p["amount"]
	var cap: Label = p["capacity"]
	var plate: Control = p["amount_plate"]
	var what := "%s: \"%s %s\"" % [tag, amount.text, cap.text]
	var a_end := amount.position.x + _width(amount)
	var c_end := cap.position.x + _width(cap)
	_check(cap.position.x >= a_end + 4.0, "%s: what it holds runs into the gold waiting" % what)
	_check(c_end <= plate.position.x + plate.size.x - 10.0,
		"%s: the figures run to %.0f, past the plate's end (%.0f)" % [what, c_end, plate.position.x + plate.size.x - 10.0])
	# On one baseline: both centred in the plate's row, the smaller set down by
	# half what their lines differ by above and below it.
	var sa := amount.label_settings
	var sc := cap.label_settings
	var base_a := amount.position.y + (amount.size.y - sa.font.get_height(sa.font_size)) / 2.0 + sa.font.get_ascent(sa.font_size)
	var base_c := cap.position.y + (cap.size.y - sc.font.get_height(sc.font_size)) / 2.0 + sc.font.get_ascent(sc.font_size)
	_check(absf(base_a - base_c) <= 1.0, "%s: the two figures sit %.1f apart, not on one baseline" % [what, base_a - base_c])
	_check(amount.label_settings.font_size >= 18, "%s: the gold waiting is set at %d" % [what, amount.label_settings.font_size])
	for id in ["holds", "full_in", "vault_fee"]:
		var l: Label = p[id]
		var box: float = float(l.get_meta("box_w", l.size.x))
		_check(_width(l) <= box + 1.0, "%s: \"%s\" is %.0f wide in a %.0f box" % [tag, l.text, _width(l), box])


func _pump(until: Callable, frames: int = 600) -> bool:
	for i in frames:
		_stub.poll()
		if until.call():
			return true
		await process_frame
	return false


func _carries(family: GDScript) -> void:
	var built: Array = await _new_tab(family, Vector2i(941, 1672))
	var vp: SubViewport = built[0]
	var tab: Control = built[1]
	var store: Dictionary = tab.get("_store")
	var p: Dictionary = store["parts"]

	# The vault shut: said here, nothing sent.
	_gs.call("adopt", _snap(1, _sh(40000, 337600, 42200, 8.0, false)))
	_refusals.clear()
	(p["to_vault"] as BaseButton).pressed.emit()
	await _pump(func() -> bool: return false, 20)
	_check(_refusals == ["The vault opens at level 8"], "a tap on the shut vault says %s" % str(_refusals))
	_check(_stub.posts().is_empty(), "a tap on the shut vault asked the server")

	# One carry at a time, whichever button is pressed while it is out.
	_gs.call("adopt", _snap(12, _sh(12345678, 337600000, 4220000, 8.0, true), 41))
	_notices.clear()
	_stub.hold = true
	(p["collect"] as BaseButton).pressed.emit()
	(p["collect"] as BaseButton).pressed.emit()
	(p["to_vault"] as BaseButton).pressed.emit()
	await _pump(func() -> bool: return not _stub.posts().is_empty(), 300)
	await _pump(func() -> bool: return false, 30)
	(p["collect"] as BaseButton).pressed.emit()
	await _pump(func() -> bool: return false, 10)
	var posts := _stub.posts()
	_check(posts.size() == 1, "%d carries went out while the first was in flight" % posts.size())
	if not posts.is_empty():
		var r: Dictionary = posts[0]
		_check(r["path"] == CARRY and str(r["body"].get("to", "")) == "purse" and int(r["body"].get("action_seq", 0)) == 42,
			"COLLECT sent %s %s, not {to: purse, action_seq: 42} to %s" % [r["path"], str(r["body"]), CARRY])
	_check(bool(tab.get("_busy")), "the card let go of its carry before the answer")
	var after := _snap(12, _sh(678, 337600000, 4220000, 8.0, true), 42)
	after["player"]["gold"] = "13345"
	_stub.answers[CARRY] = [[200, {"to": "purse", "carried": 12345, "fee": 0, "banked": 0, "snapshot": after}]]
	_stub.release()
	await _pump(func() -> bool: return not bool(tab.get("_busy")), 600)
	_check(_notices.has("+12,345 to the purse"), "the carry to the purse said %s" % str(_notices))
	_check(int((_gs.call("storehouse") as Dictionary).get("milli", -1)) == 678, "the carry's snapshot was not adopted")
	_check(_stub.posts().size() == 1, "a second carry went out after the first landed")

	# To the vault: what landed and what the fee took.
	_notices.clear()
	var banked := _snap(12, _sh(0, 337600000, 4220000, 8.0, true), 43)
	_stub.answers[CARRY] = [[200, {"to": "treasury", "carried": 12345, "fee": 1235, "banked": 11110, "snapshot": banked}]]
	(p["to_vault"] as BaseButton).pressed.emit()
	await _pump(func() -> bool: return _stub.posts().size() >= 2 and not bool(tab.get("_busy")), 600)
	var last: Dictionary = _stub.posts().back()
	_check(str(last["body"].get("to", "")) == "treasury" and int(last["body"].get("action_seq", 0)) == 43,
		"TO VAULT sent %s" % str(last["body"]))
	_check(_notices.has("+11,110 to the vault (1,235 fee)"), "the carry to the vault said %s" % str(_notices))

	# Refusals in the game's words.
	for row in [[409, "storehouse_empty", "the storehouse holds nothing yet", "purse",
			(family.get_script_constant_map()["STORE_REFUSALS"] as Dictionary)["storehouse_empty"]],
			[403, "level_too_low", "your level is too low: the treasury opens at level 8", "treasury",
			"The vault opens at level 8"]]:
		_refusals.clear()
		var n := _stub.posts().size()
		_stub.answers[CARRY] = [[row[0], {"code": row[1], "message": row[2]}]]
		(p["collect" if row[3] == "purse" else "to_vault"] as BaseButton).pressed.emit()
		await _pump(func() -> bool: return _stub.posts().size() > n and not bool(tab.get("_busy")), 600)
		_check(_refusals == [row[4]], "a %d %s is said as %s, not \"%s\"" % [row[0], row[1], str(_refusals), row[4]])
	vp.queue_free()
	await process_frame
