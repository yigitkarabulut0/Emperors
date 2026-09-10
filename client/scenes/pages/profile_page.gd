extends RefCounted
## PROFILE — the lord's own page, opened from the portrait at the top of the
## rail: the face other lords see, the name, the rankings, and the account.
##
## Deleting the account is here because the App Store requires it of any app
## that makes accounts (Guideline 5.1.1(v)). Two confirmations: a warning that
## says what goes, then the password -- a phone left unlocked on a table is not
## consent to something that cannot be undone.



static func open(host: Node) -> Sheet:
	var s := Sheet.open(host, "YOUR LORDSHIP", "How the realm sees you, and your account.")
	_paint(s)
	s.add_close()
	return s


static func _paint(s: Sheet) -> void:
	s.clear_body()
	var p := GameState.player()

	# The face on other lords' lists.
	s.heading("YOUR FACE")
	s.paragraph("The portrait other lords see beside your name when they look for someone to raid.", 22, UI.DIM)
	var faces := HBoxContainer.new()
	faces.add_theme_constant_override("separation", 18)
	faces.alignment = BoxContainer.ALIGNMENT_CENTER
	faces.custom_minimum_size = Vector2(s.inner_w, 170)
	s.body.add_child(faces)
	var mine := Art.avatar(str(p.get("avatar", "")))
	for choice in Art.AVATAR_CHOICES:
		var face: String = choice[0]
		var id: String = (choice[1] as Array)[0]
		faces.add_child(_face_button(s, face, id, face == mine))

	s.heading("YOUR NAME")
	var row := s.slot(116)
	Sheet.put(row, str(p.get("username", "")), Rect2(24, 0, s.inner_w - 280, 116), 32, UI.INK, "title", 700)
	var price := int(GameState.snapshot.get("prices", {}).get("rename_diamonds", 0))
	var rename := Sheet.button("RENAME  %d" % price, Dialog.QUIET_PLATE, UI.INK, 96, 24)
	UI.place(rename, Rect2(s.inner_w - 250, 10, 236, 96))
	rename.pressed.connect(func() -> void: _rename(s))
	row.add_child(rename)

	s.heading("THE REALM")
	var ranks := Sheet.button("RANKINGS OF THE LORDS", Dialog.QUIET_PLATE, UI.INK)
	ranks.pressed.connect(func() -> void:
		var lb: GDScript = load("res://scenes/pages/leaderboard_page.gd")
		lb.open(s))
	s.body.add_child(ranks)

	s.heading("ACCOUNT")
	var out := Sheet.button("SIGN OUT", Dialog.QUIET_PLATE, UI.INK)
	out.pressed.connect(func() -> void: _sign_out(s))
	s.body.add_child(out)
	var del := Sheet.button("DELETE ACCOUNT", Dialog.DANGER_PLATE, Color("#F3FBF3"))
	del.pressed.connect(func() -> void: _delete(s))
	s.body.add_child(del)

	var version := str(ProjectSettings.get_setting("application/config/version", ""))
	s.paragraph("Emperors%s  ·  signed in as %s" % [(" " + version) if version != "" else "",
		str(p.get("username", ""))], 20, UI.DIM, HORIZONTAL_ALIGNMENT_CENTER)


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
		_paint(s)


static func _rename(s: Sheet) -> void:
	var price := int(GameState.snapshot.get("prices", {}).get("rename_diamonds", 0))
	var have := int(GameState.player().get("diamonds", 0))
	var r: Dictionary = await Dialog.prompt_text(s, {
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
		_paint(s)


static func _sign_out(s: Sheet) -> void:
	if not await Dialog.ask(s, {"title": "Sign out?", "body": "Your realm waits for you. Sign in again with your name and password.",
			"confirm_text": "Sign out"}):
		return
	s.close()
	Session.sign_out()


static func _delete(s: Sheet) -> void:
	if not await Dialog.ask(s, {"title": "Delete your account?",
			"body": "Your lord, gold, vault, gear, soldiers, estates, diamonds and battles are deleted for good. " +
				"If you are a king, your crown passes to your longest-serving captain.\n\nThis cannot be undone.",
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
