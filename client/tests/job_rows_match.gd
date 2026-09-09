extends SceneTree
## A job row, drawn the way the game draws it, must look like the painting.
##
## The row template places every tile at the same spot inside the row -- [2, -2]
## -- so every tile has to be CUT from the same spot inside its own painted row.
## Five of the six were not: each was taken two units lower, which put its own
## steel border two units inside the row's and left the row's chamfered corner
## showing past it as a notch. Only the grapes row, which the frame itself was
## cut from, looked right.
##
## Nothing measured this, because both pieces were correct on their own. So this
## builds each row out of the shipped pieces and compares it with the painting
## at the corner where the two borders meet.
##
## Run: godot --headless --path client --script tests/job_rows_match.gd

## Where each row actually sits in the painting, from the light edge of its
## frame at x=170: 526, 690, 857, 1025, 1194, 1363, less the 9 units that edge
## sits below the row's own origin.
const ROW_Y := [517, 681, 848, 1016, 1185, 1354]
const JOBS := ["job_grapes", "job_strawberries", "job_wheat", "job_timber",
	"job_stone", "job_tax"]
## The corner where the tile's border meets the row's, which is what went wrong.
const CORNER := Rect2i(166, 0, 60, 40)
const TOLERANCE := 0.055

var _fails: int = 0
var _checked: int = 0


func _initialize() -> void:
	await process_frame
	var ref := Image.load_from_file("res://../art/reference/collect.png")
	var frame := Image.load_from_file("res://assets/collect/job_row.png")
	if ref == null or frame == null:
		print("FAIL  could not load the painting or the row frame")
		quit(1)
		return
	ref.convert(Image.FORMAT_RGBA8)
	frame.convert(Image.FORMAT_RGBA8)
	var offset := _tile_offset()

	for i in JOBS.size():
		var tile := Image.load_from_file("res://assets/collect/%s.png" % JOBS[i])
		if tile == null:
			_fail("%s is missing" % JOBS[i])
			continue
		tile.convert(Image.FORMAT_RGBA8)
		var y: int = ROW_Y[i]
		var drawn := Image.create(941, 200, false, Image.FORMAT_RGBA8)
		drawn.fill(Color("#0b151f"))
		drawn.blend_rect(frame, Rect2i(0, 0, 762, 156), Vector2i(166, 0))
		drawn.blend_rect(tile, Rect2i(0, 0, tile.get_width(), tile.get_height()),
			Vector2i(166 + int(offset.x), int(offset.y)))
		var diff := _difference(drawn, Rect2i(CORNER.position, CORNER.size),
			ref, Rect2i(CORNER.position.x, y + CORNER.position.y, CORNER.size.x, CORNER.size.y))
		_checked += 1
		if diff > TOLERANCE:
			_fail("%s: the corner where the tile meets the row is %.1f%% off the painting"
				% [JOBS[i], diff * 100.0])

	if _checked == 0:
		_fail("no row was compared")
	else:
		print("  compared %d row(s) against the painting" % _checked)
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  every job row's tile sits in its frame the way the painting has it")
	quit()


func _fail(msg: String) -> void:
	_fails += 1
	print("  FAIL  " + msg)


## Where the layout puts a tile inside its row.
func _tile_offset() -> Vector2:
	var L: GDScript = load("res://scripts/ui/layout.gd")
	var row: Dictionary = L.find("collect", "job_row")
	for q in row.get("parts", []):
		if str(q.get("id", "")) == "tile":
			return L.rect_of(q).position
	_fail("the job row has no tile part")
	return Vector2(2, -2)


## Mean absolute difference over a window, 0 for identical.
func _difference(a: Image, ar: Rect2i, b: Image, br: Rect2i) -> float:
	var total := 0.0
	var n := 0
	for y in ar.size.y:
		for x in ar.size.x:
			var pa := a.get_pixel(ar.position.x + x, ar.position.y + y)
			var pb := b.get_pixel(br.position.x + x, br.position.y + y)
			total += absf(pa.r - pb.r) + absf(pa.g - pb.g) + absf(pa.b - pb.b)
			n += 3
	return total / maxf(float(n), 1.0)
