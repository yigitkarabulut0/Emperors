class_name Layout
extends RefCounted
## Builds a screen from its layout file (client/layout/<screen>.json).
##
## The layout files are measured off the reference paintings, so a screen's code
## never carries a coordinate: it asks for parts by id and fills in the live
## values. Kinds: image, text, button, template, scroll, fill.

static var _specs: Dictionary = {}


static func spec(screen: String) -> Dictionary:
	if _specs.has(screen):
		return _specs[screen]
	var path := "res://layout/%s.json" % screen
	if not FileAccess.file_exists(path):
		push_warning("[layout] no layout file for " + screen)
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	var d: Dictionary = parsed if parsed is Dictionary else {}
	_specs[screen] = d
	return d


static func element(screen: String, id: String) -> Dictionary:
	for e in spec(screen).get("elements", []):
		if str(e.get("id", "")) == id:
			return e
	return {}


## Finds an element or part by id anywhere in the tree (parts, scroll content).
static func find(screen: String, id: String) -> Dictionary:
	return _find_in(spec(screen).get("elements", []), id)


static func _find_in(list: Array, id: String) -> Dictionary:
	for e in list:
		if not (e is Dictionary):
			continue
		if str(e.get("id", "")) == id:
			return e
		for k in ["parts", "content"]:
			if e.has(k):
				var hit := _find_in(e[k], id)
				if not hit.is_empty():
					return hit
	return {}


static func rect_of(e: Dictionary, origin: Vector2 = Vector2.ZERO) -> Rect2:
	var r: Array = e.get("rect", [0, 0, 0, 0])
	return Rect2(origin.x + float(r[0]), origin.y + float(r[1]), float(r[2]), float(r[3]))


## Builds every top-level element into `host`. Returns {id: node} for plain
## elements and {id: [ {node, parts}, ... ]} for templates with instances.
static func build(screen: String, host: Control) -> Dictionary:
	var out := {}
	# A template a scroll region names in its content is a prototype for the
	# screen's own list; its painted instances must not be built as static copies.
	var prototypes := {}
	for e in spec(screen).get("elements", []):
		if str(e.get("kind", "")) == "scroll":
			for c in e.get("content", []):
				if c is String:
					prototypes[c] = true
	for e in spec(screen).get("elements", []):
		var id := str(e.get("id", ""))
		var kind := str(e.get("kind", "image"))
		if kind == "template" and prototypes.has(id):
			out[id] = []
			continue
		if kind == "template":
			# Templates with instances are built in place; templates without are
			# left to the screen (they live inside a scroll region).
			var list: Array = []
			for inst in e.get("instances", []):
				var built := instantiate(e, inst)
				host.add_child(built["node"])
				list.append(built)
			out[id] = list
		else:
			var n := _build_part(e, Vector2.ZERO)
			if n != null:
				host.add_child(n)
				out[id] = n
				if str(e.get("anchor", "")) == "bottom":
					_anchor_bottom(n, rect_of(e))
				elif str(e.get("grow", "")) == "bottom":
					_grow_to_bottom(n, rect_of(e))
	return out


## Keeps a region's top where the painting has it and lets its bottom follow the
## screen's, so a list gets the extra height a tall phone has instead of leaving
## it as ground. The gap it keeps to the design's foot (a pinned footer, usually)
## is the gap it keeps to the screen's.
static func _grow_to_bottom(n: Control, r: Rect2) -> void:
	n.anchor_bottom = 1.0
	n.offset_bottom = r.end.y - 1672.0


## Pins a node to the bottom of a taller-than-design viewport.
static func _anchor_bottom(n: Control, r: Rect2) -> void:
	n.anchor_top = 1.0
	n.anchor_bottom = 1.0
	n.offset_top = -(1672.0 - r.position.y)
	n.offset_bottom = n.offset_top + r.size.y
	n.grow_vertical = Control.GROW_DIRECTION_BEGIN


