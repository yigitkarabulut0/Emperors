extends SceneTree
## Every card in the Family ledger wears its own scene.
##
## All the upgrade and holding cards used to wear the granary, then three scenes
## shared by group; the ledger read as one card repeated. What must hold now:
##  - every upgrade and holding in balance/estates.json has its own scene,
##    family/ledger_<id> (the Granary keeps the painting its card was cut with),
##    the Legacy wears its own (family/ledger_legacy, ledger_extra_sheet.png),
##    and no two of the ledger's cards share one. The Royal Treasury is no card
##    of the ledger: it is its own card under the storehouse
##    (tests/family_treasury_card.gd);
##  - every scene is exactly the card window's size, 364x216, and was cut at that
##    shape, drawn down and never stretched or drawn up;
##  - the card lays its window's own frame edge (the chamfered corner and rim the
##    Granary's painting keeps) over whatever scene it wears.
##
## Run: godot --headless --path client --script tests/ledger_scenes.gd

const WINDOW := Vector2(364, 216)
var _fails := 0
var _checked := 0


func _initialize() -> void:
	await process_frame
	var family: GDScript = load("res://scenes/tabs/family.gd")
	if not family.has_method("card_scene"):
		print("FAIL  the Family tab has no card_scene, so cards cannot wear their own scenes")
		quit(1)
		return
	var f := FileAccess.open("res://../balance/estates.json", FileAccess.READ)
	var d: Dictionary = JSON.parse_string(f.get_as_text()) if f != null else {}
	var cards := []
	for u in d.get("upgrades", []):
		cards.append(["upgrade", u])
	for h in d.get("holdings", []):
		cards.append(["holding", h])
	cards.append(["legacy", {}])
	if cards.size() < 4:
		_fail("could not read balance/estates.json")
	var seen := {}
	for c in cards:
		var who: String = str(c[1].get("id", c[0]))
		var art: String = family.card_scene(c[0], c[1])
		_checked += 1
		if seen.has(art):
			_fail("%s and %s share %s" % [seen[art], who, art])
		seen[art] = who
		if c[0] in ["upgrade", "holding"] and who != "granary" and art != "family/ledger_%s" % who:
			_fail("%s wears %s, not its own scene" % [who, art])
		if c[0] == "legacy" and art != "family/ledger_legacy":
			_fail("the Legacy wears %s, not its gallery of ancestors (family/ledger_legacy)" % art)
		var path := "res://assets/%s.png" % art
		if not ResourceLoader.exists(path):
			_fail("%s's scene %s is not on disk" % [who, art])
			continue
		var tex := load(path) as Texture2D
		if tex.get_size() != WINDOW:
			_fail("%s is %s, drawn in a %s window" % [art, tex.get_size(), WINDOW])
	_check_cuts()
	_check_window()
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  all %d ledger cards wear their own scene, cut at the window's shape" % cards.size())
	quit()


func _fail(msg: String) -> void:
	_fails += 1
	print("  FAIL  " + msg)


## Every scene wears the card window's own edge: the frame's chamfered corner
## and its two or three units of rim, laid over the scene. A scene cut square
## covered the corner the Granary's painting keeps.
func _check_window() -> void:
	var L: GDScript = load("res://scripts/ui/layout.gd")
	var card: Dictionary = L.find("family", "upgrade_card")
	var order := []
	var art_rect := Rect2()
	var frame_rect := Rect2()
	for q in card.get("parts", []):
		order.append(str(q.get("id", "")))
		if str(q.get("id", "")) == "art":
			art_rect = L.rect_of(q)
		if str(q.get("id", "")) == "art_frame":
			frame_rect = L.rect_of(q)
	_checked += 1
	if not ("art_frame" in order and order.find("art") < order.find("art_frame")):
		_fail("the card does not lay the window's frame over its scene: %s" % str(order))
		return
	if frame_rect != art_rect:
		_fail("the window's frame is at %s, the scene at %s" % [frame_rect, art_rect])
	var img := Image.load_from_file("res://assets/family/art_frame.png")
	if img == null:
		_fail("family/art_frame is missing")
		return
	img.convert(Image.FORMAT_RGBA8)
	# Solid: the chamfered corner and the rim; clear: the scene.
	for p in [Vector2i(0, 0), Vector2i(4, 4), Vector2i(1, 100), Vector2i(100, 0), Vector2i(362, 100)]:
		if img.get_pixelv(p).a < 0.98:
			_fail("the window's frame is see-through at %s, where the frame is" % p)
	for p in [Vector2i(20, 20), Vector2i(182, 108), Vector2i(100, 215), Vector2i(359, 214)]:
		if img.get_pixelv(p).a > 0.02:
			_fail("the window's frame covers the scene at %s" % p)


func _check_cuts() -> void:
	var found := 0
	for m in ["ledger_upgrades", "ledger_holdings", "ledger_extra"]:
		var f := FileAccess.open("res://../art/slices/%s.json" % m, FileAccess.READ)
		if f == null:
			_fail("art/slices/%s.json is missing" % m)
			continue
		for c in JSON.parse_string(f.get_as_text()).get("crops", []):
			found += 1
			var r: Array = c["rect"]
			var s: Array = c.get("scale", [r[2], r[3]])
			var stretch := absf((float(r[2]) / float(r[3])) / (float(s[0]) / float(s[1])) - 1.0)
			_checked += 1
			if stretch > 0.01:
				_fail("%s is cut %dx%d and drawn %dx%d: stretched %.1f%%" % [c["name"], r[2], r[3], s[0], s[1], stretch * 100.0])
			if float(s[0]) > float(r[2]) + 0.5:
				_fail("%s is drawn larger than it was painted" % c["name"])
	if found != 20:
		_fail("%d ledger scenes are cut, want 20 (10 upgrades, 8 holdings, the treasury and the legacy)" % found)
