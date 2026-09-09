extends SceneTree
## Every button on every screen is big enough to press.
##
## The design grid is 941 units across and the phone draws it over 440 pt, so a
## unit is 0.47 pt and the 44 pt Apple asks for is 95 units. The references
## paint buttons at a mock-up's proportions, not a thumb's: 31 of the game's 37
## were under 44 pt and the smallest was 17. They are grown by
## scripts/fit-tap-targets.py, which stops at whatever else can be pressed --
## two tap areas sharing pixels means one of them cannot be reached, which is
## worse than a small button.
##
## Run: godot --headless --path client --script tests/tap_targets.gd

const PT_PER_UNIT := 440.0 / 941.0
const MIN_PT := 44.0

## The two the painting will not give room to, with what stops them. Listed
## rather than ignored: if a panel is ever redrawn, this is the list to empty.
## The six that cannot reach 44 pt, with what stops each. All six are drawn over
## a twin painted into the panel behind them, so growing one means growing it
## around its own centre or the player sees the button twice -- and around the
## centre there is something else in the way. A correctly placed button beats a
## bigger one drawn twice. Empty this list if those panels are ever redrawn.
const CRAMPED := {
	"army/auto_equip":
		"the slot row's window starts 24 units below it and would take the drags",
	"attack/view_all":
		"it sits at the top of the history panel; there is no panel above it",
	"family/edit":
		"the identity plate is only 95 units of height wide enough to hold it",
	"family/equip_best":
		"the gear panel's header band ends where the gear tiles begin",
	"kingdom/lords_view_all":
		"the lords panel's header band is 58 units and the rows under it are tap targets too",
	"kingdom/upgrade":
		"four works rows share the panel; a taller button would cover the row below",
}

var _fails: int = 0
var _L: GDScript


func _initialize() -> void:
	await process_frame
	_L = load("res://scripts/ui/layout.gd")
	if _L == null or not _L.has_method("spec"):
		print("FAIL  could not load layout.gd; nothing below ran")
		quit(1)
		return
	var seen := 0
	var dir := DirAccess.open("res://layout")
	for file in dir.get_files():
		if not file.ends_with(".json"):
			continue
		seen += _walk(file.get_basename(), _L.spec(file.get_basename()).get("elements", []),
			Vector2(941, 1672))
	if seen == 0:
		_fail("no buttons were found at all, so nothing was checked")
	else:
		print("  checked %d control(s)" % seen)
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  every button takes a thumb, bar the %d the paintings cramp" % CRAMPED.size())
	quit()


func _fail(msg: String) -> void:
	_fails += 1
	print("  FAIL  " + msg)


func _walk(screen: String, list: Array, bounds: Vector2) -> int:
	var n := 0
	for e in list:
		if not (e is Dictionary):
			continue
		var kind := str(e.get("kind", ""))
		var r: Rect2 = _L.rect_of(e)
		if kind == "button" or kind == "hotspot":
			n += 1
			_check(screen, e, r)
		for key in ["parts", "content"]:
			if e.has(key):
				n += _walk(screen, e[key], r.size)
		if e.has("instances") and e.has("parts"):
			pass  # the parts were walked once above; instances repeat the same rects
	return n


func _check(screen: String, e: Dictionary, r: Rect2) -> void:
	var id := "%s/%s" % [screen, str(e.get("id", ""))]
	var w := r.size.x * PT_PER_UNIT
	var h := r.size.y * PT_PER_UNIT
	var small: bool = minf(w, h) < MIN_PT
	if small and not CRAMPED.has(id):
		_fail("%s is %.0fx%.0f pt, under %.0f -- grow it with scripts/fit-tap-targets.py"
			% [id, w, h, MIN_PT])
	if not small and CRAMPED.has(id):
		_fail("%s now fits (%.0fx%.0f pt); take it out of CRAMPED" % [id, w, h])
	# A button is drawn centred in its rect, and nearly all of them have a twin
	# painted into the panel behind. Move the centre and the player sees two --
	# which is what AUTO EQUIP did after it was grown upward to reach 44 pt.
	if e.has("paint_rect"):
		var pr: Array = e["paint_rect"]
		var painted := Vector2(float(pr[0]) + float(pr[2]) / 2.0, float(pr[1]) + float(pr[3]) / 2.0)
		var now := r.position + r.size / 2.0
		if now.distance_to(painted) > 1.0:
			_fail("%s has moved %.0f units off where it is painted; it will be drawn twice"
				% [id, now.distance_to(painted)])
