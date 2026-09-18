extends SceneTree
## The hour's event as it begins (scenes/court/hourly_popup.gd):
##
## - it is due once an hour, for an hour after the one the lord arrived in, and
##   never for the hour already shown;
## - the card says the event -- its name, its blurb, what it does for this lord
##   (the server's figure), its time left, counting -- with the event's disc set
##   in the kit's burning hour (events_kit/gauge_blazing) standing out of its top;
##   the disc sits in the gauge's well, the whole card and emblem on the canvas,
##   centred, the buttons on the card;
## - its green plate leads to where the hour matters: TO WORK for gold and
##   experience and Busy Hands, TO THE MARKET for Fortune's Favour and Fresh
##   Wares, REFILL for the sale, CLAIM for the courier's gift waiting;
## - the next hour's, shown for a capture in a quiet hour, says THE NEXT HOUR and
##   when it begins.
##
## Run: godot --headless --path client --script tests/hourly_popup_card.gd

const HOUR := {"id": "gold_rush", "name": "Gold Rush", "blurb": "Every job pays double gold.", "icon": "hourly/gold_rush",
	"kind": "boost", "bucket": "collect_income_bp", "bp": 10000, "effective_bp": 10000, "active": true,
	"ends_in": 840, "next_in": 2640, "left": 0, "next": null}

var _fails := 0
var _checked := 0


func _initialize() -> void:
	await process_frame
	root.get_node("Env").set("api_base_url", "http://127.0.0.1:9")
	var popup: GDScript = load("res://scenes/court/hourly_popup.gd")
	for m in ["maybe_show", "due", "claim", "action"]:
		if not popup.has_method(m):
			print("FAIL  hourly_popup.%s does not exist" % m)
			quit(1)
			return
	_expect(not popup.due(500, -1, -1), "a popup is due before the lord's arrival hour is known")
	_expect(not popup.due(500, 500, -1), "the hour the lord arrived in is due its popup")
	_expect(popup.due(501, 500, -1), "the next hour's event is not due its popup")
	_expect(not popup.due(501, 500, 501), "an hour already shown is due again")
	var act := func(extra: Dictionary) -> Array:
		var h := HOUR.duplicate()
		h.merge(extra, true)
		return popup.action(h)
	_expect(act.call({}) == ["TO WORK", "collect"], "Gold Rush leads %s" % [act.call({})])
	_expect(act.call({"bucket": "xp_bp"}) == ["TO WORK", "collect"], "Scholar's Hour leads elsewhere")
	_expect(act.call({"bucket": "luck_bp"}) == ["TO THE MARKET", "shop"], "Fortune's Favour leads elsewhere")
	_expect(act.call({"kind": "free_reroll"}) == ["TO THE MARKET", "shop"], "Fresh Wares leads elsewhere")
	_expect(act.call({"kind": "refill_discount"}) == ["REFILL", "energy"], "the sale leads elsewhere")
	_expect(act.call({"kind": "quest_multiplier"}) == ["TO WORK", "collect"], "Busy Hands leads elsewhere")
	_expect(act.call({"kind": "gift", "left": 1}) == ["CLAIM", "claim"], "the courier's gift is not claimed from the card")
	_expect(act.call({"kind": "gift", "left": 0}) == ["SPLENDID", ""], "a taken gift offers CLAIM")
	for canvas in [Vector2(941, 1672), Vector2(941, 2040)]:
		await _card(popup, canvas)
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  %d checks: the hour's card is due once an hour, says the event in the server's figures, and leads to it" % _checked)
	quit()


