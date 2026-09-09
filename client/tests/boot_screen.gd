extends SceneTree
## The loading bar's gold stays inside the frame the painting draws for it.
##
## The painting is extended to 941x2200 so that covering a tall phone crops it
## top and bottom rather than at the sides, where the title is. Anything drawn
## on top has to go
## through that same transform or it slides off what it belongs to. The bar is
## the only thing drawn on top, and it has to land in its frame on every canvas
## the game stretches to.
##
## The splash and the loading painting are also checked to be the pair they
## should be: the splash carries no progress bar, because iOS shows it before
## the app is running.
##
## Run: godot --headless --path client --script tests/boot_screen.gd

const ART := Vector2(941.0, 2200.0)
## The painted frame the gold sits in, read off the loading painting.
const FRAME := Rect2(162, 1766, 578, 70)
## The canvases the game stretches to: the grid, and the tallest phones.
const CANVASES := [Vector2(941, 1672), Vector2(941, 1900), Vector2(941, 2040), Vector2(941, 2140)]

var _fails: int = 0


func _initialize() -> void:
	await process_frame
	var fill := _fill_rect()
	if fill == Rect2():
		print("FAIL  could not read FILL_RECT out of boot.gd")
		quit(1)
		return
	_the_bar_lands_in_its_frame(fill)
	_the_two_layouts_agree(fill)
	_the_art_is_there_and_is_the_right_pair()
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  the bar stays in its frame, and the splash carries no bar")
	quit()


func _fail(msg: String) -> void:
	_fails += 1
	print("  FAIL  " + msg)


func _fill_rect() -> Rect2:
	var src := FileAccess.get_file_as_string("res://scenes/boot/boot.gd")
	var at := src.find("const FILL_RECT := Rect2(")
	if at < 0:
		return Rect2()
	var open_at := at + "const FILL_RECT := Rect2(".length()
	var parts := src.substr(open_at, src.find(")", open_at) - open_at).split(",")
	if parts.size() != 4:
		return Rect2()
	return Rect2(float(parts[0]), float(parts[1]), float(parts[2]), float(parts[3]))


func _the_bar_lands_in_its_frame(fill: Rect2) -> void:
	for c in CANVASES:
		var s := maxf(c.x / ART.x, c.y / ART.y)
		var off := Vector2((c.x - ART.x * s) / 2.0, (c.y - ART.y * s) / 2.0)
		var bar := Rect2(off + fill.position * s, fill.size * s)
		var frame := Rect2(off + FRAME.position * s, FRAME.size * s)
		if not frame.encloses(bar):
			_fail("on %dx%d the bar %s is not inside its painted frame %s"
				% [int(c.x), int(c.y), str(bar), str(frame)])
		if not Rect2(Vector2.ZERO, c).encloses(bar):
			_fail("on %dx%d the bar %s is off the screen" % [int(c.x), int(c.y), str(bar)])


## boot.gd fills the track and make-branding.py empties it; they must agree on
## where it is, or the gold is drawn beside the hole rather than in it.
func _the_two_layouts_agree(fill: Rect2) -> void:
	var py := FileAccess.get_file_as_string("res://../scripts/make-branding.py")
	var at := py.find("FILL = (")
	if at < 0:
		_fail("make-branding.py no longer says where the track is")
		return
	var parts := py.substr(at + 8, py.find(")", at) - at - 8).split(",")
	if parts.size() != 4:
		_fail("could not read FILL from make-branding.py")
		return
	var theirs := Rect2(float(parts[0]), float(parts[1]), float(parts[2]), float(parts[3]))
	if not theirs.is_equal_approx(fill):
		_fail("boot.gd fills %s and make-branding.py empties %s" % [str(fill), str(theirs)])


func _the_art_is_there_and_is_the_right_pair() -> void:
	for a in ["branding/loading", "branding/loading_fill"]:
		if not ResourceLoader.exists("res://assets/%s.png" % a):
			_fail("boot.gd draws %s and it is not there" % a)
	var loading := Image.load_from_file("res://assets/branding/loading.png")
	if loading != null and Vector2(loading.get_size()) != ART:
		_fail("the loading painting is %s, not the %s the bar was measured on"
			% [str(loading.get_size()), str(ART)])
	# The splash must not carry a bar of its own: the track's row should be part
	# of the picture, not a dark channel with a gold frame around it.
	var splash := Image.load_from_file("res://assets/branding/launch@3x.png")
	if splash == null:
		_fail("no launch@3x.png")
		return
	if splash.get_width() * 2796 != splash.get_height() * 1290:
		_fail("launch@3x is %s, which is not the phone's shape" % str(splash.get_size()))
