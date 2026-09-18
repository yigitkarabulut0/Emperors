extends SceneTree
## The hour on the Collect tab's band (collect_events.png's band, LiveEvents.band):
##
## - the hour's event while it runs: its disc (hourly/<id>, events_kit.png)
##   pinned over the band's scene against the name plate, its name, what it does
##   for this lord in the server's figures, its time left; "· 1 more" for a
##   festival running beside it;
## - each kind in its own words: a boost's "+100% for you", the sale's
##   "Refills -50%", the free restock left, Busy Hands' "Quests count ×2" (and
##   today's heading "×2" while it runs), the courier's gift with a CLAIM plate
##   over the time plate until it is taken;
## - the hour's minutes over, the festival running takes the band; in a quiet
##   hour the next hour's event is announced -- its disc quieter, the kit's NEXT
##   plate on its foot, "Next hour", "in 12m 40s"; a festival only announced
##   is "Coming soon"; with nothing to say there is no band;
## - every hourly name fits its plate: in capitals at 15 or more, or -- the
##   longest, Quartermaster's Sale and Merchant Caravan -- in Cinzel's small
##   capitals at 14 or more; the disc and NEXT stand on the band's scene, clear
##   of the name plate's frame (x 362) and inside the band.
##
## Run: godot --headless --path client --script tests/hourly_band.gd
##
## The Collect tab is loaded at run time, never named as a class here: a class
## named in this script compiles before the autoloads exist.

const PLATE_FRAME_X := 362.0
const BAND := Vector2(762, 147)
const NAMES := ["Gold Rush", "Scholar's Hour", "Fortune's Favour", "Quartermaster's Sale", "Fresh Wares",
	"Busy Hands", "Royal Courier", "Honor Hour"]

var _fails := 0
var _checked := 0


func _initialize() -> void:
	await process_frame
	root.get_node("Env").set("api_base_url", "http://127.0.0.1:9")
	for canvas in [Vector2i(941, 1672), Vector2i(941, 2040)]:
		await _canvas(canvas)
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  %d checks: the band says the hour -- its disc, its kind's words, the gift's CLAIM, the next hour's NEXT -- and fits every name" % _checked)
	quit()


func _expect(cond: bool, msg: String) -> void:
	_checked += 1
	if not cond:
		_fails += 1
		print("  FAIL  " + msg)


func _hour(kind: String, extra: Dictionary = {}) -> Dictionary:
	var h := {"id": "gold_rush", "name": "Gold Rush", "blurb": "Every job pays double gold.",
		"icon": "hourly/gold_rush", "kind": kind, "active": true, "ends_in": 840, "next_in": 2640, "left": 0,
		"next": null}
	h.merge(extra, true)
	return h


func _snap(live: Dictionary) -> Dictionary:
	return {"player": {"level": 30, "gold": "1", "action_seq": 1}, "jobs": [], "energy": {}, "live": live}


