class_name Look
extends RefCounted
## How a lord looks to everyone else, drawn the same wherever another lord
## appears: a rival card, a revenge card, the kingdom's lords, the rankings, a
## battle report.
##
## The server embeds a Look in every view of another lord
## (server/internal/service/look.go, cosmetics.go):
##   worn: {frame?, title?, color?, crest?}   what they wear, resolved
##   vip_seal: bool                            Royal Favour's seal, no level
## and this is the one place that reads it:
##   - the name in the colour they wear (paint_name), with the seal beside it
##     when they have one -- the wax seal (icons/vip_seal), drawn down to the
##     name's type, never up;
##   - the title they wear, on whatever line a surface keeps under the name
##     (paint_title);
##   - the frame they wear over their portrait (paint_frame): `<art>_square`
##     on a square portrait, `<art>_ring` on a round window -- or the large ring
##     where a window is wider than the ring was cut -- sized so its band
##     covers the portrait's own frame, and never drawn up;
##   - the crest they wear, or the one the id picks (crest).
## A surface calls these with its own boxes; nothing else draws a look.

const SEAL := "icons/vip_seal"
## A seal is this many times as tall as the name's type -- level with its
## capitals and a little over -- and sits this far from the words.
const SEAL_PER_SIZE := 1.2
const SEAL_GAP := 8.0
## The plain bands the frames were cut to, outer size: a square's 160 and a
## ring's 96 (art/slices/frames_cosmetic_a.json), the large rings' 132
## (art/slices/looks.json). A frame is scaled so its band covers the portrait's
## frame, and at most to 1.
const SQUARE_BAND := 160.0
const RING_BAND := 96.0
const LARGE_RING_BAND := 132.0


## The asker's own look, as the others see it: their snapshot's player keeps
## what they wear under `worn`, the key every other lord's view uses.
static func mine() -> Dictionary:
	var p: Dictionary = GameState.player()
	var w: Variant = p.get("worn", {})
	return {"worn": w if w is Dictionary else {}, "vip_seal": bool(p.get("vip_seal", false))}


## What a view says the lord wears; empty when it says nothing.
static func worn(d: Dictionary) -> Dictionary:
	var w: Variant = d.get("worn", null)
	return w if w is Dictionary else {}


## Whether the lord has Royal Favour's seal.
static func sealed(d: Dictionary) -> bool:
	return bool(d.get("vip_seal", false))


## The name's colour: the one they wear, else `fallback`.
static func colour(d: Dictionary, fallback: Color) -> Color:
	var hex := str(worn(d).get("color", ""))
	return Color(hex) if hex != "" and Color.html_is_valid(hex) else fallback


## The words they wear under their name; "" for none.
static func title(d: Dictionary) -> String:
	return str(worn(d).get("title", ""))


## The crest they wear, or -- when they wear none -- the one of the twelve
## their id picks (Art.crest), so a lord keeps a crest either way.
static func crest(d: Dictionary, key: String) -> String:
	var art := str(worn(d).get("crest", ""))
	return art if art != "" and Art.has(art) else Art.crest(key)


## Puts crest `key` in the crest box `t`: drawn down to fit, never up, centred.
## The twelve crests_sheet shields and the Crown of Constancy are cut 182x240 and
## every box was sized for them; a crest cut smaller (the Constancy was 61x79
## before its own painting) was stretched three times over into a blur. Every
## screen that shows a crest -- a rival's card, the profile, the wardrobe, the
## hall -- puts it here, so one crest is drawn the same way everywhere.
static func paint_crest(t: TextureRect, key: String) -> void:
	t.texture = Art.tex(key)
	var ts := t.texture.get_size() if t.texture != null else Vector2.ZERO
	t.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	t.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED if ts.x <= t.size.x and ts.y <= t.size.y \
		else TextureRect.STRETCH_KEEP_ASPECT_CENTERED


## The size a crest box draws its crest at (paint_crest's rule, and what any
## other stretch would do), for the tests that hold every box to it.
static func crest_drawn(t: TextureRect) -> Vector2:
	if t.texture == null:
		return Vector2.ZERO
	var ts := t.texture.get_size()
	match t.stretch_mode:
		TextureRect.STRETCH_KEEP_CENTERED, TextureRect.STRETCH_KEEP, TextureRect.STRETCH_TILE:
			return ts
		TextureRect.STRETCH_KEEP_ASPECT, TextureRect.STRETCH_KEEP_ASPECT_CENTERED:
			return ts * minf(t.size.x / ts.x, t.size.y / ts.y)
		TextureRect.STRETCH_KEEP_ASPECT_COVERED:
			return ts * maxf(t.size.x / ts.x, t.size.y / ts.y)
	return t.size


## The worn frame's crop for a portrait whose frame band is `band` across:
## "square" or "ring" (the large ring past the small one's band). "" for none.
static func frame_art(d: Dictionary, shape: String, band: float) -> String:
	var art := str(worn(d).get("frame", ""))
	if art == "":
		return ""
	if shape == "ring" and band > RING_BAND:
		var large := "looks/%s_ring_large" % art.get_file()
		if Art.has(large):
			return large
	var key := "%s_%s" % [art, shape]
	return key if Art.has(key) else ""


