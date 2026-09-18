class_name QuestTile
extends RefCounted
## One of the painted quest tiles (collect_events.png): a task's mark over the
## tile, what it asks on the name plate, where it stands on the progress
## plate, and what it pays on the gold-rimmed plate. The Collect tab's three
## tiles show today's quests or the week's; the weekly page lays out all six
## the same way. One painter, so a task reads the same wherever it is.
##
## Every figure is the server's: target, progress, what it pays, its points.

## A day's task's mark, by what it asks for (the ids are the balance's).
const DAILY_ICON := {"collect_": "icons/quest_scroll_lg", "energy_": "icons/quest_bolt_lg",
	"win_": "icons/quest_swords_lg", "buy_": "icons/market_tent"}
## A week's task names its mark (wave3-api: quest_scroll | quest_bolt | quest_swords),
## drawn from the tiles' own larger paintings.
const WEEKLY_ICON := {"quest_scroll": "icons/quest_scroll_lg", "quest_bolt": "icons/quest_bolt_lg",
	"quest_swords": "icons/quest_swords_lg"}
## The marker the chest bar sets where the fill reaches a chest: beside a
## week's task's points it says "this much toward the chests".
const POINTS_MARK := "collect/chest_marker"
const XP_MARK := "icons/reward_crown"
const GOLD_MARK := "icons/coin_small"

## The words and the plate's figures: the painting's sizes, and how far they
## may shrink before a long task or a late-game figure is cut.
const TITLE_FIT := Vector2i(21, 15)
const FIGURE_FIT := Vector2i(22, 13)
const PROGRESS_SIZE := 18
const ICON_GAP := 4.0
const PAIR_GAP := 10.0
const IN_PROGRESS := Color("#E9E3D5")
## A finished bar is full, and full is gold, so the word on it is dark ink.
const ON_FULL_BAR := Color("#2E1D05")
const INK := Color("#F3EDE0")
const CLAIMED_TINT := Color(0.62, 0.62, 0.66)

## What a task is: "claimed", "done" (waiting to be claimed) or "open".
static func state(q: Dictionary) -> String:
	if bool(q.get("claimed", false)):
		return "claimed"
	if bool(q.get("done", false)):
		return "done"
	return "open"


## Paints a day's task onto a tile's parts. Returns its state.
static func paint_daily(parts: Dictionary, q: Dictionary) -> String:
	var mark := "icons/quest_scroll_lg"
	for prefix in DAILY_ICON:
		if str(q.get("id", "")).begins_with(prefix):
			mark = DAILY_ICON[prefix]
	_set_mark(parts, mark)
	_set_title(parts, daily_title(q))
	var st := state(q)
	_set_progress(parts, q, st)
	var col := _reward_colour(st)
	paint_pair(parts["reward_row"], Art.tex(XP_MARK), "+" + UI.short_number(int(q.get("xp", 0))),
		Art.tex(GOLD_MARK), "+" + UI.short_number(int(q.get("gold", 0))), col)
	return st


## Paints a week's task onto a tile's parts. Returns its state.
static func paint_weekly(parts: Dictionary, q: Dictionary) -> String:
	_set_mark(parts, str(WEEKLY_ICON.get(str(q.get("icon", "")), "icons/quest_scroll_lg")))
	_set_title(parts, weekly_title(q))
	var st := state(q)
	_set_progress(parts, q, st)
	var col := _reward_colour(st)
	var lines: Array = q.get("lines", [])
	var first: Dictionary = lines[0] if not lines.is_empty() and lines[0] is Dictionary else {}
	var pts := "+%d" % int(q.get("points", 0))
	if first.is_empty():
		paint_pair(parts["reward_row"], null, "", Art.tex(POINTS_MARK), pts, col)
	else:
		paint_pair(parts["reward_row"], Art.reward_line_icon(first), "+" + UI.short_number(int(first.get("amount", 0))),
			Art.tex(POINTS_MARK), pts, col)
	return st


## Paints a festival's task onto a tile's parts. Returns its state.
##
## A festival's task pays its own reward and no points -- a festival's points
## come from what a lord does anyway (its `sources`) -- so the plate carries
## what it pays alone, where a week's task shows its points beside it.
static func paint_festival(parts: Dictionary, q: Dictionary) -> String:
	_set_mark(parts, str(WEEKLY_ICON.get(str(q.get("icon", "")), "icons/quest_scroll_lg")))
	_set_title(parts, weekly_title(q))
	var st := state(q)
	_set_progress(parts, q, st)
	var col := _reward_colour(st)
	var lines: Array = q.get("lines", [])
	var first: Dictionary = lines[0] if not lines.is_empty() and lines[0] is Dictionary else {}
	if first.is_empty():
		paint_pair(parts["reward_row"], null, "", null, "", col)
	else:
		paint_pair(parts["reward_row"], null, "", Art.reward_line_icon(first), reward_words(first), col)
	return st


## What a reward line says on a tile's plate: a count and its picture
## ("+588"), or the thing itself when it has no count worth showing.
static func reward_words(l: Dictionary) -> String:
	var n := int(l.get("amount", 0))
	if str(l.get("kind", "")) == "cosmetic" or n <= 0:
		return str(l.get("text", ""))
	return "+" + UI.short_number(n)


## What a day's task asks, in one line: "Collect 20 times".
static func daily_title(q: Dictionary) -> String:
	var id := str(q.get("id", ""))
	var n := int(q.get("target", 0))
	if id.begins_with("collect_"):
		return "Collect %s times" % UI.grouped(n)
	if id.begins_with("energy_"):
		return "Spend %s energy" % UI.grouped(n)
	if id.begins_with("win_"):
		return "Defeat %d rival%s" % [n, "" if n == 1 else "s"]
	if id.begins_with("buy_"):
		return "Buy %d item%s" % [n, "" if n == 1 else "s"]
	return str(q.get("name", ""))


