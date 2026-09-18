extends Control
## ATTACK — four ways to make war, on one painted header.
##
##   RAID      scores to settle, then matchmade targets, then the history
##   ARENA     the Honour Arena's ladder (scenes/attack/arena_view.gd)
##   CAMPAIGN  the Conquest Campaign's map (scenes/attack/campaign_view.gd)
##   BOUNTIES  the Bounty Board (scenes/attack/bounty_board.gd)
##
## The four-tab strip stands in attack.png's own painted band; RAID's own
## REVENGE / TARGETS strip stands directly under it, and the flow starts under
## both. The page is layers, and what shows is decided PER LAYER, never per
## node -- the rule the Kingdom tab learned the hard way (kingdom.gd), and the
## reason a revenge card cannot turn up on the ARENA.
##
## Layout: layout/attack.json; the two bodies bring their own (layout/arena.json,
## layout/bounties.json) and are laid over this one at (0,0), so every rect in
## them is a screen coordinate.
##
## The client never simulates a fight: the server returns the outcome and the
## client shows it.
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
## The Attack tab's four sub-tabs. Each is gated by its own navigation section,
## and a tab a lord cannot open yet is dimmed and says when it opens rather than
## swallowing the tap -- a plate that eats a finger reads as a broken screen.
const SUBS := ["raid", "arena", "campaign", "bounties"]
const SUB_SCRIPT := {"arena": "res://scenes/attack/arena_view.gd",
	"campaign": "res://scenes/attack/campaign_view.gd",
	"bounties": "res://scenes/attack/bounty_board.gd"}
## Which navigation section opens each. "raid" is the tab's own gate.
const SUB_SECTION := {"raid": "fight", "arena": "arena", "campaign": "campaign",
	"bounties": "bounty"}
## Everything layout/attack.json paints below the strips: RAID's own body.
const RAID_PARTS := ["revenge_card", "divider_targets", "target_card", "history_panel", "notice_bar"]
## The first card, under BOTH strips: the four-tab plates stand on the header's
## gold rule at 353, RAID's own long plates on 452, and the painting's own gap
## between a rule and the card under it is 11.
const CARD_TOP := 463.0
const CARD_GAP := 10.0
const PANEL_GAP := 20.0
const EMPTY_H := 190.0
## The notice sits in the painted foliage at the page's foot, where
## ground_bottom has it baked: 131 units above the bottom, 202 tall with the
## foliage. The live bar is laid exactly over the baked one.
const FOOT_H := 202.0
const NOTICE_FROM_FOOT := 131.0
## Karel the Bandit's card, on the guide's bandit step (scripts/ui/guide.gd):
## the target card with its painted "Steal up to 3% gold" lifted, since his
## purse is the server's own figure and no share of anyone's gold; the words
## above the purse sit where the painting set that line, in the revenge
## card's live rate type.
const BANDIT_CARD := "attack/target_card_plain"
const BANDIT_PURSE_LINE := Rect2(506, 14, 216, 30)
const BANDIT_PURSE_WORDS := "His purse"

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
var _subs: TabStrip              ## RAID / ARENA / CAMPAIGN / BOUNTIES
var _tabs: TabStrip              ## REVENGE / TARGETS, RAID's own row
var _raid: Control               ## the layer holding RAID's body and Karel
var _sub_host: Control           ## where a sub-tab's own body is mounted
var _sub: Control                ## the live sub-tab body, or null on RAID
var _sub_id := "raid"
var _page_h := 1672.0

