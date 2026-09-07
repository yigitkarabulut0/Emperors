extends SceneTree
## Every progress bar a layout describes must be a clipped wrap that remembers
## its full width, and Layout.set_fill() must be safe to call on every repaint.
##
## The measured layouts write a bar as an image with a "fill" side. Built as a
## plain image, set_fill() had nothing to remember the full width by, so each
## call scaled the bar by the fraction of what the previous call had left: the
## Family XP bar crept backwards on every repaint while the XP figure stayed put.
##
## Run: godot --headless --path client --script tests/fill_bars.gd

const SCREENS := ["army", "attack", "collect", "family", "inventory", "kingdom", "shop"]
const FRAC := 0.6

var _fails: int = 0
## Loaded once the tree is up: a static reference would compile Layout (and UI,
## and their Art autoload calls) before the autoloads exist, and fail.
var _L: GDScript


func _initialize() -> void:
	# Autoloads (Art, for the textures) are registered after _init.
	await process_frame
	_L = load("res://scripts/ui/layout.gd")
	_set_fill_is_idempotent_on_a_bare_control()
	var bars := 0
	for screen in SCREENS:
		bars += _layout_bars_are_clipped_wraps(screen)
	if bars == 0:
		_fail("no layout describes a bar; the walk over the layouts is broken")
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  %d bars keep their width across repaints" % bars)
	quit()


func _fail(msg: String) -> void:
	_fails += 1
	print("  FAIL  " + msg)


## A Control that was never built as a fill still must not shrink on repaint.
func _set_fill_is_idempotent_on_a_bare_control() -> void:
	var c := Control.new()
	c.size = Vector2(100, 10)
	_L.set_fill(c, FRAC)
	_L.set_fill(c, FRAC)
	if not is_equal_approx(c.size.x, 100.0 * FRAC):
		_fail("bare control: two set_fill(%.1f) left width %.1f, want %.1f" % [FRAC, c.size.x, 100.0 * FRAC])
	_L.set_fill(c, 1.0)
	if not is_equal_approx(c.size.x, 100.0):
		_fail("bare control: set_fill(1.0) did not restore the full width (%.1f)" % c.size.x)
	c.free()


## Builds one screen and checks every part its layout marks with a "fill" side.
## Returns how many bars it checked.
func _layout_bars_are_clipped_wraps(screen: String) -> int:
	var expected: Dictionary = {}
	_bars_in_spec(_L.spec(screen).get("elements", []), expected)
	if expected.is_empty():
		return 0
	var host := Control.new()
	var built: Dictionary = _L.build(screen, host)
	var found: Dictionary = {}
	_bars_in_built(built, expected, found)
	# Templates a scroll region only names (a list's prototype row) are not built
	# by Layout.build; instantiate each once so their bars are checked too.
	var protos: Array = []
	_templates_in_spec(_L.spec(screen).get("elements", []), protos)
	for tpl in protos:
		var inst: Dictionary = _L.instantiate(tpl)
		host.add_child(inst["node"])
		_bars_in_built(inst, expected, found)
	var n := 0
	for id in expected:
		if not found.has(id):
			_fail("%s: bar '%s' was not found in the built screen" % [screen, id])
			continue
		for node in found[id]:
			n += 1
			_check_bar(screen, id, node, float(expected[id]))
	host.free()
	return n


func _check_bar(screen: String, id: String, node: Control, want_w: float) -> void:
	var tag := "%s/%s" % [screen, id]
	if not node.has_meta("full"):
		_fail(tag + ": built without a full-width meta, so set_fill() would compound")
		return
	if not node.clip_contents:
		_fail(tag + ": does not clip, so the fill would be squashed rather than cut")
	var full: Vector2 = node.get_meta("full")
	if not is_equal_approx(full.x, want_w):
		_fail("%s: full width %.1f, the layout says %.1f" % [tag, full.x, want_w])
	if node.get_child_count() != 1 or not (node.get_child(0) is TextureRect):
		_fail(tag + ": expected exactly one TextureRect inside the clip")
	elif not (node.get_child(0) as Control).size.is_equal_approx(full):
		_fail(tag + ": the image inside the clip is not drawn at its full size")
	_L.set_fill(node, FRAC)
	var once := node.size.x
	_L.set_fill(node, FRAC)
	if not is_equal_approx(node.size.x, once):
		_fail("%s: a repaint at the same fraction moved the bar (%.1f -> %.1f)" % [tag, once, node.size.x])
	if not is_equal_approx(once, full.x * FRAC):
		_fail("%s: set_fill(%.1f) gave width %.1f, want %.1f" % [tag, FRAC, once, full.x * FRAC])
	_L.set_fill(node, 1.0)
	if not is_equal_approx(node.size.x, full.x):
		_fail("%s: set_fill(1.0) did not restore the full width" % tag)
	_L.set_fill(node, 0.0)
	if node.visible:
		_fail("%s: an empty bar is still visible" % tag)


## Every template with parts, at any depth.
func _templates_in_spec(list: Array, out: Array) -> void:
	for e in list:
		if not (e is Dictionary):
			continue
		if str(e.get("kind", "")) == "template" and e.has("parts"):
			out.append(e)
		for k in ["parts", "content"]:
			if e.has(k):
				_templates_in_spec(e[k], out)


## id -> rect width, for every element in a layout that carries a "fill" side.
func _bars_in_spec(list: Array, out: Dictionary) -> void:
	for e in list:
		if not (e is Dictionary):
			continue
		if e.has("fill"):
			var r: Array = e.get("rect", [0, 0, 0, 0])
			out[str(e.get("id", ""))] = r[2] if r.size() == 4 else 0
		for k in ["parts", "content"]:
			if e.has(k):
				_bars_in_spec(e[k], out)


## Walks what Layout.build() returned -- plain nodes, [{node, parts}] lists, and
## the "parts"/"instances" metas of groups and nested templates -- collecting
## every node keyed by one of the expected ids.
func _bars_in_built(v: Variant, expected: Dictionary, out: Dictionary) -> void:
	if v is Array:
		for e in v:
			_bars_in_built(e, expected, out)
	elif v is Dictionary:
		for k in v:
			var e: Variant = v[k]
			if e is Control and expected.has(str(k)):
				if not out.has(str(k)):
					out[str(k)] = []
				if not out[str(k)].has(e):
					out[str(k)].append(e)
			_bars_in_built(e, expected, out)
	elif v is Control:
		if v.has_meta("parts"):
			_bars_in_built(v.get_meta("parts"), expected, out)
		if v.has_meta("instances"):
			_bars_in_built(v.get_meta("instances"), expected, out)
