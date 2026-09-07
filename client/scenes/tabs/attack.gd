extends Control
## ATTACK — revenge first, then matchmade targets, then the battle history.
## Layout: layout/attack.json. The client never simulates a fight: the server
## returns the outcome and the client shows it.

const SCREEN := "attack"

var _ui: Dictionary = {}
var _revenge_card: Dictionary
var _targets: Array = []          ## built target cards
var _history_rows: Array = []
var _data: Dictionary = {}
var _history: Array = []
var _loaded_ms := -100000
var _busy := false
var _view := "revenge"            ## revenge | targets
var _tab_labels: Dictionary = {}
var _badge: Label


func _ready() -> void:
	_ui = Layout.build(SCREEN, self)
	_revenge_card = _ui["revenge_card"][0]
	_revenge_card["parts"]["attack"].pressed.connect(_attack_revenge)
	_targets = _ui["target_card"]
	for i in _targets.size():
		_targets[i]["parts"]["attack"].pressed.connect(_attack_target.bind(i))
		_build_bar(_targets[i])
	var hp: Dictionary = _ui["history_panel"][0]["parts"]
	_history_rows = hp["row"].get_meta("instances", []) if hp.has("row") else []
	hp["view_all"].pressed.connect(_view_all_history)
	# Tabs: the painted labelled tabs for the reference state; frames + live labels otherwise.
	for id in ["tab_revenge", "tab_targets"]:
		var b: TextureButton = _ui[id]
		b.pressed.connect(_set_view.bind(id.trim_prefix("tab_")))
		var l := UI.label(id.trim_prefix("tab_").to_upper(), 31, Color("#F4F0EA"), "title", 700, HORIZONTAL_ALIGNMENT_CENTER)
		l.visible = false
		add_child(l)
		_tab_labels[id] = l
	_badge = UI.label("", 22, UI.INK, "body", 700, HORIZONTAL_ALIGNMENT_CENTER)
	UI.place(_badge, Rect2(183 + 268, 284 + 14, 40, 34))
	add_child(_badge)
	_apply_tabs()


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
	_paint()


func _set_view(v: String) -> void:
	_view = v
	_apply_tabs()
	_paint()


func _apply_tabs() -> void:
	var spec_r := Layout.element(SCREEN, "tab_revenge")
	var spec_t := Layout.element(SCREEN, "tab_targets")
	var rs: Dictionary = spec_r["states"]["active" if _view == "revenge" else "inactive"]
	var ts: Dictionary = spec_t["states"]["active" if _view == "targets" else "inactive"]
	for pair in [[_ui["tab_revenge"], rs, "tab_revenge"], [_ui["tab_targets"], ts, "tab_targets"]]:
		var b: TextureButton = pair[0]
		var st: Dictionary = pair[1]
		b.texture_normal = Art.tex(str(st["asset"]))
		UI.place(b, Layout.rect_of(st))
		var l: Label = _tab_labels[pair[2]]
		l.visible = st.has("label")
		if st.has("label"):
			var ls: Dictionary = st["label"]
			UI.place(l, Layout.rect_of(ls))
			l.label_settings.font_color = Color(str(ls.get("color", "#F4F0EA")))
			l.label_settings.font_size = int(ls.get("size", 31))
	_badge.visible = _view == "revenge"


func _paint() -> void:
	var revenge: Array = _data.get("revenge", [])
	var targets: Array = _data.get("targets", [])
	var my_might := int(_data.get("might", 0))
	_badge.text = str(revenge.size())
	var show_revenge := _view == "revenge" and not revenge.is_empty()
	_revenge_card["node"].visible = show_revenge
	_ui["divider_targets"].visible = true
	if show_revenge:
		_paint_card(_revenge_card, revenge[0], my_might, true)
	# In the targets view (or with no revenge) the target list moves up into the revenge card's place.
	var list: Array = targets if _view == "targets" or revenge.is_empty() else targets
	var shift := 0.0 if show_revenge else -(Layout.rect_of(Layout.element(SCREEN, "divider_targets")).position.y - 364.0) + 12.0
	_ui["divider_targets"].position.y = Layout.rect_of(Layout.element(SCREEN, "divider_targets")).position.y + shift
	var base := Layout.rect_of(Layout.element(SCREEN, "target_card")).position.y
	var pitch := float(Layout.element(SCREEN, "target_card").get("pitch", 229))
	for i in _targets.size():
		var c: Dictionary = _targets[i]
		if i >= list.size():
			c["node"].visible = false
			continue
		c["node"].visible = true
		c["node"].position.y = base + shift + i * pitch
		_paint_card(c, list[i], my_might, false)
	_paint_history()


