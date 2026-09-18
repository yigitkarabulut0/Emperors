extends SceneTree
## The season's nobility wear their own frames (art/reference/frames_noble.png,
## cut by art/slices/frames_noble.json): Knight, Baron, Count, Duke, Prince and
## Emperor, each a square, a ring, the wardrobe's tile and the podium's large
## ring, cut as every other frame is.
##
## Before this sheet was cut the catalogue named frames/noble_<id> and nothing
## drew them: a noble's frame came out as no frame at all, on the podium, in the
## rows, in the wardrobe and on the profile.
##
## What must hold, for every noble frame the catalogue names:
##  - the four crops exist: frames/noble_<id>_square, _ring, _tile and
##    looks/noble_<id>_ring_large;
##  - each is centred on its own window (a portrait drawn at the crop's centre
##    sits in the frame's opening);
##  - the rings' windows are the other rings' size (oak's, charter's: 70-74
##    across), so a noble ring covers a portrait's frame as any ring does, and
##    the large rings are the same crop larger;
##  - the tile fits the wardrobe's 224x190 art box;
##  - Look picks them for a lord who wears one, the large ring past the small
##    ring's band as for every other frame.
##
## Run: godot --headless --path client --script tests/frames_noble.gd

const IDS := ["knight", "baron", "count", "duke", "prince", "emperor"]

var _fails := 0
var _checked := 0


func _initialize() -> void:
	await process_frame
	var art: Node = root.get_node("Art")
	var cos: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://../balance/cosmetics.json"))
	var named := []
	for c in cos.get("items", []):
		if str(c.get("art", "")).begins_with("frames/noble_"):
			named.append(str(c.get("art", "")).get_file().trim_prefix("noble_"))
	_expect(named.size() == IDS.size(), "the catalogue names %d noble frames: %s" % [named.size(), named])
	var oak_ring := _window(art.call("tex", "frames/oak_ring"))
	for id in named:
		var keys := {"square": "frames/noble_%s_square" % id, "ring": "frames/noble_%s_ring" % id,
			"tile": "frames/noble_%s_tile" % id, "large": "looks/noble_%s_ring_large" % id}
		for kind in keys:
			var key: String = keys[kind]
			_checked += 1
			if not bool(art.call("has", key)):
				_expect(false, "%s is not cut" % key)
				continue
			var tex: Texture2D = art.call("tex", key)
			var win := _window(tex)
			var size := tex.get_size()
			var off: Vector2 = win["centre"] - size / 2.0
			# A crown or an eagle hanging into a square's window moves the
			# opening's centroid down a little; the crop is centred on the frame.
			_expect(absf(off.x) <= 2.0 and absf(off.y) <= 3.5, "%s: its window is %s off the crop's centre" % [key, off])
			match kind:
				"ring":
					_expect(absf(float(win["w"]) - float(oak_ring["w"])) <= 6.0,
						"%s: its window is %d across, the other rings' %d" % [key, int(win["w"]), int(oak_ring["w"])])
				"large":
					var small := _window(art.call("tex", keys["ring"]))
					var k := float(win["w"]) / float(small["w"])
					_expect(k > 1.25 and k < 1.5, "%s: %.2f times the small ring, want 132/96" % [key, k])
				"tile":
					_expect(size.x <= 224.0 and size.y <= 190.0, "%s is %s, over the wardrobe's 224x190" % [key, size])
				"square":
					_expect(float(win["w"]) >= 110.0 and float(win["w"]) <= 135.0,
						"%s: its window is %d across, the square frames' 116-131" % [key, int(win["w"])])
	# Look draws them for a lord who wears one.
	var look: GDScript = load("res://scripts/ui/look.gd")
	var duke := {"worn": {"frame": "frames/noble_duke", "title": "Duke"}}
	_expect(str(look.call("frame_art", duke, "ring", 79.0)) == "frames/noble_duke_ring", "a row's ring is not the Duke's")
	_expect(str(look.call("frame_art", duke, "ring", 132.0)) == "looks/noble_duke_ring_large", "the podium's ring is not the Duke's large one")
	_expect(str(look.call("frame_art", duke, "square", 160.0)) == "frames/noble_duke_square", "a square portrait's frame is not the Duke's")
	_expect(str(look.call("title", duke)) == "Duke", "the Duke's title does not read Duke")
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  %d checks: the six noble frames are cut as every frame is, and worn" % _checked)
	quit()


## A crop's window: the clear opening its frame encloses -- the pixels flooded
## from the crop's centre across what is clear -- its width, and its centroid.
func _window(t: Texture2D) -> Dictionary:
	if t == null:
		return {"w": 0, "centre": Vector2.ZERO}
	var img := t.get_image()
	if img.is_compressed():
		img.decompress()
	var w := img.get_width()
	var h := img.get_height()
	var seen := {}
	var stack: Array = [Vector2i(w / 2, h / 2)]
	var sum := Vector2.ZERO
	var n := 0
	var x0 := w
	var x1 := 0
	while not stack.is_empty():
		var p: Vector2i = stack.pop_back()
		if p.x < 0 or p.y < 0 or p.x >= w or p.y >= h or seen.has(p):
			continue
		seen[p] = true
		if img.get_pixelv(p).a >= 0.5:
			continue
		sum += Vector2(p)
		n += 1
		x0 = mini(x0, p.x)
		x1 = maxi(x1, p.x)
		for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			stack.append(p + d)
	return {"w": x1 - x0 + 1 if n > 0 else 0, "centre": sum / float(maxi(n, 1)) + Vector2(0.5, 0.5)}


func _expect(cond: bool, what: String) -> void:
	if not cond:
		_fails += 1
		print("  FAIL  " + what)
