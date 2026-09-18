extends SceneTree
## The Kingdom's painted pieces are each work's own and each rank's own.
##
## - Every Kingdom Work (balance/kingdoms.json) has its own scene, set by its id
##   on the Realm panel and on the Works page, in the works sheet's frame. There
##   were four pictures for eight works, handed out by position.
## - The reputation card lights the rank the kingdom holds with that rank's own
##   lit hexagon and gold word, and the other three unlit. The painting had
##   only RESPECTED lit and the rest were tinted to fake it.
## - Every crest on a rival card is one of the twelve painted crests.
##
## Run: godot --headless --path client --script tests/kingdom_art.gd

var _fails := 0
var _checked := 0


func _initialize() -> void:
	await process_frame
	var works := _balance_works()
	_expect(works.size() == 8, "the balance lists %d Kingdom Works, want 8" % works.size())
	var section: GDScript = load("res://scenes/kingdom/kingdom_section.gd")
	var scenes := {}
	for w in works:
		var art: String = section.work_art(str(w["id"]))
		_checked += 1
		_expect(ResourceLoader.exists("res://assets/%s.png" % art), "%s has no scene on disk (%s)" % [w["id"], art])
		_expect(not scenes.has(art), "%s shares its scene with %s" % [w["id"], scenes.get(art, "")])
		scenes[art] = w["id"]

	await _realm(works)
	await _works_page(works)
	_crests()

	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  %d kingdom pieces are each work's, rank's and crest's own" % _checked)
	quit()


## The Kingdom tab with a kingdom in it: four works on the Realm panel, and each
## reputation rank in turn.
func _realm(works: Array) -> void:
	var gs: Node = root.get_node("GameState")
	gs.set("snapshot", {"player": {"username": "Wwwwwwwwwwwwwwww", "level": 30, "gold": "1", "action_seq": 1,
		"kingdom_id": "k"}, "energy": {"current": 1, "max": 2}, "sections": []})
	var host := Control.new()
	host.size = Vector2(941, 1672)
	root.add_child(host)
	var tab: Control = (load("res://scenes/tabs/kingdom.gd") as GDScript).new()
	tab.size = host.size
	host.add_child(tab)
	for i in 3:
		await process_frame
	var ups: Array = []
	for w in works:
		ups.append({"id": w["id"], "name": w["name"], "bucket": w.get("bucket", ""), "level": 3,
			"effect_now": 600, "next_cost": 1000, "maxed": false})
	# The Realm panel shows the works in their order; rotate the list so a row
	# that painted by position would show the wrong scene.
	var shown := ups.slice(3) + ups.slice(0, 3)
	tab.set("_data", {"upgrades": shown, "members": []})
	tab.call("_paint_works")
	var rows: Array = tab.get("_works")
	for i in rows.size():
		if i >= shown.size():
			break
		var p: Dictionary = rows[i]["parts"]
		var want := "res://assets/kingdom/work_%s.png" % str(shown[i]["id"])
		var tex: Texture2D = (p["painting"] as TextureRect).texture
		_checked += 1
		_expect(tex != null and tex.resource_path == want, "Realm row %d draws %s, want %s" % [i, tex.resource_path if tex else "nothing", want])
		_expect(p.has("frame"), "Realm row %d has no frame round its scene" % i)

	# Each rank in turn: its own lit hexagon, the other three unlit.
	var ranks: Array = tab.get("RANKS")
	var hexes: Array = tab.get("_hexes")
	_expect(hexes.size() == 4, "%d rank hexagons on the card, want 4" % hexes.size())
	var rank_hex: Callable = Callable(tab, "rank_hex")
	for held in ranks.size():
		for i in hexes.size():
			tab.call("_light_rank", i, i == held)
		for i in hexes.size():
			var h: Dictionary = hexes[i]
			var tex: Texture2D = (h["hex"] as TextureRect).texture
			var want := "res://assets/%s.png" % str(rank_hex.call(i, i == held))
			_checked += 1
			_expect(tex != null and tex.resource_path == want, "with rank %d held, hexagon %d draws %s, want %s" % [held, i, tex.resource_path if tex else "nothing", want])
			_expect((h["hex"] as TextureRect).modulate == Color.WHITE, "hexagon %d is tinted" % i)
			var word: Label = h["word"]
			var gold: bool = word.label_settings.font_color == tab.get("WORD_LIT")
			_expect(gold == (i == held), "with rank %d held, word %d is %s" % [held, i, "gold" if gold else "grey"])
			_expect(word.text == str(ranks[i][0]), "word %d says %s" % [i, word.text])
	# The lit and unlit paintings really are different.
	for i in 4:
		var a: Texture2D = load("res://assets/%s.png" % str(rank_hex.call(i, false)))
		var b: Texture2D = load("res://assets/%s.png" % str(rank_hex.call(i, true)))
		_checked += 1
		_expect(a != null and b != null and a.get_image().get_data() != b.get_image().get_data(), "rank %d's lit and unlit hexagons are the same" % i)
	host.queue_free()
	await process_frame


