extends Control
## ATTACK — scores to settle, then matchmade targets, then the battle history.
## Layout: layout/attack.json. The client never simulates a fight: the server
## returns the outcome and the client shows it.
##
## The page scrolls and its cards flow, top to bottom: however many revenge
## strikes are waiting (REVENGE tab), the targets, the history, the notice. It
## used to be pinned to the painting's positions -- one revenge card, three
## targets -- so a second raider had nowhere to go, a missing revenge card left
## a hole the targets slid into, and the history sat 200 units under the last
## card whatever was above it.
##
## Every number on a card is the server's: the take, the rate it prints, the
## energy a strike costs. The revenge strike is half price and a third more
## gold, and that arithmetic lives on the server only.

const SCREEN := "attack"
const CARD_TOP := 380.0          ## the first card, just under the tabs
const CARD_GAP := 10.0
const PANEL_GAP := 20.0
const EMPTY_H := 190.0
## The notice sits in the painted foliage at the page's foot, where
## ground_bottom has it baked: 131 units above the bottom, 202 tall with the
## foliage. The live bar is laid exactly over the baked one.
const FOOT_H := 202.0
const NOTICE_FROM_FOOT := 131.0

var _scroll: ScrollContainer
var _content: Control
var _ui: Dictionary = {}
var _revenge_cards: Array = []   ## one built card per score to settle
var _targets: Array = []         ## built target cards
var _history_rows: Array = []
var _history_panel: Control
var _history_empty: Label
var _empty: Control              ## the "nothing here" card
var _empty_title: Label
var _empty_body: Label
var _count: Label                ## the number in the REVENGE tab's bubble
var _tab_labels: Dictionary = {}
var _page_h := 1672.0

var _data: Dictionary = {}
var _history: Array = []
var _loaded := false
var _loaded_ms := -100000
var _busy := false
var _view := "revenge"           ## revenge | targets


func _ready() -> void:
	_scroll = ScrollContainer.new()
	_scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	_scroll.scroll_deadzone = 14
	add_child(_scroll)
	_content = Control.new()
	_content.custom_minimum_size = Vector2(941, 1672)
	_content.mouse_filter = Control.MOUSE_FILTER_PASS
	_scroll.add_child(_content)
	_scroll.resized.connect(_fit_page)

	_ui = Layout.build(SCREEN, _content)
	# The notice and the foliage are laid along the page's own foot by
	# _fit_page, which is the screen's foot or further down when the flow is
	# longer than the screen.
	_unanchor(_ui["notice_bar"])
	_unanchor(_ui["ground_bottom"])
	_content.move_child(_ui["ground_bottom"], 0)
	UI.fade_top(_ui["ground_bottom"], 70.0)

	_revenge_cards = _ui["revenge_card"]
	for i in _revenge_cards.size():
		_wire_revenge(_revenge_cards[i], i)
	_targets = _ui["target_card"]
	for i in _targets.size():
		_targets[i]["parts"]["attack"].pressed.connect(_attack_target.bind(i))
		_build_bar(_targets[i])

	var hp: Dictionary = _ui["history_panel"][0]["parts"]
	_history_panel = _ui["history_panel"][0]["node"]
	_history_rows = hp["row"].get_meta("instances", []) if hp.has("row") else []
	hp["view_all"].pressed.connect(_view_all_history)
	for i in _history_rows.size():
		_dress_history_row(_history_rows[i], i)
	# An empty history says so in the painted rows' own bands, one line each,
	# rather than across the lines between them.
	_history_empty = UI.label("", 24, UI.INK, "body", 600, HORIZONTAL_ALIGNMENT_CENTER)
	UI.place(_history_empty, Rect2(18, 56, 708, 48))
	_history_panel.add_child(_history_empty)
	var sub := UI.label("", 21, UI.DIM, "body", 500, HORIZONTAL_ALIGNMENT_CENTER)
	UI.place(sub, Rect2(18, 107, 708, 48))
	_history_empty.add_child(sub)
	sub.position = Vector2(0, 51)
	_history_empty.set_meta("sub", sub)

	# Tabs: the painted labelled tabs for the reference state; frames + live labels otherwise.
	for id in ["tab_revenge", "tab_targets"]:
		var b: TextureButton = _ui[id]
		b.pressed.connect(_set_view.bind(id.trim_prefix("tab_")))
		var l := UI.label(id.trim_prefix("tab_").to_upper(), 31, Color("#F4F0EA"), "title", 700, HORIZONTAL_ALIGNMENT_CENTER)
		l.visible = false
		_content.add_child(l)
		_tab_labels[id] = l
	# The bubble is painted into the active REVENGE tab, empty; the number is live.
	_count = UI.label("", 26, Color("#FFF4EC"), "title", 800, HORIZONTAL_ALIGNMENT_CENTER)
	UI.place(_count, Rect2(447, 283, 44, 42))
	_count.visible = false
	_content.add_child(_count)

	_build_empty()
	_apply_tabs()
	_paint()
	_fit_page()


