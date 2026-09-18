extends SceneTree
## ROYAL COURT is court.png's six cards, each with its live line and its count.
##
## Checked: the six cards stand where the painting has them, each its own
## painting with nothing over another; every card is live since Wave 4 built
## the Charter, and SEASON PASS says the tier and the season's time; each
## plate says what its card holds -- a new
## lord with nothing (no letters, no offer, no event), a lord with a dozen
## letters and three unseen offers (9+ in the disc, and 9+ on the rail's COURT,
## which adds the same counts up), an event running beside one announced, the
## Tax Cart below its level, with carts and writs waiting, and counting to the
## next; the longest line each card can say fits its plate at a size that
## still reads; the discs show only when something waits; and STORE, ROYAL
## MAIL, OFFERS and CHESTS open their Court views over the COURT tab, which the
## views close back to -- SEASON PASS and EVENTS with them, since Wave 4, and
## OFFERS its own ROYAL OFFERS screen since its painting was cut.
##
## Run: godot --headless --path client --script tests/court_grid.gd

const CARDS := ["store", "pass", "events", "mail", "chests", "offers"]
## Where court.png's frames are (outer rims), per card.
const PAINTED := {"store": Rect2(171, 487, 361, 343), "pass": Rect2(545, 487, 367, 343),
	"events": Rect2(171, 843, 361, 345), "mail": Rect2(545, 843, 367, 345),
	"chests": Rect2(171, 1199, 361, 351), "offers": Rect2(545, 1199, 367, 351)}
## An offer three hours and twenty minutes from its end, as /v1/store/court sends it.
const COURT := {"products": [{"id": "offer_a", "shelf": "offers", "ends_in": 12000},
	{"id": "offer_b", "shelf": "offers", "ends_in": 90000}, {"id": "pack", "shelf": "packs"}],
	"stipend": {"active": true, "claimable_today": true}}
const LIVE := {"boosts": [{"bucket": "collect_income_bp", "bp": 5000, "effective_bp": 7000, "ends_in": 12000}],
	"upcoming": [{"bucket": "xp_bp", "bp": 2500, "effective_bp": 2500, "starts_in": 18000, "ends_in": 25200}]}

var _fails := 0


func _initialize() -> void:
	await process_frame
	var gs := root.get_node("GameState")
	gs.set("snapshot", {"player": {"username": "Wwwwwwwwwwwwwwww", "level": 1, "gold": "0",
		"diamonds": 0, "action_seq": 1}, "energy": {"current": 1, "max": 2}, "sections": []})
	var script: GDScript = load("res://scenes/tabs/court.gd")
	if script == null or not FileAccess.file_exists("res://layout/court.json"):
		_fail("there is no COURT tab (scenes/tabs/court.gd, layout/court.json)")
		_done()
		return
	_statuses(script)
	await _grid(script, 1672.0)
	await _grid(script, 2040.0)
	await _taps()
	_done()


