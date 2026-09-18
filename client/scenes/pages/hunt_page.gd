extends RefCounted
## THE HUNT -- where a soldier is sent, and what they might bring back.
##
## Built from the owner's own painting (art/reference/expedition.png, slices
## art/slices/expedition.json, layout client/layout/expedition.json). It was a
## Sheet of text rows for a wave, because the painting sat unused in the design
## pack; this is the page the painting asks for: four roads as painted cards,
## one chosen at a time, and one SEND at the foot.
##
## An expedition costs no energy at all: what it costs is the SOLDIER. Away,
## they do not fight in their lord's own battles and cannot be rerolled,
## dismissed or re-geared -- and they still stand on the walls, because a lord
## cannot choose when they are raided.
##
## Every figure on a card is the server's (GET /v1/hunt?soldier=<id>), already
## resolved for this lord: the gold and the experience a haul is worth at their
## own best job, not the wages the balance is written in. The roll happens at
## the TAP and is frozen, so the range on a card is a promise the server keeps.

const PAGE := "expedition"
## The four roads stand where the painting stands them: its own grid, measured
## off the gold of the frames (pitch 421 across, 526 down).
const CARD_AT := [Vector2(55, 441), Vector2(476, 441), Vector2(55, 967), Vector2(476, 967)]
## Each field's own scene, in the balance's own order.
const SCENES := ["expedition/field_1", "expedition/field_2", "expedition/field_3", "expedition/field_4"]


## Opens the roads for one soldier. `army` is the Army tab, which reloads when
## the page has done something.
static func open(host: Node, army: Node, soldier: Dictionary, view: Dictionary) -> PaintedPage:
	var p := PaintedPage.open(host, PAGE)
	p.set_meta("army", army)
	p.set_meta("soldier", soldier)
	p.set_meta("view", view)
	p.set_meta("chosen", 0)
	p.on("send", func() -> void: _send(p))
	_paint(p)
	return p


static func _view(p: PaintedPage) -> Dictionary:
	return p.get_meta("view", {})


static func _fields(p: PaintedPage) -> Array:
	return _view(p).get("fields", [])


static func _paint(p: PaintedPage) -> void:
	var v := _view(p)
	var soldier: Dictionary = p.get_meta("soldier", {})

	# Who is being sent: their face in the painting's window, their name on its
	# plate, their rank on the little octagon beside it.
	var tier := SoldierArt.tier_of(str(soldier.get("tier", "common")))
	var face := p.node("soldier_face") as TextureRect
	if face != null:
		face.texture = Art.tex(SoldierArt.large(str(soldier.get("type", "peasant")), tier))
		face.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	p.set_text("soldier_name", str(soldier.get("name", "")), 16)
	# The rank's own painted numeral, as the Army's cards wear it, on the
	# painting's little octagon.
	var numeral := p.node("soldier_tier")
	if numeral is Label:
		(numeral as Label).text = ""
	var mark := p.node("soldier_badge") as TextureRect
	if mark != null:
		var pip := TextureRect.new()
		pip.texture = Art.tex(SoldierArt.numeral(tier))
		pip.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		pip.mouse_filter = Control.MOUSE_FILTER_IGNORE
		UI.place(pip, Rect2(0, 0, mark.size.x, mark.size.y))
		for old_pip in mark.get_children():
			old_pip.queue_free()
		mark.add_child(pip)

	# The hunt itself opens at a level (balance/hunt.json: 8), and the Army's
	# HUNT stands on every soldier from the first. Under it the server refuses
	# the send, so the page must say so before the tap: every road wears the
	# painting's padlock and SEND is out.
	var open_at := int(v.get("unlock_level", 0))
	var used := int(v.get("used", 0))
	var slots := int(v.get("slots", 0))
	var line := "%d of %d roads walked" % [used, slots]
	if not _unlocked(p):
		line = "The roads open at level %d" % open_at
	elif int(v.get("next_slot_at", 0)) > 0:
		line += "  ·  one more at level %d" % int(v.get("next_slot_at", 0))
	p.set_text("walked", line, 15)

	_cards(p)
	# SEND is lit only while the roads are open, one is free and one is chosen.
	p.set_enabled("send", _unlocked(p) and used < slots and _chosen(p) != null)


## Whether this lord may send anyone at all. The server says so; the page never
## works it out from the level itself.
static func _unlocked(p: PaintedPage) -> bool:
	return bool(_view(p).get("unlocked", true))


## The road the lord is standing in front of, or null.
static func _chosen(p: PaintedPage) -> Variant:
	var fields := _fields(p)
	var i := int(p.get_meta("chosen", 0))
	return fields[i] if i >= 0 and i < fields.size() else null


