extends SceneTree
## THE KINGDOM'S BEAST (scenes/kingdom/boss_section.gd) and THE KINGDOM WAR
## (scenes/kingdom/war_section.gd).
##
## What must hold on the beast:
##  - the blows a lord still has stand first, in gold, and the spent ones after
##    them in steel -- the painting's own order, and the one a player reads as
##    "four left" rather than "four used";
##  - the bar is the SERVER'S basis points and nothing here divides anything;
##  - every one of the six beasts has a picture, and the panel's window is the
##    size every one of them was cut to;
##  - ATTACK takes a thumb's 95 units, and is dark when there is no blow left.
##
## And on the war:
##  - a lord's banners are the ones they still HOLD first, the fallen after;
##  - a routed lord is drawn back, stamped, and may still be ridden at: the
##    FIGHT plate stays lit, because beating them is worth a quarter and not
##    nothing;
##  - what a lord is worth is printed as the server sent it;
##  - no two rows' taps share a pixel, and a kingdom's name fits its plate;
##  - a lord with no kingdom is told so, not shown an empty banner.
##
## Run: godot --headless --path client --script tests/boss_and_war.gd

const CANVASES := [Vector2(941, 1672), Vector2(941, 2040)]
const THUMB := 95.0
## The six the balance rotates through.
const BEASTS := ["ashfall_wyrm", "garrow", "iron_colossus", "fen_witch", "ulgrim", "black_knight"]
## The panel's window, which every beast's picture is drawn down into.
const WINDOW := Vector2(728, 300)

## Every picture these two screens draw that a check below has to tell apart.
const _KEYS := ["boss/blow_on", "boss/blow_off", "boss/attack", "boss/hp_fill",
	"boss/name_plate", "boss/panel", "war/banner", "war/banner_lost", "war/fight",
	"war/panel", "war/row", "war/routed", "war/name_plate", "war/might_plate"]

var _fails := 0
var _checked := 0


func _initialize() -> void:
	await process_frame
	root.get_node("Env").set("api_base_url", "http://127.0.0.1:9")
	_no_arithmetic()
	_every_beast_is_painted()
	for canvas in CANVASES:
		await _boss(canvas)
		await _war(canvas)
	await _shut_doors()
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  %d checks: the beast and the war print the server's own numbers" % _checked)
	quit()


func _expect(ok: bool, what: String) -> void:
	_checked += 1
	if not ok:
		_fails += 1
		print("  FAIL  " + what)


## Neither screen works a number out. The health left, its fraction, what a blow
## costs, what a lord is worth and what the day allows are all the server's.
func _no_arithmetic() -> void:
	for f in ["res://scenes/kingdom/boss_section.gd", "res://scenes/kingdom/war_section.gd"]:
		var src := FileAccess.get_file_as_string(f)
		for word in ["hp_per_might", "valour_share", "win_base", "ratio_min", "rout_bp",
				"energy_base", "* 10000", "attacks_per_day -"]:
			_expect(not src.contains(word), "%s works out %s itself" % [f, word])
	# And the war attack must not move the sequence: nothing of the lord's own
	# moves in one (server/internal/service/war.go says which and why).
	var war := FileAccess.get_file_as_string("res://scenes/kingdom/war_section.gd")
	_expect(not war.contains("GameState.act("),
		"war_section.gd sends a war attack as a SEQUENCED action: nothing of the lord's own moves "
		+ "in one, so the number the queued collects are waiting on must not move either")
	var boss := FileAccess.get_file_as_string("res://scenes/kingdom/boss_section.gd")
	_expect(boss.contains("GameState.act(\"/v1/boss/hit\""),
		"boss_section.gd does not spend the blow through the sequenced action: it costs energy")


## Every beast in the rotation has a picture, and all six were cut to the one
## window the panel has.
func _every_beast_is_painted() -> void:
	var art: Node = root.get_node("Art")
	for id in BEASTS:
		var key: String = "boss/scene_" + str(id)
		_expect(art.call("has", key), "there is no picture of %s" % id)
		if not art.call("has", key):
			continue
		var tex: Texture2D = art.call("tex", key)
		_expect(tex != null and tex.get_size() == WINDOW,
			"%s is %s, and the panel's window is %s" % [id, tex.get_size() if tex else "nothing", WINDOW])