## What each plate says, for the hard cases, straight from the tab's rule.
func _statuses(script: GDScript) -> void:
	var none := {}
	var cases := [
		# id, badges, live, court, want
		["mail", {}, none, none, "No letters"],
		["mail", {"mail": 1}, none, none, "1 letter waiting"],
		["mail", {"mail": 12}, none, none, "12 letters waiting"],
		["offers", {}, none, none, "No offer now"],
		["offers", {"offers_unseen": 3}, none, COURT, "Ends in 3h 20m"],
		["store", {}, none, none, ""],
		["store", {}, none, COURT, "An offer ends in 3h 20m"],
		["store", {"store_free": true}, none, COURT, "Today's stipend waits"],
		["store", {"store_free": true}, none, none, "A free gift waits"],
		["store", {"store_free": true}, none, {"vip": {"gift_claimable": true}}, "Royal Favour's gift waits"],
		["store", {"store_free": true}, none, {"deals": {"slots": [{"slot": 0, "claimed": false}, {"slot": 1, "claimed": false}]}}, "Today's free gift waits"],
		["store", {"store_free": true}, none, {"deals": {"slots": [{"slot": 0, "claimed": true}]}}, "A free gift waits"],
		["events", {}, none, none, "No event now"],
		["events", {}, LIVE, none, "Job payout +50% · 3h 20m"],
		["events", {}, {"upcoming": LIVE["upcoming"]}, none, "Starts in 5h 00m"],
		# The Charter, from the snapshot's season: its tier and what the season
		# has left; nothing before the first season.
		["pass", {}, LIVE, COURT, ""],
		["pass", {}, {"season": {"number": 1, "tier": 12, "tiers": 50, "ends_in": 86400 * 12 + 3600}}, COURT,
			"Tier 12 of 50  ·  12d 01h left"],
		["pass", {}, {"season": {"number": 3, "tier": 0, "tiers": 50, "ends_in": 60}}, COURT,
			"Tier 0 of 50  ·  1m 00s left"],
	]
	for c in cases:
		var got := str(script.call("status_for", c[0], c[1], c[2], 0, c[3], 0))
		_expect(got == c[4], "%s with %s says \"%s\", not \"%s\"" % [c[0], c[1], got, c[4]])
	# The Tax Cart, from the snapshot's cart: below its level, carts and writs
	# waiting (a writ is one more cart), counting to the next, and nothing from
	# a server that sends no cart.
	var carts := [
		[{}, 0, ""],
		[{"unlocked": false, "unlock_level": 2}, 0, "Opens at level 2"],
		[{"unlocked": true, "stock": 2, "cap": 3, "tokens": 0, "next_in": 5400}, 0, "2 carts waiting"],
		[{"unlocked": true, "stock": 0, "cap": 3, "tokens": 1, "next_in": 5400}, 0, "1 cart waiting"],
		[{"unlocked": true, "stock": 3, "cap": 3, "tokens": 2, "next_in": 0}, 0, "5 carts waiting"],
		[{"unlocked": true, "stock": 0, "cap": 3, "tokens": 0, "next_in": 4800}, 0, "Next cart in 1h 20m"],
		[{"unlocked": true, "stock": 0, "cap": 3, "tokens": 0, "next_in": 4800}, 3600, "Next cart in 20m 00s"],
		[{"unlocked": true, "stock": 0, "cap": 3, "tokens": 0, "next_in": 60}, 3600, "Next cart in 0s"],
	]
	for c in carts:
		var got := str(script.call("status_for", "chests", {"store_free": true}, LIVE, c[1], COURT, 0, c[0]))
		_expect(got == c[2], "chests with %s, %ds on, says \"%s\", not \"%s\"" % [c[0], c[1], got, c[2]])
	# Counted down from the answer's moment: an hour on, an hour less.
	_expect(str(script.call("status_for", "events", {}, LIVE, 3600, {}, 0)) == "Job payout +50% · 2h 20m",
		"the event's time does not count down from the snapshot")
	_expect(str(script.call("status_for", "offers", {}, {}, 0, COURT, 3600)) == "Ends in 2h 20m",
		"the offer's time does not count down from the store's answer")
	# The discs add up to the rail's COURT bubble.
	var b := {"mail": 12, "offers_unseen": 3, "store_free": true, "quests": 4, "cart": 2}
	var sum := 0
	for id in CARDS:
		sum += int(script.call("count_for", id, b))
	var shell: GDScript = load("res://scenes/shell/shell.gd")
	_expect(sum == int(shell.call("court_count", b)) and sum == 18,
		"the cards count %d and the rail's COURT %d, for 12 letters, 3 offers, the free thing and 2 carts" % [sum, shell.call("court_count", b)])
	_expect(int(script.call("count_for", "chests", b)) == 2, "the Chests card does not count the carts waiting")