var _data: Dictionary = {}
var _history: Array = []
var _loaded := false
var _loaded_ms := -100000
var _busy := false
var _view := "revenge"           ## revenge | targets
var _bandit: Dictionary = {}     ## Karel's card, built once
var _army_might := -1            ## the lord's might from /v1/army, while the tab is still locked


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
	var rules := UI.hotspot(Rect2(0, -16, 744, 96), true)
	rules.pressed.connect(_open_rules)
	_ui["notice_bar"].add_child(rules)
	_build_notice_line()
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

	_build_empty()
	_build_bandit()
	_layer_the_page()

	# RAID / ARENA / CAMPAIGN / BOUNTIES in the painting's own band, and RAID's
	# own REVENGE / TARGETS directly under it. The four take the short plates
	# (tabs/short_<id>, already cut); the two take the long ones, as they always
	# have. A strip never mixes the two, so these are two strips and not one.
	_subs = TabStrip.make(SUBS, Layout.rect_of(Layout.element(SCREEN, "subtabs")), _sub_id)
	_subs.changed.connect(_set_sub)
	_subs.refused.connect(func(_id: String, words: String) -> void: GameState.toast(words))
	_content.add_child(_subs)
	_tabs = TabStrip.make(["revenge", "targets"], Layout.rect_of(Layout.element(SCREEN, "tabs")), _view)
	_tabs.changed.connect(_set_view)
	_content.add_child(_tabs)

	_apply_tabs()
	_paint()
	_fit_page()


## Moves what Layout built into the page's layers, keeping the painting's order.
## RAID's body goes in its own layer so that showing the ARENA hides all of it
## at once: a hidden layer draws nothing, which is the only way a card cannot
## come back on a tab it does not belong to.
func _layer_the_page() -> void:
	_raid = _layer()
	_sub_host = _layer()
	_sub_host.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var mine := {}
	for id in RAID_PARTS:
		if not _ui.has(id):
			continue
		var v: Variant = _ui[id]
		if v is Control:
			mine[v] = true
		elif v is Array:
			for inst in v:
				mine[inst["node"]] = true
	if _empty != null:
		mine[_empty] = true
	if not _bandit.is_empty():
		mine[_bandit["node"]] = true
	# Collected first, then moved: reparenting inside the loop mutates the list
	# being walked, and half the body would stay in the page -- which is exactly
	# how RAID's notice bar turned up over the ARENA.
	var move: Array = []
	for c in _content.get_children():
		if c != _raid and c != _sub_host and mine.has(c):
			move.append(c)
	for c in move:
		(c as Node).reparent(_raid)
	# The foliage along the foot is the page's, above every layer.
	var ground: Control = _ui.get("ground_bottom")
	if ground != null and ground.get_parent() == _content:
		_content.move_child(ground, 0)


## A full-page layer that ignores the mouse, so the strips, the buttons and the
## drag that scrolls the page all reach what is underneath.
func _layer() -> Control:
	var l := Control.new()
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.position = Vector2.ZERO
	l.size = Vector2(941, 1672)
	_content.add_child(l)
	return l


## Opens one of the four. Public, so --sub and the shell can use it.
func open_sub(which: String) -> void:
	if not SUBS.has(which):
		return
	_set_sub(which)


## Which sub-tab is showing, and its body (null on RAID). For tests.
func sub() -> Control:
	return _sub


func _set_sub(which: String) -> void:
	if _sub_id == which:
		return
	_sub_id = which
	_free_sub()
	var on_raid := which == "raid"
	_raid.visible = on_raid
	_tabs.visible = on_raid
	_subs.select(which)
	_scroll.scroll_vertical = 0
	if on_raid:
		_paint()
		_fit_page()
		return
	var script: GDScript = load(SUB_SCRIPT[which])
	_sub = script.new()
	_sub.connect("grew", func(_h: float) -> void: _fit_page())
	if _sub.has_signal("scroll_to"):
		# A body inside the tab's scroll cannot move it; it asks, and the tab
		# does it once its own height has been worked out.
		_sub.connect("scroll_to", func(y: float) -> void:
			_fit_page()
			await get_tree().process_frame
			_scroll.scroll_vertical = int(maxf(0.0, y)))
	_sub_host.add_child(_sub)
	_sub.call("refresh")
	_fit_page()


func _free_sub() -> void:
	if _sub != null:
		_sub.queue_free()
		_sub = null


