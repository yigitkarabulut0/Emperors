extends SceneTree
## THE BOUNTY BOARD (scenes/attack/bounty_board.gd) prices nothing.
##
## The rule this screen exists to keep: every figure on it is the server's. The
## board's three amounts and their BURNED fees arrive resolved, a tap names a
## plate and never a number, and what the client sends carries no amount at all
## -- the server's strict decode refuses one, which is the guard.
##
## What must hold:
##  - four posters, each the painting's; a slot with no price on it keeps the
##    painted empty poster and answers nothing;
##  - a hunted lord under a shield wears the RAID's own shield pill, the same
##    asset a raid card uses, and cannot be hunted;
##  - the fee printed is the server's fee, to the coin -- changing it in the
##    answer changes the words and nothing else;
##  - which price is chosen is said by the number's colour, and PLACE BOUNTY
##    stays dim until a price and a head are both in hand;
##  - both bands say so when they hold nothing;
##  - a nine-figure purse fits its plate.
##
## Run: godot --headless --path client --script tests/bounty_board.gd

const CANVASES := [Vector2(941, 1672), Vector2(941, 2040)]
const LONG := "Wwwwwwwwwwwwwwww"

var _fails := 0
var _checked := 0
## Loaded once the autoloads are up: naming UI here would meet Art before it
## exists (the rule tab_strip.gd's own test records).
var U: GDScript


func _initialize() -> void:
	await process_frame
	root.get_node("Env").set("api_base_url", "http://127.0.0.1:9")
	U = load("res://scripts/ui/ui.gd")
	_prices_nothing()
	for canvas in CANVASES:
		await _board(canvas, _full())
		await _board(canvas, _bare())
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  %d checks: the board draws the server's prices and works out none of them" % _checked)
	quit()


func _expect(ok: bool, what: String) -> void:
	_checked += 1
	if not ok:
		_fails += 1
		print("  FAIL  " + what)


## Read the screen: it may not carry the fee's rate, the raid cap, or any way
## of pricing a bounty for itself.
func _prices_nothing() -> void:
	var src := FileAccess.get_file_as_string("res://scenes/attack/bounty_board.gd")
	for word in ["fee_bp", "claim_cap_multiple", "min_amount", "raidCap", "0.2", "* 2000"]:
		_expect(not src.contains(word), "bounty_board.gd carries %s: the server prices a bounty" % word)
	_expect(src.contains('"plate": _plate'), "the placing does not send a plate's id")
	_expect(not src.contains('"amount":'), "the placing sends an amount")


func _poster(name: String, pot: int, shield: int) -> Dictionary:
	return {"id": "b" + name, "target_id": "t" + name, "name": name, "avatar": "knight",
		"level": 22, "pot": pot, "pays": mini(pot, 8625), "expires_in": 3600 * 41,
		"shield_seconds": shield, "energy_cost": 9, "worn": {}, "vip_seal": false}


func _full() -> Dictionary:
	return {"unlocked": true, "unlock_level": 15,
		"posters": [_poster(LONG, 9_999_999_999, 0), _poster("Aldric", 5000, 4 * 3600),
			_poster("Seraphine", 1000, 0)],
		"on_my_head": [{"id": "x", "name": "Lord Darius", "pot": 5000, "expires_in": 3600 * 20}],
		"mine": [{"id": "y", "name": "Aldric", "pot": 1000, "expires_in": 3600 * 9, "state": "open"}],
		"presets": [{"id": "plate_1000", "amount": 1000, "fee": 200, "total": 1200, "affordable": true},
			{"id": "plate_5000", "amount": 5000, "fee": 1000, "total": 6000, "affordable": true},
			{"id": "plate_20000", "amount": 20000, "fee": 4000, "total": 24000, "affordable": false}],
		"can_place": [{"player_id": "p1", "name": "Aldric", "avatar": "knight", "level": 20,
			"worn": {}, "vip_seal": false}],
		"places_left": 3, "gold": "50000000",
		"rules": {"hours": 48, "fee_bp": 2000, "claim_cap_multiple": 3, "claims_per_target": 4,
			"cooldown_minutes": 120, "pair_claims_per_week": 2, "min_account_hours": 72,
			"max_levels_above": 5, "places_per_day": 3, "claim_cap": 8625}}