func _boss_view(hits: int, standing: bool = true) -> Dictionary:
	var rows: Array = []
	var names := ["wave7cap", "Aldric the Grey", "Seraphine", "Darian of the Marches", "Mira"]
	for i in names.size():
		rows.append({"place": i + 1, "player_id": "p%d" % i, "name": names[i], "avatar": "knight",
			"level": 30 - i, "hits": 6 - i, "damage": 5000 - i * 900,
			"share_bp": 1700 - i * 300, "mine": i == 0, "worn": {}, "vip_seal": false})
	return {"unlocked": true, "unlock_level": 10, "has_kingdom": true,
		"standing": standing, "rises_in": 0 if standing else 4000,
		"beast": {"id": "ashfall_wyrm", "name": "Ashfall Wyrm", "blurb": "A dragon.",
			"art": "boss/ashfall_wyrm", "level": 3, "hp_max": 28793, "hp_left": 12793,
			"hp_left_bp": 4443, "might": 12790, "kingdom_might": 14766, "members": 6,
			"ends_in": 172716, "killed": false, "fighters": 6, "damage_done": 16000},
		"mine": {"hits": hits, "hits_left": 6 - hits, "hits_total": 6, "damage": 5120,
			"place": 1, "energy": 22, "can_strike": standing and hits < 6, "valour_need": 1333},
		"damage": rows, "top_diamonds": [10, 6, 4], "top_title": "Slayer",
		"chests": [
			{"id": "struck", "name": "The Blooded", "need": "hit", "lines": ["1,200 gold"], "earned": true},
			{"id": "valour", "name": "The Valiant", "need": "valour", "lines": ["2,700 gold"], "earned": true},
			{"id": "slain", "name": "The Slayers", "need": "kill", "lines": ["5 diamonds"], "earned": false},
		],
		"rules": {"cycle_hours": 48, "hits_per_member": 6, "rounds_per_hit": 8, "valour_share_bp": 5000}}


func _boss(canvas: Vector2) -> void:
	var tag := "%dx%d" % [int(canvas.x), int(canvas.y)]
	var host := Control.new()
	host.size = canvas
	root.add_child(host)
	var s: Control = (load("res://scenes/kingdom/boss_section.gd") as GDScript).new()
	host.add_child(s)
	for i in 3:
		await process_frame
	s.call("paint", _boss_view(2))
	await process_frame

	var images: Array = []
	var taps: Array = []
	_walk(s, images, taps)

	# The blows: four gold then two steel, in that order.
	var blows: Array = []
	for im in images:
		var key := _key_of(im)
		if key == "boss/blow_on" or key == "boss/blow_off":
			blows.append([(im as Control).position.x, key])
	blows.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	_expect(blows.size() == 6, "%s: %d blows are drawn, not six" % [tag, blows.size()])
	var order := ""
	for b in blows:
		order += "G" if str((b as Array)[1]) == "boss/blow_on" else "s"
	_expect(order == "GGGGss",
		"%s: two blows of six are spent and the row reads %s, not GGGGss" % [tag, order])

	# ATTACK takes a thumb, and is lit while a blow is left.
	var attack: Control = _tap_over(taps, images, "boss/attack")
	_expect(attack != null, "%s: ATTACK has no tap at all" % tag)
	if attack != null:
		_expect(attack.size.x >= THUMB and attack.size.y >= THUMB,
			"%s: ATTACK takes a %.0fx%.0f tap" % [tag, attack.size.x, attack.size.y])
		_expect(not (attack as BaseButton).disabled, "%s: ATTACK is dark with four blows left" % tag)

	# The bar's fill is the server's fraction of the track, and nothing else.
	var fill: Control = _by_key(images, "boss/hp_fill")
	_expect(fill != null, "%s: the beast's bar has no fill" % tag)
	if fill != null:
		var want := 674.0 * 4443.0 / 10000.0
		_expect(absf(fill.size.x - want) < 2.0,
			"%s: the bar is %.0f wide and the server said %.0f" % [tag, fill.size.x, want])

	# Spent to the last blow: ATTACK goes dark rather than refusing on the tap.
	s.call("paint", _boss_view(6))
	await process_frame
	images.clear()
	taps.clear()
	_walk(s, images, taps)
	var spent: Control = _tap_over(taps, images, "boss/attack")
	_expect(spent != null and (spent as BaseButton).disabled,
		"%s: a lord with no blows left is still offered ATTACK" % tag)
	host.queue_free()
	await process_frame