## Lights the four, and dims the ones this lord cannot open yet. A dimmed tab
## still answers: it says when it opens, as the rail's locked entries do.
func _apply_subs() -> void:
	if _subs == null:
		return
	for id in SUBS:
		var section := str(SUB_SECTION.get(id, ""))
		if section == "" or GameState.is_unlocked(section):
			_subs.set_enabled(id, true)
		else:
			_subs.set_off(id, "Unlocks at level %d" % GameState.unlock_level(section))
	_subs.set_count("bounties", int(GameState.badges.get("bounty_on_me", 0)))
	_subs.set_count("campaign", int(GameState.badges.get("campaign", 0)))
	_subs.set_count("raid", (_data.get("revenge", []) as Array).size())


func _unanchor(n: Control) -> void:
	var r := Rect2(n.position, n.size)
	n.anchor_top = 0.0
	n.anchor_bottom = 0.0
	n.grow_vertical = Control.GROW_DIRECTION_END
	n.position = r.position
	n.size = r.size


func refresh() -> void:
	if _sub != null:
		_sub.call("refresh")
		return
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
	# Before the tab's own level the targets say nothing of the lord's might;
	# Karel's card weighs it against his, from the army.
	if Guide.bandit_step() and not res.ok:
		var army: Api.Response = await Api.get_json("/v1/army")
		if army.ok:
			_army_might = int(army.data.get("totals", {}).get("might", 0))
	_paint()
	# Dev: --replay-last opens the most recent battle's playback on arrival.
	if Env.args.has("replay_last") and not _history.is_empty():
		Env.args.erase("replay_last")
		_replay(0)


func _set_view(v: String) -> void:
	if _sub_id != "raid":
		open_sub("raid")
	if _view == v:
		return
	_view = v
	_apply_tabs()
	_paint()
	_scroll.scroll_vertical = 0


## Lights the tab being shown, and counts the scores waiting on REVENGE in the
## rail's own bubble -- whichever tab is lit, since it is on TARGETS that a
## player needs telling. None waiting, no bubble: an empty one reads as though
## something were.
func _apply_tabs() -> void:
	_tabs.select(_view)
	_tabs.set_count("revenge", (_data.get("revenge", []) as Array).size())
	_apply_subs()


# --- the flow ------------------------------------------------------------------------

func _paint() -> void:
	_apply_tabs()
	if _sub_id != "raid":
		return
	for c in _revenge_cards:
		c["node"].visible = false
	for c in _targets:
		c["node"].visible = false
	_empty.visible = false
	_ui["divider_targets"].visible = false
	var y := _paint_bandit(CARD_TOP)
	# Below the tab's own level Karel's card is all it holds: the scores, the
	# targets and the history are the raiding the lord cannot do yet.
	if not _loaded or (Guide.bandit_step() and not GameState.is_unlocked("fight")):
		# Nothing on the painting's sample cards until the server has answered.
		_history_panel.visible = false
		_ui["notice_bar"].visible = false
		return
	_history_panel.visible = true
	_ui["notice_bar"].visible = true
	_paint_notice()

	var revenge: Array = _data.get("revenge", [])
	var targets: Array = _data.get("targets", [])
	var my_might := int(_data.get("might", 0))

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
	var flow := _page_h
	if _sub != null and _sub.has_method("height"):
		flow = float(_sub.call("height")) + NOTICE_FROM_FOOT
	var h := maxf(flow, _scroll.size.y if _scroll.size.y > 0 else 1672.0)
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


func _build_bandit() -> void:
	var tpl := Layout.element(SCREEN, "target_card")
	var built := Layout.instantiate(tpl, {"assets": {"frame": BANDIT_CARD}})
	built["node"].position.x = Layout.rect_of(tpl).position.x
	built["node"].visible = false
	_content.add_child(built["node"])
	built["parts"]["attack"].pressed.connect(_fight_bandit)
	_build_bar(built)
	var purse := UI.label("", 22, Color("#E6E0D6"), "body", 500, HORIZONTAL_ALIGNMENT_CENTER)
	UI.place(purse, BANDIT_PURSE_LINE)
	built["node"].add_child(purse)
	built["purse"] = purse
	_bandit = built
	GuideTargets.register("attack.bandit", built["parts"]["attack"])


