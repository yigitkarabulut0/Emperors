extends SceneTree
## THE THRONE (scenes/court/throne_view.gd), Emperor of the Week.
##
## What must hold:
##  - it is a VIEW, not a page: throne.png bakes the shell's rail and its three
##    pills into the painting, and a page's backdrop would black out the real
##    ones. So it carries back_requested and a CourtBack plate;
##  - nobody reigning SAYS so, on the plate and on the kingdom's line, and the
##    kingdom's line counts to the next crowning instead;
##  - the emperor's face sits under the crowned ring, which is drawn over it;
##  - the three edicts are the painting's three, each with the server's figure
##    and minutes; the one chosen keeps its light and the others are drawn down;
##  - DECLARE is lit for the Crowned Emperor alone, and gone once a decree
##    stands;
##  - PAST REIGNS draws what there is and says so when there is none;
##  - nothing runs off the page, on either canvas, with or without the notch.
##
## Run: godot --headless --path client --script tests/throne_view.gd

const CANVASES := [Vector2(941, 1672), Vector2(941, 2040)]
const LONG := "Wwwwwwwwwwwwwwww"

var _fails := 0
var _checked := 0


func _initialize() -> void:
	await process_frame
	root.get_node("Env").set("api_base_url", "http://127.0.0.1:9")
	_is_a_view()
	for canvas in CANVASES:
		await _page(canvas, _empty(), "empty")
		await _page(canvas, _reigning(false), "reigning")
		await _page(canvas, _reigning(true), "declared")
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  %d checks: the throne in every state it can be in" % _checked)
	quit()


func _expect(ok: bool, what: String) -> void:
	_checked += 1
	if not ok:
		_fails += 1
		print("  FAIL  " + what)


## A view, hosted over a tab, and not a page over the whole screen.
func _is_a_view(_x: int = 0) -> void:
	var src := FileAccess.get_file_as_string("res://scenes/court/throne_view.gd")
	_expect(src.contains("signal back_requested"), "the throne has no back_requested: it is not a view")
	_expect(src.contains("CourtBack.build"), "the throne has no CourtBack plate")
	_expect(not src.contains("PaintedPage"), "the throne is built as a page; throne.png bakes the rail")
	var shell := FileAccess.get_file_as_string("res://scenes/shell/shell.gd")
	_expect(shell.contains('"throne": "res://scenes/court/throne_view.gd"'),
		"the shell does not host the throne")


func _decrees() -> Array:
	return [
		{"id": "hour_of_plenty", "name": "Hour of Plenty", "blurb": "b", "icon": "throne/decree_hour_of_plenty",
			"bucket": "collect_income_bp", "bp": 5000, "minutes": 60},
		{"id": "hour_of_learning", "name": "Hour of Learning", "blurb": "b", "icon": "throne/decree_hour_of_learning",
			"bucket": "xp_bp", "bp": 5000, "minutes": 60},
		{"id": "hour_of_fortune", "name": "Hour of Fortune", "blurb": "b", "icon": "throne/decree_hour_of_fortune",
			"bucket": "luck_bp", "bp": 3000, "minutes": 60}]


## The week's race, which the server has always sent and the screen drew nowhere
## until it was looked for: who is winning the crown, and where this lord stands.
func _race() -> Array:
	return [
		{"place": 1, "kingdom_id": "a", "kingdom_name": LONG, "kingdom_tag": "WWWW",
			"renown": 12480, "members": 12, "mine": false},
		{"place": 2, "kingdom_id": "b", "kingdom_name": "House Karabulut", "kingdom_tag": "KRB",
			"renown": 9020, "members": 6, "mine": true},
		{"place": 3, "kingdom_id": "c", "kingdom_name": "Wolves of the Fen", "kingdom_tag": "FEN",
			"renown": 880, "members": 5, "mine": false},
	]


func _empty() -> Dictionary:
	return {"reign": null, "crowns_in": 3600 * 59, "race": _race(), "my_place": 2, "my_renown": 9020,
		"can_declare": false, "decrees": _decrees(), "declared": "", "decree_ends_in": 0,
		"scope": "realm", "past": [],
		"rules": {"min_members": 3, "reign_days": 7, "measure": "week_gain", "scope": "realm"}}


func _reigning(declared: bool) -> Dictionary:
	var v := _empty()
	v["reign"] = {"week": 20700, "kingdom_id": "k", "kingdom_name": LONG, "kingdom_tag": "WWWW",
		"emperor_id": "e", "emperor_name": LONG, "avatar": "knight", "renown": 12480,
		"members": 12, "ends_in": 3600 * 76, "worn": {}, "vip_seal": true}
	v["can_declare"] = not declared
	if declared:
		v["declared"] = "hour_of_learning"
		v["decree_ends_in"] = 2520
	v["past"] = [{"week": 20693, "kingdom_name": "Lion Banner", "kingdom_tag": "LION",
		"emperor_name": "Lord Darius", "renown": 9000, "members": 8, "ends_in": 0}]
	return v


