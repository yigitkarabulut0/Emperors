class_name FramedFace
extends RefCounted
## A frame cosmetic shown as it will be worn: the lord's own face under the
## frame's open window.
##
## A frame on its own, in a reward's tile, is an ornate border round nothing,
## and read as an empty slot. The square frames (frames/<id>_square, art/slices/
## frames_cosmetic_a.json and _b.json) are cut centred on their windows, whose
## windows key clear, at one scale: every square's plain band is 160 across.
## The face fills the window it is drawn under, a little past its edges so the
## band's inner line sits on it: the first sheet's windows are about 116x107 at
## that scale, the second's as wide as 130 and as short as 98, and a face drawn
## 112 square left the ground showing down both sides of those. The same face
## in the same frame, drawn down together to whatever box shows the reward.

## The least a face is drawn, against a square frame at its own scale: the
## wardrobe's 112 in its 160 band, for a frame whose window cannot be read.
const FACE_AT_SCALE := 112.0
## How far past the window's edges the face runs, under the band.
const FACE_OVER := 2.0
const SQUARE := "_square"
## Under this drawn side, the face is the 96 cut: the 236 shrunk that far,
## with no mipmaps, shimmers.
const SMALL_FACE_UNDER := 96.0
## A pixel of the frame is solid from this alpha: the window keyed clear, the
## band's inner shadow partly.
const SOLID := 0.5

## Each square frame's window, read once.
static var _windows := {}


## The square frame for a frame cosmetic's art key (frames/<id>), or "" when
## this build has no picture of it.
static func square_of(art: String) -> String:
	var sq := art + SQUARE
	return sq if art.begins_with("frames/") and Art.has(sq) else ""


## A square frame's window at its own scale: the clear opening round the crop's
## centre (every square is cut centred on its window), read across on the rows
## near the middle and down on the columns a quarter in either side. The face
## is centred on the frame, so what it must cover is twice the farthest the
## opening reaches from that centre each way -- a window a pixel off centre, or
## one an ornament crosses on one side only (the Royal Charter's ribbon), is
## still covered, the face going under the ornament.
static func window_of(square: String) -> Vector2:
	if _windows.has(square):
		return _windows[square]
	var out := Vector2(FACE_AT_SCALE, FACE_AT_SCALE)
	var tex := Art.tex(square)
	var img: Image = tex.get_image() if tex != null else null
	if img != null and not img.is_empty():
		if img.is_compressed():
			img.decompress()
		var w := img.get_width()
		var h := img.get_height()
		var c := Vector2i(w / 2, h / 2)
		var half_x := 0
		for dy in [-h / 10, 0, h / 10]:
			var at := Vector2i(c.x, c.y + dy)
			var reach := maxi(_open(img, at, Vector2i(-1, 0)), _open(img, at, Vector2i(1, 0)))
			# A reading that runs off the crop found no band there.
			if reach < w / 2 - 1:
				half_x = maxi(half_x, reach)
		var half_y := 0
		for dx in [-w / 4, w / 4]:
			var at := Vector2i(c.x + dx, c.y)
			var reach := maxi(_open(img, at, Vector2i(0, -1)), _open(img, at, Vector2i(0, 1)))
			if reach < h / 2 - 1:
				half_y = maxi(half_y, reach)
		if half_x > 4 and half_y > 4:
			out = Vector2(half_x * 2 + 1, half_y * 2 + 1)
	_windows[square] = out
	return out


## Clear pixels from `from` (not counting it) along `step`, to the first solid.
static func _open(img: Image, from: Vector2i, step: Vector2i) -> int:
	var n := 0
	var p := from + step
	while p.x >= 0 and p.y >= 0 and p.x < img.get_width() and p.y < img.get_height():
		if img.get_pixelv(p).a >= SOLID:
			break
		n += 1
		p += step
	return n


## The face's size under a square frame at its own scale: its window, and a
## little past it.
static func face_size(square: String) -> Vector2:
	return window_of(square) + Vector2(FACE_OVER, FACE_OVER) * 2.0


## The frame and the face in `box`, centred, drawn at the scale that fits the
## frame into it -- never up. `avatar` is the portrait id (the lord's own,
## GameState.player().avatar).
static func build(square: String, box: Rect2, avatar: String) -> Control:
	var root := Control.new()
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.position = box.position
	root.size = box.size
	var sz := Art.tex(square).get_size()
	var k := minf(1.0, minf(box.size.x / sz.x, box.size.y / sz.y))
	var centre := box.size / 2.0
	var fs := face_size(square) * k
	var key := Art.avatar_small(avatar) if maxf(fs.x, fs.y) < SMALL_FACE_UNDER else Art.avatar(avatar)
	if not Art.has(key):
		key = Art.avatar(avatar)
	# Covered, not fitted: a window wider than it is tall shows the face's
	# middle, the square portrait cut above and below.
	var face := UI.image(key, Rect2(centre - fs / 2.0, fs))
	face.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	face.clip_contents = true
	face.set_meta("framed_face", true)
	root.add_child(face)
	var frame := UI.image(square, Rect2(centre - sz * k / 2.0, sz * k))
	frame.set_meta("framed_frame", true)
	root.add_child(frame)
	return root
