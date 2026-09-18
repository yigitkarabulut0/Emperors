extends RefCounted
## YOUR LORDSHIP — the lord's own page, opened from the portrait at the top of
## the rail: the face and the look other lords see, the name, where they stand,
## and every page that hangs off the lord -- the Royal Mail, Splendour, the
## Crown's Favour, the rankings, the account, a code to redeem, a friend to
## bring.
##
## It is the owner's painting of it (art/reference/profile.png, cut by
## art/slices/profile.json, laid out by client/layout/profile.json) on the
## painted pages' host. The header is the painting's: the lord's round face in
## its gilded ring (a tap chooses another), the name on its plate in the colour
## they wear with Royal Favour's seal beside it and the rename quill at its end,
## the title they wear on the red ribbon (or their level), their level, might
## and kingdom on the crown, swords and castle plates, and their crest where the
## painting has its lion shield -- all of the look through Look (look.gd), as
## every other lord's is drawn. Under it, the painting's seven rows, each its
## plate, its icon and its gold chevron; FRIENDS and SETTINGS, the friends and
## the two toggles are the painting's and are not drawn (there is nothing
## behind them yet).
##
## Deleting the account is here, under ACCOUNT, because the App Store requires
## it of any app that makes accounts (Guideline 5.1.1(v)). Two confirmations: a
## warning that says what goes, then the password -- a phone left unlocked on a
## table is not consent to something that cannot be undone.

const PAGE := "profile"
const SCREEN := "page:profile"
## The seven rows, in the painting's places: the action each taps, its word,
## and its icon.
const ROWS := [
	["friends", "FRIENDS", "profile/icon_friends"],
	["splendour", "WARDROBE", "profile/icon_wardrobe"],
	["rankings", "RANKINGS", "profile/icon_rankings"],
	["settings", "SETTINGS", "profile/icon_settings"],
	["account", "ACCOUNT", "profile/icon_account"],
	["redeem", "REDEEM A CODE", "profile/icon_redeem"],
	["invite", "INVITE A FRIEND", "profile/icon_invite"],
]
## A face inside a worn frame fills the frame's own window: the same share of
## the ring as the rankings' podium gives it.
const FACE_IN_FRAME := 0.78
const NO_KINGDOM := "No kingdom"
## The smallest the ribbon's title and the castle plate's kingdom are set.
const RIBBON_MIN := 14
const KINGDOM_MIN := 15
const TAG_MIN := 12
const FACE_COLUMNS := 4
const FACE_GAP := Vector2i(24, 12)


## Opens the page over `host` (the shell, from the rail's portrait). `opts` goes
## to PaintedPage.open (a test's "inset").
static func open(host: Node, opts: Dictionary = {}) -> PaintedPage:
	var o := {"screen": SCREEN}
	o.merge(opts, true)
	var p := PaintedPage.open(host, PAGE, o)
	_rows(p)
	p.on("face", func() -> void: face_picker(p, func() -> void: paint(p)))
	p.on("rename", func() -> void: _rename(p))
	p.on("friends", func() -> void: load("res://scenes/pages/friends_page.gd").open(p))
	p.on("splendour", func() -> void: _to_view(p, "wardrobe", false))
	p.on("settings", func() -> void: load("res://scenes/pages/settings_page.gd").open(p))
	p.on("rankings", func() -> void: load("res://scenes/pages/leaderboard_page.gd").open(p))
	p.on("account", func() -> void: account(p))
	p.on("redeem", func() -> void: load("res://scenes/pages/redeem_page.gd").open(p,
		{"open_mail": func() -> void: _to_view(p, "mail", true)}))
	p.on("invite", func() -> void: load("res://scenes/pages/invite_page.gd").open(p))
	paint(p)
	_listen(p)
	_realm(p)
	return p


# --- the header ------------------------------------------------------------------------

