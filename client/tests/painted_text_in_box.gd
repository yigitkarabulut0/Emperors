extends SceneTree
## A one-line word on a painted page sits in its box, on the box's middle.
##
## A layout's text part is built around its painting's sample, and a Label grows
## to its words: the Stat Points' plate is 292 units wide and its sample, "99
## POINTS TO PLACE" at 36, 404. The label kept that width when emptied, the page
## fitted "NO POINTS TO PLACE" against 404, and the centred words sat 56 units
## right of the plate's middle and ran off its end. Layout now records each
## part's box ("box_w") and PaintedPage.set_text fits to it and sizes the label
## back to it.
##
## Every painted page's one-line text parts are set to their samples at both
## canvases: each fits its box, and a centred one is centred on it. The Stat
## Points' plate, with its longest real words, is checked by name.
##
## Run: godot --headless --path client --script tests/painted_text_in_box.gd

const CANVASES := [Vector2(941, 1672), Vector2(941, 2040)]
const SLACK := 1.5

var _fails := 0
var _checked := 0


func _initialize() -> void:
	await process_frame
	root.get_node("Env").set("api_base_url", "http://127.0.0.1:9")
	var L: GDScript = load("res://scripts/ui/layout.gd")
	var P: GDScript = load("res://scripts/ui/painted_page.gd")
	for canvas in CANVASES:
		for file in DirAccess.get_files_at("res://layout"):
			if not file.ends_with(".json"):
				continue
			var id := file.get_basename()
			var spec: Dictionary = L.spec(id)
			var els: Array = spec.get("elements", [])
			if els.is_empty() or not (els[0] is Dictionary) or str(els[0].get("id", "")) != "page":
				continue
			var host := Control.new()
			host.size = canvas
			root.add_child(host)
			var p: Control = P.open(host, id)
			await process_frame
			for e in els:
				if e is Dictionary and str(e.get("kind", "")) == "text" and not bool(e.get("wrap", false)) \
						and str(e.get("sample", "")) != "" and not bool(e.get("static", false)):
					_in_box(p.call("set_text", str(e["id"]), str(e["sample"]), 14), e,
						"%s/%s %dx%d" % [id, e["id"], int(canvas.x), int(canvas.y)])
			if id == "stats":
				for words in ["NO POINTS TO PLACE", "99 POINTS TO PLACE", "1 POINT TO PLACE"]:
					_in_box(p.call("set_text", "points", words, 22), L.element("stats", "points"),
						"stats/points \"%s\" %dx%d" % [words, int(canvas.x), int(canvas.y)])
			p.call("close")
			host.queue_free()
			await process_frame
	if _checked == 0:
		print("FAIL  no painted page's text was measured")
		quit(1)
		return
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  %d one-line words on painted pages sit in their boxes" % _checked)
	quit()


func _fail(msg: String) -> void:
	_fails += 1
	print("  FAIL  " + msg)


func _in_box(l: Label, e: Dictionary, tag: String) -> void:
	if l == null:
		return
	_checked += 1
	var r: Array = e["rect"]
	var box_w := float(r[2])
	var s := l.label_settings
	var words := s.font.get_string_size(l.text, HORIZONTAL_ALIGNMENT_LEFT, -1, s.font_size).x
	if words > box_w + SLACK:
		# Too long for its box even at the least size: the page's own code cuts
		# such a word (a lord's name, with an ellipsis); the host cannot.
		if s.font_size > 14:
			_fail("%s: \"%s\" is %.0f wide at %d, its box %.0f" % [tag, l.text, words, s.font_size, box_w])
		return
	if absf(l.size.x - box_w) > SLACK:
		_fail("%s: the label is %.0f wide, its box %.0f -- centred words sit off the box" % [tag, l.size.x, box_w])
	if l.horizontal_alignment == HORIZONTAL_ALIGNMENT_CENTER:
		var mid := l.position.x + l.size.x / 2.0
		# The box's middle, where the page has moved it (bands move y only).
		var want := float(r[0]) + box_w / 2.0
		if absf(mid - want) > SLACK:
			_fail("%s: the words' middle is at %.0f, the box's at %.0f" % [tag, mid, want])
