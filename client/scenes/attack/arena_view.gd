extends Control
## THE HONOUR ARENA -- the Attack tab's ARENA body, cut from
## art/reference/arena.png (art/slices/arena.json, layout client/layout/arena.json).
##
## A ladder that touches no gold. A fight here costs one of the day's five
## tickets and nothing else: no energy, no shield either way, no purse. What
## moves is a rating, so losing to somebody stronger costs a number and nothing
## a lord would miss -- which is the whole reason it is safe to pick the hardest
## fight on the card.
##
## EVERY figure here is the server's (GET /v1/arena), including the two that
## look most like arithmetic:
##
##   * the bar's fraction comes from bar_from, bar_to and rating -- the client
##     places the fill and never works out a league threshold;
##   * a rival's card shows BOTH rating_gain and rating_loss, each resolved by
##     the server running the ladder's own function twice. An Elo worked out
##     here would be the second implementation CLAUDE.md forbids, and Elo is
##     the easiest formula in the game to get quietly wrong.
##
## POST /v1/arena/fight and /v1/arena/refresh are the lord's own sequenced
## actions and go through GameState.act.

signal grew(height: float)

const SCREEN := "arena"
## A plate that cannot be pressed now, drawn as every dimmed one is.
const DIMMED := Color(0.55, 0.55, 0.55)
## The painted crest's own box on a rival card, for the live frame's band.
const FRAME_BAND := 136.0
const NAME_SIZE := 30
const LEAGUE_SIZE := 30
const LEAGUE_MIN := 20
const LINE_SIZE := 24
const LINE_MIN := 17
## The bar's channel inside its rim, in the fill's own parent.
const FILL_W := 198.0
## What the foot of the flow is, so the tab can lay its foliage under it.
const FOOT := 1448.0

var _ui: Dictionary = {}
var _data: Dictionary = {}
var _rivals: Array = []
var _chests: Array = []
var _tickets: Array = []
var _thin: Dictionary = {}       ## the card shown where the ladder runs out of rivals
var _busy := false
var _loading := false
var _at_ms := 0


func _ready() -> void:
	size = Vector2(941, 1672)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ui = Layout.build(SCREEN, self)
	_rivals = _ui["rival"]
	_chests = _ui["chest"]
	_tickets = _ui["ticket"]
	for i in _rivals.size():
		(_rivals[i]["parts"]["fight"] as BaseButton).pressed.connect(_fight.bind(i))
	(_ui["refresh"] as BaseButton).pressed.connect(_refresh)
	# A realm with few lords near this rating fills fewer than the three painted
	# cards, and card-shaped holes down to the chests read as a screen that
	# failed to load. One card says why, in the object every empty list uses.
	_thin = UI.empty_card(self, _rival_rect(0))
	_thin["node"].visible = false
	var tick := Timer.new()
	tick.wait_time = 1.0
	tick.timeout.connect(_tick)
	add_child(tick)
	tick.start()
	_paint()


## The height the flow reaches, so the tab's foliage sits under it.
func height() -> float:
	return FOOT


func refresh() -> void:
	if _loading:
		return
	_loading = true
	var res: Api.Response = await Api.get_json("/v1/arena")
	_loading = false
	if not is_inside_tree():
		return
	if res.ok and res.data is Dictionary:
		paint(res.data)


## Paints with a /v1/arena answer. Public for tests and captures.
func paint(v: Dictionary) -> void:
	_data = v
	_at_ms = Time.get_ticks_msec()
	_paint()


func _age() -> int:
	return int((Time.get_ticks_msec() - _at_ms) / 1000)


func _tick() -> void:
	if _data.is_empty() or _ui.is_empty():
		return
	_say("season", UI.time_left(maxi(0, int(_data.get("season_ends_in", 0)) - _age())))


func _say(id: String, words: String, size: int = 0, low: int = 0) -> void:
	var l: Label = _ui.get(id)
	if l == null or l.text == words:
		return
	l.text = words
	if size > 0:
		UI.fit_line(l, size, low)


func _paint() -> void:
	if _ui.is_empty():
		return
	var league: Dictionary = _data.get("league", {}) if _data.get("league") is Dictionary else {}
	(_ui["league_emblem"] as TextureRect).texture = Art.tex(str(league.get("emblem", "")))
	_say("league_name", str(league.get("name", "")).to_upper(), LEAGUE_SIZE, LEAGUE_MIN)
	_say("rating", UI.grouped(int(_data.get("rating", 0))), LEAGUE_SIZE, LEAGUE_MIN)
	_tick()

	# The bar. The three numbers are the server's; this only places the fill.
	var from := int(_data.get("bar_from", 0))
	var to := int(_data.get("bar_to", 0))
	var at := int(_data.get("rating", 0))
	var fill: Control = _ui["bar_fill"]
	fill.size.x = FILL_W * clampf(bar_fraction(at, from, to), 0.0, 1.0)
	fill.visible = fill.size.x >= 2.0

	var left := int(_data.get("tickets", 0))
	for i in _tickets.size():
		var p: Dictionary = _tickets[i]["parts"]
		(p["lit"] as CanvasItem).visible = i < left
		(p["spent"] as CanvasItem).visible = i >= left
	var can_refresh := int(_data.get("refreshes", 0)) > 0
	(_ui["refresh"] as CanvasItem).modulate = Color.WHITE if can_refresh else DIMMED

	var rivals: Array = _data.get("rivals", [])
	for i in _rivals.size():
		var card: Dictionary = _rivals[i]
		card["node"].visible = i < rivals.size()
		if i < rivals.size():
			_paint_rival(card, rivals[i], left > 0)
	_paint_thin(rivals.size())
	var chests: Array = _data.get("chests", [])
	for i in _chests.size():
		var c: Dictionary = _chests[i]
		c["node"].visible = i < chests.size()
		if i < chests.size():
			_paint_chest(c, chests[i])
	grew.emit(height())