static func _cards(p: PaintedPage) -> void:
	for old in p.get_meta("cards", []):
		if is_instance_valid(old):
			(old as Node).queue_free()
	var made: Array = []
	var tpl := Layout.element(PAGE, "card")
	if tpl.is_empty():
		return
	var fields := _fields(p)
	var chosen := int(p.get_meta("chosen", 0))
	for i in mini(fields.size(), CARD_AT.size()):
		var f: Dictionary = fields[i]
		var built := Layout.instantiate(tpl)
		var node: Control = built["node"]
		var parts: Dictionary = built["parts"]
		# `place` puts it on the page itself, under the notch and moving with
		# the page's stretch bands, as every part the layout built does.
		p.place(node, Rect2(CARD_AT[i], node.size))
		# Its parts by id, as every built part of a layout carries them: the
		# page never looks them up, but a test reads the card through them.
		node.set_meta("parts", parts)
		made.append(node)

		# The chosen road wears the painting's own glow -- its own crop, laid
		# over the plain card, reaching exactly the gutter beside it.
		(parts["lit"] as CanvasItem).visible = i == chosen and _unlocked(p)
		(parts["scene"] as TextureRect).texture = Art.tex(SCENES[mini(i, SCENES.size() - 1)])
		(parts["scene"] as TextureRect).stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED

		# Shut is the whole hunt, not one road: the balance gates no field, and
		# a padlock on a road the server would have taken would be a lie.
		var shut := not _unlocked(p)
		(parts["lock"] as CanvasItem).visible = shut
		# The same dim every painted thing out of reach wears here (the Army's
		# REROLL and DISMISS on an empty slot).
		(node as CanvasItem).modulate = Color.WHITE if not shut else Color(0.5, 0.5, 0.5)

		_words(p, parts, f)
		(parts["hit"] as BaseButton).pressed.connect(_choose.bind(p, i, f))
	p.set_meta("cards", made)


## What a road promises, in the server's own resolved numbers.
static func _words(p: PaintedPage, parts: Dictionary, f: Dictionary) -> void:
	_fit(parts["name"], str(f.get("name", "")), 14)
	_fit(parts["time"], UI.short_duration(int(f.get("hours", 0)) * 3600), 14)
	_fit(parts["gold"], _range(int(f.get("gold_low", 0)), int(f.get("gold_high", 0))), 12)
	_fit(parts["xp"], _range(int(f.get("xp_low", 0)), int(f.get("xp_high", 0))), 12)
	var chance := int(f.get("item_chance_bp", 0))
	_fit(parts["gear"], ("%d in 100" % int(round(chance / 100.0))) if chance > 0 else "—", 12)


static func _range(lo: int, hi: int) -> String:
	if lo == hi:
		return UI.short_number(lo)
	return "%s - %s" % [UI.short_number(lo), UI.short_number(hi)]


static func _fit(n: Variant, words: String, min_size: int) -> void:
	var l := n as Label
	if l == null:
		return
	var painted := int(l.get_meta("painted_size", l.label_settings.font_size))
	l.set_meta("painted_size", painted)
	l.label_settings.font_size = painted
	l.text = words
	UI.fit_label(l, painted, mini(min_size, painted))


static func _choose(p: PaintedPage, i: int, f: Dictionary) -> void:
	if not p.armed():
		return
	if not _unlocked(p):
		GameState.toast("The roads open at level %d." % int(_view(p).get("unlock_level", 0)))
		return
	p.set_meta("chosen", i)
	_paint(p)


static func _send(p: PaintedPage) -> void:
	if bool(p.get_meta("busy", false)) or not p.armed():
		return
	if not _unlocked(p):
		return
	var f: Variant = _chosen(p)
	if not (f is Dictionary):
		return
	var field: Dictionary = f
	var soldier: Dictionary = p.get_meta("soldier", {})
	p.set_meta("busy", true)
	var res: Api.Response = await Api.post_json("/v1/hunt/send", {
		"soldier_id": str(soldier.get("id", "")), "field_id": str(field.get("id", "")),
	})
	p.set_meta("busy", false)
	if not res.ok:
		GameState.action_failed.emit(res.error)
		return
	GameState.toast("%s is on the road to %s." % [str(soldier.get("name", "The soldier")),
		str(field.get("name", ""))])
	var army: Variant = p.get_meta("army") if p.has_meta("army") else null
	if army is Node and is_instance_valid(army) and (army as Node).has_method("reload_now"):
		await (army as Node).call("reload_now")
	if is_instance_valid(p):
		p.close()