## Paints the header from the snapshot (and what _realm read). Public: a
## rename, a new face or a new look paints it again.
static func paint(p: PaintedPage) -> void:
	if not is_instance_valid(p):
		return
	var me: Dictionary = GameState.player()
	var look := Look.mine()
	_face(p, str(me.get("avatar", "")), look)
	Look.paint_name(p.node("name") as Label, look, str(me.get("username", "")),
		p.map_rect(Layout.rect_of(Layout.element(PAGE, "name"))), 28, 16, UI.INK)
	p.set_text("price", UI.grouped(int(GameState.snapshot.get("prices", {}).get("rename_diamonds", 0))), 14)
	var title := Look.title(look)
	var ribbon := p.set_text("ribbon", title if title != "" else "Level %d" % int(me.get("level", 0)), RIBBON_MIN)
	if ribbon != null:
		ribbon.label_settings.font_color = Look.colour(look, UI.GOLD) if title != "" else UI.GOLD
		# A title longer than the ribbon's face at its smallest is cut there with
		# an ellipsis, never run out over the ribbon's folds.
		ribbon.set_meta("box_w", Layout.rect_of(Layout.element(PAGE, "ribbon")).size.x)
		UI.fit_line(ribbon, ribbon.label_settings.font_size, RIBBON_MIN)
	p.set_text("level", UI.grouped(int(me.get("level", 0))), 16)
	var realm: Dictionary = p.get_meta("realm", {})
	# Might the way the paintings write a big figure (9.99B), in the swords'
	# plate; the kingdom's name on the castle's, beside the castle.
	p.set_text("might", UI.short_number(int(realm["might"])) if realm.has("might") else "—", 16)
	_kingdom(p, realm)
	Look.paint_crest(p.node("crest") as TextureRect, Look.crest(look, str(me.get("id", ""))))
	p.set_text("build", "Emperors build %s  ·  signed in as %s" % [Env.build_version, str(me.get("username", ""))], 14)


## The lord's face, round, in the painted ring's window -- or, when they wear a
## frame, in the frame's own window inside it, the frame over the face.
static func _face(p: PaintedPage, avatar: String, look: Dictionary) -> void:
	var win := Layout.rect_of(Layout.element(PAGE, "ring_window"))
	var band := win.size.x
	var framed := Look.frame_art(look, "ring", band) != ""
	var d := band * FACE_IN_FRAME if framed else band + 2.0
	var old: Variant = p.get_meta("face") if p.has_meta("face") else null
	if old is TextureRect and is_instance_valid(old):
		var old_ring: Variant = (old as TextureRect).get_meta("look_frame") if (old as TextureRect).has_meta("look_frame") else null
		if old_ring is Node and is_instance_valid(old_ring):
			(old_ring as Node).queue_free()
		(old as TextureRect).queue_free()
	var face := UI.image(Art.avatar_ring(avatar), Rect2())
	face.name = "Face"
	p.place(face, Rect2(win.get_center() - Vector2(d, d) / 2.0, Vector2(d, d)))
	p.set_meta("face", face)
	Look.paint_frame(face, look, "ring", band)


## The kingdom on the castle's plate, beside the castle: its name, in the two
## lines the plate holds, no smaller than KINGDOM_MIN -- a unit is under half
## a point on the phone, and smaller than that no longer reads. A name that
## will not go is written as its tag, as the Hall writes a kingdom ("[SWT]");
## a lord without a kingdom reads "No kingdom"; "—" until /v1/kingdom answers.
static func _kingdom(p: PaintedPage, realm: Dictionary) -> void:
	var name := str(realm.get("kingdom", ""))
	if not realm.has("kingdom") or name == "":
		_kingdom_text(p, NO_KINGDOM if realm.has("kingdom") else "—", KINGDOM_MIN)
		return
	var l := _kingdom_text(p, name, KINGDOM_MIN)
	var tag := str(realm.get("tag", ""))
	if l != null and tag != "" and not kingdom_fits(l):
		_kingdom_text(p, "[%s]" % tag, TAG_MIN)


## The castle plate's words, set from its whole box each time: a wrapped label
## grows to the lines of a long word, and would otherwise measure the next
## words against that and sit them low.
static func _kingdom_text(p: PaintedPage, text: String, min_size: int) -> Label:
	var l := p.node("kingdom") as Label
	if l == null:
		return null
	var box := Layout.rect_of(Layout.element(PAGE, "kingdom"))
	l.set_meta("box_w", box.size.x)
	l.text = ""
	l.size = box.size
	l = p.set_text("kingdom", text, min_size)
	l.size.y = box.size.y
	return l


## Whether the castle plate's words fit its box at the size they were set.
static func kingdom_fits(l: Label) -> bool:
	var s := l.label_settings
	var box := Layout.rect_of(Layout.element(PAGE, "kingdom"))
	var m := s.font.get_multiline_string_size(l.text, HORIZONTAL_ALIGNMENT_LEFT, box.size.x, s.font_size)
	return m.x <= box.size.x + 0.5 and m.y <= box.size.y + 0.5


## What the snapshot does not carry: the lord's might (the army's) and their
## kingdom's name and tag, read once when the page opens.
static func _realm(p: PaintedPage) -> void:
	var army: Api.Response = await Api.get_json("/v1/army")
	var house: Api.Response = await Api.get_json("/v1/kingdom")
	if not is_instance_valid(p) or not p.is_inside_tree():
		return
	var realm := {}
	if army.ok:
		realm["might"] = int(army.data.get("totals", {}).get("might", 0))
	if house.ok:
		var k: Variant = house.data.get("kingdom", null)
		realm["kingdom"] = str((k as Dictionary).get("name", "")) if k is Dictionary else ""
		realm["tag"] = str((k as Dictionary).get("tag", "")) if k is Dictionary else ""
	p.set_meta("realm", realm)
	paint(p)