## One instance of a template: a Control the size of the template with its
## parts built inside. `inst` may be [x, y] or {pos, assets, texts, rects}
## overriding a part's asset, sample text or rect. Returns {node, parts}.
static func instantiate(template: Dictionary, inst: Variant = null) -> Dictionary:
	var r := rect_of(template)
	var root := Control.new()
	root.size = r.size
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var overrides: Dictionary = inst if inst is Dictionary else {}
	var parts := {}
	for p in template.get("parts", []):
		var q: Dictionary = p.duplicate()
		var pid := str(q.get("id", ""))
		if overrides.get("assets", {}).has(pid):
			q["asset"] = overrides["assets"][pid]
		if overrides.get("texts", {}).has(pid):
			q["sample"] = overrides["texts"][pid]
		if overrides.get("rects", {}).has(pid):
			q["rect"] = overrides["rects"][pid]
		var n := _build_part(q, Vector2.ZERO)
		if n == null:
			continue
		root.add_child(n)
		parts[pid] = n
	if inst is Array:
		root.position = Vector2(float(inst[0]), float(inst[1]))
	elif inst is Dictionary:
		var at: Variant = inst.get("pos", inst.get("at", null))
		if at is Array:
			root.position = Vector2(float(at[0]), float(at[1]))
	return {"node": root, "parts": parts, "data": inst.get("data", {}) if inst is Dictionary else {}}


## Builds ONE recorded part on its own, for a screen that draws a piece the
## manifest wrote down but `build` does not reach -- an element's `alt`, say.
## `origin` is added to the part's rect, so a part going INSIDE another node
## passes the negative of that node's own position and lands where the painting
## has it.
static func part(spec: Dictionary, origin: Vector2 = Vector2.ZERO) -> Control:
	return _build_part(spec, origin)


static func _build_part(p: Dictionary, origin: Vector2) -> Control:
	var kind := str(p.get("kind", "image"))
	# The measured layouts write a bar as an image with a "fill" side ("left"),
	# not as kind "fill". Both mean the same thing: a clipped wrap that remembers
	# its full width, so set_fill() can be called on it on every repaint. Built as
	# a plain image it is a TextureRect with nothing to remember that width by,
	# and set_fill() then scales it by the fraction of its *current* width each
	# time -- the bar creeps backwards on every paint while the number beside it
	# stays put.
	if kind == "image" and p.has("fill"):
		kind = "fill"
	var r := rect_of(p, origin)
	var n: Control = _build_kind(p, kind, r)
	if n != null and p.has("parts") and kind != "template" and kind != "group":
		var parts := {}
		for c in p.get("parts", []):
			var child := _build_part(c, Vector2.ZERO)
			if child != null:
				n.add_child(child)
				parts[str(c.get("id", ""))] = child
		n.set_meta("parts", parts)
	return n