func _paint_card(c: Dictionary, t: Dictionary, my_might: int, is_revenge: bool) -> void:
	var p: Dictionary = c["parts"]
	p["portrait"].texture = Art.tex(_portrait_for(t))
	p["crest"].texture = Art.tex(_crest_for(t))
	p["name"].text = str(t.get("name", ""))
	UI.fit_label(p["name"], 30, 18)
	p["level"].text = "LEVEL %d" % int(t.get("level", 1))
	var their := int(t.get("might", 0))
	p["power"].text = UI.grouped(their)
	p["amount"].text = UI.grouped(int(t.get("estimated_steal", 0)))
	if not is_revenge:
		p["your_num"].text = UI.grouped(my_might)
		p["their_num"].text = UI.grouped(their)
		var shielded := t.has("shield_seconds") and int(t.get("shield_seconds", 0)) > 0
		p["attack"].visible = not shielded
		p["shield"].visible = shielded
		if shielded:
			p["shield"].get_meta("parts")["time"].text = "Shield  " + UI.short_duration(int(t.get("shield_seconds", 0)))
		_set_bar(c, float(my_might) / maxf(1.0, float(my_might + their)))


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


func _paint_history() -> void:
	for i in _history_rows.size():
		var r: Dictionary = _history_rows[i]
		if i >= _history.size():
			r["node"].visible = false
			continue
		r["node"].visible = true
		var e: Dictionary = _history[i]
		var p: Dictionary = r["parts"]
		var won := bool(e.get("won", e.get("attacker_won", false)))
		p["icon"].texture = Art.tex("icons/sword_victory" if won else "icons/sword_defeat")
		var who := str(e.get("opponent", e.get("opponent_name", "")))
		p["result"].text = "%s vs. %s" % ["Victory" if won else "Defeat", who]
		p["result"].label_settings.font_color = UI.GREEN if won else UI.RED
		var gold := int(str(e.get("gold", e.get("gold_delta", "0"))))
		p["gold"].text = ("+" if gold > 0 else "") + UI.grouped(gold) if gold != 0 else "-"
		p["coin"].visible = gold != 0
		p["time"].text = UI.ago(int(e.get("seconds_ago", 0)))
	# Tapping a row replays the fight.
	for i in _history_rows.size():
		var r: Dictionary = _history_rows[i]
		if not r.has("hit"):
			var hit := UI.hotspot(Rect2(Vector2.ZERO, r["node"].size))
			hit.pressed.connect(_replay.bind(i))
			r["node"].add_child(hit)
			r["hit"] = hit


func _portrait_for(t: Dictionary) -> String:
	var names := ["portraits/rival_darius", "portraits/rival_seraphine", "portraits/rival_keldric", "portraits/rival_malric"]
	return names[absi(str(t.get("player_id", t.get("name", ""))).hash()) % names.size()]


func _crest_for(t: Dictionary) -> String:
	var names := ["icons/crest_wolf", "icons/crest_lion", "icons/crest_stag", "icons/crest_eagle"]
	return names[absi(str(t.get("player_id", t.get("name", ""))).hash()) % names.size()]


# --- actions -------------------------------------------------------------------------

func _attack_revenge() -> void:
	var revenge: Array = _data.get("revenge", [])
	if revenge.is_empty():
		return
	await _attack(revenge[0], true)


func _attack_target(i: int) -> void:
	var targets: Array = _data.get("targets", [])
	if i >= targets.size():
		return
	await _attack(targets[i], false)


func _attack(t: Dictionary, revenge: bool) -> void:
	if _busy:
		return
	var cost := int(_data.get("energy_cost", 0))
	if revenge:
		cost = int(ceil(cost / 2.0))
	if not await Dialog.ask(self, {"title": "Raid %s?" % str(t.get("name", "")),
			"body": "Costs %d energy. Steal up to %s gold." % [cost, UI.grouped(int(t.get("estimated_steal", 0)))],
			"confirm_text": "Attack", "danger": true}):
		return
	_busy = true
	var res: Api.Response = await GameState.act("/v1/attack", {"target_id": str(t.get("player_id", "")), "revenge": revenge})
	_busy = false
	if res.ok:
		var won := bool(res.data.get("won", res.data.get("attacker_won", false)))
		var gold := int(str(res.data.get("gold", res.data.get("gold_stolen", "0"))))
		await Dialog.ask(self, {"title": "Victory!" if won else "Defeat",
			"body": ("You plundered %s gold." % UI.grouped(gold)) if won else "Your army was driven back.", "confirm_text": "OK"})
		await _load()


func _replay(i: int) -> void:
	if i >= _history.size():
		return
	var e: Dictionary = _history[i]
	var res: Api.Response = await Api.get_json("/v1/battles/%s" % str(e.get("battle_id", "")))
	if not res.ok:
		return
	var rounds: Array = res.data.get("events", res.data.get("rounds", []))
	await Dialog.ask(self, {"title": "Battle replay", "body": "%d rounds. %s" % [rounds.size(),
		"Victory" if bool(res.data.get("attacker_won", false)) else "Defeat"], "confirm_text": "Close"})


func _view_all_history() -> void:
	var lines: Array = []
	for e in _history.slice(0, 12):
		var won := bool(e.get("won", e.get("attacker_won", false)))
		lines.append("%s vs. %s  %s" % ["Victory" if won else "Defeat", str(e.get("opponent", "")), UI.ago(int(e.get("seconds_ago", 0)))])
	await Dialog.ask(self, {"title": "Battle history", "body": "\n".join(lines) if not lines.is_empty() else "No battles yet.", "confirm_text": "Close"})
