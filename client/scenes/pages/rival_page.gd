extends RefCounted
## A RIVAL'S PAGE -- rival.png: what one lord may see of another, and the
## spyglass that buys the rest.
##
## The page is free and says what anybody could work out by fighting them:
## their level, their kingdom, their Might, what they wear, their gear BY NAME
## and the front rank of their army BY TYPE AND RANK. No numbers on any of it.
## The spyglass buys the numbers for an hour, frozen at the moment it was
## bought, and the rival is told they were scouted -- so the page only carries a
## figure per soldier while a report of this lord is live, on the kit's chip
## across the foot of each ring.
##
## One tap opens it from everywhere a lord is drawn -- the hall, the rankings, a
## raid's target list -- so a face always means the same thing.
##
## The painting draws five rings, and an army runs to ten slots: the five shown
## are the five at the front, in the rival's own order, which is the order they
## fight in.

const PAGE := "rival"
const SCREEN := "page:rival"
## The gear slots the painting has frames for, in its order, with the ghost
## and the word an empty one shows -- the same two as every other gear slot in
## the game (family.gd, army.gd).
const SLOTS := ["weapon", "armor", "horse"]
const GHOSTS := ["items/army_spear", "items/army_leather_armor", "items/army_horse"]
const WORDS := ["WEAPON", "ARMOR", "HORSE"]
## An empty ring, as the Army tab draws an empty card: the plainest soldier,
## drawn down into the dark, and no numeral on the diamond.
const EMPTY_FACE := Color(0.25, 0.25, 0.3)
## A patron's seal stands on the name plate's right end (the layout's "vip"),
## so the words stop here when one is shown.
const NAME_BEFORE_SEAL := 776.0
## The SCOUTED seal covers the left end of the plate under the portrait.
const SEEN_AFTER_SEAL := 230.0
## The smallest the name and the kingdom are set: a unit is under half a point
## on the phone, and smaller than this no longer reads.
const NAME_MIN := 14
const KINGDOM_MIN := 15
const TAG_MIN := 17


## Opens a lord's page over `host`. opts.player_id is whose.
static func open(host: Node, opts: Dictionary = {}) -> PaintedPage:
	var o := {"screen": SCREEN}
	o.merge(opts, true)
	var pid := str(o.get("player_id", ""))
	o.erase("player_id")
	o.erase("offline")
	var p := PaintedPage.open(host, PAGE, o)
	p.set_meta("player_id", pid)
	p.on("close", func() -> void: p.close())
	p.on("add_friend", func() -> void: await _befriend(p))
	p.on("spy", func() -> void: await _spy(p))
	p.on("attack", func() -> void: _attack(p))
	p.on("report", func() -> void: await _report(p))
	# Nothing of the painting's own gear or faces is left standing while the
	# realm answers: an empty page reads as a lord with nothing, not as the
	# painter's sword.
	paint(p, {})
	if not bool(opts.get("offline", false)) and pid != "":
		_load(p)
	return p


static func _load(p: PaintedPage) -> void:
	var pid := str(p.get_meta("player_id", ""))
	var res: Api.Response = await Api.get_json("/v1/lords/" + pid)
	if not is_instance_valid(p) or not p.is_inside_tree():
		return
	if not res.ok:
		GameState.toast(res.error if res.error != "" else "That lord could not be found.")
		p.close()
		return
	paint(p, res.data)


## Paints with a /v1/lords/<id> answer. Public for the tests and the captures.
static func paint(p: PaintedPage, v: Dictionary) -> void:
	p.set_meta("rival", v)
	var look: Variant = v.get("look", null)
	var worn: Dictionary = look if look is Dictionary else {}
	var scouted := bool(v.get("scouted", false))

	var face := p.node("portrait") as TextureRect
	if face != null:
		face.texture = Art.tex(Art.avatar(str(v.get("avatar", ""))))
		face.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	p.set_shown("scouted", scouted)
	Look.paint_crest(p.node("crest") as TextureRect,
		Look.crest(worn, str(v.get("player_id", ""))))
	_name(p, worn, str(v.get("name", "")))
	Look.paint_title(p.node("title") as Label, worn,
		Layout.rect_of(Layout.element(PAGE, "title")), 26, 16)

	p.set_text("level", "Level %d" % int(v.get("level", 0)), 18)
	_kingdom(p, v)
	p.set_text("might", "%s Might" % UI.grouped(int(v.get("might", 0))), 16)
	_seen(p, v, scouted)
	_gear(p, v.get("gear", []))
	_army(p, v.get("army", []))
	_light(p, v, scouted)


