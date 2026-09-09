extends SceneTree
## Every live word lands where the painting put its own.
##
## A layout's text rect is measured off the reference's ink, and most of them
## come out tighter than the leading of the type that fills them. A Label cannot
## be shorter than one line, so Godot grew the control downward from the rect's
## top and the words landed low: the Kingdom's realm bonuses sat on the labels
## baked underneath them, and its ranking number eight units below the painting.
## Nothing measured it, because a control that is merely a few units low still
## fits inside every box a test was checking.
##
## Run: godot --headless --path client --script tests/text_sits_where_painted.gd

## A unit is 0.47 pt on the phone, so three is about a point and a half -- the
## most a word may drift before it reads as unaligned against a baked one.
const SLACK := 3.0

var _fails: int = 0
var _checked: int = 0
var _L: GDScript


func _initialize() -> void:
	await process_frame
	_L = load("res://scripts/ui/layout.gd")
	if _L == null:
		print("FAIL  could not load the layout builder")
		quit(1)
		return
	var dir := DirAccess.open("res://layout")
	for file in dir.get_files():
		if file.ends_with(".json"):
			await _check_screen(file.get_basename())
	if _checked == 0:
		print("FAIL  no text was built, so nothing was measured")
		quit(1)
		return
	print("  measured %d live text box(es)" % _checked)
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  every live word is centred on the rect the painting gave it")
	quit()


func _check_screen(screen: String) -> void:
	var host := Control.new()
	host.size = Vector2(941, 1672)
	root.add_child(host)
	var ui: Dictionary = _L.build(screen, host)
	await process_frame
	for e in _L.spec(screen).get("elements", []):
		if not (e is Dictionary) or str(e.get("kind", "")) != "text":
			continue
		var id := str(e.get("id", ""))
		if not ui.has(id) or not (ui[id] is Label):
			continue
		# Only a centred line is asked to be centred; a top- or bottom-aligned
		# one is asked for its edge, and gets it.
		if str(e.get("valign", "center")) != "center":
			continue
		var l: Label = ui[id]
		var r: Array = e["rect"]
		var want := float(r[1]) + float(r[3]) / 2.0
		# The block, not one line: a two-line description is given a rect that
		# holds two lines, and its centre is the centre of both.
		var got := l.position.y + l.get_minimum_size().y / 2.0
		_checked += 1
		if absf(got - want) > SLACK:
			_fails += 1
			print("  FAIL  %s/%s sits %.0f units off the rect it was measured into"
				% [screen, id, got - want])
	host.queue_free()
	await process_frame
