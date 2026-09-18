extends SceneTree
## The live words on the Family and the Army sit on the painting's own grain,
## in the painting's own type and place.
##
## Where the painting had words that the game sets live -- a name, a level, a
## figure -- the crop had them lifted by a flat erase: each row filled with one
## colour. Every live word then sat on a box a shade off the plate's grain:
## LEVEL and the name on the identity plate, a ledger card's rows, a soldier
## card's name and figures, the HERO SUPPORT figures, the selected soldier's
## name, blurb, troop count and figures, the tier chip's word and the ground
## the chip stood on. On the recruit cards a softened lift
## hazed the price and blurred the painted coin's edge. And the HERO SUPPORT
## figures were set a quarter larger than the painted ones, with SPEED centred
## six units above ATTACK and DEFENCE; the soldier's blurb broke a word early.
## What must hold:
##  - every such region keeps grain (no row of it one flat colour), and
##    nothing of the painted words stands in it (the POWER figure's comma);
##  - the recruit cards' painted coins and the villager's hood are as painted;
##  - the support figures are the painted size and place, SPEED sits on the
##    painted labels' line in their type, and the blurb breaks where the
##    painting does.
##
## Run: godot --headless --path client --script tests/live_words_on_grain.gd

## [asset, its crop's origin on the painting, the lifted rect on the painting].
const REGIONS := [
	["army/hero_support", Vector2i(170, 342), Rect2i(284, 424, 90, 40)],
	["army/hero_support", Vector2i(170, 342), Rect2i(516, 424, 90, 40)],
	["army/hero_support", Vector2i(170, 342), Rect2i(760, 424, 90, 40)],
	["army/hero_support", Vector2i(170, 342), Rect2i(762, 397, 116, 26)],
	["army/card", Vector2i(480, 559), Rect2i(487, 740, 137, 24)],
	["army/card", Vector2i(480, 559), Rect2i(534, 771, 82, 29)],
	["army/card", Vector2i(480, 559), Rect2i(534, 799, 82, 29)],
	["army/card", Vector2i(480, 559), Rect2i(534, 827, 82, 31)],
	["army/selected_panel", Vector2i(170, 898), Rect2i(398, 968, 150, 36)],
	["army/selected_panel", Vector2i(170, 898), Rect2i(398, 1010, 316, 56)],
	["army/selected_panel", Vector2i(170, 898), Rect2i(779, 968, 130, 36)],
	["army/selected_panel", Vector2i(170, 898), Rect2i(434, 1100, 66, 34)],
	["army/selected_panel", Vector2i(170, 898), Rect2i(538, 1100, 72, 34)],
	["army/selected_panel", Vector2i(170, 898), Rect2i(640, 1100, 64, 34)],
	# The ground under the tier chip, which shows beside the chip now that it
	# follows the name, and under EMPTY SLOT; and the chip's own plate, round
	# its live word (the erase there sampled the rim and left a lighter box).
	["army/selected_panel", Vector2i(170, 898), Rect2i(553, 970, 86, 32)],
	["army/tier_chip", Vector2i(553, 972), Rect2i(566, 978, 62, 18)],
	["family/identity_plate", Vector2i(168, 640), Rect2i(355, 655, 490, 58)],
	["family/identity_plate", Vector2i(168, 640), Rect2i(405, 722, 160, 26)],
	["family/identity_plate", Vector2i(168, 640), Rect2i(355, 790, 250, 28)],
	["family/upgrade_card", Vector2i(172, 1323), Rect2i(578, 1346, 300, 38)],
	["family/upgrade_card", Vector2i(172, 1323), Rect2i(572, 1388, 334, 82)],
	["family/stats_strip", Vector2i(172, 836), Rect2i(190, 968, 226, 48)],
	["family/stats_strip", Vector2i(172, 836), Rect2i(438, 968, 222, 48)],
	["family/stats_strip", Vector2i(172, 836), Rect2i(680, 968, 232, 48)],
]
## Lifted words with nothing of the painted ones left standing: the POWER
## figure's comma ran below a 42-tall erase and stood under the live figure.
const NO_STUB := [
	["family/stats_strip", Vector2i(172, 836), Rect2i(190, 968, 226, 48)],
	["family/stats_strip", Vector2i(172, 836), Rect2i(438, 968, 222, 48)],
	["family/stats_strip", Vector2i(172, 836), Rect2i(680, 968, 232, 48)],
	["army/hero_support", Vector2i(170, 342), Rect2i(284, 424, 90, 40)],
	["army/card", Vector2i(480, 559), Rect2i(534, 771, 82, 87)],
	["army/selected_panel", Vector2i(170, 898), Rect2i(553, 970, 86, 32)],
	["army/tier_chip", Vector2i(553, 972), Rect2i(566, 978, 62, 18)],
]
## Painted things a lift must leave alone: [asset, origin, rect on the painting].
const KEEP := [
	["army/recruit_villager", Vector2i(178, 1341), Rect2i(236, 1462, 30, 36)],
	["army/recruit_mercenary", Vector2i(420, 1341), Rect2i(478, 1462, 29, 36)],
	["army/recruit_gladiator", Vector2i(667, 1341), Rect2i(723, 1462, 31, 36)],
	["army/recruit_villager", Vector2i(178, 1341), Rect2i(240, 1380, 25, 66)],
	["army/selected_panel", Vector2i(170, 898), Rect2i(383, 1100, 40, 34)],
	["army/selected_panel", Vector2i(170, 898), Rect2i(508, 1100, 24, 34)],
	["army/selected_panel", Vector2i(170, 898), Rect2i(596, 1100, 40, 34)],
]
## The painting's own "+18%" in the HERO SUPPORT row: ink 71 wide from x 292.
const PAINTED_FIGURE_W := 71.0
const PAINTED_FIGURE_X := [292.0, 524.0, 768.0]
const SUPPORT_IDS := ["support_attack", "support_defence", "support_troop"]

