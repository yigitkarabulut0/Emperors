extends SceneTree
## A word no painted plate carries is set in type on the plates with no word.
##
## The rankings' week and season boards are RAIDS, EXPERIENCE, RENOWN and the
## season's MIGHT, and tabs_sheet has no plate for the first three: the strip
## drew no texture and no word at all. Now a strip that needs one sets every
## word of it in type (a painted plate beside a set one reads as two hands) on
## tabs/blank or tabs/short_blank -- the painted plates with their word lifted
## (art/slices/tabs_blank.json) -- in the paintings' ivory Cinzel at the painted
## words' cap height.
##
## What must hold:
##  - the choice: a strip with a word no plate carries sets its words; one
##    whose words are all painted draws its plates, as before; three or more set
##    take the short plate;
##  - the blank plates carry no word (their word band holds no ivory ink), and
##    are their painted twins' size;
##  - a set strip's plates are the blanks, lit and unlit as painted; each wears
##    its word, centred, the painted words' cap height, inside its plate;
##  - lighting swaps the plate and keeps the word; a tab that is off dims it.
##
## Run: godot --headless --path client --script tests/typeset_tabs.gd

var _fails := 0
var _checked := 0


func _initialize() -> void:
	await process_frame
	var TS: GDScript = load("res://scripts/ui/tab_strip.gd")
	var art: Node = root.get_node("Art")
	# The choice.
	var cases := [
		[["raids", "experience"], true, false, "the week's two"],
		[["renown", "raids", "experience", "might"], true, true, "the season's four"],
		[["might", "level", "wealth"], false, false, "the standing three, painted"],
		[["realm", "lords", "works", "ranks"], false, true, "the Kingdom's four, painted short"],
		[["revenge", "targets"], false, false, "a painted two"],
	]
	for c in cases:
		_checked += 1
		_expect(bool(TS.call("typeset", c[0])) == bool(c[1]), "%s: set in type is %s" % [c[3], not c[1]])
		_expect(bool(TS.call("takes_short", c[0])) == bool(c[2]), "%s: the short plates %s" % [c[3], "missed" if c[2] else "taken"])
	# The blank plates: their twins' size, and no word.
	for pair in [["tabs/blank", "tabs/level"], ["tabs/blank_lit", "tabs/level_lit"],
			["tabs/short_blank", "tabs/short_all"], ["tabs/short_blank_lit", "tabs/short_all_lit"]]:
		_checked += 1
		var blank: Texture2D = art.call("tex", pair[0])
		var twin: Texture2D = art.call("tex", pair[1])
		if blank == null:
			_expect(false, "%s is not cut" % pair[0])
			continue
		_expect(blank.get_size() == twin.get_size(), "%s is %s, its plate %s" % [pair[0], blank.get_size(), twin.get_size()])
		_expect(_word_ink(blank) == 0, "%s still carries %d pixels of a word" % [pair[0], _word_ink(blank)])
		_expect(_word_ink(twin) > 200, "the word finder finds no word on %s" % pair[1])
	# A set strip, as the rankings' week row stands.
	var rect := Rect2(213, 312, 514, 60)
	var s: Control = TS.call("make", ["raids", "experience"], rect, "raids")
	root.add_child(s)
	await process_frame
	_expect(bool(s.get("set_in_type")), "the week's strip does not set its words")
	for id in ["raids", "experience"]:
		_checked += 1
		var p: TextureRect = s.call("plate", id)
		var want := "tabs/blank" + ("_lit" if id == "raids" else "")
		_expect(p != null and p.texture != null and p.texture.resource_path.ends_with(want + ".png"),
			"%s wears %s, not %s" % [id, p.texture.resource_path if p and p.texture else "nothing", want])
		var l: Label = s.call("word_label", id)
		if l == null:
			_expect(false, "%s has no word" % id)
			continue
		_expect(l.text == id.to_upper(), "%s reads %s" % [id, l.text])
		var cap := float(l.label_settings.font_size) * float(TS.get("CINZEL_CAP"))
		var want_cap := float(TS.get("WORD_CAP")) * p.size.y
		_expect(absf(cap - want_cap) <= 1.5 or l.label_settings.font_size < roundf(want_cap / float(TS.get("CINZEL_CAP"))),
			"%s's capitals are %.1f, the painted words' %.1f" % [id, cap, want_cap])
		var f: Font = l.label_settings.font
		var drawn := f.get_string_size(l.text, HORIZONTAL_ALIGNMENT_LEFT, -1, l.label_settings.font_size).x
		_expect(drawn <= p.size.x * float(TS.get("WORD_SPAN")) + 0.5, "%s's word (%.0f) runs past its plate's face (%.0f)" % [id, drawn, p.size.x * float(TS.get("WORD_SPAN"))])
		_expect(absf(l.position.x + l.size.x / 2.0 - p.size.x / 2.0) <= 1.0, "%s's word is off its plate's centre" % id)
	# Lighting swaps the plate and keeps the word; off dims both.
	s.call("select", "experience", true)
	_expect((s.call("plate", "experience") as TextureRect).texture.resource_path.ends_with("tabs/blank_lit.png"), "EXPERIENCE did not light")
	_expect((s.call("word_label", "experience") as Label) != null, "lighting EXPERIENCE lost its word")
	s.call("set_enabled", "raids", false)
	_expect((s.call("plate", "raids") as TextureRect).modulate != Color.WHITE, "RAIDS off is not dimmed")
	# The season's four, short, every one set -- MIGHT too, beside the set three.
	var four: Control = TS.call("make", ["renown", "raids", "experience", "might"], Rect2(81, 312, 777, 60), "renown")
	root.add_child(four)
	await process_frame
	_checked += 1
	_expect(bool(four.get("short")) and bool(four.get("set_in_type")), "the season's four are not set on the short plates")
	for id in ["renown", "raids", "experience", "might"]:
		var p: TextureRect = four.call("plate", id)
		_expect(p.texture.resource_path.contains("short_blank"), "%s wears %s" % [id, p.texture.resource_path])
		var l: Label = four.call("word_label", id)
		_expect(l != null and l.text == id.to_upper(), "%s's word is %s" % [id, l.text if l else "missing"])
		if l != null:
			var drawn := l.label_settings.font.get_string_size(l.text, HORIZONTAL_ALIGNMENT_LEFT, -1, l.label_settings.font_size).x
			_expect(drawn <= p.size.x * float(TS.get("WORD_SPAN")) + 0.5, "%s runs past its short plate" % id)
	# A painted strip is untouched: no words set over its plates.
	var painted: Control = TS.call("make", ["might", "level", "wealth"], Rect2(81, 312, 777, 60), "might")
	root.add_child(painted)
	await process_frame
	_expect(not bool(painted.get("set_in_type")) and painted.call("word_label", "might") == null, "the painted strip set a word over MIGHT")
	for n in [s, four, painted]:
		n.queue_free()
	await process_frame
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  %d checks: a word with no plate is set in type on the blank plates, a whole strip at a time" % _checked)
	quit()


## Ivory word pixels in a plate's word band (as tests/tab_strip.gd finds a word).
func _word_ink(t: Texture2D) -> int:
	var img := t.get_image()
	if img.is_compressed():
		img.decompress()
	var w := img.get_width()
	var h := img.get_height()
	var n := 0
	for y in range(14, h - 14):
		for x in range(30, w - 30):
			var c := img.get_pixel(x, y)
			if c.a < 0.5:
				continue
			var hi := maxf(c.r, maxf(c.g, c.b))
			var lo := minf(c.r, minf(c.g, c.b))
			if hi > 0.725 and hi - lo < 0.29:
				n += 1
	return n


func _expect(cond: bool, what: String) -> void:
	if not cond:
		_fails += 1
		print("  FAIL  " + what)
