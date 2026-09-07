extends SceneTree
## Two pieces of chrome whose position is measured off a painting, not chosen.
## A painting can be repainted and a coordinate can be nudged, so both are
## re-derived here from the images themselves and checked against the code.
##
## Run: godot --headless --path client --script tests/chrome_fit.gd

var _fails: int = 0


func _initialize() -> void:
	_level_badge_sits_on_the_plaque()
	_empty_button_has_no_green_and_no_word()
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  chrome fits its paintings")
	quit()


func _fail(msg: String) -> void:
	_fails += 1
	print("  FAIL  " + msg)


## The rail's level number must land on the plaque painted into chrome/avatar.
## The plaque is not centred in its own 132x190 tile, so "half the avatar" is
## the wrong answer; the interior is found here and compared with shell.gd.
func _level_badge_sits_on_the_plaque() -> void:
	var img := Image.load_from_file("res://assets/chrome/avatar.png")
	var band := _plaque_interior(img)
	if band == Rect2i():
		_fail("could not find the plaque interior in chrome/avatar.png")
		return

	var avatar_at := _rect_in("scenes/shell/shell.gd", 'UI.image("chrome/avatar", Rect2(')
	var label_at := _rect_in("scenes/shell/shell.gd", "UI.place(_level, Rect2(")
	if avatar_at == Rect2() or label_at == Rect2():
		_fail("could not read the avatar or level rect out of shell.gd")
		return

	var plaque := Vector2(band.position.x + band.size.x / 2.0, band.position.y + band.size.y / 2.0) \
		+ avatar_at.position
	var label := label_at.get_center()
	# One unit of slack each way: the glyphs' optical centre sits a shade below
	# the label box's, so an exact match is not the goal.
	if absf(label.x - plaque.x) > 1.5:
		_fail("level number is %.1f off the plaque horizontally (plaque %.1f, label %.1f)"
			% [label.x - plaque.x, plaque.x, label.x])
	if absf(label.y - plaque.y) > 1.5:
		_fail("level number is %.1f off the plaque vertically (plaque %.1f, label %.1f)"
			% [label.y - plaque.y, plaque.y, label.y])


## The dark red field between the plaque's two gold rims, on its own centre.
func _plaque_interior(img: Image) -> Rect2i:
	var minx := 999
	var maxx := -1
	for y in range(138, 152):
		for x in range(0, 132):
			var c := img.get_pixel(x, y)
			if _is_field(c):
				minx = mini(minx, x)
				maxx = maxi(maxx, x)
	if maxx < 0:
		return Rect2i()
	var cx := int((minx + maxx) / 2.0)
	var top := -1
	var bottom := -1
	for y in range(130, 186):
		if _is_rim(img.get_pixel(cx, y)):
			if top < 0:
				top = y
			else:
				bottom = y
	if top < 0 or bottom < 0:
		return Rect2i()
	return Rect2i(minx, top + 1, maxx - minx + 1, bottom - top - 1)


func _is_field(c: Color) -> bool:
	return c.a > 0.5 and c.r > c.b and c.r < 0.45 and c.g < 0.22


func _is_rim(c: Color) -> bool:
	return c.a > 0.5 and c.r > 0.62 and c.g > 0.45 and c.b < 0.42 and c.r - c.b > 0.28


## The baked "no energy" button must be the Collect button with a red field and
## no word on it: same size, same gold frame, no green left anywhere, and no
## near-white pixels where COLLECT used to be.
func _empty_button_has_no_green_and_no_word() -> void:
	var green := Image.load_from_file("res://assets/collect/collect_button.png")
	var red := Image.load_from_file("res://assets/collect/collect_button_empty.png")
	if red.get_size() != green.get_size():
		_fail("collect_button_empty is %s, collect_button is %s"
			% [str(red.get_size()), str(green.get_size())])
		return

	var still_green := 0
	var word := 0
	var frame_moved := 0
	for y in red.get_height():
		for x in red.get_width():
			var c := red.get_pixel(x, y)
			if c.a <= 0.004:
				continue
			if c.g > c.r + 0.02 and c.g > c.b + 0.02:
				still_green += 1
			if x >= 12 and x < 166 and y >= 10 and y < 66:
				if minf(minf(c.r, c.g), c.b) > 0.34:
					word += 1
			# The frame and the silhouette are not ours to change.
			var g := green.get_pixel(x, y)
			if absf(c.a - g.a) > 0.02:
				frame_moved += 1
	if still_green > 0:
		_fail("%d green pixels left on the no-energy button" % still_green)
	if word > 0:
		_fail("%d pixels of the painted word left on the no-energy button" % word)
	if frame_moved > 0:
		_fail("%d pixels of the button's silhouette moved" % frame_moved)


## Reads a literal Rect2(a, b, c, d) that follows `needle` in a source file, so
## the test measures what ships rather than a copy of it.
func _rect_in(path: String, needle: String) -> Rect2:
	var src := FileAccess.get_file_as_string("res://" + path)
	var at := src.find(needle)
	if at < 0:
		return Rect2()
	var open_at := src.find("Rect2(", at + needle.length() - 6)
	var close_at := src.find(")", open_at)
	var parts := src.substr(open_at + 6, close_at - open_at - 6).split(",")
	if parts.size() != 4:
		return Rect2()
	return Rect2(float(parts[0]), float(parts[1]), float(parts[2]), float(parts[3]))