var _fails := 0
var _checked := 0


func _initialize() -> void:
	await process_frame
	var ref := Image.load_from_file("res://../art/reference/army.png")
	var fam := Image.load_from_file("res://../art/reference/family.png")
	for r in REGIONS:
		_grain(r[0], r[1], r[2])
	for k in KEEP:
		_kept(k[0], k[1], k[2], ref if str(k[0]).begins_with("army") else fam)
	for n in NO_STUB:
		_no_stub(n[0], n[1], n[2])
	_support()
	_blurb()
	_level(fam)
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  %d live words sit on the painting's grain, in its type and place" % _checked)
	quit()


func _fail(msg: String) -> void:
	_fails += 1
	print("  FAIL  " + msg)


func _img(asset: String) -> Image:
	var img := Image.load_from_file("res://assets/%s.png" % asset)
	if img != null:
		img.convert(Image.FORMAT_RGBA8)
	return img


## No row of a lifted region is one flat colour: its grain survives.
func _grain(asset: String, origin: Vector2i, r: Rect2i) -> void:
	var img := _img(asset)
	if img == null:
		_fail("%s is missing" % asset)
		return
	_checked += 1
	var rows := 0.0
	for y in r.size.y:
		var sum := 0.0
		var sum2 := 0.0
		for x in r.size.x:
			var c := img.get_pixel(r.position.x - origin.x + x, r.position.y - origin.y + y)
			var v := (c.r + c.g + c.b) / 3.0 * 255.0
			sum += v
			sum2 += v * v
		var n := float(r.size.x)
		rows += sqrt(maxf(0.0, sum2 / n - (sum / n) * (sum / n)))
	var grain := rows / float(r.size.y)
	if grain < 1.0:
		_fail("%s at %s is a flat box (grain %.2f): the words were erased, not lifted" % [asset, r, grain])


## A painted thing beside a lift is as painted.
func _kept(asset: String, origin: Vector2i, r: Rect2i, ref: Image) -> void:
	var img := _img(asset)
	if img == null or ref == null:
		_fail("%s or its painting is missing" % asset)
		return
	ref.convert(Image.FORMAT_RGBA8)
	_checked += 1
	var total := 0.0
	for y in r.size.y:
		for x in r.size.x:
			var a := img.get_pixel(r.position.x - origin.x + x, r.position.y - origin.y + y)
			var b := ref.get_pixel(r.position.x + x, r.position.y + y)
			total += absf(a.r - b.r) + absf(a.g - b.g) + absf(a.b - b.b)
	var mean := total / float(r.size.x * r.size.y * 3) * 255.0
	if mean > 3.0:
		_fail("%s at %s is %.1f levels off the painting: a lift reached it" % [asset, r, mean])


## Nothing as bright as the painted words is left in a lifted region.
func _no_stub(asset: String, origin: Vector2i, r: Rect2i) -> void:
	var img := _img(asset)
	if img == null:
		_fail("%s is missing" % asset)
		return
	_checked += 1
	var left := 0
	for y in r.size.y:
		for x in r.size.x:
			var c := img.get_pixel(r.position.x - origin.x + x, r.position.y - origin.y + y)
			if (c.r + c.g + c.b) / 3.0 > 150.0 / 255.0:
				left += 1
	if left > 0:
		_fail("%s at %s keeps %d pixels of the painted words" % [asset, r, left])


