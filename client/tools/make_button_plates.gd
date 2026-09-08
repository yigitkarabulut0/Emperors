extends SceneTree
## Bakes the word out of each painted button, leaving a plate.
##
## A button in the references is one texture: the plate, its bevel and the word
## are all paint. That fixes its size, because the only way to make it taller is
## to scale the picture -- and scaling a 122x43 button to the 95 units a 44 pt
## tap target needs blows the word up 2.2x with it, soft and far too big.
##
## With the word gone the plate is a nine-patch: corners stay at their painted
## resolution, the middle stretches, and the word is set in type over it at
## whatever size the layout asks for. The button can then be any shape, and it
## is crisp at all of them.
##
## Same method as collect_button_empty: mask the near-white glyphs, grow the
## mask to swallow their shadow, and close the hole by diffusion from the
## gradient around it, so the plate keeps its own shading rather than a flat
## fill.
##
## Run: godot --headless --path client --script tools/make_button_plates.gd

const JOBS := [
	{"src": "inventory/btn_equip", "dst": "inventory/btn_equip_plate", "inset": 8},
	{"src": "inventory/btn_sell", "dst": "inventory/btn_sell_plate", "inset": 8},
	{"src": "shop/buy", "dst": "shop/buy_plate", "inset": 10},
]
const DILATE := 5
const PASSES := 700


func _initialize() -> void:
	for job in JOBS:
		var img := Image.load_from_file("res://assets/%s.png" % job["src"])
		img.convert(Image.FORMAT_RGBAF)
		var w := img.get_width()
		var h := img.get_height()
		var inset: int = job["inset"]
		var inner := Rect2i(inset, inset, w - 2 * inset, h - 2 * inset)
		var mask := _word_mask(img, w, h, inner)
		_inpaint(img, mask, w, h, inner)
		img.convert(Image.FORMAT_RGBA8)
		var err := img.save_png(ProjectSettings.globalize_path("res://assets/%s.png" % job["dst"]))
		print("wrote %s err=%d masked=%d" % [job["dst"], err, _count(mask)])
	quit()


func _word_mask(img: Image, w: int, h: int, inner: Rect2i) -> Array:
	var seed_mask := _blank(w, h)
	for y in range(inner.position.y, inner.end.y):
		for x in range(inner.position.x, inner.end.x):
			var c := img.get_pixel(x, y)
			if minf(minf(c.r, c.g), c.b) > 0.42:
				seed_mask[y][x] = true
	var out := _blank(w, h)
	for y in range(inner.position.y, inner.end.y):
		for x in range(inner.position.x, inner.end.x):
			if not seed_mask[y][x]:
				continue
			for dy in range(-DILATE, DILATE + 1):
				for dx in range(-DILATE, DILATE + 1):
					if inner.has_point(Vector2i(x + dx, y + dy)):
						out[y + dy][x + dx] = true
	return out


func _inpaint(img: Image, mask: Array, w: int, h: int, inner: Rect2i) -> void:
	for _pass in PASSES:
		for y in range(inner.position.y, inner.end.y):
			for x in range(inner.position.x, inner.end.x):
				if not mask[y][x]:
					continue
				var sum := Color(0, 0, 0, 0)
				var n := 0
				for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
					var nx: int = x + d.x
					var ny: int = y + d.y
					if nx < 0 or ny < 0 or nx >= w or ny >= h:
						continue
					sum += img.get_pixel(nx, ny)
					n += 1
				if n > 0:
					var m := sum / float(n)
					m.a = img.get_pixel(x, y).a
					img.set_pixel(x, y, m)


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
