extends SceneTree
## A screen shows nothing of the painting's copy before the server answers.
##
## Every text part in a layout carries the painting's own words as its sample
## -- "Lord Darius", "278,000", "Restore 513 Energy" -- because that is what the
## type was measured from. Drawn as the label's text, a slow network or a failed
## request showed the painting's names and numbers as the player's. Only fixed
## copy, marked "static", may be drawn before the data arrives.
##
## Run: godot --headless --path client --script tests/no_sample_text.gd

var _fails := 0
var _checked := 0


func _initialize() -> void:
	await process_frame
	var L: GDScript = load("res://scripts/ui/layout.gd")
	var dir := DirAccess.open("res://layout")
	for file in dir.get_files():
		if not file.ends_with(".json"):
			continue
		var screen := file.get_basename()
		var host := Control.new()
		host.size = Vector2(941, 1672)
		root.add_child(host)
		L.build(screen, host)
		# Templates nested in scrolls are left to their screens; build one of
		# each here too, so their parts are checked as well.
		for e in L.spec(screen).get("elements", []):
			_instantiate_nested(L, e, host)
		await process_frame
		_walk(host, screen, L.spec(screen))
		host.queue_free()
		await process_frame
	if _checked == 0:
		print("FAIL  no label was built, so nothing was checked")
		quit(1)
		return
	if _fails > 0:
		print("FAIL  %d label(s) show the painting's copy" % _fails)
		quit(1)
		return
	print("PASS  %d labels start empty until the server answers" % _checked)
	quit()


func _instantiate_nested(L: GDScript, e: Variant, host: Control) -> void:
	if not (e is Dictionary):
		return
	for c in e.get("content", []):
		if c is Dictionary and str(c.get("kind", "")) == "template":
			host.add_child(L.instantiate(c)["node"])


func _static_words(spec: Dictionary) -> Dictionary:
	var out := {}
	var stack: Array = spec.get("elements", []).duplicate()
	while not stack.is_empty():
		var e: Variant = stack.pop_back()
		if not (e is Dictionary):
			continue
		if str(e.get("kind", "")) == "text" and bool(e.get("static", false)):
			out[str(e.get("sample", ""))] = true
		for k in ["parts", "content"]:
			if e.has(k):
				stack.append_array(e[k])
	return out


func _walk(n: Node, screen: String, spec: Dictionary) -> void:
	var allowed := _static_words(spec)
	var stack: Array = [n]
	while not stack.is_empty():
		var cur: Node = stack.pop_back()
		for c in cur.get_children():
			stack.append(c)
		if cur is Label:
			_checked += 1
			var t := (cur as Label).text
			if t != "" and not allowed.has(t):
				_fails += 1
				print("  FAIL  %s: a label starts as \"%s\"" % [screen, t.replace("\n", " ")])