## The support figures at the painted size and place; SPEED on the labels' line.
func _support() -> void:
	var L: GDScript = load("res://scripts/ui/layout.gd")
	var ui: GDScript = load("res://scripts/ui/ui.gd")
	for i in SUPPORT_IDS.size():
		var e: Dictionary = L.find("army", SUPPORT_IDS[i])
		_checked += 1
		var s: LabelSettings = ui.settings(int(e.get("size", 0)), Color.WHITE, str(e.get("font", "body")),
			int(e.get("weight", 500)))
		var w: float = s.font.get_string_size("+18%", HORIZONTAL_ALIGNMENT_LEFT, -1, s.font_size).x
		if absf(w - PAINTED_FIGURE_W) > 5.0:
			_fail("%s sets '+18%%' %d wide; the painting's is %d" % [SUPPORT_IDS[i], int(w), int(PAINTED_FIGURE_W)])
		var x := float(L.rect_of(e).position.x)
		if absf(x + 2.0 - PAINTED_FIGURE_X[i]) > 3.0:
			_fail("%s starts at %d; the painting's figure at %d" % [SUPPORT_IDS[i], int(x), int(PAINTED_FIGURE_X[i])])
	var army: GDScript = load("res://scenes/tabs/army.gd")
	var consts := army.get_script_constant_map()
	_checked += 1
	if not consts.has("SUPPORT_LABEL_RECT"):
		_fail("SPEED has no measured place (SUPPORT_LABEL_RECT)")
		return
	var r: Rect2 = consts["SUPPORT_LABEL_RECT"]
	# The painted ATTACK and DEFENCE: caps on rows 409..419, the cell's text at x 767.
	if absf(r.get_center().y - 414.0) > 2.0 or absf(r.position.x - 765.0) > 3.0:
		_fail("SPEED is placed at %s, off the painted labels' line (centre 414, x 765)" % r)
	if int(consts.get("SUPPORT_LABEL_SIZE", 0)) != 16:
		_fail("SPEED is set at %d; the painted labels' caps are 11 tall (16)" % int(consts.get("SUPPORT_LABEL_SIZE", 0)))


## The identity plate's LEVEL line starts where the painted one does: its gold
## ink runs from x 409 on rows 728..747. The live line stood five units right
## of it and two above.
func _level(fam: Image) -> void:
	var L: GDScript = load("res://scripts/ui/layout.gd")
	var plate: Dictionary = L.find("family", "identity")
	var level: Dictionary = {}
	for q in plate.get("parts", []):
		if str(q.get("id", "")) == "level":
			level = q
	_checked += 1
	if level.is_empty():
		_fail("the identity plate has no level part")
		return
	fam.convert(Image.FORMAT_RGBA8)
	var ink_x := -1
	for x in range(400, 600):
		for y in range(720, 752):
			var c := fam.get_pixel(x, y)
			if c.r > 0.7 and c.g > 0.55 and c.b < 0.47:
				ink_x = x
				break
		if ink_x >= 0:
			break
	var at: Rect2 = L.rect_of(level, L.rect_of(plate).position)
	# Cinzel's side bearing puts the ink two units in from the rect.
	if absf(at.position.x + 2.0 - float(ink_x)) > 2.0:
		_fail("LEVEL is set from x %d; the painted one's ink starts at %d" % [int(at.position.x) + 2, ink_x])
	if absf(at.get_center().y - 737.0) > 2.0:
		_fail("LEVEL is centred on row %d; the painted one on 737" % int(at.get_center().y))


## The villager's blurb breaks where the painting does: "... The backbone".
func _blurb() -> void:
	var L: GDScript = load("res://scripts/ui/layout.gd")
	var ui: GDScript = load("res://scripts/ui/ui.gd")
	var e: Dictionary = L.find("army", "sel_description")
	var s: LabelSettings = ui.settings(int(e.get("size", 20)), Color.WHITE, "body", int(e.get("weight", 500)))
	var w: float = s.font.get_string_size("Humble but reliable. The backbone", HORIZONTAL_ALIGNMENT_LEFT, -1,
		s.font_size).x
	_checked += 1
	if w > L.rect_of(e).size.x:
		_fail("the blurb's first line is %d in a %d box: 'backbone' falls to the second line" % [int(w),
			int(L.rect_of(e).size.x)])
	if absf(w - 281.0) > 8.0:
		_fail("the blurb's first line sets %d wide; the painting's ink is 276" % int(w))
