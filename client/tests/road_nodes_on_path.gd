extends SceneTree
## The Victory Road's fifteen milestones stand on the painted road.
##
## The maps were asked for without markers so the game could place its own
## (PAINTING_BRIEFS_2, correction 5): layout/road.json keeps each milestone's
## place, measured off the maps as they are stacked in the page's scroll. This
## holds those places to the paintings themselves:
##  - under every milestone's disc is the painted road -- its dirt, not the
##    grass, the trees or the river beside it;
##  - each place lies on the measured centreline (`centre`), and the
##    milestones climb the road in order, foot to castle, far enough apart that
##    no two shields meet;
##  - no shield stands on the mountain gate or on either bridge;
##  - each milestone's reward box, on the side the layout names, lies mostly off
##    the road: the side the road bends away from.
## The maps are read from the cut assets, stacked as the scroll stacks them
## (each over the one under it, its faded foot over the other's head).
##
## Run: godot --headless --path client --script tests/road_nodes_on_path.gd

const DISC_R := 48.0
const BOX := Vector2(152, 96)       ## a two-reward box
const BOX_OFF := 62.0               ## the shield's half-width and the gap

var _fails := 0
var _checked := 0


func _initialize() -> void:
	await process_frame
	var layout: GDScript = load("res://scripts/ui/layout.gd")
	var spec: Dictionary = layout.call("find", "road", "road")
	var nodes: Array = spec.get("nodes", [])
	var centre: Array = spec.get("centre", [])
	var marks: Dictionary = spec.get("landmarks", {})
	var h := int(spec.get("height", 0))
	_expect(nodes.size() == 15, "the layout places %d milestones, not 15" % nodes.size())
	_expect(h == 2970, "the stacked road is %d tall, not 2970" % h)
	var stack := _stack(spec, h)
	if stack == null:
		print("FAIL  the road maps could not be read")
		quit(1)
		return
	var prev_y := INF
	for i in nodes.size():
		var n: Array = nodes[i]
		var at := Vector2(float(n[0]), float(n[1]))
		# Dirt under the disc.
		var road := _road_share(stack, Rect2(at - Vector2(5, 5), Vector2(11, 11)))
		_expect(road >= 0.5, "milestone %d at %s stands on %.0f%% road" % [i, at, road * 100.0])
		# On the measured centreline.
		var cx := _centre_x(centre, at.y)
		_expect(absf(cx - at.x) <= 12.0, "milestone %d at %s is %.0f off the road's centre (x %.0f)" % [i, at, absf(cx - at.x), cx])
		# In order up the road, apart.
		_expect(at.y < prev_y - 110.0, "milestone %d at y %.0f is not above the one before it (y %.0f)" % [i, at.y, prev_y])
		prev_y = at.y
		# Off the landmarks.
		for k in marks:
			var r: Array = marks[k]
			var lr := Rect2(float(r[0]), float(r[1]), float(r[2]), float(r[3]))
			_expect(not _circle_hits(at, DISC_R, lr) and not lr.intersects(Rect2(at + Vector2(-47, 44), Vector2(94, 34))),
				"milestone %d at %s stands on the %s %s" % [i, at, k, lr])
		# Its box mostly off the road.
		var side := str(n[2])
		var bx := at.x + BOX_OFF if side == "right" else at.x - BOX_OFF - BOX.x
		var box := Rect2(Vector2(clampf(bx, 6.0, 770.0 - BOX.x), at.y + 10.0 - BOX.y / 2.0), BOX)
		var under := _road_share(stack, box)
		_expect(under <= 0.25, "milestone %d's box on its %s covers %.0f%% road" % [i, side, under * 100.0])
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  %d checks: every milestone stands on the painted road, in order, clear of the gate and the bridges" % _checked)
	quit()


func _expect(ok: bool, msg: String) -> void:
	_checked += 1
	if not ok:
		_fails += 1
		print("  FAIL  " + msg)


## The three maps as the scroll lays them: its content's parts, in order, each
## blended over what is under it.
func _stack(spec: Dictionary, h: int) -> Image:
	var out := Image.create(776, h, false, Image.FORMAT_RGBA8)
	for part in spec.get("content", []):
		var img := Image.load_from_file(ProjectSettings.globalize_path("res://assets/%s.png" % str(part["asset"])))
		if img == null or img.is_empty():
			return null
		img.convert(Image.FORMAT_RGBA8)
		var r: Array = part["rect"]
		out.blend_rect(img, Rect2i(0, 0, img.get_width(), img.get_height()), Vector2i(int(r[0]), int(r[1])))
	return out


## How much of `rect` is the painted road's dirt: warm, light, more red than
## green and much more than blue (the grass is green, the rocks grey, the river
## blue, the trees dark).
func _road_share(img: Image, rect: Rect2) -> float:
	var n := 0
	var hit := 0
	for y in range(int(rect.position.y), int(rect.end.y)):
		for x in range(int(rect.position.x), int(rect.end.x)):
			if x < 0 or y < 0 or x >= img.get_width() or y >= img.get_height():
				continue
			var c := img.get_pixel(x, y)
			var r := c.r8
			var g := c.g8
			var b := c.b8
			n += 1
			if r > 175 and g > 135 and b > 70 and r - b > 45 and r >= g and g - b > 20 and (r + g + b) / 3 > 150:
				hit += 1
	return float(hit) / float(maxi(1, n))


func _centre_x(centre: Array, y: float) -> float:
	for i in range(1, centre.size()):
		var a: Array = centre[i - 1]
		var b: Array = centre[i]
		if float(b[1]) >= y:
			var t := (y - float(a[1])) / maxf(1.0, float(b[1]) - float(a[1]))
			return lerpf(float(a[0]), float(b[0]), clampf(t, 0.0, 1.0))
	return float(centre[-1][0])


func _circle_hits(c: Vector2, r: float, rect: Rect2) -> bool:
	var p := Vector2(clampf(c.x, rect.position.x, rect.end.x), clampf(c.y, rect.position.y, rect.end.y))
	return p.distance_to(c) < r
