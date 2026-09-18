extends SceneTree
## A frame shown as worn fills its window with the lord's face.
##
## FramedFace drew every face 112 square in a 160 band. The first frame sheet's
## windows are about 116x107 at that scale, and the second sheet's (Companion's,
## the Thirtieth, Loyal Vassal, Rising Lord, Heir, the Royal Charter) as wide as
## 130 -- the ground showed in a strip down both sides of the face, in the
## offer tiles, the store's deals and the Royal Delivery alike. The face now
## covers the window it sits under, read off the frame's own crop.
##
## What must hold for every square frame the game has, in a large box and a
## small one: the face is centred on the frame; it reaches past the window's
## clear opening on all four sides (no pixel of the window along its centre
## lines is left uncovered); and it is never drawn larger than the frame.
##
## Run: godot --headless --path client --script tests/framed_face_window.gd

const IDS := ["oak", "laurel", "laurel_gilded", "founder", "patron", "aureole",
	"companion", "thirtieth", "loyal_vassal", "rising_lord", "heir", "charter",
	"noble_knight", "noble_baron", "noble_count", "noble_duke", "noble_prince", "noble_emperor"]

var _fails := 0
var _checked := 0


func _initialize() -> void:
	await process_frame
	var ff: GDScript = load("res://scripts/ui/framed_face.gd")
	var art: Node = root.get_node("Art")
	for id in IDS:
		var square := str(ff.call("square_of", "frames/" + id))
		if square == "":
			_fail("frames/%s has no square crop" % id)
			continue
		var tex: Texture2D = art.call("tex", square)
		var img := tex.get_image()
		if img.is_compressed():
			img.decompress()
		for box in [Rect2(0, 0, 260, 260), Rect2(0, 0, 120, 120)]:
			var root_c: Control = ff.call("build", square, box, "knight")
			var face: TextureRect = null
			var frame: TextureRect = null
			for c in root_c.get_children():
				if c.has_meta("framed_face"):
					face = c
				if c.has_meta("framed_frame"):
					frame = c
			if face == null or frame == null:
				_fail("%s: no face or no frame" % id)
				continue
			_checked += 1
			var k := frame.size.x / float(img.get_width())
			var fc := face.position + face.size / 2.0
			var frc := frame.position + frame.size / 2.0
			if fc.distance_to(frc) > 0.51:
				_fail("%s in %s: the face is %.1f off the frame's centre" % [id, box.size, fc.distance_to(frc)])
			if frame.size.x > img.get_width() + 0.5:
				_fail("%s in %s: the frame is drawn up" % [id, box.size])
			# The window's clear pixels along the centre lines, from the crop.
			var w := img.get_width()
			var h := img.get_height()
			var cx := w / 2
			var cy := h / 2
			var l := cx
			while l > 0 and img.get_pixel(l - 1, cy).a < 0.5:
				l -= 1
			var r := cx
			while r < w - 1 and img.get_pixel(r + 1, cy).a < 0.5:
				r += 1
			var t := cy
			var b := cy
			var qx := cx - w / 4
			while t > 0 and img.get_pixel(qx, t - 1).a < 0.5:
				t -= 1
			while b < h - 1 and img.get_pixel(qx, b + 1).a < 0.5:
				b += 1
			# In the frame's drawn units, relative to its drawn origin.
			var win := Rect2(frame.position + Vector2(l, t) * k, Vector2(r - l + 1, b - t + 1) * k)
			var fr := Rect2(face.position, face.size)
			if not fr.grow(0.5).encloses(win):
				_fail("%s in %s: the face %s leaves the window %s showing" % [id, box.size, fr, win])
	if _checked < IDS.size() * 2:
		_fail("only %d of %d framed faces were built" % [_checked, IDS.size() * 2])
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  %d framed faces fill their frames' windows, centred, never drawn up" % _checked)
	quit()


func _fail(msg: String) -> void:
	_fails += 1
	print("  FAIL  " + msg)