## The Works page: every work, each its own scene, each in a frame.
func _works_page(works: Array) -> void:
	var ups: Array = []
	for w in works:
		ups.append({"id": w["id"], "name": w["name"], "bucket": w.get("bucket", ""), "level": 3,
			"effect_now": 600, "next_cost": 1000, "maxed": false})
	var sec: Control = (load("res://scenes/kingdom/kingdom_section.gd") as GDScript).new()
	sec.setup("works", {"upgrades": ups, "members": []}, {})
	var host := Control.new()
	host.size = Vector2(941, 1672)
	root.add_child(host)
	host.add_child(sec)
	for i in 3:
		await process_frame
	var drawn: Array = []
	var frames := 0
	var stack: Array = [sec]
	while not stack.is_empty():
		var n: Node = stack.pop_front()
		for c in n.get_children():
			stack.append(c)
		if n is TextureRect and (n as TextureRect).texture != null:
			var path := (n as TextureRect).texture.resource_path
			if path.contains("/kingdom/work_") and not path.contains("work_frame"):
				drawn.append(path.get_file().get_basename().trim_prefix("work_"))
		if n is NinePatchRect and (n as NinePatchRect).texture != null and (n as NinePatchRect).texture.resource_path.contains("work_frame"):
			frames += 1
	var want: Array = []
	for w in works:
		want.append(str(w["id"]))
	_checked += 1
	_expect(drawn == want, "the Works page draws %s, want %s" % [drawn, want])
	_expect(frames == works.size(), "the Works page frames %d scenes, want %d" % [frames, works.size()])
	host.queue_free()
	await process_frame


func _crests() -> void:
	var art: Node = root.get_node("Art")
	var names: Array = art.get("CRESTS")
	_expect(names.size() == 12, "the crests come to %d, want 12" % names.size())
	for n in names:
		_checked += 1
		_expect(ResourceLoader.exists("res://assets/%s.png" % n), "%s is not on disk" % n)
		var t: Texture2D = load("res://assets/%s.png" % n)
		if t != null:
			# Kept large and drawn down: twice the Attack card's 91x120 slot,
			# and above the 147 the hall draws an invitation's crest at.
			_expect(t.get_width() >= 182 and absf(t.get_width() / float(t.get_height()) - 91.0 / 120.0) < 0.01,
				"%s is %s, want 91:120 at 182 wide or more" % [n, t.get_size()])
			var img := t.get_image()
			var w := img.get_width()
			var h := img.get_height()
			_expect(img.get_pixel(2, 2).a < 0.05 and img.get_pixel(w / 2, h / 2).a > 0.95,
				"%s is not a shield on a clear ground" % n)
	var picked := {}
	for i in 60:
		picked[str(art.call("crest", "lord-%d" % i))] = true
	_expect(picked.size() >= 8, "sixty lords wore only %d different crests" % picked.size())
	# One rule for every crest a lord or kingdom has not chosen: the rival cards
	# (through Look.crest, which takes a worn crest first) and the hall both ask
	# Art, so the same id wears the same crest on both.
	var attack_src := FileAccess.get_file_as_string("res://scenes/tabs/attack.gd")
	var hall_src := FileAccess.get_file_as_string("res://scenes/kingdom/kingdom_hall.gd")
	var look_src := FileAccess.get_file_as_string("res://scripts/ui/look.gd")
	_expect(attack_src.contains("Look.crest(") and look_src.contains("Art.crest(") and hall_src.contains("Art.crest("),
		"the rival cards and the hall do not both take their crests from Art.crest")


func _balance_works() -> Array:
	var path := ProjectSettings.globalize_path("res://").path_join("../balance/kingdoms.json")
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return []
	var d: Variant = JSON.parse_string(f.get_as_text())
	return (d as Dictionary).get("upgrades", []) if d is Dictionary else []


func _expect(cond: bool, what: String) -> void:
	if not cond:
		_fails += 1
		print("  FAIL  " + what)