func _canvas(canvas: Vector2i) -> void:
	var vp := SubViewport.new()
	vp.size = canvas
	root.add_child(vp)
	root.get_node("Nav").set("host", vp)
	var gs: Node = root.get_node("GameState")
	gs.call("adopt", _snap({}))
	var tab: Control = (load("res://scenes/tabs/collect.gd") as GDScript).new()
	tab.size = Vector2(canvas)
	vp.add_child(tab)
	await process_frame
	var tag := "%dx%d" % [canvas.x, canvas.y]
	var ui: Dictionary = tab.get("_ui")
	var band: Control = ui["event_band"]
	var parts: Dictionary = band.get_meta("parts")
	var icon: TextureRect = tab.get("_band_icon")
	var next: TextureRect = tab.get("_band_next")
	var claim: Button = tab.get("_band_claim")
	if icon == null or next == null or claim == null:
		_expect(false, "%s: the band has no hourly disc, NEXT plate or CLAIM" % tag)
		vp.queue_free()
		return
	var name := parts["name"] as Label
	var worth := parts["worth"] as Label
	var more := parts["more"] as Label
	var time := parts["time"] as Label
	var title := ui["quests_title"] as Label
	var paint := func(live: Dictionary) -> void:
		gs.call("adopt", _snap(live))
		gs.set("_energy_at_ms", Time.get_ticks_msec())
		tab.call("paint_band")

	# Gold Rush running, a festival beside it.
	var fest := {"id": 1, "name": "Harvest Festival", "theme": "harvest", "bucket": "collect_income_bp", "bp": 2500,
		"effective_bp": 2500, "running": true, "starts_in": 0, "ends_in": 200000, "points": 5}
	paint.call({"hourly": _hour("boost", {"bucket": "collect_income_bp", "bp": 10000, "effective_bp": 10000}), "festival": fest})
	await process_frame
	_expect(band.visible and name.text == "GOLD RUSH" and worth.text == "+100% for you" and more.text == " · 1 more",
		"%s: Gold Rush reads %s / %s%s" % [tag, name.text, worth.text, more.text])
	_expect(time.visible and time.text == "14m 00s", "%s: its time reads %s" % [tag, time.text])
	_expect(icon.visible and icon.texture != null and icon.texture.resource_path.ends_with("hourly/gold_rush.png")
		and icon.modulate == Color.WHITE, "%s: the hour's disc is not drawn as painted" % tag)
	_expect(not next.visible and not claim.visible, "%s: a running event shows NEXT or CLAIM" % tag)
	var r := Rect2(icon.position, icon.size)
	_expect(r.end.x <= PLATE_FRAME_X - 4.0 and r.position.y >= 0.0 and r.end.y <= BAND.y and r.position.x >= 200.0,
		"%s: the disc (%s) is not on the scene, clear of the plate" % [tag, r])
	# Its rim, 137 of the 290 painted, is 110 across on the band.
	_expect(absf(icon.size.x * 137.3 / 290.0 * 2.0 - 110.0) < 1.5, "%s: the disc's rim is %.0f across, not 110" % [tag, icon.size.x * 137.3 / 290.0 * 2.0])

	# Each kind says what it does.
	paint.call({"hourly": _hour("refill_discount", {"id": "quartermasters_sale", "name": "Quartermaster's Sale",
		"icon": "hourly/quartermasters_sale", "bp": 5000})})
	# Too long for the plate in full capitals above 15: Cinzel's small capitals.
	_expect(name.text == "Quartermaster's Sale" and worth.text == "Refills -50%" and more.text == ""
		and (name.label_settings as LabelSettings).font_size >= 14,
		"%s: the sale reads %s at %d / %s" % [tag, name.text, (name.label_settings as LabelSettings).font_size, worth.text])
	_fits(parts, tag + " the longest name")
	paint.call({"hourly": _hour("free_reroll", {"id": "fresh_wares", "name": "Fresh Wares", "icon": "hourly/fresh_wares", "left": 1})})
	_expect(worth.text == "1 free restock", "%s: Fresh Wares reads %s" % [tag, worth.text])
	paint.call({"hourly": _hour("free_reroll", {"id": "fresh_wares", "name": "Fresh Wares", "icon": "hourly/fresh_wares", "left": 0})})
	_expect(worth.text == "Free restock taken", "%s: Fresh Wares taken reads %s" % [tag, worth.text])
	paint.call({"hourly": _hour("quest_multiplier", {"id": "busy_hands", "name": "Busy Hands", "icon": "hourly/busy_hands", "x": 2})})
	_expect(worth.text == "Quests count ×2" and title.text == "TODAY'S QUESTS  ×2",
		"%s: Busy Hands reads %s, the heading %s" % [tag, worth.text, title.text])

	# The courier's gift: CLAIM over the hourglass and the time plate, until taken.
	var gift := _hour("gift", {"id": "royal_courier", "name": "Royal Courier", "icon": "hourly/royal_courier", "left": 1,
		"lines": [{"kind": "token", "id": "cart", "amount": 1, "text": "Cart Writ", "icon": "cart"}]})
	paint.call({"hourly": gift})
	await process_frame
	_expect(worth.text == "Cart Writ for you" and claim.visible and not time.visible,
		"%s: the gift reads %s, CLAIM %s, the time %s" % [tag, worth.text, claim.visible, time.visible])
	# Over the time plate, the painted hourglass (x 575..595) left beside it, clear of the chevron (x 719).
	_expect(Rect2(claim.position, claim.size).encloses(Rect2(604, 84, 103, 31)) and claim.position.x >= 596.0
		and claim.position.x + claim.size.x < 717.0, "%s: CLAIM (%s) does not cover the time plate alone" % [tag, Rect2(claim.position, claim.size)])
	_expect(claim.text == "CLAIM" and claim.size.y >= 43.0, "%s: the CLAIM plate reads %s at %.0f tall" % [tag, claim.text, claim.size.y])
	gift["left"] = 0
	paint.call({"hourly": gift})
	_expect(worth.text == "Gift taken" and not claim.visible and time.visible, "%s: a taken gift still offers CLAIM" % tag)

	# Its minutes over: the festival running has the band, and the heading is plain again.
	paint.call({"hourly": _hour("quest_multiplier", {"active": false, "ends_in": 0, "x": 2}), "festival": fest})
	_expect(name.text == "HARVEST FESTIVAL" and worth.text == "+25% for you" and not icon.visible and title.text == "TODAY'S QUESTS",
		"%s: after the hour's minutes the band reads %s / %s, the heading %s" % [tag, name.text, worth.text, title.text])
	var moon := fest.duplicate()
	moon.merge({"name": "Blood Moon", "bucket": "reputation_bp", "bp": 5000, "effective_bp": 5000}, true)
	paint.call({"festival": moon})
	_expect(worth.text == "+50% renown", "%s: the Blood Moon reads %s" % [tag, worth.text])
	var caravan := fest.duplicate()
	caravan.merge({"name": "Merchant Caravan", "bucket": "shop_discount_bp", "bp": 1000, "effective_bp": 1500}, true)
	paint.call({"festival": caravan})
	_expect(worth.text == "15% off the market", "%s: the Caravan reads %s" % [tag, worth.text])

	# A quiet hour: the next hour's event, announced.
	var quiet := {"id": "", "active": false, "ends_in": 0, "next_in": 760, "left": 0,
		"next": {"id": "gold_rush", "name": "Gold Rush", "blurb": "Every job pays double gold.", "icon": "hourly/gold_rush"}}
	paint.call({"hourly": quiet})
	await process_frame
	_expect(band.visible and name.text == "GOLD RUSH" and worth.text == "Next hour" and time.text == "in 12m 40s",
		"%s: the next hour reads %s / %s / %s" % [tag, name.text, worth.text, time.text])
	_expect(icon.visible and icon.modulate != Color.WHITE and next.visible and not claim.visible,
		"%s: the next hour's disc is not quieter with NEXT on it" % tag)
	var nr := Rect2(next.position, next.size)
	_expect(nr.end.x <= PLATE_FRAME_X - 4.0 and nr.end.y <= BAND.y - 5.0 and nr.intersects(Rect2(icon.position, icon.size))
		and absf(nr.get_center().x - Rect2(icon.position, icon.size).get_center().x) < 1.0,
		"%s: NEXT (%s) is not on the disc's foot, inside the band" % [tag, nr])
	# A festival only announced, nothing else.
	var coming := fest.duplicate()
	coming.merge({"running": false, "starts_in": 190800, "ends_in": 450000}, true)
	paint.call({"hourly": {"id": "", "active": false, "next_in": 900, "next": null}, "festival": coming})
	_expect(band.visible and worth.text == "Coming soon" and time.text == "in 2d 05h" and not icon.visible and not next.visible,
		"%s: a festival announced reads %s / %s" % [tag, worth.text, time.text])
	# Nothing at all: no band.
	paint.call({"hourly": {"id": "", "active": false, "next_in": 900, "next": null}})
	_expect(not band.visible, "%s: a band shows with nothing to say" % tag)

	# Every hourly name fits its plate, in capitals at 15 or more where they
	# fit, else in small capitals at 14 or more.
	for n in NAMES + ["Harvest Festival", "Merchant Caravan"]:
		paint.call({"hourly": _hour("boost", {"name": n, "bucket": "xp_bp", "bp": 10000, "effective_bp": 10000})})
		_fits(parts, "%s %s" % [tag, n])
		var size := (name.label_settings as LabelSettings).font_size
		_expect((name.text == n.to_upper() and size >= 15) or (name.text == n and size >= 14),
			"%s: %s is set as %s at %d" % [tag, n, name.text, size])

	vp.queue_free()
	await process_frame


## Every word inside its box at its fitted size: nothing cut by an ellipsis.
func _fits(parts: Dictionary, tag: String) -> void:
	for id in ["name", "worth", "time"]:
		var l := parts[id] as Label
		var s := l.label_settings
		var w := s.font.get_string_size(l.text, HORIZONTAL_ALIGNMENT_LEFT, -1, s.font_size).x
		_expect(w <= float(l.get_meta("box_w", l.size.x)) + 0.5 and s.font_size >= 13,
			"%s: %s \"%s\" is %.0f wide at %d in a %.0f box" % [tag, id, l.text, w, s.font_size, float(l.get_meta("box_w", l.size.x))])