## The rows: each its icon and word, the painting's own seven. FRIENDS wears the
## red badge the painting puts on it: the lords waiting for an answer.
static func _rows(p: PaintedPage) -> void:
	var list: Array = p.parts.get("row", [])
	for i in mini(list.size(), ROWS.size()):
		var parts: Dictionary = list[i]["parts"]
		(parts["icon"] as TextureRect).texture = Art.tex(str(ROWS[i][2]))
		var l: Label = parts["label"]
		l.text = str(ROWS[i][1])
		UI.fit_line(l, 28, 18)
		list[i]["node"].set_meta("row", str(ROWS[i][0]))
	_badge(p)


static func _badge(p: PaintedPage) -> void:
	if not is_instance_valid(p):
		return
	var list: Array = p.parts.get("row", [])
	for i in mini(list.size(), ROWS.size()):
		var parts: Dictionary = list[i]["parts"]
		var n := int(GameState.badges.get("friends", 0)) if str(ROWS[i][0]) == "friends" else 0
		(parts["badge"] as Control).visible = n > 0
		var t: Label = parts["badge_text"]
		t.visible = n > 0
		t.text = str(n) if n < 10 else "9+"


## The badge follows the asks as they are answered, and the header the snapshot
## as it changes; both let go when the page closes.
static func _listen(p: PaintedPage) -> void:
	var on_badges := func() -> void: _badge(p)
	var on_changed := func() -> void: paint(p)
	GameState.badges_changed.connect(on_badges)
	GameState.changed.connect(on_changed)
	p.closed.connect(func() -> void:
		if GameState.badges_changed.is_connected(on_badges):
			GameState.badges_changed.disconnect(on_badges)
		if GameState.changed.is_connected(on_changed):
			GameState.changed.disconnect(on_changed))


## A Court view from a row. The mail is hosted by the shell under the pages, so
## the profile gives way to it; Splendour and the Favour are whole painted
## pages that open over it and close back to it.
static func _to_view(p: PaintedPage, view: String, close_first: bool) -> void:
	var shell := p.get_tree().get_first_node_in_group("shell") if p.is_inside_tree() else null
	if close_first:
		p.close()
	if shell != null:
		shell.open_view(view)


# --- the face ----------------------------------------------------------------------------

## The faces a lord may choose between, on a page over the profile: a tap on the
## ring opens it. `changed` runs after a new face is chosen.
static func face_picker(host: Node, changed: Callable = Callable()) -> Sheet:
	var s := Sheet.open(host, "YOUR FACE", "The portrait other lords see beside your name when they look for someone to raid.")
	if changed.is_valid():
		s.set_meta("changed", changed)
	_faces(s)
	s.add_close()
	return s


static func _faces(s: Sheet) -> void:
	s.clear_body()
	# Twelve faces, one to each portrait id, in four columns: a thumb-sized tile
	# each, and the grid centred on the page at both canvases.
	var faces := GridContainer.new()
	faces.columns = FACE_COLUMNS
	faces.add_theme_constant_override("h_separation", FACE_GAP.x)
	faces.add_theme_constant_override("v_separation", FACE_GAP.y)
	var centre := CenterContainer.new()
	centre.custom_minimum_size = Vector2(s.inner_w, 0)
	centre.add_child(faces)
	s.body.add_child(centre)
	var mine := Art.avatar(str(GameState.player().get("avatar", "")))
	for choice in Art.AVATAR_CHOICES:
		var face: String = choice[0]
		var id: String = (choice[1] as Array)[0]
		faces.add_child(_face_button(s, face, id, face == mine))


static func _face_button(s: Sheet, face: String, id: String, current: bool) -> Control:
	var box := Control.new()
	box.custom_minimum_size = Vector2(160, 170)
	var img := UI.image(face, Rect2(12, 6, 136, 136))
	img.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	img.clip_contents = true
	box.add_child(img)
	var ring := UI.image("inventory/frame_legendary" if current else "inventory/frame_common", Rect2(8, 2, 144, 144))
	box.add_child(ring)
	if not current:
		img.modulate = Color(0.72, 0.72, 0.76)
	var mark := UI.label("YOURS" if current else "", 20, UI.GOLD, "title", 700, HORIZONTAL_ALIGNMENT_CENTER)
	UI.place(mark, Rect2(0, 142, 160, 28))
	box.add_child(mark)
	var hit := UI.hotspot(Rect2(0, 0, 160, 170), true)
	hit.pressed.connect(func() -> void: _choose_face(s, id, current))
	box.add_child(hit)
	return box


