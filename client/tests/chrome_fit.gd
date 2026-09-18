extends SceneTree
## Two pieces of chrome whose position is measured off a painting, not chosen.
## A painting can be repainted and a coordinate can be nudged, so both are
## re-derived here from the images themselves and checked against the code.
##
## Run: godot --headless --path client --script tests/chrome_fit.gd

var _fails: int = 0


func _initialize() -> void:
	_level_badge_sits_on_the_plaque()
	_no_energy_face_covers_collect()
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


## The NO ENERGY face covers the painted COLLECT whole. collect.gd lays the
## painted plate (collect/no_energy_plate, from art/reference/plates_sheet.png)
## over COLLECT_PLATE, in the button picture's space; the picture stands at 566,
## 13 in the row. Re-derived from the images: the COLLECT plate's rim in the row
## painting must lie inside that rect, and the NO ENERGY plate's corner may cut
## no deeper than COLLECT's or a sliver of green rim shows at each corner. The
## face used to be the COLLECT picture baked red (collect_button_empty), which
## must be gone.
func _no_energy_face_covers_collect() -> void:
	if FileAccess.file_exists("res://assets/collect/collect_button_empty.png"):
		_fail("the baked red COLLECT (collect_button_empty) is still shipped")
	var face := _rect_in("scenes/tabs/collect.gd", "COLLECT_PLATE := ")
	if face.size == Vector2.ZERO:
		_fail("collect.gd has no COLLECT_PLATE")
		return
	face.position += Vector2(566, 13)
	var row := Image.load_from_file("res://assets/collect/job_row.png")
	var lo := Vector2i(100000, 100000)
	var hi := Vector2i(-1, -1)
	# The button's band of the row, above the mastery bar and its gold markers.
	for y in range(0, 96):
		for x in range(540, 762):
			if _is_rim(row.get_pixel(x, y)):
				lo = Vector2i(mini(lo.x, x), mini(lo.y, y))
				hi = Vector2i(maxi(hi.x, x), maxi(hi.y, y))
	if hi.x < 0:
		_fail("no painted COLLECT rim found in the row")
		return
	var rim := Rect2(lo, hi - lo + Vector2i.ONE)
	if not face.grow(0.5).encloses(rim):
		_fail("the NO ENERGY face %s does not cover the painted COLLECT %s" % [face, rim])
	var plate := Image.load_from_file("res://assets/collect/no_energy_plate.png")
	if plate == null:
		_fail("there is no collect/no_energy_plate")
		return
	# The corner cut: how far along the top edge the plate's first solid pixel sits.
	var cut := 0
	while cut < plate.get_width() and plate.get_pixel(cut, 0).a < 0.5:
		cut += 1
	var green_cut := 0
	while green_cut < 40 and not _is_rim(row.get_pixel(lo.x + green_cut, lo.y)):
		green_cut += 1
	if cut > green_cut + 1:
		_fail("the NO ENERGY plate's corner cuts %d deep against COLLECT's %d: green shows at its corners" % [cut, green_cut])


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
