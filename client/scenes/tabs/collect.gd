extends Control
## COLLECT — today's quests and the job list. Layout: layout/collect.json.
##
## The screen renders what the server sent: payouts are resolved values, the
## counter is collects / next milestone, and a tap queues an optimistic collect
## through GameState (confirmed + replay(pending) is what the pills show).

const SCREEN := "collect"
const PAINTINGS := ["collect/job_grapes", "collect/job_strawberries", "collect/job_wheat",
	"collect/job_timber", "collect/job_stone", "collect/job_tax"]
const PAINTING_BY_WORD := {"grape": 0, "berr": 1, "wheat": 2, "timber": 3, "wood": 3, "log": 3,
	"stone": 4, "quarry": 4, "tax": 5}

var _ui: Dictionary = {}
var _rows: Array = []            ## [{node, parts, job_id}]
var _quests: Array = []
var _quest_cards: Array = []
var _quests_loaded_ms := -100000
var _built := false
var _busy := false


func _ready() -> void:
	_ui = Layout.build(SCREEN, self)
	_quest_cards = _ui.get("quest_card", [])
	for i in _quest_cards.size():
		var hit := UI.hotspot(Rect2(Vector2.ZERO, _quest_cards[i]["node"].size))
		hit.pressed.connect(_claim_quest.bind(i))
		_quest_cards[i]["node"].add_child(hit)
	var sc: ScrollContainer = _ui["job_list"]
	sc.scroll_deadzone = 14
	_built = true
	GameState.energy_changed.connect(func(_v: int) -> void: _paint_rows())
	set_process(true)


func refresh() -> void:
	if not _built:
		return
	_ensure_rows()
	_paint_rows()
	_paint_quests()
	if Time.get_ticks_msec() - _quests_loaded_ms > 3000:
		_load_quests()


func _process(_dt: float) -> void:
	if not visible:
		return
	var l: Label = _ui.get("quests_reset")
	if l != null:
		l.text = "Resets in " + UI.duration(_seconds_to_local_midnight())


# --- jobs -------------------------------------------------------------------------

func _ensure_rows() -> void:
	var jobs: Array = GameState.jobs().duplicate()
	jobs.sort_custom(func(a, b): return int(a.get("order", 0)) < int(b.get("order", 0)))
	if _rows.size() == jobs.size():
		return
	var sc: ScrollContainer = _ui["job_list"]
	var content: Control = sc.get_meta("content")
	for r in _rows:
		r["node"].queue_free()
	_rows.clear()
	var tpl := Layout.element(SCREEN, "job_row")
	var origin := Layout.rect_of(tpl).position - Layout.rect_of(Layout.element(SCREEN, "job_list")).position
	var pitch := float(tpl.get("pitch", 168))
	for i in jobs.size():
		var job: Dictionary = jobs[i]
		var built := Layout.instantiate(tpl, {"assets": {"tile": _painting_for(job, i)}})
		built["node"].position = origin + Vector2(0, i * pitch)
		content.add_child(built["node"])
		built["job_id"] = str(job.get("id", ""))
		var btn: TextureButton = built["parts"]["collect"]
		btn.pressed.connect(_on_collect.bind(str(job.get("id", ""))))
		_rows.append(built)
	content.custom_minimum_size = Vector2(sc.size.x, origin.y + jobs.size() * pitch + 8)


func _painting_for(job: Dictionary, index: int) -> String:
	var key := (str(job.get("id", "")) + " " + str(job.get("name", ""))).to_lower()
	for word in PAINTING_BY_WORD:
		if key.contains(word):
			return PAINTINGS[PAINTING_BY_WORD[word]]
	return PAINTINGS[index % PAINTINGS.size()]


func _job(id: String) -> Dictionary:
	for j in GameState.jobs():
		if str(j.get("id", "")) == id:
			return j
	return {}