static func _choose_face(s: Sheet, id: String, current: bool) -> void:
	if current:
		return
	var res: Api.Response = await GameState.act("/v1/avatar", {"avatar": id})
	if res.ok:
		GameState.toast("Your portrait is changed")
		_faces(s)
		var changed: Variant = s.get_meta("changed") if s.has_meta("changed") else null
		if changed is Callable and (changed as Callable).is_valid():
			(changed as Callable).call()


# --- the name ----------------------------------------------------------------------------

static func _rename(p: PaintedPage) -> void:
	var price := int(GameState.snapshot.get("prices", {}).get("rename_diamonds", 0))
	var have := int(GameState.player().get("diamonds", 0))
	var r: Dictionary = await Dialog.prompt_text(p, {
		"title": "Change your name",
		"body": "3 to 16 letters, digits or underscore.\nCosts %d diamonds. You have %d." % [price, have],
		"placeholder": str(GameState.player().get("username", "")),
		"max_length": 16,
		"confirm_text": "Rename for %d diamonds" % price,
	})
	var name := str(r.get("text", ""))
	if str(r.get("action", "")) != "confirm" or name == "":
		return
	var res: Api.Response = await GameState.act("/v1/profile/rename", {"name": name})
	if res.ok:
		GameState.toast("You are now %s" % name)
		paint(p)


# --- the account -------------------------------------------------------------------------

## ACCOUNT: signing out, and deleting the account, on a page over the profile.
static func account(host: Node) -> Sheet:
	var me: Dictionary = GameState.player()
	var s := Sheet.open(host, "YOUR ACCOUNT", "Signed in as %s." % str(me.get("username", "")))
	var out := Sheet.button("SIGN OUT", Dialog.QUIET_PLATE, UI.INK)
	out.pressed.connect(func() -> void: _sign_out(s))
	s.body.add_child(out)
	var del := Sheet.button("DELETE ACCOUNT", Dialog.DANGER_PLATE, Color("#F3FBF3"))
	del.pressed.connect(func() -> void: _delete(s))
	s.body.add_child(del)
	s.paragraph("Emperors build %s" % Env.build_version, 20, UI.DIM, HORIZONTAL_ALIGNMENT_CENTER)
	s.add_close()
	return s


static func _sign_out(s: Sheet) -> void:
	if not await Dialog.ask(s, {"title": "Sign out?", "body": "Your realm waits for you. Sign in again with your name and password.",
			"confirm_text": "Sign out"}):
		return
	s.close()
	Session.sign_out()


## What deleting the account takes, in the first confirmation's words. A
## patron is told that deleting does not end Crown Patronage -- Apple bills it,
## and only the lord can cancel it -- and how; a lord who bought anything, that
## it stays with their Apple ID and is gone from this account. A lord who never
## paid is told neither.
static func delete_words(player: Dictionary) -> String:
	var words := "Your lord, gold, vault, gear, soldiers, estates, diamonds and battles are deleted for good. " \
		+ "If you are a king, your crown passes to your longest-serving captain."
	if int(player.get("patron_seconds", 0)) > 0:
		words += "\n\nCrown Patronage is billed by Apple, and deleting your account does not cancel it. " \
			+ "Cancel it first in your iPhone's Settings › your name › Subscriptions."
	if int(player.get("vip_level", 0)) > 0:
		words += "\n\nWhat you bought stays with your Apple ID, but it is gone from this game account " \
			+ "and cannot be moved to another."
	return words + "\n\nThis cannot be undone."


static func _delete(s: Sheet) -> void:
	if not await Dialog.ask(s, {"title": "Delete your account?", "body": delete_words(GameState.player()),
			"confirm_text": "Continue", "danger": true}):
		return
	var r: Dictionary = await Dialog.prompt_text(s, {"title": "Confirm with your password",
		"body": "Type your password to delete %s for good." % str(GameState.player().get("username", "")),
		"placeholder": "Password", "secret": true, "confirm_text": "Delete for good"})
	if str(r.get("action", "")) != "confirm" or str(r.get("text", "")) == "":
		return
	var res: Api.Response = await Api.post_json("/v1/account/delete", {"password": str(r.get("text", ""))})
	if res.ok:
		s.close()
		Session.ended_reason = "Your account has been deleted."
		Session.sign_out()
	elif res.code == "wrong_password":
		await Dialog.ask(s, {"title": "Not deleted", "body": "That is not your password. Nothing was deleted.", "confirm_text": "OK"})
	else:
		GameState.action_failed.emit(res.error)
