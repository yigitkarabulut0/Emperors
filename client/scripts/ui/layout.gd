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
	return out


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
			return UI.image(str(p.get("asset", "")), r)
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
			var img := UI.image(str(p.get("asset", "")), Rect2(Vector2.ZERO, r.size))
			wrap.add_child(img)
			wrap.set_meta("full", r.size)
			wrap.set_meta("img", img)
			set_fill(wrap, float(p.get("ratio", 1.0)))
			return wrap
		"text":
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
				# Godot's default leading is ~1.25 em; the layouts record the painting's.
				l.label_settings.line_spacing = int(p.get("size", 24)) * (float(p["line_height"]) - 1.25)
			UI.place(l, r)
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
				var hs := UI.hotspot(r)
				hs.set_meta("action", str(p.get("action", "")))
				return hs
			var b := UI.tex_button(asset, r)
			b.set_meta("action", str(p.get("action", "")))
			return b
		"hotspot":
			var h := UI.hotspot(r)
			h.set_meta("action", str(p.get("action", "")))
			return h
		"scroll":
			var sc := ScrollContainer.new()
			UI.place(sc, r)
			sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
			sc.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
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