func _war_view(routed_banners: int) -> Dictionary:
	var enemies: Array = []
	var names := ["Ulf Ironhand", "Greta of the Fen", "Halvard", "Eskil the Younger", "Ivar"]
	for i in names.size():
		var lost := 0 if i < 3 else routed_banners
		enemies.append({"player_id": "e%d" % i, "name": names[i], "avatar": "berserk",
			"level": 33 - i, "might": 3200 - i * 400, "points": 0,
			"banners_lost": lost, "banners": 3, "routed": lost >= 3,
			"met": 0, "worth": 10 - i * 2 if lost < 3 else 1, "mine": false,
			"worn": {}, "vip_seal": false})
	return {"unlocked": true, "unlock_level": 10, "has_kingdom": true, "bye": false,
		"draws_in": 112079,
		"war": {"id": "w1", "side": "a", "starts_in": 0, "ends_in": 158399, "live": true,
			"mine": {"kingdom_id": "k1", "name": "House Karabulut", "tag": "KRB",
				"points": 47, "might": 10836, "members": 6},
			"theirs": {"kingdom_id": "k2", "name": "Wolves of the Fen Vales",
				"tag": "FEN", "points": 14, "might": 7514, "members": 5},
			"settled": false, "won": false, "drawn": false},
		"enemies": enemies, "allies": [], "scorers": [],
		"log": [{"at": "2026-09-17T12:11:33Z", "attacker": "wave7cap", "defender": "Ulf Ironhand",
			"won": true, "points": 13, "routed": false, "ours": true}],
		"mine": {"attacks": 2, "attacks_left": 1, "per_day": 3, "resets_in": 40062,
			"banners_lost": 1, "banners": 3, "routed": false, "points": 24, "might": 3016},
		"rules": {"attacks_per_day": 3, "banners": 3, "rout_bp": 2500, "win_base": 10,
			"ratio_min_bp": 5000, "ratio_max_bp": 20000, "loss": 2, "held": 3,
			"top_members": 15, "max_ratio_bp": 15000, "min_members": 3, "days": 3,
			"shield_note": "A shield guards against raids, not against the Kingdom War."},
		"purse": {"won": {"lines": ["a purse"], "reputation": 400, "kingdom_xp": 250000},
			"lost": {"lines": ["a smaller purse"], "reputation": 100, "kingdom_xp": 80000}}}