func _unanchor(n: Control) -> void:
	var r := Rect2(n.position, n.size)
	n.anchor_top = 0.0
	n.anchor_bottom = 0.0
	n.grow_vertical = Control.GROW_DIRECTION_END
	n.position = r.position
	n.size = r.size


func refresh() -> void:
	if Time.get_ticks_msec() - _loaded_ms > 3000:
		_load()
	else:
		_paint()


func _load() -> void:
	_loaded_ms = Time.get_ticks_msec()
	var res: Api.Response = await Api.get_json("/v1/attack/targets")
	if res.ok:
		_data = res.data
	var h: Api.Response = await Api.get_json("/v1/attack/history")
	if h.ok:
		_history = h.data.get("entries", [])
	_loaded = _loaded or (res.ok and h.ok)
	_paint()
	# Dev: --replay-last opens the most recent battle's playback on arrival.
	if Env.args.has("replay_last") and not _history.is_empty():
		Env.args.erase("replay_last")
		_replay(0)


func _set_view(v: String) -> void:
	if _view == v:
		return
	_view = v
	_apply_tabs()
	_paint()
	_scroll.scroll_vertical = 0


func _apply_tabs() -> void:
	var waiting: int = (_data.get("revenge", []) as Array).size()
	var spec_r := Layout.element(SCREEN, "tab_revenge")
	var spec_t := Layout.element(SCREEN, "tab_targets")
	var rs: Dictionary = spec_r["states"]["active" if _view == "revenge" else "inactive"]
	var ts: Dictionary = spec_t["states"]["active" if _view == "targets" else "inactive"]
	for pair in [[_ui["tab_revenge"], rs, "tab_revenge"], [_ui["tab_targets"], ts, "tab_targets"]]:
		var b: TextureButton = pair[0]
		var st: Dictionary = pair[1]
		var asset := str(st["asset"])
		# The active REVENGE tab has the painting's bubble, emptied; it carries
		# the number of scores waiting and is only drawn when there is one. An
		# empty circle -- or a 0 -- reads as though something is waiting.
		if asset == "attack/tab_revenge" and waiting == 0:
			asset = "attack/tab_revenge_plain"
		b.texture_normal = Art.tex(asset)
		UI.place(b, Layout.rect_of(st))
		var l: Label = _tab_labels[pair[2]]
		l.visible = st.has("label")
		if st.has("label"):
			var ls: Dictionary = st["label"]
			UI.place(l, Layout.rect_of(ls))
			l.label_settings.font_color = Color(str(ls.get("color", "#F4F0EA")))
			l.label_settings.font_size = int(ls.get("size", 31))
	_count.visible = _view == "revenge" and waiting > 0
	_count.text = str(waiting) if waiting < 10 else "9+"


# --- the flow ------------------------------------------------------------------------

func _paint() -> void:
	_apply_tabs()
	for c in _revenge_cards:
		c["node"].visible = false
	for c in _targets:
		c["node"].visible = false
	_empty.visible = false
	_ui["divider_targets"].visible = false
	if not _loaded:
		# Nothing on the painting's sample cards until the server has answered.
		_history_panel.visible = false
		_ui["notice_bar"].visible = false
		return
	_history_panel.visible = true
	_ui["notice_bar"].visible = true

	var revenge: Array = _data.get("revenge", [])
	var targets: Array = _data.get("targets", [])
	var my_might := int(_data.get("might", 0))
	var y := CARD_TOP

	if _view == "revenge":
		if revenge.is_empty():
			y = _show_empty(y, "NO SCORES TO SETTLE",
				"When a rival raids you, you can strike back here for a day: half the energy, a third more gold, and their shield will not stop you.")
		else:
			for i in revenge.size():
				var c := _revenge_card(i)
				c["node"].position.y = y
				c["node"].visible = true
				_paint_card(c, revenge[i], my_might, true)
				y += c["node"].size.y + CARD_GAP
		if not targets.is_empty():
			var div: Control = _ui["divider_targets"]
			div.visible = true
			div.position.y = y + 2.0
			y += div.size.y + 12.0

	if targets.is_empty():
		if _view == "targets":
			y = _show_empty(y, "NO RIVALS IN REACH",
				"Nobody near your level can be raided right now. Rivals come back into reach as their shields fall -- look again soon.")
	else:
		var n := mini(targets.size(), _targets.size())
		for i in n:
			var c: Dictionary = _targets[i]
			c["node"].position.y = y
			c["node"].visible = true
			_paint_card(c, targets[i], my_might, false)
			y += c["node"].size.y + (CARD_GAP if i < n - 1 else 0.0)

	y += PANEL_GAP
	_history_panel.position.y = y
	_paint_history()
	y += _history_panel.size.y + PANEL_GAP
	_page_h = y + NOTICE_FROM_FOOT
	_fit_page()


