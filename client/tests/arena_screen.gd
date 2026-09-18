extends SceneTree
## THE HONOUR ARENA (scenes/attack/arena_view.gd) draws the server's ladder and
## works out none of it.
##
## What must hold:
##  - the league's arma is the key the server named, and it is drawn DOWN into
##    the painted crest's box, never up;
##  - the bar stands where the server's three numbers put it -- bar_from,
##    bar_to and rating -- and the client's one piece of arithmetic is
##    placement, not a threshold;
##  - the day's fights are pips, lit for those left and spent for those used;
##  - a rival's card shows BOTH what a win and a loss would move, as the server
##    resolved them, and neither is recomputed here;
##  - the four chests say the rating they open at, TAKEN once taken, and one
##    not reached is drawn down;
##  - a ladder too thin to fill the three painted cards says so in the card
##    every empty list uses, reaching the last card's floor, instead of leaving
##    card-shaped holes down to the chests;
##  - the longest name, a rating of 0 and a rating at the ceiling all fit;
##  - nothing runs off the page, on either canvas.
##
## Run: godot --headless --path client --script tests/arena_screen.gd

const CANVASES := [Vector2(941, 1672), Vector2(941, 2040)]
const LONG := "Wwwwwwwwwwwwwwww"

var _fails := 0
var _checked := 0
var LO: GDScript


func _initialize() -> void:
	await process_frame
	root.get_node("Env").set("api_base_url", "http://127.0.0.1:9")
	LO = load("res://scripts/ui/layout.gd")
	_bar_is_placement()
	for canvas in CANVASES:
		await _screen(canvas, _view())
		await _screen(canvas, _empty())
		await _screen(canvas, _thin())
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  %d checks: the lists draw the server's ladder and work out none of it" % _checked)
	quit()


func _expect(ok: bool, what: String) -> void:
	_checked += 1
	if not ok:
		_fails += 1
		print("  FAIL  " + what)


## The bar's fraction is placement between two numbers the server sent, and
## nothing else: a client that worked out its own league threshold would be the
## second implementation of the ladder.
func _bar_is_placement() -> void:
	var v: GDScript = load("res://scenes/attack/arena_view.gd")
	for c in [[1000, 1000, 1150, 0.0], [1075, 1000, 1150, 0.5], [1150, 1000, 1150, 1.0],
			[1900, 1800, 1800, 1.0]]:
		var got: float = v.call("bar_fraction", int(c[0]), int(c[1]), int(c[2]))
		_expect(absf(got - float(c[3])) < 0.01,
			"rating %d in %d..%d places the bar at %.2f, not %.2f" % [c[0], c[1], c[2], got, c[3]])
	var src := FileAccess.get_file_as_string("res://scenes/attack/arena_view.gd")
	for word in ["at_rating", "k_factor", "defender_k"]:
		_expect(not src.contains(word), "arena_view.gd reads %s: the ladder is the server's" % word)


## A number as the screens write it, so a check can look for it in a line.
func _grouped(n: int) -> String:
	var s := str(n)
	var out := ""
	for i in s.length():
		if i > 0 and (s.length() - i) % 3 == 0:
			out += ","
		out += s[i]
	return out


func _rival(name: String, rating: int, gain: int, loss: int) -> Dictionary:
	return {"player_id": "r" + name, "name": name, "avatar": "knight", "level": 31,
		"might": 2980, "rating": rating, "league": "gold", "rating_gain": gain,
		"rating_loss": loss, "is_bot": false, "worn": {}, "vip_seal": false}


func _view() -> Dictionary:
	var chests: Array = []
	var at := [1150, 1300, 1450, 1600]
	for i in 4:
		chests.append({"index": i, "rating": at[i], "reached": i < 2, "claimed": i == 0,
			"lines": ["10 diamonds"]})
	return {"unlocked": true, "unlock_level": 12, "season": 3, "season_ends_in": 3600 * 76,
		"rating": 1480, "peak": 1500, "place": 4, "wins": 12, "losses": 5, "streak": 3,
		"league": {"id": "platinum", "name": "Platinum", "emblem": "arena/league_platinum",
			"at_rating": 1450},
		"bar_from": 1450, "bar_to": 1600,
		"next": {"id": "sapphire", "name": "Sapphire", "emblem": "arena/league_sapphire", "at_rating": 1600},
		"tickets": 3, "tickets_total": 5, "ticket_tokens": 0, "refreshes": 2,
		"first_win": true, "first_win_lines": ["297 gold"],
		"rivals": [_rival(LONG, 1499, 16, -16), _rival("Aldric", 1420, 12, -20),
			_rival("Seraphine", 1550, 20, -12)],
		"chests": chests, "recent": [],
		"rules": {"tickets_per_day": 5, "refreshes_per_day": 3, "start_rating": 1000,
			"floor_rating": 800, "k_factor": 32, "defender_k_bp": 5000, "reset_bp": 5000,
			"leagues": []}}


## A lord with nothing: no rivals, no fights left, at the very bottom.
func _empty() -> Dictionary:
	var v := _view()
	v["rivals"] = []
	v["tickets"] = 0
	v["refreshes"] = 0
	v["rating"] = 0
	v["bar_from"] = 0
	v["bar_to"] = 1150
	v["first_win"] = false
	for c in v["chests"]:
		c["reached"] = false
		c["claimed"] = false
	return v


## A realm with one rival to offer: the common state on a small server, and the
## one the painted three cards cannot fill.
func _thin() -> Dictionary:
	var v := _view()
	v["rivals"] = [_rival("A Hired Champion", 1001, 8, -8)]
	return v


