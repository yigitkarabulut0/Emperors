extends SceneTree
## A job row, drawn the way the game draws it, must look like the painting.
##
## A row is three pieces: the row's frame (collect/job_row, row one of the
## painting), the job's painting in the frame's window, and collect/job_frame --
## row one's own steel frame with the window cut out -- laid over the painting.
## Two things can go wrong, and both did once:
##  - the frame over the painting sits a unit or two off the row's, leaving the
##    row's chamfered corner showing past it as a notch. Every row now wears row
##    one's frame, so every row's corner must match row one of the painting;
##  - a painting cut from the wrong spot in its row shows a sliver of its own
##    frame inside the window. Each of the six paintings cut from collect.png must
##    match its own row's window.
##
## Nothing measured this, because each piece was correct on its own. So this
## builds each row out of the shipped pieces and compares it with the painting.
##
## Run: godot --headless --path client --script tests/job_rows_match.gd

## Where each row actually sits in the painting, from the light edge of its
## frame at x=170: 526, 690, 857, 1025, 1194, 1363, less the 9 units that edge
## sits below the row's own origin.
const ROW_Y := [517, 681, 848, 1016, 1185, 1354]
const JOBS := ["job_grapes", "job_strawberries", "job_wheat", "job_timber",
	"job_stone", "job_tithe"]
## The corner where the frame over the painting meets the row's own frame.
const CORNER := Rect2i(166, 0, 60, 40)
## The frame's window, in row coordinates, and inset a unit from its bevel.
const WINDOW := Rect2i(166 + 14, 11, 159, 135)
## The frame's opening itself (x 13..173, y 10..146 of the row, less the
## chamfered corner), which the frame comparison leaves out.
const OPENING := Rect2i(166 + 13, 10, 161, 137)
const TOLERANCE := 0.055

var _fails: int = 0
var _checked: int = 0


func _initialize() -> void:
	await process_frame
	var ref := Image.load_from_file("res://../art/reference/collect.png")
	var frame := Image.load_from_file("res://assets/collect/job_row.png")
	var ring := Image.load_from_file("res://assets/collect/job_frame.png")
	if ref == null or frame == null or ring == null:
		print("FAIL  could not load the painting, the row frame or the job frame")
		quit(1)
		return
	for img in [ref, frame, ring]:
		img.convert(Image.FORMAT_RGBA8)
	var at := _part_positions()

	for i in JOBS.size():
		var painting := Image.load_from_file("res://assets/collect/%s.png" % JOBS[i])
		if painting == null:
			_fail("%s is missing" % JOBS[i])
			continue
		painting.convert(Image.FORMAT_RGBA8)
		var drawn := Image.create(941, 200, false, Image.FORMAT_RGBA8)
		drawn.fill(Color("#0b151f"))
		drawn.blend_rect(frame, Rect2i(0, 0, 762, 156), Vector2i(166, 0))
		drawn.blend_rect(painting, Rect2i(0, 0, painting.get_width(), painting.get_height()),
			Vector2i(166 + int(at["painting"].x), int(at["painting"].y)))
		drawn.blend_rect(ring, Rect2i(0, 0, ring.get_width(), ring.get_height()),
			Vector2i(166 + int(at["tile"].x), int(at["tile"].y)))
		# The frame: every row wears row one's. Only the frame is compared -- the
		# window holds each row's own painting.
		var corner := _difference(drawn, CORNER,
			ref, Rect2i(CORNER.position.x, ROW_Y[0] + CORNER.position.y, CORNER.size.x, CORNER.size.y), OPENING)
		_checked += 1
		if corner > TOLERANCE:
			_fail("%s: the corner where the frame meets the row is %.1f%% off the painting's first row"
				% [JOBS[i], corner * 100.0])
		# The painting: its own row's window, from the right spot.
		var window := _difference(drawn, WINDOW,
			ref, Rect2i(WINDOW.position.x, ROW_Y[i] + WINDOW.position.y, WINDOW.size.x, WINDOW.size.y))
		_checked += 1
		if window > 0.01:
			_fail("%s: the painting in the window is %.1f%% off its own row in the painting"
				% [JOBS[i], window * 100.0])

	if _checked == 0:
		_fail("no row was compared")
	else:
		print("  compared %d row(s) against the painting" % (_checked / 2))
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  every job row's painting and frame sit the way the painting has them")
	quit()


func _fail(msg: String) -> void:
	_fails += 1
	print("  FAIL  " + msg)


## Where the layout puts the painting and the frame inside a row.
func _part_positions() -> Dictionary:
	var L: GDScript = load("res://scripts/ui/layout.gd")
	var row: Dictionary = L.find("collect", "job_row")
	var out := {"painting": Vector2(11, 8), "tile": Vector2(2, -2)}
	var found := 0
	for q in row.get("parts", []):
		var id := str(q.get("id", ""))
		if out.has(id):
			out[id] = L.rect_of(q).position
			found += 1
	if found < 2:
		_fail("the job row has no painting and tile parts")
	return out


## Mean absolute difference over a window, 0 for identical; pixels of `a`
## inside `skip` (not its chamfered corner) are left out.
func _difference(a: Image, ar: Rect2i, b: Image, br: Rect2i, skip := Rect2i()) -> float:
	var total := 0.0
	var n := 0
	for y in ar.size.y:
		for x in ar.size.x:
			var ax := ar.position.x + x
			var ay := ar.position.y + y
			if skip.has_point(Vector2i(ax, ay)) and (ax - skip.position.x) + (ay - skip.position.y) > 7:
				continue
			var pa := a.get_pixel(ax, ay)
			var pb := b.get_pixel(br.position.x + x, br.position.y + y)
			total += absf(pa.r - pb.r) + absf(pa.g - pb.g) + absf(pa.b - pb.b)
			n += 3
	return total / maxf(float(n), 1.0)
