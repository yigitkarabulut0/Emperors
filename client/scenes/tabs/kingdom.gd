extends Control
## KINGDOM — the realm: identity, treasury, reputation, lords, works, ranking.
## Layout: layout/kingdom.json. Without a kingdom the same page offers founding
## and any invitations.

const SCREEN := "kingdom"
const LORD_PORTRAITS := ["portraits/lord_yigit", "portraits/lord_aldric", "portraits/lord_seraphine", "portraits/lord_darian"]
const WORK_ART := ["kingdom/work_banner_hall", "kingdom/work_training_grounds", "kingdom/work_granary_law", "kingdom/work_royal_archives"]
const ROLE_ICON := {"king": "icons/role_king", "captain": "icons/role_captain", "lord": "icons/role_lord"}
## Reputation ranks: name, threshold. The server stores a number; the ladder is presentation.
const RANKS := [["NEUTRAL", 0], ["RESPECTED", 10000], ["HONORED", 50000], ["LEGENDARY", 200000]]
const HEX_ASSETS := ["kingdom/rep_hex_1", "kingdom/rep_hex_2_lit", "kingdom/rep_hex_3", "kingdom/rep_hex_4"]
const HEX_LABELS := ["kingdom/rep_label_neutral", "kingdom/rep_label_respected", "kingdom/rep_label_honored", "kingdom/rep_label_legendary"]
## Where the painting draws the four hexagons and their labels (the card keeps
## them baked, with tier II lit); overlays only where the live state differs.
const HEX_RECTS := [[574, 1028, 47, 59], [656, 1024, 56, 66], [752, 1028, 49, 60], [847, 1028, 49, 60]]
const LABEL_RECTS := [[562, 1090, 68, 22], [644, 1090, 78, 22], [744, 1090, 68, 22], [830, 1090, 82, 22]]
const TAB_ASSETS := {"realm": "kingdom/tab_realm_active", "lords": "kingdom/tab_lords", "works": "kingdom/tab_works", "ranks": "kingdom/tab_ranks"}
const SECTION_Y := {"realm": 0, "lords": 1131, "works": 1131, "ranks": 1483}

var _scroll: ScrollContainer
var _content: Control
var _ui: Dictionary = {}
var _lords: Array = []
var _works: Array = []
var _hexes: Array = []
var _data: Dictionary = {}
var _shop: Dictionary = {}
var _boards: Dictionary = {}
var _loaded_ms := -100000
var _busy := false
var _found_button: TextureButton
var _found_label: Label


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
	_ui = Layout.build(SCREEN, _content)

	_lords = _ui["lord_row"]
	_works = _ui["work_row"]
	for i in _works.size():
		_works[i]["parts"]["upgrade"].pressed.connect(_upgrade.bind(i))
	_ui["donate"].pressed.connect(_donate)
	_ui["edit_name"].pressed.connect(_rename)
	_ui["lords_view_all"].pressed.connect(_lords_dialog)
	_ui["works_view_all"].pressed.connect(_works_dialog)
	_ui["view_rankings"].pressed.connect(_rankings_dialog)
	# Tabs are anchors on a page that shows every section.
	var tabs: Array = _ui["tabs"]
	var names := ["realm", "lords", "works", "ranks"]
	for i in tabs.size():
		var node: Control = tabs[i]["node"]
		var chip: TextureRect = tabs[i]["parts"]["chip"]
		chip.texture = Art.tex(TAB_ASSETS[names[i]])
		chip.size = chip.texture.get_size()
		tabs[i]["parts"]["label"].visible = false
		var hit := UI.hotspot(Rect2(Vector2.ZERO, chip.size))
		hit.pressed.connect(_jump.bind(names[i]))
		node.add_child(hit)
	# Reputation ladder overlays, drawn over the card's baked hexagons.
	for i in HEX_RECTS.size():
		var hr: Array = HEX_RECTS[i]
		var hex := UI.image(HEX_ASSETS[i], Rect2(hr[0], hr[1], hr[2], hr[3]))
		hex.visible = false
		_content.add_child(hex)
		var lr: Array = LABEL_RECTS[i]
		var lab := UI.image(HEX_LABELS[i], Rect2(lr[0], lr[1], lr[2], lr[3]))
		lab.visible = false
		_content.add_child(lab)
		_hexes.append({"hex": hex, "label": lab})
	# Founding / invitations live on the realm card when there is no kingdom.
	_found_button = UI.tex_button("family/btn_upgrade_plate", Rect2(190, 790, 326, 70))
	_found_label = UI.label("FOUND A KINGDOM", 24, UI.INK, "title", 700, HORIZONTAL_ALIGNMENT_CENTER)
	UI.place(_found_label, Rect2(190, 790, 326, 70))
	_found_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_found_button.pressed.connect(_found_or_accept)
	_found_button.visible = false
	_found_label.visible = false
	_content.add_child(_found_button)
	_content.add_child(_found_label)