## The page is as tall as its flow, and at least as tall as the screen, with the
## painted foliage and the notice in it along the very bottom.
func _fit_page() -> void:
	if _content == null:
		return
	var h := maxf(_page_h, _scroll.size.y if _scroll.size.y > 0 else 1672.0)
	_content.custom_minimum_size = Vector2(941, h)
	var g: Control = _ui.get("ground_bottom")
	if g != null:
		g.position.y = h - FOOT_H
	var n: Control = _ui.get("notice_bar")
	if n != null:
		n.position.y = h - NOTICE_FROM_FOOT


## A revenge card for the i-th score, built from the template when the painting's
## one is not enough.
func _revenge_card(i: int) -> Dictionary:
	while _revenge_cards.size() <= i:
		var built := Layout.instantiate(Layout.element(SCREEN, "revenge_card"))
		built["node"].position.x = Layout.rect_of(Layout.element(SCREEN, "revenge_card")).position.x
		_content.add_child(built["node"])
		_wire_revenge(built, _revenge_cards.size())
		_revenge_cards.append(built)
	return _revenge_cards[i]


func _wire_revenge(c: Dictionary, i: int) -> void:
	c["parts"]["attack"].pressed.connect(_attack_revenge.bind(i))
	# The line above the take, where the painting said "Steal up to 3% gold": a
	# revenge strike takes more, so it is set live from the server's rate.
	var rate := UI.label("", 22, Color("#E6E0D6"), "body", 500, HORIZONTAL_ALIGNMENT_CENTER)
	UI.place(rate, Rect2(506, 62, 216, 30))
	c["node"].add_child(rate)
	c["rate"] = rate
	# How long the chance lasts.
	var left := UI.label("", 20, Color("#F2B8A8"), "body", 500, HORIZONTAL_ALIGNMENT_LEFT)
	UI.place(left, Rect2(270, 180, 210, 30))
	c["node"].add_child(left)
	c["left"] = left


func _show_empty(y: float, title: String, body: String) -> float:
	_empty.position.y = y
	_empty.visible = true
	_empty_title.text = title
	_empty_body.text = body
	return y + EMPTY_H + CARD_GAP


func _build_empty() -> void:
	var np := NinePatchRect.new()
	np.texture = Art.tex("inventory/card_frame")
	for m in ["left", "top", "right", "bottom"]:
		np.set("patch_margin_" + m, 26)
	np.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UI.place(np, Rect2(180, CARD_TOP, 744, EMPTY_H))
	np.self_modulate = Color(0.85, 0.85, 0.9)
	_content.add_child(np)
	_empty = np
	var icon := UI.image("icons/shield_small", Rect2(40, 58, 60, 72))
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	np.add_child(icon)
	_empty_title = UI.label("", 26, UI.GOLD, "title", 700)
	UI.place(_empty_title, Rect2(126, 26, 580, 40))
	np.add_child(_empty_title)
	_empty_body = UI.label("", 22, UI.DIM, "body", 500)
	_empty_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_empty_body.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	UI.place(_empty_body, Rect2(126, 68, 586, 104))
	np.add_child(_empty_body)