## What a week's task asks: its short line, else its name.
static func weekly_title(q: Dictionary) -> String:
	var s := str(q.get("short", ""))
	return s if s != "" else str(q.get("name", ""))


## The order the week's tasks take on the Collect tab's three tiles: one
## waiting to be claimed first, then those still open, the claimed last, each
## group in the server's order. The weekly page shows all six in order.
static func weekly_order(tasks: Array) -> Array:
	var rank := {"done": 0, "open": 1, "claimed": 2}
	var out: Array = []
	for t in tasks:
		if t is Dictionary:
			out.append(t)
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var ra: int = rank[state(a)]
		var rb: int = rank[state(b)]
		if ra != rb:
			return ra < rb
		return int(a.get("slot", 0)) < int(b.get("slot", 0)))
	return out


static func _set_mark(parts: Dictionary, asset: String) -> void:
	var icon: TextureRect = parts["icon"]
	icon.texture = Art.tex(asset)
	# At its own size, centred where the painting drew each tile's mark; a mark
	# painted larger than the place (the market's tent) is drawn down to it.
	var t := icon.texture
	var big := t != null and (t.get_width() > icon.size.x or t.get_height() > icon.size.y)
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED if big else TextureRect.STRETCH_KEEP_CENTERED


static func _set_title(parts: Dictionary, text: String) -> void:
	var l: Label = parts["title"]
	l.text = text
	UI.fit_line(l, TITLE_FIT.x, TITLE_FIT.y)


## The progress plate: the fill to where the task stands and its words --
## "7 / 20", TAP TO CLAIM on a full bar, CLAIMED.
static func _set_progress(parts: Dictionary, q: Dictionary, st: String) -> void:
	var target := int(q.get("target", 0))
	var progress := mini(int(q.get("progress", 0)), target)
	Layout.set_fill(parts["bar_fill"], 1.0 if st != "open" else float(progress) / maxf(1.0, float(target)))
	var bar: Label = parts["progress"]
	if not bar.has_meta("font"):
		bar.set_meta("font", bar.label_settings.font)
	var full := st != "open"
	bar.text = "CLAIMED" if st == "claimed" else ("TAP TO CLAIM" if st == "done" else "%s / %s" % [UI.grouped(progress), UI.grouped(target)])
	bar.label_settings.font_size = PROGRESS_SIZE
	bar.label_settings.font_color = ON_FULL_BAR if full else IN_PROGRESS
	bar.label_settings.font = UI.font("body", 800) if full else bar.get_meta("font")
	bar.label_settings.shadow_color = Color(1, 0.9, 0.6, 0.35) if full else Color(0, 0, 0, 0.45)
	# A part-filled bar is gold on its left and navy on its right, and "7 / 20"
	# stands across the edge: a dark outline reads on both.
	bar.label_settings.outline_size = 0 if full else 5
	bar.label_settings.outline_color = Color(0.03, 0.06, 0.09, 0.9)
	UI.fit_line(bar, PROGRESS_SIZE, 13)


static func _reward_colour(st: String) -> Color:
	match st:
		"done":
			return UI.GREEN
		"claimed":
			return UI.DIM
	return INK


## Lays out two marks and their figures, centred as a pair on the row and
## shrunk together until both fit it. `a` may be null (a task that pays
## nothing but its points).
static func paint_pair(row: Control, a: Texture2D, a_text: String, b: Texture2D, b_text: String, col: Color) -> void:
	var p: Dictionary = row.get_meta("parts", {})
	var ia: TextureRect = p["icon_a"]
	var fa: Label = p["figure_a"]
	var ib: TextureRect = p["icon_b"]
	var fb: Label = p["figure_b"]
	ia.texture = a
	ia.visible = a != null
	fa.visible = a != null
	ib.texture = b
	# A festival's task pays one thing and no points, so the second half of the
	# pair can be empty too; an empty picture with a stray figure beside it is
	# what a tile showed before this.
	ib.visible = b != null
	fb.visible = b != null
	for ic in [ia, ib]:
		(ic as TextureRect).expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		(ic as TextureRect).stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	var font := fa.label_settings.font
	var room := row.size.x
	var size := FIGURE_FIT.x
	var wa := 0.0
	var wb := 0.0
	var total := 0.0
	while true:
		wa = font.get_string_size(a_text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x if a != null else 0.0
		wb = font.get_string_size(b_text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x if b != null else 0.0
		total = (ib.size.x + ICON_GAP + wb) if b != null else 0.0
		if a != null:
			total += ia.size.x + ICON_GAP + wa + (PAIR_GAP if b != null else 0.0)
		if total <= room or size <= FIGURE_FIT.y:
			break
		size -= 1
	var x := (room - total) / 2.0
	var pairs: Array = [[ib, fb, b_text, wb]] if b != null else []
	if a != null:
		pairs.push_front([ia, fa, a_text, wa])
	for pair in pairs:
		var icon: Control = pair[0]
		var label: Label = pair[1]
		icon.position = Vector2(x, (row.size.y - icon.size.y) / 2.0)
		x += icon.size.x + ICON_GAP
		label.text = pair[2]
		label.label_settings.font_size = size
		label.label_settings.font_color = col
		label.position.x = x
		label.size.x = float(pair[3]) + 2.0
		x += float(pair[3]) + PAIR_GAP