func refresh() -> void:
	if Time.get_ticks_msec() - _loaded_ms > 3000:
		_load()
	else:
		_paint()


func _load() -> void:
	_loaded_ms = Time.get_ticks_msec()
	var res: Api.Response = await Api.get_json("/v1/kingdom")
	if res.ok:
		_data = res.data
	if bool(_data.get("in_kingdom", false)):
		var sh: Api.Response = await Api.get_json("/v1/kingdom/shop")
		if sh.ok:
			_shop = sh.data
	_paint()


func _kingdom() -> Dictionary:
	var k: Variant = _data.get("kingdom", null)
	return k if k is Dictionary else {}


func _paint() -> void:
	var k := _kingdom()
	var in_kingdom := bool(_data.get("in_kingdom", false)) and not k.is_empty()
	_found_button.visible = not in_kingdom
	_found_label.visible = not in_kingdom
	if not in_kingdom:
		_ui["kingdom_name"].text = "NO KINGDOM"
		var invites: Array = _data.get("invites", [])
		_ui["motto"].text = "Found one at level %d for %s gold%s" % [int(_data.get("found_level", 20)),
			UI.short_number(int(_data.get("found_cost", 0))), (" · %d invitation%s" % [invites.size(), "" if invites.size() == 1 else "s"]) if not invites.is_empty() else ""]
		_found_label.text = "ACCEPT INVITATION" if not invites.is_empty() else "FOUND A KINGDOM"
		_ui["level"].text = "LEVEL -"
		Layout.set_fill(_ui["level_bar_fill"], 0.0)
		for id in ["stat_renown_value", "stat_treasury_value", "stat_members_value"]:
			_ui[id].text = "-"
		_ui["bonus_income"].text = "+0%"
		_ui["bonus_xp"].text = "+0%"
		_ui["rep_rank_name"].text = "-"
		_ui["rep_progress"].text = ""
		Layout.set_fill(_ui["rep_bar_fill"], 0.0)
		for r in _lords:
			r["node"].visible = false
		for w in _works:
			w["node"].visible = false
		_ui["rank"].text = "#-"
		return

	_ui["kingdom_name"].text = str(k.get("name", "")).to_upper()
	UI.fit_label(_ui["kingdom_name"], 48, 26)
	_ui["motto"].text = "[%s] · Kingdom of %d lord%s" % [str(k.get("tag", "")), int(k.get("members", 1)), "" if int(k.get("members", 1)) == 1 else "s"]
	_ui["level"].text = "LEVEL %d" % int(k.get("level", 1))
	var need := int(k.get("xp_to_next", 0))
	Layout.set_fill(_ui["level_bar_fill"], (float(int(k.get("xp", 0))) / float(need)) if need > 0 else 1.0)
	_ui["stat_renown_value"].text = UI.grouped(int(k.get("reputation", 0)))
	_ui["stat_treasury_value"].text = UI.short_number(int(str(k.get("treasury", "0"))))
	_ui["stat_members_value"].text = "%d/%d" % [int(k.get("members", 0)), int(k.get("member_cap", 0))]

	var by_bucket := {}
	for u in _data.get("upgrades", []):
		by_bucket[str(u.get("bucket", ""))] = int(u.get("effect_now", 0))
	_ui["bonus_income"].text = "+%d%%" % (int(by_bucket.get("collect_income_bp", 0)) / 100)
	_ui["bonus_xp"].text = "+%d%%" % (int(by_bucket.get("xp_bp", 0)) / 100)

	_paint_reputation(int(k.get("reputation", 0)))
	_paint_lords()
	_paint_works()
	var rank := 0
	var top: Array = _data.get("leaderboard", [])
	for i in top.size():
		if str(top[i].get("id", "")) == str(k.get("id", "")):
			rank = i + 1
	_ui["rank"].text = "#%d" % rank if rank > 0 else "#-"