## Karel's card at `y` while the steward's bandit step runs (the server's
## preview: name, face, level, might, purse), and where the flow goes on
## below it. Nothing, and `y` back, otherwise.
func _paint_bandit(y: float) -> float:
	if _bandit.is_empty():
		return y
	var node: Control = _bandit["node"]
	node.visible = Guide.bandit_step()
	if not node.visible:
		return y
	var b: Dictionary = GameState.guide().get("bandit", {})
	var t := {"name": str(b.get("name", "")), "avatar": str(b.get("avatar", "bandit")),
		"level": int(b.get("level", 1)), "player_id": "bandit"}
	var p: Dictionary = _bandit["parts"]
	p["portrait"].texture = Art.tex(Art.avatar(str(t["avatar"])))
	Look.paint_frame(p["portrait"], t, "square", FRAME_BAND)
	Look.paint_crest(p["crest"], crest_for(t))
	var name_box := _part_rect("target_card", "name")
	name_box.size.x -= NAME_CLEAR
	Look.paint_name(p["name"], t, str(t["name"]), name_box, NAME_SIZE, 18)
	p["level"].text = "LEVEL %d" % int(t["level"])
	_paint_title(_bandit, t, "target_card")
	var his := int(b.get("might", 0))
	p["power"].text = UI.grouped(his)
	UI.fit_label(p["power"], 30, 18)
	p["amount"].text = UI.grouped(int(b.get("purse", 0)))
	UI.fit_label(p["amount"], 27, 18)
	(_bandit["purse"] as Label).text = BANDIT_PURSE_WORDS
	var mine := int(_data.get("might", _army_might if _army_might >= 0 else 0))
	p["your_num"].text = UI.grouped(mine)
	p["their_num"].text = UI.grouped(his)
	UI.fit_label(p["your_num"], int(p["your_num"].label_settings.font_size), 14)
	UI.fit_label(p["their_num"], int(p["their_num"].label_settings.font_size), 14)
	p["attack"].visible = true
	p["shield"].visible = false
	_set_bar(_bandit, float(mine) / maxf(1.0, float(mine + his)))
	node.position.y = y
	return y + node.size.y + CARD_GAP


## Karel's FIGHT: the steward's fight, played on the battle screen (Guide).
func _fight_bandit() -> void:
	if _busy:
		return
	_busy = true
	await Guide.fight_bandit(self)
	_busy = false
	_paint()


func _build_empty() -> void:
	# The same object the Honour Arena shows over a thin ladder (UI.empty_card).
	var card := UI.empty_card(_content, Rect2(180, CARD_TOP, 744, EMPTY_H))
	_empty = card["node"]
	_empty_title = card["title"]
	_empty_body = card["body"]


## How a rival looks on a card (scripts/ui/look.gd): the frame they wear over
## the portrait, its band over the card's own painted frame (133x136 round the
## 125x127 window); their name in their colour with the seal after it; the
## title they wear on the level's line, after LEVEL; their crest.
const FRAME_BAND := 136.0
const NAME_SIZE := 30
## The name, and a seal after it, stop this far short of the painted name box's
## end, so the seal is not pressed against the take's column ("Steal up to...").
const NAME_CLEAR := 14.0
## The title rides the level line, after the level, up to where the take's
## column begins (x 580 of the card).
const TITLE_RIGHT := 580.0
const TITLE_GAP := 16.0