func _bare() -> Dictionary:
	var v := _full()
	v["posters"] = []
	v["on_my_head"] = []
	v["mine"] = []
	v["can_place"] = []
	return v


func _board(canvas: Vector2, data: Dictionary) -> void:
	var bare := (data["posters"] as Array).is_empty()
	var tag := "%dx%d%s" % [int(canvas.x), int(canvas.y), " (bare)" if bare else ""]
	var host := Control.new()
	host.size = canvas
	root.add_child(host)
	var b: Control = (load("res://scenes/attack/bounty_board.gd") as GDScript).new()
	host.add_child(b)
	for i in 3:
		await process_frame
	b.call("paint", data)
	await process_frame
	var ui: Dictionary = b.get("_ui")

	var posters: Array = data["posters"]
	var slots: Array = ui["poster"]
	_expect(slots.size() == 4, "%s: the board has %d slots, not the painting's four" % [tag, slots.size()])
	for i in slots.size():
		var c: Dictionary = slots[i]
		var p: Dictionary = c["parts"]
		var filled := i < posters.size()
		_expect((p["portrait"] as CanvasItem).visible == filled,
			"%s: slot %d draws a face it should not" % [tag, i])
		_expect((c["hit"] as BaseButton).disabled != (filled and int((posters[i] if filled else {}).get("shield_seconds", 0)) == 0),
			"%s: slot %d answers when it should not" % [tag, i])
	if not bare:
		# The shielded head wears the RAID's own pill and cannot be hunted.
		var shielded: Dictionary = slots[1]
		_expect((shielded["parts"]["shield"] as CanvasItem).visible,
			"%s: a shielded head wears no shield" % tag)
		_expect((shielded["hit"] as BaseButton).disabled,
			"%s: a shielded head can still be hunted" % tag)
		var pill: TextureRect = shielded["parts"]["shield"]
		_expect(pill.texture != null and str(pill.texture.resource_path).contains("attack/shield_pill"),
			"%s: the poster's shield is not the raid card's own" % tag)
		# The biggest purse the game can hold fits its plate.
		var pot: Label = (slots[0] as Dictionary)["parts"]["pot"]
		_expect(pot.text == "9,999,999,999", "%s: the pot reads %s" % [tag, pot.text])
		var ink := pot.label_settings.font.get_string_size(pot.text, HORIZONTAL_ALIGNMENT_LEFT, -1,
			pot.label_settings.font_size).x
		_expect(ink <= pot.size.x + 0.5, "%s: a nine-figure purse is %.0f in a %.0f plate" % [tag, ink, pot.size.x])

	# The fee is the server's, to the coin.
	b.set("_plate", "plate_5000")
	b.call("_paint")
	await process_frame
	_expect((ui["fee"] as Label).text.begins_with("1,000 burned"),
		"%s: the fee reads %s, not the server's 1,000" % [tag, (ui["fee"] as Label).text])
	var chosen := 0
	for a in ui["amount"]:
		var l: Label = (a as Dictionary)["parts"]["value"]
		if l.label_settings.font_color == U.get("GOLD"):
			chosen += 1
	_expect(chosen == 1, "%s: %d prices are shown as chosen" % [tag, chosen])
	_expect((ui["place"] as CanvasItem).modulate != Color.WHITE,
		"%s: PLACE BOUNTY is lit with no head chosen" % tag)

	# Both bands say so when empty.
	var head: Label = (ui["on_head_row"][0] as Dictionary)["parts"]["words"]
	var mine: Label = (ui["your_row"][0] as Dictionary)["parts"]["words"]
	if bare:
		_expect(head.text.contains("No price"), "%s: ON YOUR HEAD says %s" % [tag, head.text])
		_expect(mine.text.contains("no prices"), "%s: YOUR BOUNTIES says %s" % [tag, mine.text])
	else:
		_expect(head.text.contains("5,000") and head.text.contains("Lord Darius"),
			"%s: ON YOUR HEAD reads %s" % [tag, head.text])
	b.queue_free()
	host.queue_free()
	await process_frame