func _paint_reputation(rep: int) -> void:
	var idx := 0
	for i in RANKS.size():
		if rep >= int(RANKS[i][1]):
			idx = i
	var next_at: int = int(RANKS[idx + 1][1]) if idx + 1 < RANKS.size() else 0
	_ui["rep_rank_name"].text = RANKS[idx][0]
	if next_at > 0:
		_ui["rep_progress"].text = "%s / %s" % [UI.grouped(rep), UI.grouped(next_at)]
		var floor_at := int(RANKS[idx][1])
		Layout.set_fill(_ui["rep_bar_fill"], float(rep - floor_at) / float(next_at - floor_at))
	else:
		_ui["rep_progress"].text = UI.grouped(rep)
		Layout.set_fill(_ui["rep_bar_fill"], 1.0)
	# The painting shows tier II lit. When another tier is current, tier II is
	# dimmed with a darkened overlay and the current one lifted with a gold tint.
	for i in _hexes.size():
		var h: Dictionary = _hexes[i]
		var show := (idx != 1) and (i == 1 or i == idx)
		h["hex"].visible = show
		h["label"].visible = show
		if not show:
			continue
		if i == idx:
			h["hex"].modulate = Color(1.3, 1.15, 0.75)
			h["label"].modulate = Color(1.3, 1.1, 0.6)
		else:
			h["hex"].modulate = Color(0.45, 0.45, 0.5)
			h["label"].modulate = Color(0.55, 0.55, 0.6)


func _paint_lords() -> void:
	var members: Array = _data.get("members", [])
	members.sort_custom(func(a, b):
		var order := {"king": 0, "captain": 1, "lord": 2}
		var ra: int = order.get(str(a.get("role", "lord")), 2)
		var rb: int = order.get(str(b.get("role", "lord")), 2)
		if ra != rb:
			return ra < rb
		return int(a.get("level", 0)) > int(b.get("level", 0)))
	for i in _lords.size():
		var r: Dictionary = _lords[i]
		var p: Dictionary = r["parts"]
		# The panel keeps four painted rows; an empty row shows the blank plate only.
		for k in p:
			p[k].visible = k == "plate" or i < members.size()
		if i >= members.size():
			continue
		var m: Dictionary = members[i]
		p["portrait"].texture = Art.tex(LORD_PORTRAITS[absi(str(m.get("player_id", "")).hash()) % LORD_PORTRAITS.size()] if str(m.get("player_id", "")) != Session.player_id else LORD_PORTRAITS[0])
		p["online"].texture = Art.tex("icons/dot_online" if str(m.get("player_id", "")) == Session.player_id else "icons/dot_offline")
		p["name"].text = str(m.get("name", "")).to_upper()
		UI.fit_label(p["name"], 24, 14)
		var role := str(m.get("role", "lord"))
		p["role_icon"].texture = Art.tex(ROLE_ICON.get(role, "icons/role_lord"))
		p["role"].text = role.to_upper()
		p["might"].text = "LV %d" % int(m.get("level", 1))


func _paint_works() -> void:
	var ups: Array = _data.get("upgrades", [])
	for i in _works.size():
		var w: Dictionary = _works[i]
		if i >= ups.size():
			w["node"].visible = false
			continue
		w["node"].visible = true
		var u: Dictionary = ups[i]
		var p: Dictionary = w["parts"]
		p["painting"].texture = Art.tex(WORK_ART[i % WORK_ART.size()])
		p["name"].text = str(u.get("name", "")).to_upper()
		UI.fit_label(p["name"], 18, 12)
		p["level"].text = "Lv. %d" % int(u.get("level", 0))
		p["bonus"].text = "%s · %s" % [_bonus_text(u), UI.short_number(int(u.get("next_cost", 0)))] if not bool(u.get("maxed", false)) else _bonus_text(u) + " · MAX"
		UI.fit_label(p["bonus"], 18, 12)
		p["upgrade"].modulate = Color.WHITE if not bool(u.get("maxed", false)) else Color(0.5, 0.5, 0.5)