static func _build_kind(p: Dictionary, kind: String, r: Rect2) -> Control:
	match kind:
		"image":
			var img := UI.image(str(p.get("asset", "")), r)
			if str(p.get("fit", "")) == "contain":
				# A painting that is not a crop of this box (an item design drawn
				# into a tile) keeps its own proportions and centres in the box.
				img.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			return img
		"ninepatch":
			var np := NinePatchRect.new()
			np.texture = Art.tex(str(p.get("asset", "")))
			UI.place(np, r)
			np.mouse_filter = Control.MOUSE_FILTER_IGNORE
			np.draw_center = bool(p.get("draw_center", true))
			var m: Array = p.get("margin", [10, 10, 10, 10])
			if m.size() == 4:
				np.patch_margin_left = int(m[0]); np.patch_margin_top = int(m[1])
				np.patch_margin_right = int(m[2]); np.patch_margin_bottom = int(m[3])
			return np
		"fill":
			# A bar fill that is clipped from the left (or right) by set_meta("frac").
			var wrap := Control.new()
			UI.place(wrap, r)
			wrap.clip_contents = true
			wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
			var full := r.size
			var img: Control
			if p.has("track"):
				# The painted fill is where the painting's progress happened to
				# stand -- 85% of the Kingdom's level bar, half of its renown bar --
				# and a bar that measured itself by that image stopped there at
				# 100%. A bar with a track runs the whole track: the fill is a
				# nine-patch whose painted ends ("caps", [left, right]) keep their
				# size, so its rounded tip closes the bar at every fraction.
				var tr: Array = p["track"]
				full.x = float(tr[0]) + float(tr[2]) - r.position.x
				var np := NinePatchRect.new()
				np.texture = Art.tex(str(p.get("asset", "")))
				np.mouse_filter = Control.MOUSE_FILTER_IGNORE
				var caps: Array = p.get("caps", [4, 4])
				np.patch_margin_left = int(caps[0])
				np.patch_margin_right = int(caps[1])
				np.size = full
				img = np
			else:
				img = UI.image(str(p.get("asset", "")), Rect2(Vector2.ZERO, r.size))
			wrap.add_child(img)
			wrap.set_meta("full", full)
			wrap.set_meta("img", img)
			set_fill(wrap, float(p.get("ratio", 1.0)))
			return wrap
		"text":
			# A text part starts empty. Its "sample" is the painting's own copy --
			# "Lord Darius", "278,000", "Restore 513 Energy" -- recorded to measure
			# the type by, and it used to be drawn as the text until the server
			# answered: a slow network or a failed request showed the painting's
			# numbers as the player's. Only fixed copy (a button's word) is marked
			# "static" and drawn from the start.
			#
			# The sample is still what the label is measured with, below: the
			# centring works from the leading of real words, not of an empty line.
			var l := UI.label(str(p.get("sample", "")), int(p.get("size", 24)), Color(str(p.get("color", "#F1E9DA"))),
				str(p.get("font", "body")), int(p.get("weight", 500)), _halign(str(p.get("align", "left"))))
			l.vertical_alignment = _valign(str(p.get("valign", "center")))
			if bool(p.get("wrap", false)):
				l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			if bool(p.get("uppercase", false)):
				l.uppercase = true
			if p.has("shadow") and not bool(p["shadow"]):
				l.label_settings.shadow_color = Color(0, 0, 0, 0)
			if p.has("line_height"):
				# The layouts record the painting's own leading, and they record
				# it two ways: as a ratio of the type size (1.05) or as the line
				# height in design units (23). Reading the second as the first
				# put 522 units between the two lines of the Army screen's
				# soldier description, which is a third of the screen.
				#
				# Godot's line_spacing is what is ADDED to the font's own line,
				# so the font's line has to be read with the spacing cleared
				# before the difference can be worked out.
				var want := float(p["line_height"])
				if want < 4.0:
					want *= float(p.get("size", 24))
				l.label_settings.line_spacing = 0.0
				l.label_settings.line_spacing = want - l.get_line_height()
			UI.place(l, r)
			# A Label cannot be shorter than one line of its own type, so a rect
			# recorded tighter than the leading -- which most of them are, being
			# measured off the painting's ink -- makes Godot grow the control
			# downward from the rect's top and the words land low. The Kingdom's
			# bonus values ended up sitting on the labels baked under them, and
			# its ranking number eight units below where the painting has it.
			# Centring the line on the rect's own centre puts the ink back.
			var block := l.get_minimum_size().y
			if block > r.size.y and l.vertical_alignment == VERTICAL_ALIGNMENT_CENTER:
				l.position.y = r.position.y - (block - r.size.y) / 2.0
			if not bool(p.get("static", false)):
				l.text = ""
				# Built around its sample, a Label grows to it and keeps the grown
				# width when emptied (it is not in the tree yet, so it cannot be
				# shrunk back here): every fit measured the words against the
				# sample's width, not the box's -- the Stat Points' NO POINTS TO
				# PLACE ran off its plate. The box is the layout's; fitters read
				# it from "box_w" before the label's own width.
				if r.size.x > 0.0:
					l.set_meta("box_w", r.size.x)
			return l
		"button":
			var asset := str(p.get("asset", ""))
			if asset == "" and p.has("states"):
				# A stateful painted tab: start on whichever state the painting shows.
				var st: Dictionary = p["states"]
				var first: Dictionary = st.get("active", st.get("inactive", {}))
				asset = str(first.get("asset", ""))
			if asset == "" or asset.contains("<") or asset.contains("{"):
				# The painted button is part of a bigger crop: an invisible tap target.
				var hs := UI.hotspot(r, bool(p.get("pass_drag", false)))
				hs.set_meta("action", str(p.get("action", "")))
				return hs
			if p.has("label"):
				# A plate that stretches with the word set in type over it, so
				# the button's size is the layout's decision and not the
				# texture's. See UI.plate_button.
				var pb := UI.plate_button(asset, str(p["label"]), r,
					int(p.get("size", 26)), Color(str(p.get("color", "#F4EFE6"))),
					int(p.get("weight", 600)), int(p.get("margin", 14)))
				pb.set_meta("action", str(p.get("action", "")))
				if p.has("paint_rect"):
					# The rect is the thumb's; the plate is drawn where the
					# painting has it, which may be smaller.
					var pr := rect_of({"rect": p["paint_rect"]})
					if not pr.is_equal_approx(r):
						UI.inset_plate(pb, r, pr)
				return pb
			var b := UI.tex_button(asset, r)
			if bool(p.get("pass_drag", false)):
				b.mouse_filter = Control.MOUSE_FILTER_PASS
			if bool(p.get("keep_texture_size", false)):
				# The rect is the tap target; the texture stays the picture. Every
				# button in the references is painted wide and short -- BUY is
				# 172x58, which on the phone is 27 pt against the 44 pt a thumb
				# needs -- and stretching one to that height stretches the word
				# baked into it. So the control grows and the painting keeps its
				# own size, centred in it.
				b.stretch_mode = TextureButton.STRETCH_KEEP_CENTERED
			b.set_meta("action", str(p.get("action", "")))
			return b
		"hotspot":
			var h := UI.hotspot(r)
			h.set_meta("action", str(p.get("action", "")))
			return h
		"scroll":
			var sc := ScrollContainer.new()
			UI.place(sc, r)
			if str(p.get("axis", "vertical")) == "horizontal":
				# A row too long for the screen: the army's slots run to ten and
				# only the first four were ever drawn.
				sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
				sc.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
			else:
				sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
				sc.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
			# Without a deadzone a drag that starts on a child button never
			# reaches the container, because the button consumes it -- and every
			# row in this game is made of buttons. Each screen used to set this
			# by hand in _ready, which worked until a scroll was added that did
			# not: the army's slot row could be seen and not moved. It belongs
			# here, where a scroll cannot be built without it.
			sc.scroll_deadzone = 14
			var content := Control.new()
			content.custom_minimum_size = r.size
			content.mouse_filter = Control.MOUSE_FILTER_PASS
			sc.add_child(content)
			var parts := {}
			for c in p.get("content", []):
				if c is String or (c is Dictionary and str(c.get("kind", "")) == "template"):
					continue
				var n := _build_part(c, Vector2.ZERO)
				if n != null:
					content.add_child(n)
					parts[str(c.get("id", ""))] = n
			sc.set_meta("parts", parts)
			sc.set_meta("content", content)
			return sc
		"group":
			var g := Control.new()
			UI.place(g, r)
			g.mouse_filter = Control.MOUSE_FILTER_IGNORE
			var parts := {}
			for c in p.get("parts", []):
				var n := _build_part(c, Vector2.ZERO)
				if n != null:
					g.add_child(n)
					parts[str(c.get("id", ""))] = n
			g.set_meta("parts", parts)
			return g
		"template":
			# Nested template. With instances: a wrapper whose meta "instances" lists
			# every built {node, parts}. Without: one instance at its rect.
			if p.has("instances"):
				var wrap := Control.new()
				wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
				var list: Array = []
				for inst in p["instances"]:
					var b := instantiate(p, inst)
					wrap.add_child(b["node"])
					list.append(b)
				wrap.set_meta("instances", list)
				return wrap
			var built := instantiate(p)
			built["node"].position = r.position
			built["node"].set_meta("parts", built["parts"])
			return built["node"]
	return null