func _card(popup: GDScript, canvas: Vector2) -> void:
	var tag := "%dx%d" % [canvas.x, canvas.y]
	var vp := SubViewport.new()
	vp.size = Vector2i(canvas)
	root.add_child(vp)
	root.get_node("Nav").set("host", vp)
	var host := Control.new()
	host.size = canvas
	vp.add_child(host)
	var gs := root.get_node("GameState")
	for case in ["running", "gift", "next"]:
		var h := HOUR.duplicate()
		match case:
			"gift":
				h.merge({"id": "royal_courier", "name": "Royal Courier", "icon": "hourly/royal_courier", "kind": "gift",
					"blurb": "A courier brings a cart writ from the crown.", "ends_in": 3000, "left": 1,
					"lines": [{"kind": "token", "text": "Cart Writ", "amount": 1, "icon": "cart"}]}, true)
			"next":
				h = {"id": "", "active": false, "ends_in": 0, "next_in": 760,
					"next": {"id": "busy_hands", "name": "Busy Hands", "blurb": "The day's quests count double.", "icon": "hourly/busy_hands"}}
		gs.set("snapshot", {"player": {"level": 30, "gold": "1", "action_seq": 1}, "energy": {}, "live": {"hourly": h}})
		gs.set("_energy_at_ms", Time.get_ticks_msec())
		if case == "next":
			# A quiet hour: the dev page shows the next hour's event.
			var live: Dictionary = gs.call("live")
			var next: Dictionary = live["hourly"]["next"].duplicate()
			next.merge({"active": false, "next_in": 760}, true)
			gs.set("snapshot", {"player": {"level": 30}, "energy": {}, "live": {"hourly": next}})
		var shown: bool = popup.maybe_show(host, true)
		await process_frame
		await process_frame
		var card := _find(vp)
		_expect(shown and card != null, "%s %s: no card was shown" % [tag, case])
		if card == null:
			continue
		var rootc: Control = card.get("_root")
		var n := func(id: String) -> Node: return rootc.find_child(id, true, false)
		var title := n.call("title") as Label
		var blurb := n.call("blurb") as Label
		var worth := n.call("worth") as Label
		var time := n.call("time") as Label
		var primary := n.call("primary") as Button
		var later := n.call("later") as Button
		var gauge := n.call("gauge") as TextureRect
		var disc := n.call("disc") as TextureRect
		match case:
			"running":
				_expect(title.text == "GOLD RUSH" and blurb.text == "Every job pays double gold." and worth.text == "+100% for you"
					and time.text == "14m 00s left" and primary.text == "TO WORK" and later.text == "LATER",
					"%s: the card reads %s / %s / %s / %s / %s" % [tag, title.text, blurb.text, worth.text, time.text, primary.text])
				_expect((n.call("kicker") as Label).text == "THE HOUR BEGINS", "%s: the kicker reads %s" % [tag, (n.call("kicker") as Label).text])
			"gift":
				_expect(title.text == "ROYAL COURIER" and worth.text == "Cart Writ for you" and primary.text == "CLAIM",
					"%s: the gift's card reads %s / %s / %s" % [tag, title.text, worth.text, primary.text])
			"next":
				_expect(title.text == "BUSY HANDS" and (n.call("kicker") as Label).text == "THE NEXT HOUR"
					and time.text == "begins in 12m 40s" and worth.text == "",
					"%s: the next hour's card reads %s / %s / %s" % [tag, title.text, time.text, worth.text])
		_expect(gauge.texture.resource_path.ends_with("events_kit/gauge_blazing.png") and disc.texture != null
			and disc.texture.resource_path.begins_with("res://assets/hourly/"), "%s %s: the emblem is not the kit's" % [tag, case])
		var gauge_mid := gauge.position + Vector2(159, 180) * 0.9
		var disc_mid := disc.position + disc.size / 2.0
		_expect(gauge_mid.distance_to(disc_mid) <= 1.0, "%s %s: the disc sits %s off the gauge's well" % [tag, case, disc_mid - gauge_mid])
		var plate := Rect2()
		for c in rootc.get_children():
			if c is NinePatchRect:
				plate = Rect2((c as Control).position, (c as Control).size)
		var emblem := Rect2(gauge.position, gauge.size)
		_expect(emblem.position.y >= 0.0 and plate.end.y <= canvas.y and absf(plate.get_center().x - canvas.x / 2.0) <= 1.0,
			"%s %s: the card (%s) or its emblem (%s) is off the canvas or not centred" % [tag, case, plate, emblem])
		for b in [primary, later]:
			_expect(plate.encloses(Rect2(b.position, b.size)) and b.size.y >= 96.0, "%s %s: a button is off the card or short" % [tag, case])
		_expect(plate.encloses(Rect2(title.position, title.size)) and plate.encloses(Rect2(time.get_parent().position, (time.get_parent() as Control).size)),
			"%s %s: the words run off the card" % [tag, case])
		var tf := title.label_settings
		_expect(tf.font.get_string_size(title.text, HORIZONTAL_ALIGNMENT_LEFT, -1, tf.font_size).x <= title.size.x,
			"%s %s: the title does not fit" % [tag, case])
		card.call("close")
		await process_frame
	vp.queue_free()
	await process_frame


func _find(vp: Node) -> Node:
	for c in vp.get_children():
		if c is CanvasLayer and c.get_script() != null and (c.get_script() as Script).resource_path.ends_with("hourly_popup.gd"):
			return c
	return null


func _expect(ok: bool, why: String) -> void:
	_checked += 1
	if not ok:
		_fails += 1
		print("  FAIL  " + why)