func _paint_card(c: Dictionary, t: Dictionary, my_might: int, is_revenge: bool) -> void:
	var p: Dictionary = c["parts"]
	var card := "revenge_card" if is_revenge else "target_card"
	p["portrait"].texture = Art.tex(Art.avatar(str(t.get("avatar", ""))))
	Look.paint_frame(p["portrait"], t, "square", FRAME_BAND)
	Look.paint_crest(p["crest"], crest_for(t))
	var name_box := _part_rect(card, "name")
	name_box.size.x -= NAME_CLEAR
	Look.paint_name(p["name"], t, str(t.get("name", "")), name_box, NAME_SIZE, 18)
	p["level"].text = "LEVEL %d" % int(t.get("level", 1))
	_paint_title(c, t, card)
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
	var page: GDScript = load("res://scenes/pages/history_page.gd")
	return page.words(e)


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


## A rival's crest: the one they wear, else one of the twelve by the lord's id
## (Art.crest, the rule the hall uses for kingdoms), so the same lord always
## wears the same crest.
func crest_for(t: Dictionary) -> String:
	return Look.crest(t, str(t.get("player_id", t.get("name", ""))))


## A part's rect in its card, as the layout measured it.
func _part_rect(card: String, part: String) -> Rect2:
	for q in Layout.element(SCREEN, card).get("parts", []):
		if str(q.get("id", "")) == part:
			return Layout.rect_of(q)
	return Rect2()


## The title a rival wears, on the level's line after LEVEL: made once per card.
func _paint_title(c: Dictionary, t: Dictionary, card: String) -> void:
	var level: Label = c["parts"]["level"]
	if not c.has("title"):
		var l := UI.label("", 21, UI.GOLD_DIM, "body", 600)
		l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		level.get_parent().add_child(l)
		c["title"] = l
	var lr := _part_rect(card, "level")
	var f: Font = level.label_settings.font
	var x := lr.position.x + f.get_string_size(level.text, HORIZONTAL_ALIGNMENT_LEFT, -1,
		level.label_settings.font_size).x + TITLE_GAP
	Look.paint_title(c["title"], t, Rect2(x, lr.position.y, TITLE_RIGHT - x, lr.size.y), 21, 13)


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


## A raid asked for from somewhere else -- a lord's own page (rival_page.gd) --
## which lands in this tab's own flow: its confirm, its energy, its refusals and
## its replay. A lord already on the list is raided as their card would be; one
## who is not (the list is a band of twelve, and a page is any lord at all) is
## raided by their id, and the realm answers for whether they may be.
func raid_lord(player_id: String, lord_name := "") -> void:
	if player_id == "":
		return
	if not _loaded:
		await _load()
	for t in _data.get("targets", []):
		if t is Dictionary and str(t.get("player_id", "")) == player_id:
			await _attack(t, false)
			return
	await _attack({"player_id": player_id, "name": lord_name}, false)


func _attack(t: Dictionary, revenge: bool) -> void:
	if _busy:
		return
	_busy = true
	var cost := int(t.get("energy_cost", _data.get("energy_cost", 0)))
	var have := GameState.display_energy()
	var body := "Costs %d energy%s." % [cost, "" if have >= cost else " -- you have %d" % have]
	if t.has("estimated_steal"):
		# A lord raided from their own page is not on this list and their purse
		# is not ours to know: the line is left off rather than written as zero.
		body += " Win, and steal up to %s gold." % UI.grouped(int(t.get("estimated_steal", 0)))
	if revenge:
		body = "Revenge: half the energy and a third more gold, shield or no shield.\n" + body
	var warning := raid_warning(revenge, GameState.display_shield_seconds(), _data.get("rules", {}))
	if warning != "":
		body = warning + "\n" + body
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


## What raiding costs a lord who is shielded: the shield. Said before the tap,
## because a shield bought with diamonds and lost to a raid the player did not
## know would end it is a purchase they were not told the terms of. A revenge
## strike keeps the shield, and a server that does not break shields (rules
## without shield_breaks) gets no warning.
static func raid_warning(revenge: bool, shield_seconds: int, rules: Dictionary) -> String:
	if revenge or shield_seconds <= 0 or not bool(rules.get("shield_breaks", false)):
		return ""
	return "Attacking ends your shield (%s left)." % UI.short_duration(shield_seconds)