func _paint_rows() -> void:
	for r in _rows:
		var job := _job(r["job_id"])
		if job.is_empty():
			continue
		var p: Dictionary = r["parts"]
		var name: String = str(job.get("name", "")).to_upper()
		var name_label: Label = p["name"]
		name_label.text = name
		name_label.label_settings.font_size = 24 if name.length() <= 18 else 19
		p["energy"].text = str(int(job.get("energy_cost", 0)))
		p["gold"].text = UI.grouped(int(job.get("gold_payout", 0)))
		p["xp"].text = UI.grouped(int(job.get("xp_payout", 0)))
		var unlocked := bool(job.get("unlocked", false))
		var next := int(job.get("next_milestone", 0))
		var collects := int(job.get("collects", 0))
		if not unlocked:
			p["counter"].text = "LV %d" % int(job.get("unlock_level", 1))
		elif next <= 0:
			p["counter"].text = "%d / MAX" % collects
		else:
			p["counter"].text = "%d / %d" % [collects, next]
		var tier: Array = ["25  +5%", "50  +10%", "100  +15%"] if next <= 100 else ["250  +20%", "500  +25%", "1000  +30%"]
		p["mastery_1"].text = tier[0]
		p["mastery_2"].text = tier[1]
		p["mastery_3"].text = tier[2]
		r["node"].modulate = Color.WHITE if unlocked else Color(0.55, 0.55, 0.55)


func _on_collect(job_id: String) -> void:
	var job := _job(job_id)
	if job.is_empty():
		return
	if not bool(job.get("unlocked", false)):
		GameState.action_failed.emit("Unlocks at level %d" % int(job.get("unlock_level", 1)))
		return
	if not GameState.collect(job):
		GameState.action_failed.emit("Not enough energy")


# --- quests -----------------------------------------------------------------------

func _load_quests() -> void:
	_quests_loaded_ms = Time.get_ticks_msec()
	var res: Api.Response = await Api.get_json("/v1/quests")
	if res.ok:
		_quests = res.data.get("quests", [])
		_paint_quests()


func _paint_quests() -> void:
	for i in _quest_cards.size():
		var p: Dictionary = _quest_cards[i]["parts"]
		if i >= _quests.size():
			_quest_cards[i]["node"].visible = false
			continue
		_quest_cards[i]["node"].visible = true
		var q: Dictionary = _quests[i]
		var target := int(q.get("target", 0))
		var progress := mini(int(q.get("progress", 0)), target)
		p["title"].text = _quest_title(q)
		p["progress"].text = "%d / %d" % [progress, target]
		Layout.set_fill(p["bar_fill"], float(progress) / maxf(1.0, float(target)))
		p["reward_icon"].texture = Art.tex("icons/reward_crown")
		var claimed := bool(q.get("claimed", false))
		var done := bool(q.get("done", false))
		if claimed:
			p["reward"].text = "CLAIMED"
			p["reward"].label_settings.font_color = UI.DIM
		elif done:
			p["reward"].text = "CLAIM +%d XP" % int(q.get("xp", 0))
			p["reward"].label_settings.font_color = UI.GREEN
		else:
			p["reward"].text = "+%d XP" % int(q.get("xp", 0))
			p["reward"].label_settings.font_color = Color("#F3EDE0")


func _quest_title(q: Dictionary) -> String:
	var id := str(q.get("id", ""))
	var n := int(q.get("target", 0))
	if id.begins_with("collect_"):
		return "Collect\n%d times" % n
	if id.begins_with("energy_"):
		return "Spend\n%d energy" % n
	if id.begins_with("win_"):
		return "Defeat\n%d rival%s" % [n, "" if n == 1 else "s"]
	return str(q.get("name", ""))


func _claim_quest(i: int) -> void:
	if _busy or i >= _quests.size():
		return
	var q: Dictionary = _quests[i]
	if not bool(q.get("done", false)) or bool(q.get("claimed", false)):
		return
	_busy = true
	var res: Api.Response = await GameState.act("/v1/quests/claim", {"slot": int(q.get("slot", i))})
	_busy = false
	if res.ok:
		GameState.action_failed.emit("Quest reward claimed")
		await _load_quests()


func _seconds_to_local_midnight() -> int:
	var now := Time.get_datetime_dict_from_system()
	var passed := int(now.get("hour", 0)) * 3600 + int(now.get("minute", 0)) * 60 + int(now.get("second", 0))
	return 86400 - passed
