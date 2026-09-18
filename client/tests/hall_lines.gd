extends SceneTree
## THE HALL'S LINES stay on the parchment they are written on.
##
## A line the realm says (`kind: "system"`) is drawn on a painted scroll, and a
## line that FOLLOWS another of the realm's is set in from the horn -- the horn
## is sounded once for a run. The words were measured against the FIRST scroll's
## width whatever scroll they went on, so the second line of a run wrapped to a
## width its own parchment does not have and ran its last word under the gold
## border. This holds every line inside the scroll it is on.
##
## It also holds the input to the hall's own limit: `max_chars` is
## social.chat.max_chars in the balance, and a second copy in the client is a
## number that starts by agreeing and ends by disagreeing.
##
## Run: godot --headless --path client --script tests/hall_lines.gd

const WIDTH := 762.0
var _fails := 0
var _checked := 0


func _initialize() -> void:
	await process_frame
	root.get_node("Env").set("api_base_url", "http://127.0.0.1:9")
	var host := Control.new()
	host.size = Vector2(941, 1672)
	root.add_child(host)
	var section: Control = load("res://scenes/kingdom/chat_section.gd").new()
	host.add_child(section)
	await process_frame
	section.call("fill_height", 900.0)

	# Three lines the realm says, one after another: the first carries the horn,
	# the two after it are set in from it.
	var long := "The war is drawn against the Wolves of the Fen, and the fighting begins on Saturday."
	section.set("_data", {
		"room": "r", "head": 3, "max_chars": 300, "next_in": 0, "muted_for": 0,
		"lines": [
			{"seq": 1, "kind": "system", "system_kind": "boss", "body": long, "at": 0},
			{"seq": 2, "kind": "system", "system_kind": "war", "body": long, "at": 0},
			{"seq": 3, "kind": "system", "system_kind": "largesse", "body": long, "at": 0},
		]})
	section.call("_paint")
	await process_frame
	await process_frame

	var scrolls: Array = []
	var words: Array = []
	_walk(section, scrolls, words)
	_expect(scrolls.size() == 3, "%d scrolls for three lines" % scrolls.size())
	_expect(words.size() == 3, "%d sets of words for three lines" % words.size())

	# Every line's words are inside the parchment they are written on, and the
	# indented ones are genuinely indented.
	var lefts: Array = []
	for i in mini(scrolls.size(), words.size()):
		var scroll: Control = scrolls[i]
		var l: Label = words[i]
		var s_box := Rect2(_page_pos(scroll, section), scroll.size)
		var w_box := Rect2(_page_pos(l, section), l.size)
		lefts.append(s_box.position.x)
		_checked += 1
		_expect(w_box.position.x >= s_box.position.x and w_box.end.x <= s_box.end.x + 0.5,
			"line %d's words run from %.0f to %.0f on a scroll from %.0f to %.0f"
			% [i + 1, w_box.position.x, w_box.end.x, s_box.position.x, s_box.end.x])
		# And the words really wrap inside that width, rather than being clipped.
		var s := l.label_settings
		var m := s.font.get_multiline_string_size(l.text, HORIZONTAL_ALIGNMENT_LEFT, l.size.x, s.font_size)
		_checked += 1
		_expect(m.x <= l.size.x + 1.0,
			"line %d's longest wrapped row is %.0f in a %.0f box" % [i + 1, m.x, l.size.x])
	if lefts.size() == 3:
		_expect(lefts[1] > lefts[0] and is_equal_approx(lefts[1], lefts[2]),
			"the run is not set in from the horn: %s" % str(lefts))

	# The hall's own limit reaches the field.
	var field: LineEdit = section.get("_field")
	_expect(field != null and field.max_length == 300,
		"the field holds %d characters where the hall allows 300"
		% (field.max_length if field != null else -1))

	host.queue_free()
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  %d checks: every line the realm says stays on its own parchment" % _checked)
	quit()


## Where a node sits on the section, whatever it is nested in.
func _page_pos(n: Control, top: Node) -> Vector2:
	var at := Vector2.ZERO
	var c: Node = n
	while c != null and c != top:
		if c is Control:
			at += (c as Control).position
		c = c.get_parent()
	return at


## The scrolls and the words on them, in the order they were laid.
func _walk(n: Node, scrolls: Array, words: Array) -> void:
	for c in n.get_children():
		if c is Label and (c as Label).autowrap_mode != TextServer.AUTOWRAP_OFF \
				and str((c as Label).text) != "":
			words.append(c)
		elif c is NinePatchRect or (c is TextureRect and _is_scroll(c)):
			scrolls.append(c)
		_walk(c, scrolls, words)


func _is_scroll(n: Node) -> bool:
	var tex: Texture2D = n.get("texture")
	return tex != null and str(tex.resource_path).ends_with("chat/scroll.png")


func _expect(ok: bool, what: String) -> void:
	if not ok:
		_fails += 1
		print("  FAIL  " + what)
