extends SceneTree
## The four ceremonies wear the painted sheet, say everything they were given,
## and keep all of it on the phone.
##
## A level-up and a mastery were a title in type over the battle's burst; a
## purchase delivered and a section opened had no moment at all. Now each is
## the sheet's emblem over its light (art/reference/ceremony_sheet.png), its
## figures in the frame and on the plate, and the painted CONTINUE. What must
## hold, for the hard cases -- level 60 with five rows and points to spend, the
## shortest and the longest job names, a purchase of five lines with the first
## purchase doubled and a Royal Favour level reached, the kingdom and the
## treasury opening -- on both canvases, with and without a Dynamic Island:
##  - every piece is drawn, and none larger than it was painted;
##  - the level, the job, the purchase's title and every one of its lines are
##    on the screen, each in a box its words fit;
##  - nothing leaves the screen or goes under the notch, and CONTINUE takes a
##    thumb;
##  - a ceremony waiting for another plays after it, and a delivery that
##    granted nothing plays no ceremony.
##
## Run: godot --headless --path client --script tests/ceremonies.gd

const CANVASES := [Vector2i(941, 1672), Vector2i(941, 2040)]
const INSETS := [0.0, 141.0]
const LINES := [
	{"kind": "diamonds", "amount": 1200, "text": "1,200 diamonds", "icon": "diamond"},
	{"kind": "gold", "amount": 2500000, "text": "2,500,000 gold", "icon": "gold"},
	{"kind": "energy_potion", "amount": 5, "text": "5 energy potions", "icon": "energy_potion"},
	{"kind": "boost", "amount": 1, "text": "Double gold from every collect for 24 hours", "icon": "boost:collect"},
	{"kind": "cosmetic", "amount": 1, "text": "The Lion crest", "icon": "icons/crest_lion"}]

## Deliveries as the server writes them (POST /v1/iap/apple/verify on the
## local API): a pack, the Founder's Crate, Crown Patronage.
const PACK := [{"kind": "diamonds", "amount": 1400, "text": "1,400 diamonds", "icon": "diamond"}]
const CRATE := [
	{"kind": "diamonds", "amount": 300, "text": "300 diamonds", "icon": "diamond"},
	{"kind": "token", "id": "energy_potion", "amount": 3, "text": "3 Energy Potions", "icon": "energy_potion"},
	{"kind": "cosmetic", "id": "frame_founder", "amount": 1, "text": "Founder's Frame (frame)", "icon": "frames/founder"},
	{"kind": "cosmetic", "id": "title_founder", "amount": 1, "text": "The Founder (title)", "icon": "title:title_founder"}]
const PATRONAGE := [
	{"kind": "diamonds", "amount": 60, "text": "60 diamonds", "icon": "diamond"},
	{"kind": "patronage", "amount": 1, "text": "Crown Patronage: 1 free refill each day, +25 bag slots, the Steward", "icon": "patronage"},
	{"kind": "patronage", "id": "frame_patron", "amount": 1, "text": "Patron's Frame and Patron's Gold name colour, while it lasts",
		"icon": "frames/patron", "color": "#E8C46A"}]
## Every other kind a purchase can bring that has a large picture, five at once.
const FINERY := [
	{"kind": "cosmetic", "id": "color_rose", "amount": 1, "text": "Rose (name color)", "icon": "name_color:color_rose", "color": "#F08A8E"},
	{"kind": "cosmetic", "id": "crest_dragon", "amount": 1, "text": "Dragon (crest)", "icon": "icons/crest_dragon"},
	{"kind": "token", "id": "shield_8h", "amount": 2, "text": "2 Protection Charters", "icon": "city_shield"},
	{"kind": "steward", "amount": 1, "text": "The Steward now keeps your house", "icon": "steward"},
	{"kind": "largesse", "amount": 20, "text": "and 20 diamonds to every lord of your kingdom", "icon": "largesse"}]
## A line with a large painting of its own is drawn at least this large.
const LARGE_MIN := 96.0

var _fails := 0
var _checked := 0