## The name, in the colour they wear, on the plate the painting leaves empty.
## The seal is the painting's own -- bigger than the one Look draws beside a
## name in a list, and in the place the painter put it -- so Look is given the
## plate up to it and told of no seal, and the layout's "vip" is shown instead.
static func _name(p: PaintedPage, worn: Dictionary, name: String) -> void:
	var l := p.node("name") as Label
	if l == null:
		return
	var sealed := Look.sealed(worn)
	p.set_shown("vip", sealed)
	var box := Layout.rect_of(Layout.element(PAGE, "name"))
	if sealed:
		box.size.x = NAME_BEFORE_SEAL - box.position.x
	# 14 is the floor because a username may be sixteen capital W's, and beside
	# the seal that is 194 units of the 201 the plate leaves.
	Look.paint_name(l, {"worn": Look.worn(worn)}, name, box, 32, NAME_MIN)


## The castle's plate: the kingdom and its tag, no smaller than KINGDOM_MIN. A
## name that will not go is written as its tag, as the Hall writes a kingdom
## ("[SWT]") and as the lord's own profile does -- a kingdom may be 24
## characters and this plate is 220 units wide.
static func _kingdom(p: PaintedPage, v: Dictionary) -> void:
	var name := str(v.get("kingdom", ""))
	if name == "":
		p.set_text("kingdom", "No kingdom", KINGDOM_MIN)
		return
	var tag := str(v.get("kingdom_tag", ""))
	var l := p.set_text("kingdom", "%s  [%s]" % [name, tag] if tag != "" else name, KINGDOM_MIN)
	if l != null and not _fits(l):
		p.set_text("kingdom", "[%s]" % tag if tag != "" else name, TAG_MIN)


## Whether a label's words fit the box they were set in at the size they came
## out at -- fit_line stops at its floor and cuts with an ellipsis past it.
static func _fits(l: Label) -> bool:
	var s := l.label_settings
	var box := float(l.get_meta("box_w", l.size.x))
	return s.font.get_string_size(l.text, HORIZONTAL_ALIGNMENT_LEFT, -1, s.font_size).x <= box + 0.5


## The plate under the portrait: where they are, if they let it be said. While
## the SCOUTED seal is on the frame it covers the plate's left end, so the
## words move in behind it.
static func _seen(p: PaintedPage, v: Dictionary, scouted: bool) -> void:
	var l := p.node("seen") as Label
	if l == null:
		return
	var box := Layout.rect_of(Layout.element(PAGE, "seen"))
	if scouted:
		box.size.x = box.end.x - SEEN_AFTER_SEAL
		box.position.x = SEEN_AFTER_SEAL
	l.set_meta("box_w", box.size.x)
	UI.place(l, box)
	var words := ""
	if bool(v.get("online", false)):
		words = "here now"
	elif int(v.get("seen_ago", 0)) > 0:
		words = "seen " + UI.ago(int(v.get("seen_ago", 0)))
	p.set_text("seen", words, 14)


