extends SceneTree
## The REVENGE tab carries a count only when a score is waiting.
##
## The painting drew a bubble into the lit REVENGE plate, so a count of zero
## showed an empty circle -- a badge saying nothing, which reads as though
## something were waiting -- and the tab that replaced it was cut with `soften`,
## which is a blur and left a smudge where the circle had been.
##
## The tabs are the painted tab plates now (scripts/ui/tab_strip.gd,
## art/slices/tabs_sheet.json), which carry no bubble, and the header's own
## painted tabs are erased under them. What is checked:
## - where the painted bubble stood, the header is as flat as the ground beside
##   it: nothing of the circle is left to show between the plates;
## - no count shows with none waiting, and the number of scores waiting shows
##   in the rail's own bubble when there are some, whichever tab is lit.
##
## Run: godot --headless --path client --script tests/revenge_tab_clean.gd

## Where the bubble was painted (x 441..499, y 284..334 on the painting), in the
## header crop's own pixels -- it starts at x 155, y 0 -- and a stretch of the
## erased band beside it.
const BUBBLE := Rect2i(286, 286, 56, 34)
const CLEAN := Rect2i(350, 286, 46, 34)

var _fails: int = 0


func _initialize() -> void:
	await process_frame
	_where_the_bubble_was_is_as_flat_as_the_field()
	await _a_count_only_when_one_waits()
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  the revenge tab is clean: no bubble, no number, no smudge")
	quit()


func _fail(msg: String) -> void:
	_fails += 1
	print("  FAIL  " + msg)


## What a bubble leaves behind is a RIM: a bright ring on a field that has no
## ring in it. What finds it is how far the brightest pixel in a row stands
## above that row's own middle.
func _where_the_bubble_was_is_as_flat_as_the_field() -> void:
	var im := Image.load_from_file("res://assets/attack/header.png")
	if im == null:
		_fail("attack/header is missing")
		return
	im.convert(Image.FORMAT_RGBA8)
	var was := _spike(im, BUBBLE)
	var field := _spike(im, CLEAN)
	if was > field + 0.01:
		_fail("where the bubble was spikes %.3f against the field's %.3f: something is still there"
			% [was, field])
	else:
		print("  bubble's place spikes %.3f, the field beside it %.3f" % [was, field])


func _a_count_only_when_one_waits() -> void:
	var host := Control.new()
	host.size = Vector2(941, 1672)
	root.add_child(host)
	var tab: Control = (load("res://scenes/tabs/attack.gd") as GDScript).new()
	tab.set_anchors_preset(Control.PRESET_FULL_RECT)
	host.add_child(tab)
	for i in 3:
		await process_frame
	var strip: Control = tab.get("_tabs")
	if strip == null:
		_fail("the Attack tab has no tab strip")
		host.queue_free()
		return
	for waiting in [0, 2]:
		var revenge: Array = []
		for i in waiting:
			revenge.append({"player_id": "r%d" % i})
		for view in ["revenge", "targets"]:
			tab.set("_data", {"revenge": revenge, "targets": []})
			tab.set("_view", view)
			tab.call("_apply_tabs")
			var bubble: Control = (strip.get("_bubbles") as Dictionary).get("revenge")
			var shown := bubble != null and bubble.visible
			if waiting == 0 and shown:
				_fail("with none waiting, REVENGE wears a bubble (%s lit)" % view)
			if waiting > 0 and (not shown or (bubble.get_meta("count") as Label).text != str(waiting)):
				_fail("with %d waiting, REVENGE does not say so (%s lit)" % [waiting, view])
	host.queue_free()
	await process_frame


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