## The band a frame crop was cut to.
static func band_of(key: String) -> float:
	if key.ends_with("_ring_large"):
		return LARGE_RING_BAND
	if key.ends_with("_ring"):
		return RING_BAND
	return SQUARE_BAND


## A lord's name on `l`, in `box` (in l's parent): their colour -- else the
## label's own, `fallback` when given -- the words shrunk from `max_size`
## toward `min_size` to fit what the seal leaves, cut with an ellipsis only past
## that, and the seal beside them when they have one, level with the words (a
## little taller than the line, as a seal is). `at_end` puts the seal at the
## box's right end (a plate) rather than right after the words. The label is
## held to its words, so the seal is beside them, not under the label's box; a
## centred one keeps name and seal centred together.
static func paint_name(l: Label, d: Dictionary, text: String, box: Rect2, max_size: int,
		min_size: int = 14, fallback: Variant = null, at_end: bool = false) -> TextureRect:
	if not l.has_meta("look_plain"):
		l.set_meta("look_plain", l.label_settings.font_color)
	var plain: Color = fallback if fallback is Color else l.get_meta("look_plain")
	l.label_settings.font_color = colour(d, plain)
	var seal := _seal_of(l)
	var on := sealed(d)
	var seal_h := roundf(float(max_size) * SEAL_PER_SIZE)
	var seal_w := roundf(seal_h * 120.0 / 116.0)
	var room := box.size.x - (seal_w + SEAL_GAP if on else 0.0)
	l.text = text
	l.set_meta("box_w", room)
	UI.place(l, Rect2(box.position, Vector2(room, box.size.y)))
	UI.fit_line(l, max_size, min_size)
	var f: Font = l.label_settings.font
	var words := minf(f.get_string_size(l.text, HORIZONTAL_ALIGNMENT_LEFT, -1, l.label_settings.font_size).x, room)
	var start := box.position.x
	if l.horizontal_alignment == HORIZONTAL_ALIGNMENT_CENTER:
		start += (box.size.x - words - (SEAL_GAP + seal_w if on else 0.0)) / 2.0
	elif l.horizontal_alignment == HORIZONTAL_ALIGNMENT_RIGHT:
		start = box.end.x - words - (SEAL_GAP + seal_w if on else 0.0)
	if on:
		l.position.x = start
		l.size.x = words + 1.0
		l.set_meta("box_w", words + 1.0)
	seal.visible = on
	if on:
		var x := box.end.x - seal_w if at_end else start + words + SEAL_GAP
		UI.place(seal, Rect2(x, box.position.y + (box.size.y - seal_h) / 2.0, seal_w, seal_h))
	return seal


## The title they wear on `l`, in `box`, shrunk to fit; hidden when they wear
## none.
static func paint_title(l: Label, d: Dictionary, box: Rect2, max_size: int, min_size: int = 13) -> void:
	var t := title(d)
	l.visible = t != ""
	if t == "":
		return
	l.text = t
	l.set_meta("box_w", box.size.x)
	UI.place(l, box)
	UI.fit_line(l, max_size, min_size)


## The frame they wear over `portrait` (a square or a round window), its band
## `band` across on the portrait's centre, drawn down to fit and never up. The
## frame is the portrait's own sibling, just above it; hidden when none is worn.
static func paint_frame(portrait: Control, d: Dictionary, shape: String, band: float) -> TextureRect:
	var ring: TextureRect = portrait.get_meta("look_frame") if portrait.has_meta("look_frame") else null
	if ring == null or not is_instance_valid(ring):
		ring = TextureRect.new()
		ring.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		ring.stretch_mode = TextureRect.STRETCH_SCALE
		ring.mouse_filter = Control.MOUSE_FILTER_IGNORE
		ring.set_meta("look", "frame")
		portrait.get_parent().add_child(ring)
		portrait.get_parent().move_child(ring, portrait.get_index() + 1)
		portrait.set_meta("look_frame", ring)
	var key := frame_art(d, shape, band)
	ring.visible = key != ""
	if key == "":
		return ring
	ring.texture = Art.tex(key)
	var s := minf(1.0, band / band_of(key))
	var sz := ring.texture.get_size() * s
	var c := portrait.position + portrait.size / 2.0
	UI.place(ring, Rect2(c - sz / 2.0, sz))
	ring.set_meta("look_scale", s)
	return ring


## The seal kept beside a name label: made once, as the label's sibling.
static func _seal_of(l: Label) -> TextureRect:
	var seal: TextureRect = l.get_meta("look_seal") if l.has_meta("look_seal") else null
	if seal == null or not is_instance_valid(seal):
		seal = UI.image(SEAL, Rect2())
		seal.set_meta("look", "seal")
		l.get_parent().add_child(seal)
		l.set_meta("look_seal", seal)
	return seal