func _screen(canvas: Vector2, data: Dictionary) -> void:
	var n_rivals := (data["rivals"] as Array).size()
	var tag := "%dx%d%s" % [int(canvas.x), int(canvas.y),
		"" if n_rivals >= 3 else (" (empty)" if n_rivals == 0 else " (thin)")]
	var host := Control.new()
	host.size = canvas
	root.add_child(host)
	var v: Control = (load("res://scenes/attack/arena_view.gd") as GDScript).new()
	host.add_child(v)
	for i in 3:
		await process_frame
	v.call("paint", data)
	await process_frame

	var ui: Dictionary = v.get("_ui")
	# The arma is the server's key, drawn down into the painted crest's box.
	var emblem: TextureRect = ui["league_emblem"]
	_expect(emblem.texture != null, "%s: the league's arma is not drawn" % tag)
	if emblem.texture != null:
		_expect(emblem.texture.get_size().x >= emblem.size.x,
			"%s: the arma is drawn UP (%.0f into %.0f)" % [tag, emblem.texture.get_size().x, emblem.size.x])
	_expect((ui["league_name"] as Label).text == "PLATINUM",
		"%s: the league reads %s" % [tag, (ui["league_name"] as Label).text])

	# The bar, from the server's own three numbers.
	var want := float(int(data["rating"]) - int(data["bar_from"])) / float(maxi(1, int(data["bar_to"]) - int(data["bar_from"])))
	var fill: Control = ui["bar_fill"]
	var track: Control = ui["bar_track"]
	_expect(absf(fill.size.x - 198.0 * clampf(want, 0.0, 1.0)) <= 1.0,
		"%s: the bar is %.0f wide, not %.0f" % [tag, fill.size.x, 198.0 * want])
	_expect(fill.size.x <= track.size.x, "%s: the bar's fill runs past its channel" % tag)

	# The pips.
	var lit := 0
	for t in ui["ticket"]:
		if ((t as Dictionary)["parts"]["lit"] as CanvasItem).visible:
			lit += 1
	_expect(lit == int(data["tickets"]), "%s: %d pips are lit, not %d" % [tag, lit, data["tickets"]])

	# The rivals, with BOTH figures the server resolved.
	var rivals: Array = data["rivals"]
	var cards: Array = ui["rival"]
	for i in cards.size():
		var card: Dictionary = cards[i]
		_expect((card["node"] as CanvasItem).visible == (i < rivals.size()),
			"%s: rival card %d is drawn when it should not be" % [tag, i])
	if not rivals.is_empty():
		var first: Dictionary = cards[0]
		var name_l: Label = first["parts"]["name"]
		_expect(name_l.text != "", "%s: the first rival has no name" % tag)
		var might_l: Label = first["parts"]["might"]
		# Both figures are the server's own, read off the rival this case gave.
		_expect(might_l.text.contains(_grouped(int((rivals[0] as Dictionary)["might"])))
				and might_l.text.contains(_grouped(int((rivals[0] as Dictionary)["rating"]))),
			"%s: the rival's line reads %s" % [tag, might_l.text])

	# The chests.
	var chests: Array = data["chests"]
	for i in (ui["chest"] as Array).size():
		var c: Dictionary = (ui["chest"] as Array)[i]
		var plate: Label = c["parts"]["plate"]
		var want_words := "TAKEN" if bool((chests[i] as Dictionary).get("claimed", false)) \
			else str(int((chests[i] as Dictionary)["rating"])).pad_zeros(1)
		if want_words != "TAKEN":
			_expect(plate.text.replace(",", "") == want_words,
				"%s: chest %d says %s" % [tag, i, plate.text])
		else:
			_expect(plate.text == "TAKEN", "%s: a taken chest says %s" % [tag, plate.text])
		var dimmed := (c["node"] as CanvasItem).modulate != Color.WHITE
		_expect(dimmed == not bool((chests[i] as Dictionary)["reached"]),
			"%s: chest %d's dimming does not follow whether it was reached" % [tag, i])

	# A thin ladder says so, in the same card the Attack tab shows over an empty
	# list, and it reaches the last painted card's floor: two card-shaped holes
	# down to the chests read as a screen that failed to load.
	var thin: Dictionary = v.get("_thin")
	var thin_node: Control = thin.get("node") if not thin.is_empty() else null
	_expect(thin_node != null, "%s: the arena has no thin-ladder card" % tag)
	if thin_node != null:
		_expect(thin_node.visible == (rivals.size() < cards.size()),
			"%s: the thin-ladder card is %s with %d of %d rivals"
			% [tag, "shown" if thin_node.visible else "hidden", rivals.size(), cards.size()])
		if thin_node.visible:
			var first: Control = (cards[rivals.size()] as Dictionary)["node"]
			var last: Control = (cards[cards.size() - 1] as Dictionary)["node"]
			_expect(absf(thin_node.position.y - first.position.y) <= 1.0,
				"%s: the thin-ladder card starts at %.0f, not where the rivals ran out (%.0f)"
				% [tag, thin_node.position.y, first.position.y])
			_expect(absf(thin_node.position.y + thin_node.size.y - (last.position.y + last.size.y)) <= 1.0,
				"%s: the thin-ladder card stops at %.0f, not the last card's floor %.0f"
				% [tag, thin_node.position.y + thin_node.size.y, last.position.y + last.size.y])
			for k in ["title", "body"]:
				var l: Label = thin[k]
				_expect(l.text != "", "%s: the thin-ladder card's %s says nothing" % [tag, k])
				_expect(l.position.y >= 0.0 and l.position.y + l.size.y <= thin_node.size.y + 1.0,
					"%s: the thin-ladder card's %s falls outside it" % [tag, k])

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