## The three painted frames. Each window is filled edge to edge -- the tier's
## velvet under the piece they carry, the plainest cloth under a ghost where
## they carry nothing -- so no part of the painter's own sword is left showing.
static func _gear(p: PaintedPage, gear: Array) -> void:
	var frames: Array = p.parts.get("gear", [])
	for i in frames.size():
		var slot: Dictionary = frames[i]
		var parts: Dictionary = slot["parts"]
		var pic := parts["item"] as TextureRect
		var words := parts["name"] as Label
		var item: Dictionary = gear[i] if i < gear.size() and gear[i] is Dictionary else {}
		if not words.has_meta("plain"):
			words.set_meta("plain", words.label_settings.font_color)
		var empty := item.is_empty() or bool(item.get("empty", false)) or str(item.get("art", "")) == ""
		var ghost := _ghost(slot["node"], pic, i)
		pic.visible = not empty
		ghost.visible = empty
		if empty:
			ItemGround.under(pic, "common", Rect2(pic.position, pic.size))
			pic.get_meta("ground_node").modulate = Color(0.55, 0.58, 0.62)
			words.text = WORDS[i] if i < WORDS.size() else ""
			words.label_settings.font_color = Color(0.74, 0.78, 0.84, 0.85)
			UI.fit_line(words, 22, 15)
			continue
		pic.texture = Art.item(str(item.get("art", "")))
		pic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		ItemGround.under(pic, str(item.get("tier", "common")), Rect2(pic.position, pic.size))
		pic.get_meta("ground_node").modulate = Color.WHITE
		words.text = str(item.get("name", ""))
		words.label_settings.font_color = words.get_meta("plain")
		UI.fit_line(words, 22, 15)


## The silhouette an empty slot shows, built once per frame and kept.
static func _ghost(host: Control, pic: TextureRect, i: int) -> TextureRect:
	if host.has_meta("ghost") and is_instance_valid(host.get_meta("ghost")):
		return host.get_meta("ghost")
	var g := UI.image(GHOSTS[i] if i < GHOSTS.size() else GHOSTS[0],
		Rect2(pic.position, pic.size))
	g.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	g.modulate = Color(0.62, 0.7, 0.8, 0.24)
	host.add_child(g)
	host.set_meta("ghost", g)
	return g


## The five rings. A soldier's own painting covers the painter's face, the
## sheet's numeral covers the empty diamond, and the Might chip is shown only
## where the spyglass bought one.
static func _army(p: PaintedPage, army: Array) -> void:
	var rings: Array = p.parts.get("soldier", [])
	for i in rings.size():
		var parts: Dictionary = rings[i]["parts"]
		var pic := parts["face"] as TextureRect
		var numeral := parts["tier"] as TextureRect
		var chip := parts["might_chip"] as Control
		var might := parts["might"] as Label
		var unit: Dictionary = army[i] if i < army.size() and army[i] is Dictionary else {}
		if unit.is_empty():
			_soldier_face(pic, SoldierArt.portrait("peasant", 1))
			pic.modulate = EMPTY_FACE
			numeral.visible = false
			chip.visible = false
			might.visible = false
			continue
		var tier: Variant = unit.get("tier", "common")
		_soldier_face(pic, SoldierArt.portrait(str(unit.get("type", "peasant")), tier))
		pic.modulate = Color.WHITE
		numeral.texture = Art.tex(SoldierArt.numeral(tier))
		numeral.visible = true
		var m := int(unit.get("might", 0))
		chip.visible = m > 0
		might.visible = m > 0
		if m > 0:
			might.text = UI.grouped(m)
			UI.fit_line(might, 20, 13)


## A soldier in a round window. The paintings are 133x164 cards and the window
## is an oval a little wider than it is tall: drawn whole the card is squashed,
## and drawn to cover it loses the top of the helmet. So the window is filled
## with the BAND OF THE CARD ITS OWN SHAPE ASKS FOR, off the top -- the head and
## the shoulders, which is what the painter drew in these rings.
static func _soldier_face(pic: TextureRect, art: String) -> void:
	var tex := Art.tex(art)
	if tex == null or pic.size.x <= 0.0:
		pic.texture = tex
		return
	var at := AtlasTexture.new()
	at.atlas = tex
	var w := float(tex.get_width())
	at.region = Rect2(0.0, 0.0, w, minf(w * pic.size.y / pic.size.x, float(tex.get_height())))
	pic.texture = at
	pic.stretch_mode = TextureRect.STRETCH_SCALE