func _initialize() -> void:
	await process_frame
	var script: GDScript = load("res://scenes/pages/ceremony.gd")
	for m in ["level_up", "mastery", "delivery", "new_lands"]:
		if not script.has_method(m):
			print("FAIL  the ceremony has no %s" % m)
			quit(1)
			return
	var cases := {
		"level 60": [{"kind": "level", "level": 60, "levels": 1, "points": 5, "gems": 10,
			"unlocked": ["fight", "house"]}, ["ceremony/level_crest", "ceremony/sunburst", "ceremony/frame",
			"ceremony/plate", "ceremony/continue"], ["60", "+5 stat points to spend", "+10 diamonds",
			"Energy refilled", "ATTACK is open", "KINGDOM is open", "SPEND THE POINTS"]],
		"a 16-letter job": [{"kind": "mastery", "job": {"id": "orchard", "name": "Tend the Orchard"},
			"collects": 250, "bonus_bp": 2000, "art": "collect/job_orchard"},
			["ceremony/mastery_banner", "ceremony/coin_burst", "ceremony/frame", "ceremony/plate",
			"ceremony/continue", "collect/job_orchard"], ["TEND THE ORCHARD", "250 collects",
			"+20% gold on every one, for good"]],
		"the longest job": [{"kind": "mastery", "job": {"id": "dragon_hoard", "name": "Plunder the Dragon's Hoard"},
			"collects": 1000, "bonus_bp": 1250, "art": "collect/job_dragon_hoard"},
			["ceremony/mastery_banner", "ceremony/plate"], ["PLUNDER THE DRAGON'S HOARD", "1,000 collects",
			"+12.5% gold on every one, for good"]],
		"a delivery of five": [{"kind": "delivery", "delivery": {"title": "Chest of the Realm", "lines": LINES,
			"first_bonus": true, "vip_reached": 3}}, ["ceremony/delivery_chest", "ceremony/coin_burst",
			"ceremony/frame", "ceremony/plate", "ceremony/continue"], ["CHEST OF THE REALM", "1,200 diamonds",
			"2,500,000 gold", "5 energy potions", "Double gold from every collect for 24 hours",
			"The Lion crest", "First purchase: everything doubled", "Royal Favour 3 reached"]],
		"a pack": [{"kind": "delivery", "delivery": {"title": "700 Diamonds", "lines": PACK, "first_bonus": true,
			"vip_reached": 4}}, ["ceremony/delivery_chest", "store/vessel_700"], ["700 DIAMONDS", "1,400 diamonds",
			"First purchase: everything doubled", "Royal Favour 4 reached"]],
		"the founder's crate": [{"kind": "delivery", "delivery": {"title": "The Founder's Crate", "lines": CRATE}},
			["store/vessel_60", "store/tile_potions", "frames/founder_square", "rewards/title_scroll"],
			["THE FOUNDER'S CRATE", "300 diamonds", "3 Energy Potions", "Founder's Frame (frame)", "The Founder (title)"]],
		"the patronage": [{"kind": "delivery", "delivery": {"title": "Crown Patronage", "lines": PATRONAGE,
			"vip_reached": 3}}, ["store/vessel_60", "rewards/patronage", "frames/patron_square"],
			["CROWN PATRONAGE", "60 diamonds", "Royal Favour 3 reached"]],
		"five pieces of finery": [{"kind": "delivery", "delivery": {"title": "The Royal Wardrobe", "lines": FINERY,
			"first_bonus": true, "vip_reached": 5}}, ["icons/crest_dragon", "rewards/charter", "rewards/steward",
			"rewards/largesse"], ["THE ROYAL WARDROBE", "2 Protection Charters", "Royal Favour 5 reached"]],
		"the kingdom opens": [{"kind": "lands", "section": "house", "title": ""}, ["ceremony/new_lands",
			"ceremony/sunburst", "ceremony/frame", "ceremony/plate", "ceremony/continue", "nav/kingdom"],
			["KINGDOM", "Waiting for you on the rail."]],
		"the treasury opens": [{"kind": "lands", "section": "bank", "title": ""}, ["ceremony/new_lands",
			"icons/city_shield"], ["THE TREASURY", "Waiting for you on the Family tab."]],
	}
	for canvas in CANVASES:
		for inset in INSETS:
			for what in cases:
				var cfg: Dictionary = cases[what][0].duplicate(true)
				cfg["inset"] = inset
				await _check("%s, %dx%d, inset %d" % [what, canvas.x, canvas.y, int(inset)], canvas, inset,
					cfg, cases[what][1], cases[what][2])
	await _check_queue(script)
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  %d ceremonies wear the sheet, say it all and keep it on the phone" % _checked)
	quit()


func _fail(msg: String) -> void:
	_fails += 1
	print("  FAIL  " + msg)


func _host(canvas: Vector2i) -> SubViewport:
	var vp := SubViewport.new()
	vp.size = canvas
	root.add_child(vp)
	root.get_node("Nav").set("host", vp)
	return vp