func _bonus_text(u: Dictionary) -> String:
	var bucket := str(u.get("bucket", ""))
	var eff := int(u.get("effect_now", 0))
	var label := bucket.replace("_bp", "").replace("_flat", "").replace("_", " ").capitalize()
	if bucket.ends_with("_flat"):
		return "+%d %s" % [eff, label]
	return "+%d%% %s" % [eff / 100, label]


# --- actions ------------------------------------------------------------------------

func _jump(section: String) -> void:
	var y: int = SECTION_Y.get(section, 0)
	if section == "realm":
		_scroll.scroll_vertical = 0
	else:
		_scroll.scroll_vertical = maxi(0, y - 120)
	if section == "lords":
		_lords_dialog()
	elif section == "works":
		_works_dialog()
	elif section == "ranks":
		_rankings_dialog()


func _found_or_accept() -> void:
	if _busy:
		return
	var invites: Array = _data.get("invites", [])
	if not invites.is_empty():
		var options: Array = []
		for inv in invites:
			options.append({"id": str(inv.get("kingdom_id", "")), "label": str(inv.get("name", "")), "sub": "[%s] · level %d" % [str(inv.get("tag", "")), int(inv.get("level", 1))]})
		var pick := await Dialog.choose(self, {"title": "Invitations", "options": options})
		if pick == "":
			return
		await _act("/v1/kingdom/accept", {"kingdom_id": pick})
		return
	var level := int(GameState.player().get("level", 1))
	if level < int(_data.get("found_level", 20)):
		GameState.action_failed.emit("Founding needs level %d" % int(_data.get("found_level", 20)))
		return
	var text := await _prompt_text("Name your kingdom", "Kingdom name")
	if text == "":
		return
	var tag := await _prompt_text("A short tag (2-5 letters)", "TAG")
	if tag == "":
		return
	if not await Dialog.ask(self, {"title": "Found %s?" % text, "body": "Costs %s gold." % UI.grouped(int(_data.get("found_cost", 0))), "confirm_text": "Found"}):
		return
	await _act("/v1/kingdom/found", {"name": text, "tag": tag.to_upper()})


func _prompt_text(title: String, placeholder: String) -> String:
	var d := Dialog._Modal.new(self, {"title": title, "placeholder": placeholder, "confirm_text": "OK"}, "amount")
	var action: String = await d.finished
	if action != "confirm":
		return ""
	return d.text_value


func _rename() -> void:
	GameState.action_failed.emit("A kingdom's name is set when it is founded")


func _donate() -> void:
	if _busy or _kingdom().is_empty():
		return
	var me: Dictionary = _data.get("me", {}) if _data.get("me", null) is Dictionary else {}
	var r := await Dialog.prompt_amount(self, {"title": "Donate to the treasury",
		"body": "Donations earn Favour. Today: %s of %s." % [UI.grouped(int(me.get("donated_today", 0))), UI.grouped(int(me.get("daily_cap", 0)))],
		"placeholder": "Gold", "confirm_text": "Donate"})
	if r["action"] != "confirm" or int(r["value"]) <= 0:
		return
	await _act("/v1/kingdom/donate", {"amount": int(r["value"])})


func _upgrade(i: int) -> void:
	var ups: Array = _data.get("upgrades", [])
	if _busy or i >= ups.size():
		return
	var u: Dictionary = ups[i]
	if bool(u.get("maxed", false)):
		return
	if not await Dialog.ask(self, {"title": "Fund %s?" % str(u.get("name", "")),
			"body": "%s\nLevel %d → %d from the treasury for %s gold." % [str(u.get("blurb", "")), int(u.get("level", 0)), int(u.get("level", 0)) + 1, UI.grouped(int(u.get("next_cost", 0)))],
			"confirm_text": "Fund"}):
		return
	await _act("/v1/kingdom/upgrade", {"id": str(u.get("id", ""))})


func _act(path: String, body: Dictionary) -> void:
	_busy = true
	var res: Api.Response = await GameState.act(path, body)
	_busy = false
	if res.ok:
		await _load()


