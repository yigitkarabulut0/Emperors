extends SceneTree
## The battle wears the painted effects of art/reference/battle_fx.png.
##
## A result was a word in type -- "VICTORY", "DEFEAT", "HELD", "RAIDED" -- and
## a round a line of type; the flash of a blow and a critical were the same
## generated burst. What must hold now:
##  - every piece is on disk with real alpha (a square of navy over a face is
##    the failure this guards);
##  - the result is the painted VICTORY or DEFEAT banner, never a word, for the
##    raider and for the defender alike, and a defence says what happened;
##  - the round number is set in the battle painting's own ROUND window;
##  - each side's Fortune of War roll has its painted die beside it, and they
##    stay up once the fight is told (they are part of the painted plate);
##  - the banner lands over the battlefield, clear of the frames and plates;
##  - the light effects (burst, arc, whoosh) are drawn additively at their own
##    proportions, and a critical is the painted explosion, laid over.
##
## Run: godot --headless --path client --script tests/battle_fx.gd

const PIECES := ["impact", "slash", "crit", "dodge", "shield_spark", "victory", "defeat",
	"die_a", "die_b"]
## The battle painting's own ROUND window, and the zone over its battlefield the
## banner lands in (client/layout/battle.json).
const ROUND_WINDOW := Rect2(418, 76, 106, 57)
const BANNER_ZONE := Rect2(100, 150, 741, 240)
var _fails := 0
var _checked := 0


func _initialize() -> void:
	await process_frame
	var art: Node = root.get_node("Art")
	for p in PIECES:
		_pieces_have_alpha(art, "battle/" + p)
	await _result("the raider's win", {"won": true, "gold_stolen": "412000", "xp_gained": 640}, "battle/victory", "")
	await _result("the raider's loss", {"won": false, "ransom_paid": "300", "xp_gained": 12}, "battle/defeat", "")
	await _result("a defence that held", {"won": true, "perspective": "defender", "gold": "900"},
		"battle/victory", "Your defence held")
	await _result("a defence that fell", {"won": false, "perspective": "defender", "gold": "-4000"},
		"battle/defeat", "Your city was raided")
	await _effects()
	if _checked == 0:
		print("FAIL  nothing was measured")
		quit(1)
		return
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  %d checks: the battle wears the painted effects, plate, dice and banners" % _checked)
	quit()


func _fail(msg: String) -> void:
	_fails += 1
	print("  FAIL  " + msg)


func _pieces_have_alpha(art: Node, name: String) -> void:
	_checked += 1
	if not bool(art.call("has", name)):
		_fail("%s is not on disk" % name)
		return
	var img: Image = (art.call("tex", name) as Texture2D).get_image()
	if img.is_compressed():
		img.decompress()
	if img.detect_alpha() == Image.ALPHA_NONE:
		_fail("%s has no alpha: it would lay a square over the fight" % name)
		return
	for c in [Vector2i(0, 0), Vector2i(img.get_width() - 1, 0), Vector2i(0, img.get_height() - 1),
			Vector2i(img.get_width() - 1, img.get_height() - 1)]:
		if img.get_pixelv(c).a > 0.1:
			_fail("%s is opaque at its corner %s: the painting's ground came with it" % [name, str(c)])
			return


func _replay(winner: String) -> Dictionary:
	var events: Array = [{"r": 1, "k": "round"},
		{"r": 1, "k": "hit", "s": "a", "src": "A", "dst": "D", "dmg": 1200, "crit": true},
		{"r": 1, "k": "hp", "s": "d", "dst": "D", "hp": 6800},
		{"r": 1, "k": "dodge", "s": "d", "src": "D", "dst": "A"},
		{"r": 2, "k": "round"},
		{"r": 2, "k": "hit", "s": "a", "src": "A", "dst": "D", "dmg": 7000, "crit": false},
		{"r": 2, "k": "hp", "s": "d", "dst": "D", "hp": 0},
		{"r": 2, "k": "death", "s": "d", "dst": "D"}]
	return {"v": 2, "rounds": 2, "winner": winner, "fortune_a_bp": 10400, "fortune_d_bp": 9700,
		"attacker_might": 3350, "defender_might": 3120,
		"attacker": {"player_id": "A", "name": "Yigit", "units": [{"id": "A", "hp": 9000, "weapon": "weapon_05"}]},
		"defender": {"player_id": "D", "name": "Lord Darius", "units": [{"id": "D", "hp": 8000, "weapon": "weapon_02"}]},
		"events": events}


func _build(result: Dictionary) -> CanvasLayer:
	var host := Control.new()
	host.size = Vector2(941, 1672)
	root.add_child(host)
	var screen: CanvasLayer = load("res://scenes/battle/battle_replay.gd").new()
	screen.setup(result)
	host.add_child(screen)
	return screen