func _paint_card(c: Dictionary, t: Dictionary, my_might: int, is_revenge: bool) -> void:
	var p: Dictionary = c["parts"]
	p["portrait"].texture = Art.tex(Art.avatar(str(t.get("avatar", ""))))
	p["crest"].texture = Art.tex(_crest_for(t))
	p["name"].text = str(t.get("name", ""))
	UI.fit_label(p["name"], 30, 18)
	p["level"].text = "LEVEL %d" % int(t.get("level", 1))
	var their := int(t.get("might", 0))
	p["power"].text = UI.grouped(their)
	UI.fit_label(p["power"], 30, 18)
	p["amount"].text = UI.grouped(int(t.get("estimated_steal", 0)))
	UI.fit_label(p["amount"], 27, 18)
	if is_revenge:
		c["rate"].text = "Steal up to %s gold" % _pct(int(t.get("steal_rate_bp", 0)))
		var secs := int(t.get("expires_in", 0))
		c["left"].text = ("%s left to answer" % UI.short_duration(secs)) if secs > 0 else ""
		return
	p["your_num"].text = UI.grouped(my_might)
	p["their_num"].text = UI.grouped(their)
	UI.fit_label(p["your_num"], int(p["your_num"].label_settings.font_size), 14)
	UI.fit_label(p["their_num"], int(p["their_num"].label_settings.font_size), 14)
	var shielded := int(t.get("shield_seconds", 0)) > 0
	p["attack"].visible = not shielded
	p["shield"].visible = shielded
	if shielded:
		p["shield"].get_meta("parts")["time"].text = "Shield  " + UI.short_duration(int(t.get("shield_seconds", 0)))
	_set_bar(c, float(my_might) / maxf(1.0, float(my_might + their)))


static func _pct(bp: int) -> String:
	if bp % 100 == 0:
		return "%d%%" % (bp / 100)
	return "%.1f%%" % (bp / 100.0)


## Five reference pieces: green cap, green stretch, seam, red stretch, red cap.
func _build_bar(c: Dictionary) -> void:
	var host: Control = c["parts"]["bar"] if c["parts"].has("bar") else null
	if host == null:
		return
	var pieces := {}
	for n in ["bar_left", "bar_green", "bar_split", "bar_red", "bar_right"]:
		var img := UI.image("attack/" + n, Rect2(0, 0, 20, 26))
		host.add_child(img)
		pieces[n] = img
	c["bar"] = pieces


func _set_bar(c: Dictionary, frac: float) -> void:
	if not c.has("bar"):
		return
	var b: Dictionary = c["bar"]
	var total := 468.0
	var green := clampf(frac, 0.08, 0.92) * total
	b["bar_left"].position = Vector2(0, 0); b["bar_left"].size = Vector2(40, 26)
	b["bar_green"].position = Vector2(40, 0); b["bar_green"].size = Vector2(maxf(0, green - 40 - 10), 26)
	b["bar_split"].position = Vector2(green - 10, 0); b["bar_split"].size = Vector2(20, 26)
	b["bar_red"].position = Vector2(green + 10, 0); b["bar_red"].size = Vector2(maxf(0, total - 41 - green - 10), 26)
	b["bar_right"].position = Vector2(total - 41, 0); b["bar_right"].size = Vector2(41, 26)


# --- the history -----------------------------------------------------------------------

## A row says what happened from this player's side: "Victory vs. X" and
## "Defeat vs. X" are raids they started; "Held off X" and "Raided by X" are
## raids on them. It used to say Victory or Defeat for both, so a raid that
## emptied the player's purse overnight read "Defeat vs. X" as if they had
## started it.
func _dress_history_row(r: Dictionary, i: int) -> void:
	var p: Dictionary = r["parts"]
	var who := UI.label("", 24, Color("#EDE7DA"), "body", 500)
	UI.place(who, Rect2(p["result"].position, Vector2(320, p["result"].size.y)))
	r["node"].add_child(who)
	r["who"] = who
	var chevron := UI.image("icons/chevron_gold", Rect2(682, 9, 24, 30))
	r["node"].add_child(chevron)
	var hit := UI.hotspot(Rect2(-18, -3, 744, 51), true)
	hit.pressed.connect(_replay.bind(i))
	r["node"].add_child(hit)
	r["hit"] = hit


func _history_words(e: Dictionary) -> Array:
	var won := bool(e.get("won", false))
	var name := str(e.get("opponent_name", ""))
	if bool(e.get("raided", false)):
		return ["Held off" if won else "Raided by", name, UI.GREEN if won else UI.RED]
	return ["Victory" if won else "Defeat", "vs. " + name, UI.GREEN if won else UI.RED]


