extends SceneTree
## Bakes assets/collect/collect_button_empty.png from collect_button.png.
##
## The Collect button's green field, its gold frame and the word COLLECT are one
## painted texture, so a "no energy" face cannot be a tint (modulate multiplies,
## and green times red is nearly black) and must not be an overlay rectangle --
## an inset rectangle leaves the green showing at the chamfered corners and
## reads as a sticker.
##
## So the red face is a real texture, derived from the green one:
##   1. the painted word is masked (near-white pixels) and dilated to swallow
##      its drop shadow;
##   2. the hole is filled by diffusion from the green around it, which
##      reproduces the field's own gradient and vignette rather than a flat
##      colour;
##   3. every green-dominant pixel has its red and green channels swapped, which
##      rotates the hue to crimson while keeping every bit of the original
##      shading, bevel and edge blending. The gold frame (red-dominant) and the
##      background (blue-dominant) are untouched, so the button keeps its exact
##      silhouette.
##
## Run: godot --headless --path client --script tools/make_empty_button.gd

const SRC := "res://assets/collect/collect_button.png"
const DST := "res://assets/collect/collect_button_empty.png"
const INNER := Rect2i(12, 10, 154, 56)  # the green field, clear of the frame
const DILATE := 7                       # enough to cover the word's soft shadow
const PASSES := 900


func _initialize() -> void:
	var img := Image.load_from_file(SRC)
	img.convert(Image.FORMAT_RGBAF)
	var w := img.get_width()
	var h := img.get_height()

	var mask := _word_mask(img, w, h)
	_inpaint(img, mask, w, h)
	_to_crimson(img, w, h)

	img.convert(Image.FORMAT_RGBA8)
	var err := img.save_png(ProjectSettings.globalize_path(DST))
	print("wrote %s err=%d masked=%d" % [DST, err, _count(mask)])
	quit()


## Near-white pixels inside the field, grown by DILATE so the word's dark halo
## goes with it. Anything outside INNER is left alone: the frame is not ours.
func _word_mask(img: Image, w: int, h: int) -> Array:
	var seed_mask := _blank(w, h)
	for y in range(INNER.position.y, INNER.end.y):
		for x in range(INNER.position.x, INNER.end.x):
			var c := img.get_pixel(x, y)
			if minf(minf(c.r, c.g), c.b) > 0.34:
				seed_mask[y][x] = true
	var out := _blank(w, h)
	for y in range(INNER.position.y, INNER.end.y):
		for x in range(INNER.position.x, INNER.end.x):
			if seed_mask[y][x]:
				for dy in range(-DILATE, DILATE + 1):
					for dx in range(-DILATE, DILATE + 1):
						var ny := y + dy
						var nx := x + dx
						if INNER.has_point(Vector2i(nx, ny)):
							out[ny][nx] = true
	return out


## Replaces every masked pixel with the mean of its four neighbours, repeatedly.
## The field is a smooth gradient, so the values diffuse in from its edges and
## the hole closes seamlessly; a flat fill would show as a patch.
func _inpaint(img: Image, mask: Array, w: int, h: int) -> void:
	for _pass in PASSES:
		for y in range(INNER.position.y, INNER.end.y):
			for x in range(INNER.position.x, INNER.end.x):
				if not mask[y][x]:
					continue
				var sum := Color(0, 0, 0, 0)
				var n := 0
				for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
					var nx: int = x + d.x
					var ny: int = y + d.y
					if nx < 0 or ny < 0 or nx >= w or ny >= h:
						continue
					var c := img.get_pixel(nx, ny)
					sum += c
					n += 1
				if n > 0:
					var m := sum / float(n)
					m.a = img.get_pixel(x, y).a
					img.set_pixel(x, y, m)


## Green-dominant pixels become their own mirror image in red. Gold and
## background are red- and blue-dominant, so they pass through untouched.
func _to_crimson(img: Image, w: int, h: int) -> void:
	for y in h:
		for x in w:
			var c := img.get_pixel(x, y)
			if c.a <= 0.004:
				continue
			if c.g > c.r and c.g > c.b:
				img.set_pixel(x, y, Color(c.g, c.r, c.b, c.a))


func _blank(w: int, h: int) -> Array:
	var a: Array = []
	for _y in h:
		var row: Array = []
		row.resize(w)
		row.fill(false)
		a.append(row)
	return a


func _count(mask: Array) -> int:
	var n := 0
	for row in mask:
		for v in row:
			if v:
				n += 1
	return n
