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

## The reward row's geometry, from layout/collect.json's quest_card parts.
## reward_icon sits at x 57 and the reward text at x 104..224, so the row a
## claimed quest fills runs from 57 to 224.
const REWARD_TEXT_X := 104.0
const REWARD_TEXT_W := 120.0
const REWARD_ROW_W := 167.0

## Font sizes a row's name and its collect counter are fitted between (max, min):
## the painting's size when the text fits its box, smaller only when it would not.
const NAME_FIT := Vector2i(24, 14)
const COUNTER_FIT := Vector2i(24, 16)
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
		built["empty"] = _build_empty_face(btn)
		_rows.append(built)
	content.custom_minimum_size = Vector2(sc.size.x, origin.y + jobs.size() * pitch + 8)


## The "no energy" face of a Collect button.
##
## The button's green field, its gold frame and the word COLLECT are one painted
## texture, so there is no tint that turns it red -- modulate multiplies, and
## green times red is nearly black -- and an overlay rectangle is worse: it
## leaves green showing along the frame's chamfered corners and reads as a
## sticker laid on the button rather than as the button.
##
## So the red face is a second texture of the same painting, baked by
## tools/make_empty_button.gd: the word inpainted away and the field's hue
## rotated to crimson, with every pixel of the frame, bevel, vignette and
## silhouette kept. Swapping texture_normal swaps the whole button; the word
## NO ENERGY is then a normal label over the empty field.
##
## Returns the label, which _paint_rows() shows or hides; the swap rides along
## with it so the two can never disagree.
func _build_empty_face(btn: TextureButton) -> Label:
	var l := UI.label("NO ENERGY", 24, Color("#F7E7DA"), "body", 700, HORIZONTAL_ALIGNMENT_CENTER)
	l.set_anchors_preset(Control.PRESET_FULL_RECT)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.visible = false
	btn.add_child(l)
	return l


## Puts a Collect button on its green or its red face.
func _set_empty(row: Dictionary, empty: bool) -> void:
	var l: Label = row.get("empty")
	if l == null:
		return
	if l.visible == empty:
		return
	l.visible = empty
	var btn: TextureButton = row["parts"]["collect"]
	btn.texture_normal = Art.tex("collect/collect_button_empty" if empty else "collect/collect_button")


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
		# Fitted to the box the painting gives a name, so the longest ("PLUNDER THE
		# DRAGON'S HOARD") stops where the counter begins instead of running under it.
		UI.fit_label(name_label, NAME_FIT.x, NAME_FIT.y)
		p["energy"].text = str(int(job.get("energy_cost", 0)))
		p["gold"].text = UI.grouped(int(job.get("gold_payout", 0)))
		p["xp"].text = UI.grouped(int(job.get("xp_payout", 0)))
		var unlocked := bool(job.get("unlocked", false))
		var next := int(job.get("next_milestone", 0))
		# Confirmed plus the taps still in flight, the same sum the pills show.
		var collects := int(job.get("collects", 0)) + GameState.pending_collects(r["job_id"])
		if not unlocked:
			p["counter"].text = "LV %d" % int(job.get("unlock_level", 1))
		elif next <= 0:
			p["counter"].text = "%d / MAX" % collects
		else:
			p["counter"].text = "%d / %d" % [collects, next]
		# The painting's counter reads "0 / 25"; "1500 / MAX" is twice as wide. The
		# box ends where the painted figure does, 36 units clear of the button, and
		# a long figure shrinks to stay inside it -- a Label grows to its text, so
		# without this the count walked right until it sat on the COLLECT button.
		UI.fit_label(p["counter"], COUNTER_FIT.x, COUNTER_FIT.y)
		_paint_mastery(p, job.get("mastery", {}), collects)
		r["node"].modulate = Color.WHITE if unlocked else Color(0.55, 0.55, 0.55)

		# Energy is projected between polls rather than polled, so this is driven
		# by GameState.energy_changed as well as by a state refresh -- the button
		# has to go back to green the moment the bar ticks over the cost.
		var short_of_energy := unlocked \
			and GameState.display_energy() < int(job.get("energy_cost", 0))
		_set_empty(r, short_of_energy)


## The mastery track under a row: three painted markers labelled with the
## stretch of the ladder the player is on -- the threshold reached (its bonus is
## the one in force), the next, and the one after -- and a fill that runs from
## the first marker toward the second as the count climbs. The server resolves
## the stretch (JobView.mastery); this only places it. Zero thresholds mean
## none: a fresh row reads "0  +0%  |  25  +5%  |  50  +10%", a finished one
## carries MAX on the last marker and a full track.
func _paint_mastery(p: Dictionary, m: Dictionary, collects: int) -> void:
	var reached := int(m.get("reached", 0))
	var next := int(m.get("next", 0))
	var after := int(m.get("after", 0))
	p["mastery_1"].text = _milestone_label(reached, int(m.get("reached_bp", 0)))
	p["mastery_2"].text = _milestone_label(next, int(m.get("next_bp", 0))) if next > 0 else "MAX"
	p["mastery_3"].text = _milestone_label(after, int(m.get("after_bp", 0))) if after > 0 else ("MAX" if next > 0 else "")
	Layout.set_fill(p["mastery_fill"], mastery_fill_fraction(p, reached, next, collects))
	# The marker the fill has reached is lit; the ones ahead wait.
	var lit := [true, next == 0, false]
	for i in 3:
		p["mastery_marker_%d" % (i + 1)].modulate = Color.WHITE if lit[i] else Color(0.55, 0.55, 0.55)


static func _milestone_label(collects: int, bp: int) -> String:
	return "%d  +%d%%" % [collects, bp / 100]


## How much of the track to fill: the first marker stands for the threshold
## reached, the second for the next one, and the count's place between them is
## the fill's place between the two markers. A finished ladder fills the track.
## Geometry comes from the layout parts, never from numbers held here.
static func mastery_fill_fraction(p: Dictionary, reached: int, next: int, collects: int) -> float:
	var fill: Control = p["mastery_fill"]
	var track_x: float = fill.position.x
	var track_w: float = float(fill.get_meta("full", fill.size).x)
	if next <= 0:
		return 1.0
	var m1: Control = p["mastery_marker_1"]
	var m2: Control = p["mastery_marker_2"]
	var x1 := m1.position.x + m1.size.x / 2.0
	var x2 := m2.position.x + m2.size.x / 2.0
	var t := clampf(float(collects - reached) / float(next - reached), 0.0, 1.0)
	return clampf((x1 + t * (x2 - x1) - track_x) / track_w, 0.0, 1.0)


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
		var reward: Label = p["reward"]
		var icon: TextureRect = p["reward_icon"]
		if claimed:
			# CLAIMED is a state, not a reward, so it takes the whole reward row
			# and loses the crown. Left-aligned beside an icon it read as pushed
			# to one side, because it was: the box starts where a "+100 XP"
			# begins, and there is nothing to its left any more.
			reward.text = "CLAIMED"
			reward.label_settings.font_color = UI.DIM
			reward.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			reward.position.x = icon.position.x
			reward.size.x = REWARD_ROW_W
			icon.visible = false
		else:
			reward.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
			reward.position.x = REWARD_TEXT_X
			reward.size.x = REWARD_TEXT_W
			icon.visible = true
			if done:
				reward.text = "CLAIM +%d XP" % int(q.get("xp", 0))
				reward.label_settings.font_color = UI.GREEN
			else:
				reward.text = "+%d XP" % int(q.get("xp", 0))
				reward.label_settings.font_color = Color("#F3EDE0")


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