static func _light(p: PaintedPage, v: Dictionary, scouted: bool) -> void:
	var mine := bool(v.get("is_me", false))
	var known := v.has("player_id")
	p.set_enabled("add_friend", known and not mine
		and not bool(v.get("is_friend", false)) and not bool(v.get("requested", false)))
	p.set_enabled("attack", known and bool(v.get("can_attack", false))
		and not bool(v.get("shielded", false)))
	p.set_enabled("spy", known and not mine and not scouted and int(v.get("spy_left", 0)) > 0)
	p.set_enabled("report", known and not mine)
	if not known:
		p.set_text("spy_cost", "", 14)
	elif scouted:
		# What is left of the hour that was bought, in the price's place.
		p.set_text("spy_cost", "%s left" % UI.short_duration(int(v.get("scouted_for", 0))), 14)
	elif int(v.get("spy_left", 0)) <= 0:
		p.set_text("spy_cost", "none left today", 13)
	else:
		p.set_text("spy_cost", "%s gold" % UI.grouped(int(v.get("spy_cost", 0))), 14)


static func _befriend(p: PaintedPage) -> void:
	var v: Dictionary = p.get_meta("rival", {})
	var res: Api.Response = await Api.post_json("/v1/friends/request",
		{"username": str(v.get("username", ""))})
	if not is_instance_valid(p) or not p.is_inside_tree():
		return
	if res.ok:
		GameState.toast("Asked. They will find it on their own page.")
		_load(p)
	else:
		GameState.toast(res.error if res.error != "" else "That could not be asked.")


static func _spy(p: PaintedPage) -> void:
	var v: Dictionary = p.get_meta("rival", {})
	var ok := await Dialog.ask(p, {
		"title": "SEND A SPY",
		"body": "%s gold buys an hour's look at their army as it stands now. They will know they were scouted."
			% UI.grouped(int(v.get("spy_cost", 0))),
		"confirm_text": "SEND",
	})
	if not ok or not is_instance_valid(p) or not p.is_inside_tree():
		return
	var res: Api.Response = await GameState.act(
		"/v1/lords/%s/spy" % str(p.get_meta("player_id", "")), {})
	if not is_instance_valid(p) or not p.is_inside_tree():
		return
	if res.ok and res.data is Dictionary:
		paint(p, res.data)
		GameState.toast("The spy has reported.")
	else:
		GameState.toast(res.error if res.error != "" else "The spy did not go.")


## A raid is the Attack tab's own flow, with its confirm, its cost and its
## refusals: the page hands the shell the lord and gets out of the way.
static func _attack(p: PaintedPage) -> void:
	var v: Dictionary = p.get_meta("rival", {})
	var pid := str(p.get_meta("player_id", ""))
	var shell := p.get_tree().get_first_node_in_group("shell") if p.is_inside_tree() else null
	p.close()
	if shell != null and shell.has_method("raid_lord"):
		shell.call("raid_lord", pid, str(v.get("name", "")))


static func _report(p: PaintedPage) -> void:
	var what := await Dialog.choose(p, {
		"title": "REPORT THIS LORD",
		"body": "The crown reads what is reported: tell it what is wrong here.",
		"options": [
			{"id": "name", "label": "THEIR NAME"},
			{"id": "chat", "label": "WHAT THEY SAID"},
			{"id": "cheat", "label": "CHEATING"},
			{"id": "block", "label": "BLOCK THEM"},
		],
	})
	if what == "" or not is_instance_valid(p) or not p.is_inside_tree():
		return
	var pid := str(p.get_meta("player_id", ""))
	if what == "block":
		var res: Api.Response = await Api.post_json("/v1/blocks", {"player_id": pid})
		if is_instance_valid(p) and p.is_inside_tree():
			GameState.toast("Blocked. You will not see them, nor they you." if res.ok else res.error)
			if res.ok:
				p.close()
		return
	var sent: Api.Response = await Api.post_json("/v1/lords/%s/report" % pid, {"reason": what})
	if is_instance_valid(p) and p.is_inside_tree():
		GameState.toast("Reported. The crown will read it." if sent.ok
			else (sent.error if sent.error != "" else "That could not be reported."))