func _paint_history() -> void:
	_history_empty.visible = _history.is_empty()
	_history_empty.text = "No battles yet."
	var sub: Label = _history_empty.get_meta("sub")
	sub.text = "Every raid you make, and every raid on you, is written here."
	UI.fit_label(sub, 21, 16)
	for i in _history_rows.size():
		var r: Dictionary = _history_rows[i]
		if i >= _history.size():
			r["node"].visible = false
			continue
		r["node"].visible = true
		var e: Dictionary = _history[i]
		var p: Dictionary = r["parts"]
		var words := _history_words(e)
		var won := bool(e.get("won", false))
		p["icon"].texture = Art.tex("icons/sword_victory" if won else "icons/sword_defeat")
		var word: Label = p["result"]
		word.text = str(words[0])
		word.label_settings.font_color = words[2]
		var gap := word.label_settings.font.get_string_size(word.text + " ", HORIZONTAL_ALIGNMENT_LEFT,
			-1, word.label_settings.font_size).x
		var who: Label = r["who"]
		who.text = str(words[1])
		who.position.x = word.position.x + gap
		UI.place(who, Rect2(who.position, Vector2(maxf(40.0, 320.0 - gap), who.size.y)))
		UI.fit_label(who, 24, 16)
		var gold := int(str(e.get("gold", "0")))
		p["gold"].text = (("+" if gold > 0 else "") + UI.grouped(gold)) if gold != 0 else "-"
		p["gold"].label_settings.font_color = Color("#EFC53A") if gold >= 0 else UI.RED
		UI.fit_label(p["gold"], 24, 16)
		p["coin"].visible = gold != 0
		p["time"].text = UI.ago(_seconds_since(str(e.get("at", ""))))


func _seconds_since(iso: String) -> int:
	if iso == "":
		return 0
	var then := Time.get_unix_time_from_datetime_string(iso.trim_suffix("Z"))
	return maxi(0, int(Time.get_unix_time_from_system()) - int(then))


func _crest_for(t: Dictionary) -> String:
	var names := ["icons/crest_wolf", "icons/crest_lion", "icons/crest_stag", "icons/crest_eagle"]
	return names[absi(str(t.get("player_id", t.get("name", ""))).hash()) % names.size()]


# --- actions -------------------------------------------------------------------------

func _attack_revenge(i: int) -> void:
	var revenge: Array = _data.get("revenge", [])
	if i >= revenge.size():
		return
	await _attack(revenge[i], true)


func _attack_target(i: int) -> void:
	var targets: Array = _data.get("targets", [])
	if i >= targets.size():
		return
	await _attack(targets[i], false)


func _attack(t: Dictionary, revenge: bool) -> void:
	if _busy:
		return
	_busy = true
	var cost := int(t.get("energy_cost", _data.get("energy_cost", 0)))
	var have := GameState.display_energy()
	var body := "Costs %d energy%s. Win, and steal up to %s gold." % [cost,
		"" if have >= cost else " -- you have %d" % have, UI.grouped(int(t.get("estimated_steal", 0)))]
	if revenge:
		body = "Revenge: half the energy and a third more gold, shield or no shield.\n" + body
	if not await Dialog.ask(self, {"title": ("Avenge yourself on %s?" if revenge else "Raid %s?") % str(t.get("name", "")),
			"body": body, "confirm_text": "Attack", "danger": true}):
		_busy = false
		return
	var res: Api.Response = await GameState.act("/v1/attack", {"target_id": str(t.get("player_id", "")), "revenge": revenge})
	if res.ok:
		await _show_replay(res.data, t)
	# Held until the page shows the world after the raid, so a second tap on the
	# same ATTACK cannot send a second raid at a card that is already stale.
	await _load()
	_busy = false


func _replay(i: int) -> void:
	if _busy or i >= _history.size():
		return
	_busy = true
	var e: Dictionary = _history[i]
	var res: Api.Response = await Api.get_json("/v1/battles/%s" % str(e.get("battle_id", "")))
	if res.ok:
		await _show_replay(res.data, {"name": str(e.get("opponent_name", "")),
			"avatar": str(e.get("opponent_avatar", ""))})
	_busy = false


## The animated playback of a fight the server resolved.
func _show_replay(result: Dictionary, opponent: Dictionary) -> void:
	var replay: CanvasLayer = load("res://scenes/battle/battle_replay.gd").new()
	replay.setup(result, opponent)
	Nav.overlay_parent().add_child(replay)
	await replay.finished


func _view_all_history() -> void:
	var lines: Array = []
	for e in _history.slice(0, 20):
		var words := _history_words(e)
		var gold := int(str(e.get("gold", "0")))
		lines.append("%s %s   %s   %s" % [words[0], words[1],
			(("+" if gold > 0 else "") + UI.grouped(gold)) if gold != 0 else "-",
			UI.ago(_seconds_since(str(e.get("at", ""))))])
	await Dialog.ask(self, {"title": "Battle history",
		"body": "\n".join(lines) if not lines.is_empty() else "No battles yet.", "confirm_text": "Close"})