func _lords_dialog() -> void:
	var members: Array = _data.get("members", [])
	if members.is_empty():
		return
	var me: Dictionary = _data.get("me", {}) if _data.get("me", null) is Dictionary else {}
	var options: Array = []
	for m in members:
		options.append({"id": str(m.get("player_id", "")), "label": "%s — %s" % [str(m.get("name", "")), str(m.get("role", "")).to_upper()], "sub": "Level %d · donated %s" % [int(m.get("level", 1)), UI.short_number(int(str(m.get("donated", "0"))))]})
	options.append({"id": "__invite", "label": "Invite a player", "sub": "By username"})
	options.append({"id": "__leave", "label": "Leave the kingdom"})
	var pick := await Dialog.choose(self, {"title": "Royal Lords", "options": options.slice(0, 10)})
	if pick == "":
		return
	if pick == "__invite":
		var name := await _prompt_text("Invite by username", "Username")
		if name == "":
			return
		var found: Api.Response = await Api.get_json("/v1/kingdom/search?q=" + name.uri_encode())
		var target := ""
		for p in found.data.get("players", []) if found.ok else []:
			if str(p.get("name", "")).to_lower() == name.to_lower():
				target = str(p.get("player_id", p.get("id", "")))
		if target == "":
			GameState.action_failed.emit("No player named %s" % name)
			return
		await _act("/v1/kingdom/invite", {"player_id": target})
	elif pick == "__leave":
		if await Dialog.ask(self, {"title": "Leave the kingdom?", "confirm_text": "Leave", "danger": true}):
			await _act("/v1/kingdom/leave", {})
	elif str(me.get("role", "")) == "king" and pick != Session.player_id:
		var role := await Dialog.choose(self, {"title": "Set a role", "options": [{"id": "captain", "label": "Captain"}, {"id": "lord", "label": "Lord"}]})
		if role != "":
			await _act("/v1/kingdom/role", {"player_id": pick, "role": role})


func _works_dialog() -> void:
	var ups: Array = _data.get("upgrades", [])
	var options: Array = []
	for i in ups.size():
		var u: Dictionary = ups[i]
		options.append({"id": "up:%d" % i, "label": "%s  Lv. %d" % [str(u.get("name", "")), int(u.get("level", 0))], "sub": _bonus_text(u) + ("" if bool(u.get("maxed", false)) else " · next %s" % UI.short_number(int(u.get("next_cost", 0))))})
	var favour := int(_shop.get("favour", 0))
	for g in _shop.get("goods", []):
		options.append({"id": "good:" + str(g.get("id", "")), "label": "%s — %d Favour" % [str(g.get("name", "")), int(g.get("cost", 0))], "sub": str(g.get("blurb", ""))})
	var pick := await Dialog.choose(self, {"title": "Kingdom Works · %d Favour" % favour, "options": options.slice(0, 12)})
	if pick == "":
		return
	if pick.begins_with("up:"):
		await _upgrade(int(pick.substr(3)))
	elif pick.begins_with("good:"):
		await _act("/v1/kingdom/shop/buy", {"good": pick.substr(5)})


func _rankings_dialog() -> void:
	var lines: Array = []
	var top: Array = _data.get("leaderboard", [])
	for i in mini(5, top.size()):
		lines.append("#%d  %s  [%s]  Lv %d" % [i + 1, str(top[i].get("name", "")), str(top[i].get("tag", "")), int(top[i].get("level", 1))])
	for board in ["might", "level", "wealth"]:
		var res: Api.Response = await Api.get_json("/v1/leaderboards/" + board)
		if res.ok:
			lines.append("")
			lines.append("%s — you are #%d" % [board.to_upper(), int(res.data.get("my_rank", 0))])
			for row in res.data.get("rows", []).slice(0, 3):
				lines.append("  #%d  %s  %s" % [int(row.get("rank", 0)), str(row.get("name", "")), UI.short_number(int(str(row.get("value", "0"))))])
	await Dialog.ask(self, {"title": "Rankings", "body": "\n".join(lines) if not lines.is_empty() else "No kingdoms yet.", "confirm_text": "Close"})