func _war(canvas: Vector2) -> void:
	var tag := "%dx%d" % [int(canvas.x), int(canvas.y)]
	var host := Control.new()
	host.size = canvas
	root.add_child(host)
	var s: Control = (load("res://scenes/kingdom/war_section.gd") as GDScript).new()
	host.add_child(s)
	for i in 3:
		await process_frame
	s.call("paint", _war_view(3))
	await process_frame

	var images: Array = []
	var taps: Array = []
	var texts: Array = []
	_walk(s, images, taps, texts)

	# A routed lord's banners are all down, and a whole lord's are all up.
	var banners: Array = []
	for im in images:
		var key := _key_of(im)
		if key == "war/banner" or key == "war/banner_lost":
			banners.append([(im as Control).position.y, (im as Control).position.x, key])
	_expect(banners.size() == 15, "%s: %d banners over five lords" % [tag, banners.size()])
	var down := 0
	for b in banners:
		if str((b as Array)[2]) == "war/banner_lost":
			down += 1
	_expect(down == 6, "%s: %d banners are down; two lords lost three between them" % [tag, down])

	# The stamp does not bury what a lord compares. war.png's own routed row puts
	# ROUTED across the NAME plate -- which the artist could do, their mock plate
	# being empty -- and with a real name under it neither the name nor the Might
	# beside it could be read. It goes over the spent banners instead.
	for im in images:
		if _key_of(im) != "war/routed":
			continue
		var stamp := Rect2((im as Control).position, (im as Control).size)
		for key in ["war/name_plate", "war/might_plate"]:
			for other in images:
				if _key_of(other) != key:
					continue
				var plate := Rect2((other as Control).position, (other as Control).size)
				# Only the row the stamp is on.
				if absf(plate.get_center().y - stamp.get_center().y) > 40.0:
					continue
				_expect(not stamp.intersects(plate),
					"%s: ROUTED covers the %s a lord reads to choose a target" % [tag, key.get_file()])

	# Every FIGHT is still offered -- a routed lord may be ridden at for a
	# quarter -- and no two rows' taps share a pixel.
	var fights: Array = []
	for t in taps:
		if (t as Control).size.x > 100.0 and (t as Control).size.x < 200.0:
			fights.append(t)
	_expect(fights.size() == 5, "%s: %d FIGHT taps for five lords" % [tag, fights.size()])
	for f in fights:
		_expect(not (f as BaseButton).disabled, "%s: a lord may not be ridden at at all" % tag)
		_expect((f as Control).size.y >= 88.0,
			"%s: a FIGHT tap is %.0f tall, under the row the painting gave it" % [tag, (f as Control).size.y])
	for i in fights.size():
		for j in range(i + 1, fights.size()):
			var a := Rect2((fights[i] as Control).position, (fights[i] as Control).size)
			var b := Rect2((fights[j] as Control).position, (fights[j] as Control).size)
			_expect(not a.intersects(b), "%s: two rows' FIGHT taps share pixels" % tag)

	# The longest name a kingdom may be called still sits inside its plate --
	# on two lines if it must (app.kingdoms allows twenty-four letters).
	for l in texts:
		var label: Label = l
		if not label.text.begins_with("WOLVES OF THE FEN"):
			continue
		var box: float = float(label.get_meta("box_w", label.size.x))
		var m := label.label_settings.font.get_multiline_string_size(
			label.text, HORIZONTAL_ALIGNMENT_LEFT, box, label.label_settings.font_size)
		_expect(m.x <= box + 1.0 and m.y <= 38.0 + 1.0,
			"%s: %s is %.0fx%.0f on a %.0fx38 plate" % [tag, label.text, m.x, m.y, box])

	# What a lord is worth is the server's figure, printed.
	var joined := ""
	for l in texts:
		joined += (l as Label).text + " | "
	_expect(joined.contains("10 pts") and joined.contains("1 pts"),
		"%s: the worth the server sent is not on the rows: %s" % [tag, joined.substr(0, 200)])
	host.queue_free()
	await process_frame


## A lord with no kingdom is told what a kingdom is for, on both screens.
func _shut_doors() -> void:
	var host := Control.new()
	host.size = Vector2(941, 1672)
	root.add_child(host)
	for path in ["res://scenes/kingdom/boss_section.gd", "res://scenes/kingdom/war_section.gd"]:
		var s: Control = (load(path) as GDScript).new()
		host.add_child(s)
		for i in 3:
			await process_frame
		s.call("paint", {"unlocked": true, "unlock_level": 10, "has_kingdom": false,
			"chests": [], "damage": [], "enemies": [], "log": [], "mine": {}, "rules": {}})
		await process_frame
		var images: Array = []
		var taps: Array = []
		var texts: Array = []
		_walk(s, images, taps, texts)
		var joined := ""
		for l in texts:
			joined += (l as Label).text + " "
		_expect(joined.to_lower().contains("kingdom"),
			"%s says nothing to a lord with no kingdom: %s" % [path, joined.substr(0, 120)])
		s.queue_free()
		await process_frame
	host.queue_free()
	await process_frame


## The tap that stands over a painted plate.
func _tap_over(taps: Array, images: Array, key: String) -> Control:
	var plate: Control = _by_key(images, key)
	if plate == null:
		return null
	var box := Rect2(plate.position, plate.size)
	for t in taps:
		var r := Rect2((t as Control).position, (t as Control).size)
		if r.intersects(box):
			return t
	return null


func _by_key(images: Array, key: String) -> Control:
	for im in images:
		if _key_of(im) == key:
			return im
	return null


## Which asset a drawn node holds. Art caches one texture per key, so the
## picture a node was given IS the one the key names -- no second bookkeeping.
func _key_of(node: Control) -> String:
	var tex: Texture2D = node.get("texture")
	if tex == null:
		return ""
	for key in _KEYS:
		if root.get_node("Art").call("tex", key) == tex:
			return str(key)
	return ""


func _walk(n: Node, images: Array, taps: Array, texts: Array = []) -> void:
	for c in n.get_children():
		if c is TextureRect or c is NinePatchRect:
			images.append(c)
		if c is BaseButton:
			taps.append(c)
		if c is Label and (c as Label).text != "":
			texts.append(c)
		_walk(c, images, taps, texts)