func _check(what: String, canvas: Vector2i, inset: float, cfg: Dictionary, pieces: Array, words: Array) -> void:
	var vp := _host(canvas)
	var c: CanvasLayer = (load("res://scenes/pages/ceremony.gd") as GDScript).new()
	c.set("_cfg", cfg)
	vp.add_child(c)
	for i in 4:
		await process_frame
	var r: Control = c.get("_root")
	if r == null:
		_fail("%s: nothing was built" % what)
		vp.queue_free()
		return
	_checked += 1
	var drawn := {}
	var texts := []
	var W := float(canvas.x)
	var H := float(canvas.y)
	for n in _all(r):
		var ctl := n as Control
		# The ceremony's own full-screen holder and its dimmed ground cover
		# the screen by design.
		if ctl == null or ctl == r or not ctl.is_visible_in_tree() or ctl is ColorRect:
			continue
		var tex: Texture2D = null
		if ctl is TextureRect:
			tex = (ctl as TextureRect).texture
		elif ctl is NinePatchRect:
			tex = (ctl as NinePatchRect).texture
		elif ctl is TextureButton:
			tex = (ctl as TextureButton).texture_normal
		var key := ""
		if tex != null and tex.resource_path != "":
			key = tex.resource_path.replace("res://assets/", "").replace(".png", "")
			drawn[key] = true
		var rect := Rect2(ctl.global_position, ctl.size)
		# The light behind an emblem may reach under the notch; nothing else may.
		var top := 0.0 if ctl.name == "Glow" else inset
		if rect.position.x < -0.5 or rect.end.x > W + 0.5 or rect.position.y < top - 0.5 or rect.end.y > H + 0.5:
			# A clipped painting inside its frame is judged by its clip.
			if not (ctl.get_parent() is Control and (ctl.get_parent() as Control).clip_contents):
				_fail("%s: %s (%s) is at %s, off the %dx%d screen below %d" % [what, ctl.name, key, rect,
					canvas.x, canvas.y, int(top)])
		# Never drawn larger than painted: a nine-patch keeps its corners, and
		# the plate its height; anything else is at most its own size.
		if key.begins_with("ceremony/") and tex != null:
			var ts := tex.get_size()
			if ctl is NinePatchRect:
				if key == "ceremony/plate" and ctl.size.y > ts.y + 0.5:
					_fail("%s: the plate is drawn %d tall, painted %d" % [what, int(ctl.size.y), int(ts.y)])
			elif ctl.size.x > ts.x + 0.5 or ctl.size.y > ts.y + 0.5:
				_fail("%s: %s is drawn %s, painted %s" % [what, key, ctl.size, ts])
		if ctl is Label:
			var l := ctl as Label
			texts.append(l.text)
			var s := l.label_settings
			var box := float(l.get_meta("box_w", l.size.x))
			if l.autowrap_mode != TextServer.AUTOWRAP_OFF:
				# A tile's words wrap: its lines must fit the box's width and height.
				var m := s.font.get_multiline_string_size(l.text, HORIZONTAL_ALIGNMENT_LEFT, box, s.font_size)
				if m.x > box + 1.0 or m.y > l.size.y + 2.0:
					_fail("%s: \"%s\" wraps to %s in a %dx%d box" % [what, l.text, m, int(box), int(l.size.y)])
			else:
				var w := s.font.get_string_size(l.text, HORIZONTAL_ALIGNMENT_LEFT, -1, s.font_size).x
				if w > box + 1.0:
					_fail("%s: \"%s\" is %d wide in a %d box" % [what, l.text, int(w), int(box)])
		if ctl.name == "Continue" and ctl.size.y < 96.0:
			_fail("%s: CONTINUE is %d tall, under a thumb" % [what, int(ctl.size.y)])
	# The pieces of the plate button are drawn by its stylebox.
	for b in _all(r):
		if b is Button and not (b is TextureButton):
			var sb := (b as Button).get_theme_stylebox("normal") as StyleBoxTexture
			if sb != null and sb.texture != null:
				drawn[sb.texture.resource_path.replace("res://assets/", "").replace(".png", "")] = true
	# Frames are drawn by FramedFace, whose pieces are TextureRects too.
	for p in pieces:
		if not drawn.has(p):
			_fail("%s: %s is not drawn" % [what, p])
	if str(cfg.get("kind", "")) == "delivery":
		_check_tiles(what, r, cfg.get("delivery", {}).get("lines", []))
	for w in words:
		if not w in texts:
			_fail("%s: \"%s\" is not on the screen (%s)" % [what, w, str(texts)])
	vp.queue_free()
	await process_frame


