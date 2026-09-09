extends SceneTree
## The REVENGE tab carries no bubble and no number.
##
## The bubble is painted into the tab in the reference, so a count of zero
## showed an empty circle -- a badge saying nothing, which reads as though
## something is waiting -- and the tab that replaced it was cut with `soften`,
## which is a blur: it left a smudge where the circle had been. It is cut with
## `erase` now, filling each row from clean columns beside it, so the field and
## its gold rule come through whole.
##
## The count is not on the tab at all: the card underneath already says THEY
## ATTACKED YOU in a red frame.
##
## Run: godot --headless --path client --script tests/revenge_tab_clean.gd

## Where the bubble was, in the tab asset's own pixels, and a clean strip of
## field beside it to compare against. Both start below the tab's gold rule, so
## what is measured is the red field and whatever is standing on it.
const BUBBLE := Rect2i(258, 12, 56, 34)
const CLEAN := Rect2i(316, 12, 46, 34)

var _fails: int = 0


func _initialize() -> void:
	await process_frame
	_the_tab_the_screen_draws_has_no_bubble()
	_where_the_bubble_was_is_as_flat_as_the_field()
	_nothing_draws_a_count_on_it()
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  the revenge tab is clean: no bubble, no number, no smudge")
	quit()


func _fail(msg: String) -> void:
	_fails += 1
	print("  FAIL  " + msg)


func _the_tab_the_screen_draws_has_no_bubble() -> void:
	var src := FileAccess.get_file_as_string("res://scenes/tabs/attack.gd")
	if not src.contains("attack/tab_revenge_plain"):
		_fail("attack.gd no longer reaches for the tab without the bubble")
	if src.contains("_badge"):
		_fail("attack.gd still draws a badge on the tab")


## What a bubble leaves behind is a RIM: a bright ring on a field that has no
## ring in it. Deviation does not find it -- the disc inside the rim is smoother
## than the field, so a bubbled tab measures FLATTER overall, which is how the
## first version of this check passed with the bubble put back. What finds it is
## how far the brightest pixel in a row stands above that row's own middle.
func _where_the_bubble_was_is_as_flat_as_the_field() -> void:
	var im := Image.load_from_file("res://assets/attack/tab_revenge_plain.png")
	if im == null:
		_fail("attack/tab_revenge_plain is missing")
		return
	im.convert(Image.FORMAT_RGBA8)
	var was := _spike(im, BUBBLE)
	var field := _spike(im, CLEAN)
	if was > field:
		_fail("where the bubble was spikes %.3f against the field's %.3f: something is still there"
			% [was, field])
	else:
		print("  bubble's place spikes %.3f, the field beside it %.3f" % [was, field])


func _nothing_draws_a_count_on_it() -> void:
	var L: GDScript = load("res://scripts/ui/layout.gd")
	var tab: Dictionary = L.element("attack", "tab_revenge")
	if tab.is_empty():
		_fail("no tab_revenge in the layout")
		return
	if tab.has("badge_count"):
		_fail("the layout still measures a badge_count for a tab that has no badge")


## The largest distance, over the region's rows, between the brightest pixel in
## a row and that row's median. A ring shows here; a smooth field does not.
func _spike(im: Image, r: Rect2i) -> float:
	var worst := 0.0
	for y in r.size.y:
		var vals: Array = []
		for x in r.size.x:
			vals.append(im.get_pixel(r.position.x + x, r.position.y + y).r)
		vals.sort()
		worst = maxf(worst, float(vals[vals.size() - 1]) - float(vals[vals.size() / 2]))
	return worst