func _result(tag: String, result: Dictionary, banner: String, line: String) -> void:
	var r := result.duplicate()
	var you_won := bool(r["won"])
	var defender := str(r.get("perspective", "")) == "defender"
	r["replay"] = _replay("a" if you_won != defender else "d")
	var screen := _build(r)
	screen.set("_skip", true)
	var waited := 0
	while not bool(screen.get("_done")) and waited < 200:
		await process_frame
		waited += 1
	_checked += 1
	if not bool(screen.get("_done")):
		_fail("%s: the battle never finished" % tag)
		return
	var found: TextureRect = null
	var words: Array[String] = []
	var lines: Array[String] = []
	var stack: Array = [screen]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		if n is TextureRect and n.name == "Banner":
			found = n
		if n is Label:
			var t := (n as Label).text
			lines.append(t)
			if t.to_upper() in ["VICTORY", "DEFEAT", "HELD", "RAIDED"]:
				words.append(t)
	if found == null:
		_fail("%s: no painted banner" % tag)
	elif str(found.get_meta("asset", "")) != banner:
		_fail("%s: the banner is %s, want %s" % [tag, str(found.get_meta("asset", "")), banner])
	if not words.is_empty():
		_fail("%s: the result is still set in type: %s" % [tag, str(words)])
	if line != "" and not lines.has(line):
		_fail("%s: it does not say \"%s\"" % [tag, line])

	# The round: the number in the painted ROUND plate's own window.
	var label: Label = screen.get("_round_label")
	_checked += 1
	if label == null:
		_fail("%s: no round number" % tag)
	elif not label.text.is_valid_int() or not ROUND_WINDOW.grow(0.5).encloses(Rect2(label.global_position, label.size)):
		_fail("%s: the round number \"%s\" at %s is not in the painted window %s" % [
			tag, label.text, str(Rect2(label.global_position, label.size)), str(ROUND_WINDOW)])
	# The dice: one beside each side's roll, and still up once the fight is told.
	var fortune: Array = screen.get("_fortune")
	_checked += 1
	var dice := 0
	for n in fortune:
		if n is TextureRect and (n as TextureRect).texture.resource_path.get_file().begins_with("die_"):
			dice += 1
		if not (n as Control).visible:
			_fail("%s: a Fortune of War roll or die went away with the fight" % tag)
	if dice != 2:
		_fail("%s: Fortune of War has %d dice, want 2" % [tag, dice])
	# The banner: over the battlefield, where the fight was.
	_checked += 1
	if found != null and not BANNER_ZONE.grow(0.5).encloses(Rect2(found.global_position, found.size)):
		_fail("%s: the banner %s is not over the battlefield %s" % [tag, str(Rect2(found.global_position, found.size)), str(BANNER_ZONE)])
	screen.get_parent().queue_free()
	await process_frame


## Each effect spawns from its own painting, at its own proportions, and the
## light ones add rather than cover.
func _effects() -> void:
	var screen := _build({"won": true, "replay": _replay("a")})
	screen.set("_skip", true)
	for i in 3:
		await process_frame
	var floaters: Control = screen.get("_floaters")
	var cases := [["_burst_at", ["d", false], "impact", true], ["_burst_at", ["d", true], "crit", false],
		["_slash_at", ["d", 1.0, false], "slash", true], ["_whoosh_at", ["d", 1.0], "dodge", true],
		["_shield_spark_at", ["a"], "shield_spark", false]]
	for c in cases:
		var before := floaters.get_child_count()
		screen.callv(str(c[0]), c[1])
		_checked += 1
		if floaters.get_child_count() <= before:
			_fail("%s drew nothing" % c[0])
			continue
		var img := floaters.get_child(floaters.get_child_count() - 1) as TextureRect
		if img == null or not img.texture.resource_path.ends_with("/%s.png" % c[2]):
			_fail("%s did not draw battle/%s" % [c[0], c[2]])
			continue
		var want := float(img.texture.get_width()) / float(img.texture.get_height())
		var got := img.size.x / img.size.y
		if absf(want - got) > 0.02:
			_fail("battle/%s is drawn at %.2f:1, its painting is %.2f:1" % [c[2], got, want])
		var mat := img.material as CanvasItemMaterial
		var adds := mat != null and mat.blend_mode == CanvasItemMaterial.BLEND_MODE_ADD
		if adds != bool(c[3]):
			_fail("battle/%s is %s, want %s" % [c[2], "added" if adds else "laid over", "added" if c[3] else "laid over"])
	screen.get_parent().queue_free()
	await process_frame