## A rival card's rect on the page, from the layout's own instances.
func _rival_rect(i: int) -> Rect2:
	var card: Control = _rivals[i]["node"]
	return Rect2(card.position, card.size)


## The card over the empty half of a thin ladder: it starts where the rivals ran
## out and reaches the last painted card's floor, so what is left under the
## rivals is one thing that speaks rather than two holes.
func _paint_thin(shown: int) -> void:
	if _thin.is_empty():
		return
	var n := _rivals.size()
	var card: Control = _thin["node"]
	card.visible = shown < n
	if not card.visible:
		return
	var first := _rival_rect(shown)
	var last := _rival_rect(n - 1)
	var was := card.size.y
	card.position = first.position
	card.size = Vector2(first.size.x, last.end.y - first.position.y)
	# The shield and the words keep the middle of however many slots it spans.
	if card.size.y != was:
		var by := (card.size.y - was) * 0.5
		for k in ["icon", "title", "body"]:
			(_thin[k] as Control).position.y += by
	(_thin["title"] as Label).text = "NO RIVALS TO CALL OUT" if shown == 0 else "THE LADDER IS THIN HERE"
	(_thin["body"] as Label).text = ("Nobody else stands near your rating yet. Fight what the arena offers, "
		+ "REFRESH to look again, or come back as the season fills.")


## Where the bar stands between the band's floor and the next band's rating.
## Pure, so a test can ask it: the client's ONE piece of arithmetic here, and it
## is placement, not a game number -- every figure in it came from the server.
static func bar_fraction(rating: int, from: int, to: int) -> float:
	if to <= from:
		return 1.0
	return float(rating - from) / float(to - from)


func _paint_rival(card: Dictionary, r: Dictionary, can_fight: bool) -> void:
	var p: Dictionary = card["parts"]
	(p["portrait"] as TextureRect).texture = Art.tex(Art.avatar(str(r.get("avatar", ""))))
	Look.paint_frame(p["portrait"], r, "square", FRAME_BAND)
	Look.paint_crest(p["crest"], Look.crest(r, str(r.get("player_id", r.get("name", "")))))
	Look.paint_name(p["name"], r, str(r.get("name", "")), _part_rect("rival", "name"), NAME_SIZE, 18)
	_line(p["level"], "LEVEL %d" % int(r.get("level", 1)))
	var swords := "%s  ·  %s" % [UI.grouped(int(r.get("might", 0))), UI.grouped(int(r.get("rating", 0)))]
	_line(p["might"], swords)
	(p["fight"] as CanvasItem).modulate = Color.WHITE if can_fight else DIMMED


func _line(l: Label, words: String) -> void:
	l.text = words
	UI.fit_label(l, LINE_SIZE, LINE_MIN)


func _paint_chest(c: Dictionary, chest: Dictionary) -> void:
	var words := UI.grouped(int(chest.get("rating", 0)))
	if bool(chest.get("claimed", false)):
		words = "TAKEN"
	(c["parts"]["plate"] as Label).text = words
	UI.fit_label(c["parts"]["plate"], 23, 16)
	var reached := bool(chest.get("reached", false))
	(c["node"] as CanvasItem).modulate = Color.WHITE if reached else DIMMED


func _part_rect(el: String, part: String) -> Rect2:
	for q in Layout.element(SCREEN, el).get("parts", []):
		if str(q.get("id", "")) == part:
			return Layout.rect_of(q)
	return Rect2()


func _refresh() -> void:
	if _busy or int(_data.get("refreshes", 0)) <= 0:
		return
	_busy = true
	var res: Api.Response = await GameState.act("/v1/arena/refresh", {})
	if res.ok and res.data is Dictionary:
		paint(res.data)
	await refresh()
	_busy = false


func _fight(i: int) -> void:
	var rivals: Array = _data.get("rivals", [])
	if _busy or i >= rivals.size():
		return
	if int(_data.get("tickets", 0)) <= 0:
		GameState.toast("You have used today's arena fights")
		return
	_busy = true
	var r: Dictionary = rivals[i]
	var body := "Win and your rating rises %d. Lose and it falls %d. No gold changes hands, and no shield is spent." % [
		int(r.get("rating_gain", 0)), absi(int(r.get("rating_loss", 0)))]
	if await Dialog.ask(self, {"title": "Meet %s in the lists?" % str(r.get("name", "")),
			"body": body, "confirm_text": "Fight"}):
		var res: Api.Response = await GameState.act("/v1/arena/fight",
			{"opponent_id": str(r.get("player_id", ""))})
		if res.ok:
			await _show(res.data, r)
	# Held until the page shows the world after the fight, so a second tap
	# cannot send another at a card that is already stale.
	await refresh()
	_busy = false


## The animated playback of a fight the server resolved, then what it moved.
func _show(result: Dictionary, rival: Dictionary) -> void:
	var replay: CanvasLayer = load("res://scenes/battle/battle_replay.gd").new()
	replay.setup(result, rival)
	Nav.overlay_parent().add_child(replay)
	await replay.finished
	var lines: Array = []
	var d := int(result.get("rating_delta", 0))
	lines.append("%s%d rating" % ["+" if d > 0 else "", d])
	for w in result.get("first_win_lines", []):
		lines.append(str(w))
	for w in result.get("chest_lines", []):
		lines.append(str(w))
	GameState.toast("  ·  ".join(lines))