func _page(canvas: Vector2, data: Dictionary, state: String) -> void:
	var tag := "%s %dx%d" % [state, int(canvas.x), int(canvas.y)]
	var host := Control.new()
	host.size = canvas
	root.add_child(host)
	var v: Control = (load("res://scenes/court/throne_view.gd") as GDScript).new()
	v.set_anchors_preset(Control.PRESET_FULL_RECT)
	host.add_child(v)
	for i in 3:
		await process_frame
	v.call("paint", data)
	await process_frame
	var ui: Dictionary = v.get("_ui")

	var seated: bool = data["reign"] != null
	var name_l: Label = ui["emperor"]
	var kingdom_l: Label = ui["kingdom"]
	if seated:
		_expect(name_l.text != "" and not name_l.text.contains("EMPTY"),
			"%s: the emperor's plate reads %s" % [tag, name_l.text])
		_expect(kingdom_l.text.contains("left"), "%s: the kingdom's line reads %s" % [tag, kingdom_l.text])
	else:
		# The red plate is 225 units and painted for a NAME: "THE THRONE IS
		# EMPTY" only fits at the fitter's floor, where it reads as a caption
		# rather than a proclamation.
		_expect(name_l.text == "NO EMPEROR", "%s: an empty throne says %s" % [tag, name_l.text])
		# With no crown yet the plate says who is WINNING it, not only when it
		# is decided: the race is why a lord with no kingdom watches this screen.
		_expect(kingdom_l.text.contains("WWWW") and kingdom_l.text.contains("leads"),
			"%s: an empty throne's line does not name the leader: %s" % [tag, kingdom_l.text])
	_expect((ui["portrait"] as CanvasItem).visible == seated,
		"%s: the portrait is drawn when nobody sits" % tag)
	# The ring is drawn OVER the face.
	var face: Control = ui["portrait"]
	var ring: Control = ui["portrait_ring"]
	_expect(ring.get_index() > face.get_index(), "%s: the ring is drawn under the face" % tag)

	# The three edicts.
	var cards: Array = ui["card"]
	_expect(cards.size() == 3, "%s: %d edict cards" % [tag, cards.size()])
	var lit := 0
	for i in cards.size():
		var c: Dictionary = cards[i]
		_expect((c["parts"]["face"] as TextureRect).texture != null,
			"%s: edict %d has no picture -- its art key does not match the balance" % [tag, i])
		var plate: Label = c["parts"]["plate"]
		_expect(plate.text.contains("60m"), "%s: edict %d's plate reads %s" % [tag, i, plate.text])
		if (c["node"] as CanvasItem).modulate == Color.WHITE:
			lit += 1
	_expect(lit == 1, "%s: %d edicts are lit" % [tag, lit])

	# DECLARE.
	var declare_lit := (ui["declare"] as CanvasItem).modulate == Color.WHITE
	_expect(declare_lit == bool(data["can_declare"]),
		"%s: DECLARE is %s" % [tag, "lit" if declare_lit else "dim"])
	var timer: Label = ui["timer"]
	if str(data["declared"]) != "":
		_expect(timer.text.contains("Hour of Learning"), "%s: the timer reads %s" % [tag, timer.text])
	elif seated:
		_expect(timer.text == "No decree yet", "%s: the timer reads %s" % [tag, timer.text])
	else:
		# With no throne there can be no decree at all, so rather than a vacuous
		# "No decree yet" the box says where this lord's kingdom stands.
		_expect(timer.text.contains("2nd") and timer.text.contains("9,020"),
			"%s: an empty throne does not say where the lord stands: %s" % [tag, timer.text])

	# PAST REIGNS.
	var rows: Array = ui["reign"]
	var past: Array = data["past"]
	var first: Label = (rows[0] as Dictionary)["parts"]["words"]
	if past.is_empty():
		_expect(first.text.contains("No reign"), "%s: past reigns says %s" % [tag, first.text])
	else:
		_expect(first.text.contains("Lion Banner"), "%s: the first past reign reads %s" % [tag, first.text])

	# Nothing off the page.
	var stack: Array = [v]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for ch in n.get_children():
			stack.append(ch)
		if n is Control and (n as Control).is_visible_in_tree():
			var r: Rect2 = (n as Control).get_global_rect()
			if r.size.x > 0.0:
				_expect(r.position.x >= -1.0 and r.end.x <= canvas.x + 1.0,
					"%s: something runs off the side: %s" % [tag, r])
	v.queue_free()
	host.queue_free()
	await process_frame