func _grid(script: GDScript, h: float) -> void:
	var gs := root.get_node("GameState")
	var host := Control.new()
	host.size = Vector2(941, h)
	root.add_child(host)
	var tab: Control = script.new()
	tab.set_anchors_preset(Control.PRESET_FULL_RECT)
	host.add_child(tab)
	await process_frame
	var ui: Dictionary = tab.get("_ui")
	var tag := "%.0f" % h
	_expect(ui.has("header") and (ui["header"] as TextureRect).texture.resource_path.ends_with("court/header.png"),
		"%s: the header is not court.png's" % tag)
	var rects := {}
	for id in CARDS:
		var card: TextureRect = ui.get("card_" + id)
		if card == null:
			_fail("%s: there is no %s card" % [tag, id])
			continue
		_expect(card.texture != null and card.texture.resource_path.ends_with("court/card_%s.png" % id),
			"%s: %s wears %s" % [tag, id, card.texture.resource_path if card.texture else "nothing"])
		var r := Rect2(card.position, card.size)
		rects[id] = r
		# The crop's frame is its painted frame, one unit of margin round it.
		var painted: Rect2 = PAINTED[id]
		_expect(absf(r.position.x + 1.0 - painted.position.x) <= 1.0 and absf(r.position.y + 1.0 - painted.position.y) <= 1.0,
			"%s: %s stands at (%.0f, %.0f), the painting's frame at (%.0f, %.0f)" % [tag, id, r.position.x, r.position.y,
			painted.position.x, painted.position.y])
		# Every card is built now: none is dimmed, and each answers a tap.
		_expect(card.modulate.r >= 0.8, "%s: %s is dimmed though it is open" % [tag, id])
		var hit: BaseButton = ui["hit_" + id]
		_expect(not hit.disabled, "%s: %s's tap is dead" % [tag, id])
		# The plate's line sits inside the plate, and the disc on the frame's corner.
		var status: Label = ui["status_" + id]
		var sr := Rect2(status.position, Vector2(float(status.get_meta("box_w", status.size.x)), status.size.y))
		_expect(r.encloses(sr), "%s: %s's line runs outside its card" % [tag, id])
		var badge: Control = ui["badge_" + id]
		_expect(r.encloses(Rect2(badge.position, badge.size)), "%s: %s's disc leaves its card" % [tag, id])
	for i in CARDS.size():
		for j in range(i + 1, CARDS.size()):
			if rects.has(CARDS[i]) and rects.has(CARDS[j]):
				_expect(not (rects[CARDS[i]] as Rect2).grow(-2).intersects((rects[CARDS[j]] as Rect2).grow(-2)),
					"%s: %s and %s overlap" % [tag, CARDS[i], CARDS[j]])
	var footer: Control = ui["footer"]
	_expect(absf(footer.position.y + footer.size.y - h) < 0.5, "%s: the foot ends at %.0f" % [tag, footer.position.y + footer.size.y])
	_expect(footer.position.y >= 1549.0, "%s: the foot is over the last row of cards" % tag)

	# A new lord: nothing waits, nothing runs.
	gs.call("set_badges", {})
	gs.get("snapshot")["live"] = {}
	tab.call("paint_court", {})
	await process_frame
	for id in CARDS:
		_expect(not (ui["badge_" + id] as CanvasItem).visible, "%s: a new lord's %s shows a count" % [tag, id])
	_expect((ui["status_mail"] as Label).text == "No letters", "%s: a new lord's mail says %s" % [tag, (ui["status_mail"] as Label).text])
	_expect((ui["status_events"] as Label).text == "No event now", "%s: events says %s" % [tag, (ui["status_events"] as Label).text])
	# A dozen letters and three unseen offers: 9+ and 3.
	gs.call("set_badges", {"mail": 12, "offers_unseen": 3, "store_free": true})
	gs.get("snapshot")["live"] = LIVE
	tab.call("paint_court", COURT)
	await process_frame
	_expect((ui["badge_mail"] as CanvasItem).visible and (ui["count_mail"] as Label).text == "9+",
		"%s: twelve letters count %s" % [tag, (ui["count_mail"] as Label).text])
	_expect((ui["count_offers"] as Label).text == "3" and (ui["count_store"] as Label).text == "1",
		"%s: the offers and the store count %s and %s" % [tag, (ui["count_offers"] as Label).text, (ui["count_store"] as Label).text])
	_expect(not (ui["badge_events"] as CanvasItem).visible, "%s: EVENTS counts something" % tag)
	# The longest line each card can say fits its plate, at a size that reads.
	var longest := {"store": "An offer ends in 23h 59m", "events": "Job payout +150% · 23h 59m",
		"mail": "99 letters waiting", "offers": "Ends in 29d 23h", "pass": "Tier 50 of 50  ·  27d 23h left", "chests": "Next cart in 23h 59m"}
	for id in longest:
		var l: Label = ui["status_" + id]
		l.text = longest[id]
		UI_fit(l)
		var s := l.label_settings
		var w := s.font.get_string_size(l.text, HORIZONTAL_ALIGNMENT_LEFT, -1, s.font_size).x
		var box := float(l.get_meta("box_w", l.size.x))
		_expect(w <= box + 0.5 and s.font_size >= 20, "%s: \"%s\" is %.0f wide at %d, its plate %.0f" % [tag, l.text, w, s.font_size, box])
	host.queue_free()
	await process_frame


func UI_fit(l: Label) -> void:
	(load("res://scripts/ui/ui.gd") as GDScript).call("fit_line", l, 26, 17)


## STORE, ROYAL MAIL and OFFERS open their views over the COURT; the views
## close back to it.
func _taps() -> void:
	var parent := Control.new()
	parent.size = Vector2(941, 1672)
	root.add_child(parent)
	var shell: Control = (load("res://scenes/shell/shell.tscn") as PackedScene).instantiate()
	parent.add_child(shell)
	shell.set_anchors_preset(Control.PRESET_FULL_RECT)
	for i in 3:
		await process_frame
	shell.call("open", "court")
	await process_frame
	var tab: Control = (shell.get("_tabs") as Dictionary).get("court")
	_expect(tab != null and tab.visible, "the COURT tab did not open")
	if tab == null:
		parent.queue_free()
		return
	var ui: Dictionary = tab.get("_ui")
	for id in ["store", "mail", "offers", "chests", "pass", "events"]:
		(ui["hit_" + id] as BaseButton).pressed.emit()
		await process_frame
		var view: Control = shell.get("_view")
		# OFFERS has its own painted screen since art/reference/offers.png was
		# cut (scenes/court/offers_view.gd); it was the Royal Store scrolled to
		# its offers section before that.
		var want: String = {"mail": "mail_view.gd", "chests": "chests_view.gd", "pass": "pass_view.gd",
			"events": "events_view.gd", "offers": "offers_view.gd"}.get(id, "store_view.gd")
		_expect(view != null and (view.get_script() as Script).resource_path.ends_with(want),
			"COURT's %s opened %s" % [id, (view.get_script() as Script).resource_path if view else "nothing"])
		_expect(not tab.visible, "the COURT shows through the %s view" % id)
		shell.call("close_view")
		await process_frame
		_expect(str(shell.call("current_tab")) == "court" and tab.visible, "closing %s did not go back to the COURT" % id)

	parent.queue_free()
	await process_frame


func _done() -> void:
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  six cards where court.png has them; their lines (the Tax Cart's too), counts and taps, a new lord to 9+, on 1672 and 2040")
	quit()


func _expect(ok: bool, why: String) -> void:
	if not ok:
		_fail(why)


func _fail(why: String) -> void:
	_fails += 1
	printerr("  ", why)
