extends RefCounted
## THE DAILY REWARD — a week of diamonds, one square a day.
##
## It was a paragraph in a dialog: "● Day 1 5 diamonds / ▶ Day 3 10 diamonds",
## seven lines of bullets. It is a calendar now: the week's seven squares, the
## ones taken marked, today's lit, the rest waiting, and the streak above them.
## The rewards and which day is today are the server's (GET /v1/daily).

const CELL := Vector2(186, 190)


## Opens the calendar; `on_claimed` is called after a claim went through.
static func open(host: Node, daily: Dictionary, on_claimed: Callable = Callable()) -> Sheet:
	var s := Sheet.open(host, "THE DAILY REWARD", "Come back each day: the week's rewards grow as the streak does.")
	_paint(s, daily, on_claimed)
	return s


static func _paint(s: Sheet, d: Dictionary, on_claimed: Callable) -> void:
	s.clear_body()
	for c in s.foot.get_children():
		c.queue_free()
	var rewards: Array = d.get("rewards", [])
	var day := int(d.get("day", 1))
	var claimable := bool(d.get("claimable", false))
	var streak := int(d.get("streak", 0))
	s.paragraph("Streak: %d day%s" % [streak, "" if streak == 1 else "s"], 28, UI.GOLD, HORIZONTAL_ALIGNMENT_CENTER)

	var grid := GridContainer.new()
	grid.columns = 4
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 14)
	s.body.add_child(grid)
	for i in rewards.size():
		var n := i + 1
		var state := "taken" if n < day or (n == day and not claimable) else ("today" if n == day else "ahead")
		grid.add_child(_cell(n, int(rewards[i]), state))

	s.paragraph("Diamonds come with every level and with this reward. They buy energy refills and protection, never power.",
		22, UI.DIM, HORIZONTAL_ALIGNMENT_CENTER)

	if claimable:
		s.add_button("CLAIM %d DIAMONDS" % int(d.get("reward", 0)), "confirm", func() -> void:
			var res: Api.Response = await Api.post_json("/v1/daily/claim", {})
			if res.ok:
				GameState.toast("+%d diamonds" % int(d.get("reward", 0)))
				await GameState.refresh()
				if on_claimed.is_valid():
					on_claimed.call()
				if is_instance_valid(s):
					_paint(s, res.data, on_claimed)
			elif res.code == "already_claimed":
				if is_instance_valid(s):
					s.close()
			else:
				GameState.action_failed.emit(res.error))
		s.add_button("LATER", "quiet", s.close)
	else:
		s.add_close("COME BACK TOMORROW")


static func _cell(n: int, reward: int, state: String) -> Control:
	var box := NinePatchRect.new()
	box.texture = Art.tex("inventory/chip_frame_active" if state == "today" else UI.FIELD_PLATE)
	for m in ["left", "top", "right", "bottom"]:
		box.set("patch_margin_" + m, 14)
	box.custom_minimum_size = CELL
	var dim := Color(0.55, 0.55, 0.6) if state == "taken" else Color.WHITE
	var day := UI.label("DAY %d" % n, 24, UI.GOLD if state == "today" else UI.INK, "title", 700, HORIZONTAL_ALIGNMENT_CENTER)
	UI.place(day, Rect2(0, 10, CELL.x, 34))
	day.modulate = dim
	box.add_child(day)
	var gem := UI.image("icons/diamond", Rect2(CELL.x / 2.0 - 36, 52, 72, 60))
	gem.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	gem.modulate = dim
	box.add_child(gem)
	var amount := UI.label("+%d" % reward, 30, Color("#9FD8FF") if state != "taken" else UI.DIM, "body", 800, HORIZONTAL_ALIGNMENT_CENTER)
	UI.place(amount, Rect2(0, 116, CELL.x, 38))
	box.add_child(amount)
	var note := UI.label({"taken": "TAKEN", "today": "TODAY", "ahead": ""}[state], 18, UI.GOLD if state == "today" else UI.DIM,
		"title", 700, HORIZONTAL_ALIGNMENT_CENTER)
	UI.place(note, Rect2(0, 152, CELL.x, 28))
	box.add_child(note)
	return box
