extends SceneTree
## Every reward icon the server can send has its own picture.
##
## A reward line names its picture by a key (rewards.Line.Icon) and the client
## maps the key to a crop (Art.reward_icon); a key it does not know is drawn
## as the crown every reward used to wear. Titles (title:<id>) and name colours
## (name_color:<id>, with the colour on the line) came out as that crown. What
## must hold, for every key the server can emit -- the fixed ones in its code,
## every token, tier, painted item and cosmetic in the balance:
##  - none falls back to the crown;
##  - a title wears the crowned ribbon (rewards/title_scroll), which is never
##    drawn larger than it was cut in a reward's 46, 52 or 64-unit box;
##  - a name colour wears the enamel chip with its face in the line's colour.
##
## Run: godot --headless --path client --script tests/reward_icons_complete.gd

const CROWN := "res://assets/icons/reward_crown.png"
## Icon keys in the server's code that are not reward lines: the Diamond
## Goods' own pictures (service/store.go StoreGood.Icon), drawn by Goods.
const NOT_LINES := ["currency/bolt", "upgrades/bulwark"]
const BOXES := [46, 52, 64]

var _fails := 0
var _checked := 0


func _initialize() -> void:
	await process_frame
	var art: Node = root.get_node("Art")
	var keys := _server_keys()
	keys.append_array(_balance_keys())
	var seen := {}
	for k in keys:
		if seen.has(k) or k in NOT_LINES:
			continue
		seen[k] = true
		var t: Texture2D = art.call("reward_icon", k)
		_checked += 1
		if t == null or t.resource_path == CROWN:
			_fail("%s falls back to the crown" % k)
	# A title's picture reads at a reward's sizes without being drawn up.
	var title: Texture2D = art.call("reward_icon", "title:title_founder")
	if title != null and title.resource_path != CROWN:
		if not title.resource_path.ends_with("rewards/title_scroll.png"):
			_fail("a title wears %s, not the crowned ribbon" % title.resource_path)
		for box in BOXES:
			var k := minf(float(box) / title.get_width(), float(box) / title.get_height())
			if k > 1.0:
				_fail("the title ribbon is drawn up %.2fx in a %d box" % [k, box])
	# A name colour: the chip with its face in the line's colour.
	for c in ["#8FB8FF", "#6FD28A", "#E8C46A", "#F08A8E"]:
		var chip: Texture2D = art.call("reward_line_icon", {"icon": "name_color:x", "color": c})
		_checked += 1
		if chip == null or chip.resource_path == CROWN:
			_fail("the name colour %s falls back to the crown" % c)
			continue
		var img := chip.get_image()
		if img == null or img.get_size() != Vector2i(98, 110):
			_fail("the name colour %s is not the enamel chip (%s)" % [c, img.get_size() if img else "no image"])
			continue
		img.decompress()
		# The middle of the face, in the colour's own hue.
		var p := img.get_pixel(49, 55)
		var want := Color(c)
		var dist := absf(p.h - want.h)
		if minf(dist, 1.0 - dist) > 0.06 or p.s < 0.2:
			_fail("the chip for %s has its face in %s" % [c, p.to_html(false)])
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  %d reward icons the server can send each have their own picture" % _checked)
	quit()


func _fail(msg: String) -> void:
	_fails += 1
	print("  FAIL  " + msg)


## Every literal icon key in the server's reward code.
func _server_keys() -> Array:
	var out: Array = []
	var re := RegEx.new()
	re.compile("Icon: *\"([^\"]+)\"")
	# Outside the project, so by the file system's own path.
	var server := ProjectSettings.globalize_path("res://").path_join("../server/internal").simplify_path()
	var files := [server.path_join("game/rewards/rewards.go")]
	var dir := DirAccess.open(server.path_join("service"))
	if dir == null:
		_fail("could not read the server's service code at %s" % server)
		return out
	for f in dir.get_files():
		if f.ends_with(".go") and not f.ends_with("_test.go"):
			files.append(server.path_join("service").path_join(f))
	for f in files:
		var src := FileAccess.get_file_as_string(f)
		for m in re.search_all(src):
			out.append(m.get_string(1))
	# The boosts' keys are set as variables beside the literals above.
	out.append_array(["boost:collect", "boost:xp", "boost:luck"])
	# Wave 3's tokens (the Tax Cart, the calendar, the welcome-back letter), named
	# here too so a balance that has not been generated yet still holds them.
	out.append_array(["flask_small", "flask_large", "pardon", "cart"])
	if out.size() < 10:
		_fail("only %d icon keys found in the server's code" % out.size())
	return out


## Every key the balance makes: tokens, unrolled and rolled gear, cosmetics.
func _balance_keys() -> Array:
	var out: Array = []
	var rewards: Dictionary = _json("rewards.json")
	for t in rewards.get("tokens", []):
		out.append(str(t.get("icon", t.get("id", ""))))
	var tiers: Dictionary = _json("tiers.json")
	for t in tiers.get("tiers", []):
		out.append("item:" + str(t.get("id", "")))
	var items: Dictionary = _json("items.json")
	for d in items.get("definitions", []):
		if d is Dictionary and str(d.get("art", "")) != "":
			out.append("items/painted/" + str(d["art"]))
	var cos: Dictionary = _json("cosmetics.json")
	for c in cos.get("items", []):
		var art := str(c.get("art", ""))
		out.append(art if art != "" else "%s:%s" % [str(c.get("kind", "cosmetic")), str(c.get("id", ""))])
	if out.size() < 20:
		_fail("only %d icon keys found in the balance" % out.size())
	return out


func _json(name: String) -> Dictionary:
	var v: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://../balance/" + name))
	return v if v is Dictionary else {}