func _replay(i: int) -> void:
	if i < _history.size():
		await _replay_entry(_history[i])


func _replay_entry(e: Dictionary) -> void:
	if _busy:
		return
	_busy = true
	var res: Api.Response = await Api.get_json("/v1/battles/%s" % str(e.get("battle_id", "")))
	if res.ok:
		await _show_replay(res.data, replay_opponent(e))
	_busy = false


## Who a history entry's replay is against: their name and face, and the look
## the entry carries (opponent_look), so the battle names them in the colour and
## seal they wear, as a raid card's replay already does.
static func replay_opponent(e: Dictionary) -> Dictionary:
	var look: Variant = e.get("opponent_look", {})
	return {"name": str(e.get("opponent_name", "")), "avatar": str(e.get("opponent_avatar", "")),
		"look": look if look is Dictionary else {}}


## The animated playback of a fight the server resolved.
func _show_replay(result: Dictionary, opponent: Dictionary) -> void:
	var replay: CanvasLayer = load("res://scenes/battle/battle_replay.gd").new()
	replay.setup(result, opponent)
	Nav.overlay_parent().add_child(replay)
	await replay.finished


func _view_all_history() -> void:
	var page: GDScript = load("res://scenes/pages/history_page.gd")
	page.open(self, _history, _replay_entry)


## THE NOTICE'S LIVE LINE.
##
## The painting bakes one sentence into `attack/notice_bar` and the manifest cut
## `notice_bar_blank` beside it with those words lifted, recording the rect and
## the type they were set in (attack.layout.json's `alt`). Nothing used it, so
## the bar could only ever say the one painted thing -- and `scouted_today`, which
## the server sends BECAUSE being looked over is a thing that happens to a lord
## and should be felt where the raiding is, was never said anywhere at all.
##
## With something live to say the bar wears the blank plate and says it; with
## nothing, it is the painting's own sentence, unchanged.
func _build_notice_line() -> void:
	var bar: Control = _ui.get("notice_bar")
	if bar == null:
		return
	var alt: Dictionary = Layout.element(SCREEN, "notice_bar").get("alt", {})
	var part: Dictionary = alt.get("text", {})
	if part.is_empty():
		return
	# The alt's rect is the PAINTING's, and the label goes inside the bar, so it
	# is laid against the bar's own corner.
	var l := Layout.part(part, -Layout.rect_of(Layout.element(SCREEN, "notice_bar")).position)
	if l == null:
		return
	l.name = "live_line"
	l.visible = false
	bar.add_child(l)


## What the notice says beyond its painted sentence. Empty keeps the painting.
static func notice_line(data: Dictionary) -> String:
	var scouted := int(data.get("scouted_today", 0))
	if scouted <= 0:
		return ""
	if scouted == 1:
		return "A lord bought a look at your army today."
	return "%d lords bought a look at your army today." % scouted


func _paint_notice() -> void:
	var bar: TextureRect = _ui.get("notice_bar") as TextureRect
	if bar == null:
		return
	var l: Label = bar.get_node_or_null("live_line") as Label
	var words := notice_line(_data)
	if l == null:
		return
	if words == "":
		bar.texture = Art.tex("attack/notice_bar")
		l.visible = false
		return
	bar.texture = Art.tex("attack/notice_bar_blank")
	l.text = words
	l.visible = true
	UI.fit_line(l, int(Layout.element(SCREEN, "notice_bar").get("alt", {}).get("text", {}).get("size", 25)), 18)


## The (i) on the notice: the rules of raiding, with the server's numbers.
func _open_rules() -> void:
	var page: GDScript = load("res://scenes/pages/rules_page.gd")
	page.open(self, _data.get("rules", {}))
