extends SceneTree
## The launch image and the game's first frame are one picture.
##
## iOS draws a static image while the engine starts and the engine then draws
## its own first frame. Two different pictures make the app flash on every
## launch, so both are laid out from the same fractions: boot.gd holds them as
## constants and scripts/make-branding.py holds the same names. This checks they
## have not drifted, and that the title fits the screen it is centred on --
## EMPERORS used to be drawn half off the right edge.
##
## Run: godot --headless --path client --script tests/boot_screen.gd

const SHARED := ["VISTA_F", "FADE_F", "MED_MID_F", "MED_W_F", "TITLE_MID_F",
	"TITLE_SIZE_F", "RULE_F", "RULE_W_F", "SUB_MID_F", "SUB_SIZE_F", "FOOT_F"]

## The tallest phone canvas the game stretches to, and the design grid's own.
const CANVASES := [Vector2(941, 1672), Vector2(941, 2040), Vector2(941, 2140)]

var _fails: int = 0


func _initialize() -> void:
	await process_frame
	_the_two_layouts_agree()
	_the_title_fits_every_canvas()
	_the_pieces_it_draws_exist()
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  the launch image and the first frame are the same picture")
	quit()


func _fail(msg: String) -> void:
	_fails += 1
	print("  FAIL  " + msg)


func _the_two_layouts_agree() -> void:
	var gd := FileAccess.get_file_as_string("res://scenes/boot/boot.gd")
	var py := FileAccess.get_file_as_string("res://../scripts/make-branding.py")
	if gd == "" or py == "":
		_fail("could not read boot.gd or make-branding.py")
		return
	for name in SHARED:
		var a := _number(gd, "const %s := " % name)
		var b := _number(py, "%s = " % name)
		if a == INF or b == INF:
			_fail("%s is missing from one of the two layouts" % name)
			continue
		if absf(a - b) > 0.0005:
			_fail("%s is %.4f in boot.gd and %.4f in make-branding.py; the launch image and the first frame would not line up"
				% [name, a, b])


## Reads the first number after `key`.
func _number(src: String, key: String) -> float:
	var at := src.find(key)
	if at < 0:
		return INF
	var rest := src.substr(at + key.length(), 24)
	var digits := ""
	for c in rest:
		if c.is_valid_int() or c == "." or (digits == "" and c == "-"):
			digits += c
		elif digits != "":
			break
	return float(digits) if digits != "" else INF


func _the_title_fits_every_canvas() -> void:
	var f := FontVariation.new()
	f.base_font = load("res://assets/fonts/Cinzel-Variable.ttf")
	f.variation_opentype = {"wght": 800}
	var frac := _number(FileAccess.get_file_as_string("res://scenes/boot/boot.gd"),
		"const TITLE_SIZE_F := ")
	for c in CANVASES:
		var size := int(frac * c.y)
		var w := f.get_string_size("EMPERORS", HORIZONTAL_ALIGNMENT_CENTER, -1, size).x
		if w > c.x - 40:
			_fail("EMPERORS is %.0f units wide at size %d on a %dx%d canvas, which leaves no margin"
				% [w, size, int(c.x), int(c.y)])


func _the_pieces_it_draws_exist() -> void:
	for a in ["branding/vista", "branding/foot", "branding/medallion"]:
		if not ResourceLoader.exists("res://assets/%s.png" % a):
			_fail("boot.gd draws %s and it is not there" % a)