static func set_fill(wrap: Control, frac: float) -> void:
	# The full width is fixed on first use. Reading it off the current size would
	# make every call shrink the bar by the fraction of what the last call left.
	if not wrap.has_meta("full"):
		wrap.set_meta("full", wrap.size)
	var full: Vector2 = wrap.get_meta("full")
	var w := full.x * clampf(frac, 0.0, 1.0)
	# A zero-width clip rect does not clip at all, so an empty bar is hidden.
	wrap.visible = w >= 1.0
	wrap.size = Vector2(maxf(w, 1.0), full.y)
	# A nine-patch fill is drawn at the bar's length so its painted tip ends the
	# bar; shorter than its two caps it is drawn at their width and clipped.
	# (get_meta with a null default still reports a missing key as an error: the
	# battle's bars, built by hand, carry no "img".)
	var img: Variant = wrap.get_meta("img") if wrap.has_meta("img") else null
	if img is NinePatchRect:
		var np := img as NinePatchRect
		np.size = Vector2(maxf(w, float(np.patch_margin_left + np.patch_margin_right)), full.y)


static func _halign(a: String) -> int:
	match a:
		"center": return HORIZONTAL_ALIGNMENT_CENTER
		"right": return HORIZONTAL_ALIGNMENT_RIGHT
	return HORIZONTAL_ALIGNMENT_LEFT


static func _valign(a: String) -> int:
	match a:
		"top": return VERTICAL_ALIGNMENT_TOP
		"bottom": return VERTICAL_ALIGNMENT_BOTTOM
	return VERTICAL_ALIGNMENT_CENTER
