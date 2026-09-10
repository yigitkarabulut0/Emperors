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

## A quest card's reward row: experience and gold, each an icon and a figure,
## centred as a pair in the row the layout gives them and shrunk together until
## both fit. The done card used to say "CLAIM +396 XP" in a 30-point box that
## started a third of the way across a 241-unit card, and ran off its edge.
##
## The crown alone means experience, as it does on every job row: "+396" beside
## a crown is the game's own vocabulary, and dropping the word is what lets the
## figures stay at the painting's size.
const REWARD_SIZE := Vector2i(28, 18)
const REWARD_GAP := 16.0
const ICON_GAP := 4.0
const IN_PROGRESS := Color("#E9E3D5")
## A finished bar is full, and full is gold, so the word on it is dark ink --
## gold type on a gold bar could not be read.
const ON_FULL_BAR := Color("#2E1D05")
const READY := Color("#F0D27A")

## Font sizes a row's name and its collect counter are fitted between (max, min):
## the painting's size when the text fits its box, smaller only when it would not.
const NAME_FIT := Vector2i(24, 14)
const COUNTER_FIT := Vector2i(24, 16)
var _built := false
var _busy := false
## The gentle pulse on a card whose reward is waiting, one per card.
var _pulses: Dictionary = {}


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
		var card: Dictionary = _quest_cards[i]
		var p: Dictionary = card["parts"]
		if i >= _quests.size():
			card["node"].visible = false
			_pulse(i, false)
			continue
		card["node"].visible = true
		var q: Dictionary = _quests[i]
		var target := int(q.get("target", 0))
		var progress := mini(int(q.get("progress", 0)), target)
		var claimed := bool(q.get("claimed", false))
		var done := bool(q.get("done", false)) and not claimed
		p["title"].text = _quest_title(q)
		Layout.set_fill(p["bar_fill"], 1.0 if claimed else float(progress) / maxf(1.0, float(target)))

		# The bar says where the task stands; the row under it says what it pays,
		# in all three states, so a claimed card still shows what it gave.
		var bar: Label = p["progress"]
		if not bar.has_meta("font"):
			bar.set_meta("font", bar.label_settings.font)
		var full := claimed or done
		bar.text = "CLAIMED" if claimed else ("TAP TO CLAIM" if done else "%d / %d" % [progress, target])
		bar.label_settings.font_color = ON_FULL_BAR if full else IN_PROGRESS
		bar.label_settings.font = UI.font("body", 800) if full else bar.get_meta("font")
		bar.label_settings.shadow_color = Color(1, 0.9, 0.6, 0.35) if full else Color(0, 0, 0, 0.45)
		_paint_rewards(p["reward_row"], int(q.get("xp", 0)), int(q.get("gold", 0)),
			UI.GREEN if done else (UI.DIM if claimed else Color("#F3EDE0")))

		# A claimed card steps back; a waiting one breathes, so the eye finds it.
		card["node"].modulate = Color(0.62, 0.62, 0.66) if claimed else Color.WHITE
		_pulse(i, done)


## Lays out the experience and the gold a task pays, centred as a pair.
static func _paint_rewards(row: Control, xp: int, gold: int, col: Color) -> void:
	var parts: Dictionary = row.get_meta("parts", {})
	var xp_icon: Control = parts["xp_icon"]
	var gold_icon: Control = parts["gold_icon"]
	var xp_label: Label = parts["xp"]
	var gold_label: Label = parts["gold"]
	var xp_text := "+%s" % UI.short_number(xp)
	var gold_text := "+%s" % UI.short_number(gold)
	var room := row.size.x - 8.0
	var font := xp_label.label_settings.font
	var size := REWARD_SIZE.x
	var widths := Vector2.ZERO
	while true:
		widths = Vector2(font.get_string_size(xp_text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x,
			font.get_string_size(gold_text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x)
		var total := xp_icon.size.x + ICON_GAP + widths.x + REWARD_GAP \
			+ gold_icon.size.x + ICON_GAP + widths.y
		if total <= room or size <= REWARD_SIZE.y:
			break
		size -= 1
	var total_w := xp_icon.size.x + ICON_GAP + widths.x + REWARD_GAP \
		+ gold_icon.size.x + ICON_GAP + widths.y
	var x := (row.size.x - total_w) / 2.0
	for pair in [[xp_icon, xp_label, xp_text, widths.x], [gold_icon, gold_label, gold_text, widths.y]]:
		var icon: Control = pair[0]
		var label: Label = pair[1]
		icon.position = Vector2(x, (row.size.y - icon.size.y) / 2.0)
		x += icon.size.x + ICON_GAP
		label.text = pair[2]
		label.label_settings.font_size = size
		label.label_settings.font_color = col
		label.position = Vector2(x, label.position.y)
		label.size.x = float(pair[3]) + 2.0
		x += float(pair[3]) + REWARD_GAP


## Starts or stops the breathing of a card whose reward is waiting.
func _pulse(i: int, on: bool) -> void:
	var frame: CanvasItem = _quest_cards[i]["parts"]["frame"]
	var running: Tween = _pulses.get(i, null)
	if on == (running != null and running.is_valid()):
		return
	if running != null:
		running.kill()
		_pulses.erase(i)
	frame.modulate = Color.WHITE
	if not on:
		return
	var t := create_tween().set_loops()
	t.tween_property(frame, "modulate", Color(1.35, 1.28, 1.05), 0.7) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	t.tween_property(frame, "modulate", Color.WHITE, 0.7) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_pulses[i] = t


func _quest_title(q: Dictionary) -> String:
	var id := str(q.get("id", ""))
	var n := int(q.get("target", 0))
	if id.begins_with("collect_"):
		return "Collect\n%d times" % n
	if id.begins_with("energy_"):
		return "Spend\n%d energy" % n
	if id.begins_with("win_"):
		return "Defeat\n%d rival%s" % [n, "" if n == 1 else "s"]
	if id.begins_with("buy_"):
		return "Buy\n%d item%s" % [n, "" if n == 1 else "s"]
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
		var xp := int(q.get("xp", 0))
		var gold := int(q.get("gold", 0))
		_float_reward(i, "+%s XP   +%s gold" % [UI.grouped(xp), UI.grouped(gold)])
		GameState.action_failed.emit("Task done: +%s XP and +%s gold" % [UI.grouped(xp), UI.grouped(gold)])
		# The server's answer is the day's board, already claimed.
		var got: Array = res.data.get("quests", [])
		if not got.is_empty():
			_quests = got
			_paint_quests()
		else:
			await _load_quests()


## The reward rises off the card and fades, so the tap is answered where the
## thumb is rather than only in a toast at the foot of the screen.
func _float_reward(i: int, text: String) -> void:
	var card: Control = _quest_cards[i]["node"]
	var l := UI.label(text, 26, READY, "body", 700, HORIZONTAL_ALIGNMENT_CENTER)
	UI.place(l, Rect2(card.position.x - 30.0, card.position.y + 100.0, card.size.x + 60.0, 40))
	add_child(l)
	var t := create_tween().set_parallel()
	t.tween_property(l, "position:y", l.position.y - 90.0, 1.2).set_ease(Tween.EASE_OUT)
	t.tween_property(l, "modulate:a", 0.0, 1.2).set_ease(Tween.EASE_IN)
	t.chain().tween_callback(l.queue_free)


func _seconds_to_local_midnight() -> int:
	var now := Time.get_datetime_dict_from_system()
	var passed := int(now.get("hour", 0)) * 3600 + int(now.get("minute", 0)) * 60 + int(now.get("second", 0))
	return 86400 - passed
