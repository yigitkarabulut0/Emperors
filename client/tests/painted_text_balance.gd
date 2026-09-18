extends SceneTree
## No wrapped words on a painted page end on one word alone when a better break
## exists.
##
## The Treasury's fee note wrapped as "A deposit costs 10%, and the fee is gone
## for good. Taking gold out is" over "free." at both canvases: the wrapped
## fitting shrank the type until the block fit its plate and stopped, and the
## lines fell where a greedy wrap put them. PaintedPage.set_text now evens them
## (UI.balance_lines): the narrowest width that keeps the line count.
##
## Every painted page's wrapped text is set to its painting's own copy (the
## layout's sample) at both canvases: its last line holds as many words as the
## evenest break would give it, at least two where two can be had. And the fee
## note, with the Treasury's own words, is two lines within 30% of each other
## at a size that reads.
##
## Run: godot --headless --path client --script tests/painted_text_balance.gd

const CANVASES := [Vector2(941, 1672), Vector2(941, 2040)]
const NOTE := "A deposit costs 10%, and the fee is gone for good. Taking gold out is free."

var _fails := 0
var _checked := 0


func _initialize() -> void:
	await process_frame
	root.get_node("Env").set("api_base_url", "http://127.0.0.1:9")
	var L: GDScript = load("res://scripts/ui/layout.gd")
	var P: GDScript = load("res://scripts/ui/painted_page.gd")
	for canvas in CANVASES:
		for file in DirAccess.get_files_at("res://layout"):
			if not file.ends_with(".json"):
				continue
			var id := file.get_basename()
			var spec: Dictionary = L.spec(id)
			if not _is_painted(spec):
				continue
			var host := Control.new()
			host.size = canvas
			root.add_child(host)
			var p: Control = P.open(host, id)
			await process_frame
			for e in spec.get("elements", []):
				if e is Dictionary and str(e.get("kind", "")) == "text" and bool(e.get("wrap", false)) \
						and str(e.get("sample", "")) != "":
					var l: Label = p.call("set_text", str(e["id"]), str(e["sample"]), 14)
					_last_line_holds(l, "%s/%s %dx%d" % [id, e["id"], int(canvas.x), int(canvas.y)])
			if id == "treasury":
				_the_fee_note(p.call("set_text", "note", NOTE, 18), canvas)
			p.call("close")
			host.queue_free()
			await process_frame
	if _checked == 0:
		print("FAIL  no painted page's wrapped text was measured")
		quit(1)
		return
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  %d wrapped texts on painted pages end on more than a lone word where they can" % _checked)
	quit()


func _fail(msg: String) -> void:
	_fails += 1
	print("  FAIL  " + msg)


## A layout the painted host builds: its first element is the painting.
func _is_painted(spec: Dictionary) -> bool:
	var els: Array = spec.get("elements", [])
	return not els.is_empty() and els[0] is Dictionary and str(els[0].get("id", "")) == "page" \
		and str(els[0].get("asset", "")).ends_with("/page")


## [line widths, words on the last line] of `text` wrapped at `width`.
func _wrap(text: String, font: Font, size: int, width: float) -> Array:
	var para := TextParagraph.new()
	para.break_flags = TextServer.BREAK_MANDATORY | TextServer.BREAK_WORD_BOUND | TextServer.BREAK_ADAPTIVE
	para.width = width
	para.add_string(text, font, size)
	var widths: Array = []
	for i in para.get_line_count():
		widths.append(para.get_line_width(i))
	var last := 0
	if para.get_line_count() > 0:
		var r := para.get_line_range(para.get_line_count() - 1)
		for w in text.substr(r.x, r.y - r.x).split(" ", false):
			last += 1
	return [widths, last]


func _last_line_holds(l: Label, tag: String) -> void:
	if l == null:
		return
	_checked += 1
	var s := l.label_settings
	var got := _wrap(l.text, s.font, s.font_size, l.size.x)
	if (got[0] as Array).size() < 2:
		return
	# The evenest break at this size: the narrowest box keeping the line count.
	var box := float(l.get_meta("box_w", l.size.x))
	var n := (_wrap(l.text, s.font, s.font_size, box)[0] as Array).size()
	var lo := 1.0
	var hi := box
	while hi - lo > 0.5:
		var mid := (lo + hi) / 2.0
		if (_wrap(l.text, s.font, s.font_size, mid)[0] as Array).size() <= n:
			hi = mid
		else:
			lo = mid
	var best: int = _wrap(l.text, s.font, s.font_size, hi)[1]
	if int(got[1]) < mini(2, best):
		_fail("%s ends on one word alone (\"%s\") where the evenest break keeps %d on its last line"
			% [tag, l.text.get_slice(" ", l.text.get_slice_count(" ") - 1), best])


func _the_fee_note(l: Label, canvas: Vector2) -> void:
	_checked += 1
	var tag := "treasury/note %dx%d" % [int(canvas.x), int(canvas.y)]
	if l == null:
		_fail("%s: the Treasury has no note" % tag)
		return
	var s := l.label_settings
	var widths: Array = _wrap(l.text, s.font, s.font_size, l.size.x)[0]
	if widths.size() > 2:
		_fail("%s runs to %d lines" % [tag, widths.size()])
	if widths.size() == 2 and float(widths.min()) < 0.7 * float(widths.max()):
		_fail("%s's lines are %s wide: not within 30%% of each other" % [tag, str(widths)])
	if s.font_size < 20:
		_fail("%s is set at %d, under a size that reads" % [tag, s.font_size])
	# Inside its plate: the label never grows past the box it was measured into.
	var box_x := float(l.get_meta("box_x", l.position.x))
	var box_w := float(l.get_meta("box_w", l.size.x))
	if l.position.x < box_x - 0.5 or l.position.x + l.size.x > box_x + box_w + 0.5:
		_fail("%s leaves its plate" % tag)