## Each line of a delivery with a large painting of its own is drawn at
## LARGE_MIN or more, and drawn down, never up; a frame round a face.
func _check_tiles(what: String, r: Control, lines: Array) -> void:
	var tiles: Control = null
	for n in _all(r):
		if n is Control and (n as Control).name == "Tiles":
			tiles = n
	if tiles == null:
		_fail("%s: the delivery's lines are not drawn as tiles" % what)
		return
	for i in lines.size():
		var key := str(lines[i].get("icon", ""))
		var large := key in ["diamond", "energy_potion", "city_shield", "steward", "quartermaster", "largesse",
			"patronage", "stipend"] or key.begins_with("frames/") or key.begins_with("icons/crest_") \
			or key.begins_with("name_color:") or key.begins_with("title:")
		var slot := tiles.get_node_or_null("Art%d" % i) as TextureRect
		if slot == null:
			_fail("%s: line %d has no picture" % [what, i])
			continue
		var pic: TextureRect = slot
		if not slot.visible:
			# A frame: FramedFace beside the slot, its frame and the lord's face.
			pic = null
			var face: TextureRect = null
			for sib in tiles.get_children():
				if sib is Control and (sib as Control).position == slot.position and sib != slot:
					for k in sib.get_children():
						if k.has_meta("framed_frame"):
							pic = k
						if k.has_meta("framed_face"):
							face = k
			if pic == null or face == null or face.texture == null:
				_fail("%s: the frame in line %d is not drawn round a face" % [what, i])
				continue
		if pic.texture == null:
			_fail("%s: line %d draws nothing" % [what, i])
			continue
		var src := pic.texture.get_size()
		var drawn := src
		if pic.stretch_mode == TextureRect.STRETCH_KEEP_ASPECT_CENTERED:
			drawn = src * minf(pic.size.x / src.x, pic.size.y / src.y)
		elif pic.stretch_mode == TextureRect.STRETCH_SCALE:
			drawn = pic.size
		_checked += 1
		if drawn.x > src.x + 0.5 or drawn.y > src.y + 0.5:
			_fail("%s: \"%s\" is drawn %s, up from %s" % [what, lines[i]["text"], drawn, src])
		if large and maxf(drawn.x, drawn.y) < LARGE_MIN:
			_fail("%s: \"%s\" is drawn %s, under %d (%s)" % [what, lines[i]["text"], drawn, int(LARGE_MIN),
				pic.texture.resource_path])


## A ceremony that comes while another is up waits for it; a delivery that
## granted nothing never comes.
func _check_queue(script: GDScript) -> void:
	var vp := _host(Vector2i(941, 1672))
	script.delivery(vp, {"title": "Handful of Diamonds", "lines": [LINES[0]], "already": true})
	script.delivery(vp, {"title": "Handful of Diamonds", "lines": [LINES[0]], "revoked": true})
	script.delivery(vp, {"title": "Nothing", "lines": []})
	await process_frame
	if _layers(vp) != 0:
		_fail("a delivery that granted nothing played a ceremony")
	script.level_up({"level": 12, "levels": 1, "points": 0, "gems": 0, "unlocked": []})
	script.delivery(vp, {"title": "Handful of Diamonds", "lines": [LINES[0]]})
	script.new_lands(vp, "fight", "")
	await process_frame
	_checked += 1
	var shown := _layers(vp)
	if shown != 1:
		_fail("%d ceremonies are up at once, want 1" % shown)
	var order := []
	for i in 3:
		var c := _top_layer(vp)
		if c == null:
			_fail("the queue stopped after %s" % str(order))
			break
		order.append(str(c.get("_cfg").get("kind")))
		c.call("_close")
		# The fade out takes 0.18 s; the next waits for it.
		await create_timer(0.4).timeout
		await process_frame
	if order != ["level", "delivery", "lands"]:
		_fail("the ceremonies played as %s, want level, delivery, lands" % str(order))
	vp.queue_free()
	await process_frame


func _layers(vp: Node) -> int:
	var n := 0
	for c in vp.get_children():
		if c is CanvasLayer and not c.is_queued_for_deletion():
			n += 1
	return n


func _top_layer(vp: Node) -> CanvasLayer:
	for c in vp.get_children():
		if c is CanvasLayer and not c.is_queued_for_deletion():
			return c
	return null


func _all(n: Node) -> Array:
	var out := [n]
	for c in n.get_children():
		out.append_array(_all(c))
	return out
