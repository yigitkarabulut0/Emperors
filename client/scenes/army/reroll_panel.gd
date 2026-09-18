extends Control
## REROLL — a soldier's tier drawn again, once or until a tier the player picks.
##
## Opened from the Army screen's REROLL, where HUNT was painted. Each roll is
## one request, and the server draws the new tier from the same table a recruit
## of the soldier's type is drawn from; the result replaces the old tier, up or
## down, and the soldier keeps its slot, its type and its gear. The price, the
## odds and every result are the server's: this panel shows them, it never
## works one out.
##
## AUTO ROLL is the item-bonus reroll bot of the old MMOs, done honestly: it
## rolls, one request at a time and at a pace the eye can follow, until the tier
## reaches the one chosen, and it only runs while the game is open and on the
## screen. It stops on its own at the target, when the next roll cannot be paid
## for, on any refusal, and the moment the game leaves the screen -- nothing
## rolls in a pocket.
##
## Built from the game's own parts: the soldier's card is the Army screen's own
## template, the numerals and rarity badges are the painted ones, and the plate
## is the chamfered card frame every dialog stands on. The card's portrait is
## the soldier's type in the look of the tier it has just rolled
## (SoldierArt), so a roll that lands gilded is seen to.

signal closed

const W := 800.0
const PAD := 34.0
const BUTTON_H := 96.0
const GAP := 14.0
const PLATE := "inventory/card_frame"
const PLATE_MARGIN := 26
const HEADER := "pages/header_reroll"
const TIER_IDS := ["common", "uncommon", "rare", "epic", "legendary", "mystic", "special"]
const ROMAN := ["", "I", "II", "III", "IV", "V", "VI", "VII"]
## A roll lands at most this often, so a result can be read before the next
## replaces it; the request itself usually takes a fifth of this.
const MIN_INTERVAL := 0.45
const FLIP_STEP := 0.055
## Rolling a soldier this good once is confirmed: a roll can take it down.
const CONFIRM_FROM_TIER := 5
const UP := Color(0.55, 1.25, 0.6)
const DOWN := Color(1.35, 0.55, 0.5)
const HIT := Color(1.45, 1.25, 0.6)

var _layer: CanvasLayer
var _plate: NinePatchRect
var _soldier: Dictionary = {}
var _odds: Array = []
var _name := ""
var _type := "peasant"
var _tier := 1
var _target := 2
var _cost := 0
var _gold_left := -1
var _rolls := 0
var _spent := 0
var _best := 0
var _history: Array = []
var _running := false
var _rolling := false
var _closing := false
var _confirmed_auto := false
var _keep_on_before := true
var _flip_t := 0.0
var _flip_i := 0

var _card: Dictionary = {}
var _big: TextureRect
var _badge: TextureRect
var _price_label: Label
var _gold_label: Label
var _odds_cells: Array = []
var _chips: Array = []
var _tally: Label
var _history_row: Control
var _status: Label
var _once_button: Button
var _auto_button: Button


## Opens the panel over the game and returns it. {soldier, odds, name, type}.
static func open(host: Node, cfg: Dictionary) -> Control:
	var p: Control = load("res://scenes/army/reroll_panel.gd").new()
	p._setup(host, cfg)
	return p


func _setup(host: Node, cfg: Dictionary) -> void:
	_soldier = cfg.get("soldier", {})
	_odds = cfg.get("odds", [])
	_name = str(cfg.get("name", "SOLDIER"))
	_type = str(cfg.get("type", _soldier.get("type", "peasant")))
	_tier = _tier_of(_soldier)
	_best = _tier
	_target = mini(7, _tier + 1)
	_cost = int(_soldier.get("reroll_cost", 0))

	_layer = CanvasLayer.new()
	_layer.layer = 50
	Nav.overlay_parent().add_child(_layer)
	var back := ColorRect.new()
	back.color = Color(0, 0, 0, 0.78)
	back.set_anchors_preset(Control.PRESET_FULL_RECT)
	back.mouse_filter = Control.MOUSE_FILTER_STOP
	_layer.add_child(back)

	# The canvas the game is laid out on, as Dialog finds it: the topmost
	# Control above the host. A stretched desktop window's pixel size is not it.
	var top: Control = host as Control
	while top != null and top.get_parent() is Control:
		top = top.get_parent()
	var canvas: Vector2 = top.size if top != null and top.size.x > 0 else Vector2(941, 1672)

	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_layer.add_child(self)
	_plate = NinePatchRect.new()
	_plate.texture = Art.tex(PLATE)
	for m in ["left", "top", "right", "bottom"]:
		_plate.set("patch_margin_" + m, PLATE_MARGIN)
	add_child(_plate)
	var h := _build()
	_plate.size = Vector2(W, h)
	_plate.position = ((canvas - _plate.size) / 2.0).floor()
	# Centred, but never under the notch: the header made the plate tall.
	_plate.position.y = maxf(_plate.position.y, UI.safe_top(canvas) + 20.0)
	_paint()


# --- building -----------------------------------------------------------------------

func _build() -> float:
	# The training yard over the title, as the Sheets carry their scenes.
	var y := Sheet.header_art(_plate, HEADER, W) - Sheet.HEADER_OVERLAP
	var title := UI.label("REROLL  ·  %s" % _name, 36, UI.GOLD, "title", 700, HORIZONTAL_ALIGNMENT_CENTER)
	UI.place(title, Rect2(PAD, y, W - PAD * 2, 50))
	UI.fit_label(title, 36, 24)
	_plate.add_child(title)
	y += 58
	_rule(y)
	y += 22

	# The soldier, as the Army screen draws its card, and beside it the tier
	# that is being rolled -- the one thing this panel is about, drawn large.
	_card = Layout.instantiate(Layout.find("army", "soldier_card"))
	var card_node: Control = _card["node"]
	card_node.position = Vector2(PAD + 10, y)
	_plate.add_child(card_node)
	var cp: Dictionary = _card["parts"]
	cp["tap"].queue_free()
	cp["selected_frame"].visible = false

	var col_x := PAD + 10 + 149 + 40
	var col_w := W - PAD - col_x
	var cap := UI.label("THE TIER", 24, UI.GOLD_DIM, "title", 600, HORIZONTAL_ALIGNMENT_CENTER)
	UI.place(cap, Rect2(col_x, y + 4, col_w, 30))
	_plate.add_child(cap)
	# The fleur diamond at the size it is cut at, between the caption and the
	# rarity word under it.
	var big_size := Vector2(80, 124)
	_big = UI.image(SoldierArt.numeral_large(_tier), Rect2(col_x + (col_w - big_size.x) / 2.0, y + 42,
		big_size.x, big_size.y))
	_big.pivot_offset = big_size / 2.0
	_plate.add_child(_big)
	# The rarity word, as the inventory paints it.
	_badge = UI.image("inventory/badge_common", Rect2(col_x + (col_w - 120) / 2.0, y + 172, 120, 59))
	_badge.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_plate.add_child(_badge)
	_price_label = UI.label("", 25, UI.INK, "body", 600, HORIZONTAL_ALIGNMENT_CENTER)
	UI.place(_price_label, Rect2(col_x, y + 246, col_w, 34))
	_plate.add_child(_price_label)
	_gold_label = UI.label("", 23, UI.DIM, "body", 500, HORIZONTAL_ALIGNMENT_CENTER)
	UI.place(_gold_label, Rect2(col_x, y + 282, col_w, 32))
	_plate.add_child(_gold_label)
	y += 337 + 26

	# The odds of each tier, the server's own numbers for this player's level
	# and luck. The tiers the auto-roll is waiting for are lit.
	y = _heading("THE ODDS OF EACH ROLL", y)
	var cell_w := (W - PAD * 2) / 7.0
	for i in 7:
		var cell := Control.new()
		cell.mouse_filter = Control.MOUSE_FILTER_IGNORE
		UI.place(cell, Rect2(PAD + cell_w * i, y, cell_w, 96))
		_plate.add_child(cell)
		var badge := numeral_badge(i + 1, Rect2((cell_w - 50) / 2.0, 0, 50, 50))
		cell.add_child(badge)
		var pct := UI.label(percent(_bp_of(i + 1)), 21, UI.INK, "body", 600, HORIZONTAL_ALIGNMENT_CENTER)
		UI.place(pct, Rect2(0, 56, cell_w, 30))
		cell.add_child(pct)
		_odds_cells.append(cell)
	y += 100

	# What to stop at. Tier I is not a goal, so the chips run II to VII.
	y = _heading("STOP WHEN IT REACHES", y)
	var chip_w := (W - PAD * 2 - GAP * 5) / 6.0
	for i in 6:
		var tier := i + 2
		var chip := UI.plate_face("inventory/chip_frame_idle", 14)
		chip.text = "TIER %s" % ROMAN[tier] if chip_w > 120 else ROMAN[tier]
		chip.add_theme_font_override("font", UI.font("title", 800))
		chip.add_theme_font_size_override("font_size", 28)
		chip.add_theme_constant_override("outline_size", 0)
		UI.place(chip, Rect2(PAD + (chip_w + GAP) * i, y, chip_w, BUTTON_H))
		chip.pressed.connect(_set_target.bind(tier))
		_plate.add_child(chip)
		_chips.append(chip)
	y += BUTTON_H + 20

	_tally = UI.label("", 24, UI.DIM, "body", 600, HORIZONTAL_ALIGNMENT_CENTER)
	UI.place(_tally, Rect2(PAD, y, W - PAD * 2, 32))
	_plate.add_child(_tally)
	y += 38
	# The last rolls, newest on the left.
	_history_row = Control.new()
	_history_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UI.place(_history_row, Rect2(PAD, y, W - PAD * 2, 44))
	_plate.add_child(_history_row)
	y += 52

	_status = UI.label("", 27, UI.GOLD, "title", 700, HORIZONTAL_ALIGNMENT_CENTER)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.custom_minimum_size = Vector2(W - PAD * 2, 0)
	UI.place(_status, Rect2(PAD, y, W - PAD * 2, 70))
	_plate.add_child(_status)
	y += 74
	var note := UI.label("Auto-roll runs only while the game is open. Keep your phone on.",
		21, UI.DIM, "body", 500, HORIZONTAL_ALIGNMENT_CENTER)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.custom_minimum_size = Vector2(W - PAD * 2, 0)
	UI.place(note, Rect2(PAD, y, W - PAD * 2, 30))
	_plate.add_child(note)
	y += 44

	var half := (W - PAD * 2 - GAP) / 2.0
	_once_button = _button("ROLL ONCE", Dialog.QUIET_PLATE, UI.GOLD, Rect2(PAD, y, half, BUTTON_H))
	_once_button.pressed.connect(_roll_once)
	_auto_button = _button("AUTO ROLL", Dialog.CONFIRM_PLATE, Color("#F3FBF3"),
		Rect2(PAD + half + GAP, y, half, BUTTON_H))
	_auto_button.pressed.connect(_toggle_auto)
	y += BUTTON_H + GAP
	var close := _button("CLOSE", Dialog.QUIET_PLATE, UI.DIM, Rect2(PAD, y, W - PAD * 2, BUTTON_H))
	close.pressed.connect(_close)
	y += BUTTON_H + PAD
	return y


func _rule(y: float) -> void:
	var rule := ColorRect.new()
	rule.color = Color(UI.GOLD_DIM, 0.45)
	UI.place(rule, Rect2(PAD, y, W - PAD * 2, 2))
	rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_plate.add_child(rule)


func _heading(text: String, y: float) -> float:
	var l := UI.label(text, 24, UI.GOLD_DIM, "title", 600, HORIZONTAL_ALIGNMENT_CENTER)
	UI.place(l, Rect2(PAD, y, W - PAD * 2, 32))
	_plate.add_child(l)
	return y + 42


func _button(word: String, plate: String, col: Color, rect: Rect2) -> Button:
	var b := UI.plate_face(plate, Dialog.PLATE_EDGE)
	b.text = word
	b.add_theme_font_override("font", UI.font("title", 700))
	b.add_theme_font_size_override("font_size", 28)
	for c in ["font_color", "font_hover_color", "font_pressed_color"]:
		b.add_theme_color_override(c, col)
	b.add_theme_color_override("font_disabled_color", Color(col, 0.5))
	b.add_theme_constant_override("outline_size", 0)
	UI.place(b, rect)
	_plate.add_child(b)
	return b


## A tier's painted numeral on its diamond, I to VII -- the one the soldier
## cards wear. The odds page draws its rows with this too.
static func numeral_badge(tier: int, rect: Rect2) -> TextureRect:
	return UI.image(SoldierArt.numeral(tier), rect)


# --- painting -----------------------------------------------------------------------

func _paint() -> void:
	var cp: Dictionary = _card["parts"]
	cp["name"].text = _name
	# Fitted as the Army's own strip fits the same card.
	UI.fit_label(cp["name"], 18, 14)
	cp["attack"].text = UI.grouped(int(_soldier.get("attack", 0)))
	cp["defence"].text = UI.grouped(int(_soldier.get("defense", 0)))
	cp["power"].text = UI.grouped(int(_soldier.get("might", _soldier.get("ehp", 0))))
	cp["troop"].text = UI.grouped(int(_soldier.get("hp", 0)))
	for k in ["attack", "defence", "power"]:
		UI.fit_label(cp[k], 22, 16)
	UI.fit_label(cp["troop"], 20, 15)
	cp["portrait"].texture = Art.tex(SoldierArt.portrait(_type, _tier))
	cp["numeral"].texture = Art.tex(SoldierArt.numeral(_tier))
	_show_big(_tier)
	_badge.texture = Art.tex("inventory/badge_" + TIER_IDS[_tier - 1])

	_price_label.text = "Each roll: %s gold" % UI.grouped(_cost) if _cost > 0 else "Each roll: —"
	var gold := _gold_left if _gold_left >= 0 else GameState.display_gold()
	_gold_label.text = "You have %s" % UI.short_number(gold)

	for i in _odds_cells.size():
		var lit := i + 1 >= _target
		(_odds_cells[i] as Control).modulate = Color.WHITE if lit else Color(0.42, 0.42, 0.46)
	for i in _chips.size():
		var chip: Button = _chips[i]
		var on := i + 2 == _target
		var sb: StyleBoxTexture = chip.get_theme_stylebox("normal")
		var want := Art.tex("inventory/chip_frame_active" if on else "inventory/chip_frame_idle")
		if sb.texture != want:
			for state in ["normal", "hover", "focus", "pressed", "disabled"]:
				var s: StyleBoxTexture = chip.get_theme_stylebox(state).duplicate()
				s.texture = want
				chip.add_theme_stylebox_override(state, s)
		for c in ["font_color", "font_hover_color", "font_pressed_color"]:
			chip.add_theme_color_override(c, UI.INK if on else UI.DIM)
		chip.disabled = _running

	_tally.text = "Rolls %d   ·   Spent %s   ·   Best %s" % [_rolls, UI.short_number(_spent), ROMAN[_best]] \
		if _rolls > 0 else "No rolls yet"
	_paint_history()
	_once_button.disabled = _running or _rolling
	_auto_button.text = "STOP" if _running else "AUTO ROLL"
	var face := Dialog.DANGER_PLATE if _running else Dialog.CONFIRM_PLATE
	var cur: StyleBoxTexture = _auto_button.get_theme_stylebox("normal")
	if cur.texture != Art.tex(face):
		var fresh := UI.plate_face(face, Dialog.PLATE_EDGE)
		for state in ["normal", "hover", "focus", "pressed", "disabled"]:
			_auto_button.add_theme_stylebox_override(state, fresh.get_theme_stylebox(state))
		fresh.free()
	var col := Color("#FBEDED") if _running else Color("#F3FBF3")
	for c in ["font_color", "font_hover_color", "font_pressed_color"]:
		_auto_button.add_theme_color_override(c, col)


func _show_big(tier: int) -> void:
	_big.texture = Art.tex(SoldierArt.numeral_large(tier))


func _paint_history() -> void:
	for c in _history_row.get_children():
		c.queue_free()
	var x := 0.0
	var size := 44.0
	for i in mini(_history.size(), 14):
		var tier: int = _history[i]
		var b := numeral_badge(tier, Rect2(x, 0, size, size))
		b.modulate = HIT if tier >= _target else (Color.WHITE if i == 0 else Color(0.62, 0.62, 0.66))
		_history_row.add_child(b)
		x += size + 8.0


func _process(delta: float) -> void:
	# While a roll is in the air the big numeral turns over, tier after tier.
	# It is only a picture of waiting; the tier it stops on is the server's.
	if not _rolling:
		return
	_flip_t += delta
	if _flip_t >= FLIP_STEP:
		_flip_t = 0.0
		_flip_i = (_flip_i % 7) + 1
		_big.texture = Art.tex(SoldierArt.numeral_large(_flip_i))


## The roll has landed: the numeral settles on the result with a small jolt,
## green for up, red for down, gold at the target.
func _land(before: int, after: int) -> void:
	_show_big(after)
	var flash := HIT if after >= _target else (UP if after > before else (DOWN if after < before else Color.WHITE))
	_big.modulate = flash
	_big.scale = Vector2(1.22, 1.22)
	var t := create_tween().set_parallel()
	t.tween_property(_big, "scale", Vector2.ONE, 0.28).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	t.tween_property(_big, "modulate", Color.WHITE, 0.6)


# --- rolling ------------------------------------------------------------------------

func _set_target(tier: int) -> void:
	if _running:
		return
	_target = tier
	_status.text = ""
	_paint()


func _roll_once() -> void:
	if _running or _rolling or _closing:
		return
	if _tier >= CONFIRM_FROM_TIER:
		if not await Dialog.ask(self, {"title": "Roll a TIER %s %s?" % [ROMAN[_tier], _name.capitalize()],
				"body": "A roll replaces the tier, and it can go down as well as up.",
				"confirm_text": "Roll", "danger": true}):
			return
	_status.text = ""
	await _roll()
	_paint()


func _toggle_auto() -> void:
	if _closing:
		return
	if _running:
		_stop("Stopped.")
		return
	if _rolling:
		return
	if _tier >= _target:
		_status.text = "This soldier is already TIER %s — choose a higher tier to stop at." % ROMAN[_tier]
		return
	if _cost <= 0:
		_status.text = "The price of a roll is not known yet."
		return
	if GameState.display_gold() < _cost:
		_status.text = "Not enough gold for a roll."
		return
	if not _confirmed_auto:
		if not await Dialog.ask(self, {"title": "Roll until TIER %s?" % ROMAN[_target],
				"body": "Each roll costs %s gold and replaces the tier — it can go down as well as up. It stops at TIER %s or better, when your gold runs short, when you press STOP, or when the game leaves the screen." \
					% [UI.grouped(_cost), ROMAN[_target]],
				"confirm_text": "Start rolling"}):
			return
		_confirmed_auto = true
	_start()
	while _running:
		var started := Time.get_ticks_msec()
		var ok := await _roll()
		if not _running or _closing:
			break
		if not ok:
			_stop(_status.text if _status.text != "" else "Stopped.")
			break
		if _tier >= _target:
			_stop("TARGET REACHED — TIER %s!" % ROMAN[_tier])
			break
		if _gold_left >= 0 and _gold_left < _cost:
			_stop("Stopped: not enough gold for another roll.")
			break
		var wait := MIN_INTERVAL - float(Time.get_ticks_msec() - started) / 1000.0
		if wait > 0.0:
			await get_tree().create_timer(wait).timeout
	_paint()


func _start() -> void:
	_running = true
	_status.text = "Rolling…"
	# The project keeps the screen on already; this makes sure of it for the
	# run, and puts back whatever it found rather than switching it off.
	_keep_on_before = DisplayServer.screen_is_kept_on()
	DisplayServer.screen_set_keep_on(true)
	_paint()


func _stop(why: String) -> void:
	if not _running:
		return
	_running = false
	_status.text = why
	DisplayServer.screen_set_keep_on(_keep_on_before)
	_paint()


## One roll: the request, and what came back. False when it was refused.
func _roll() -> bool:
	var id := str(_soldier.get("id", ""))
	if id == "":
		return false
	_rolling = true
	_paint()
	var res: Api.Response = await GameState.act("/v1/army/reroll", {"soldier_id": id})
	_rolling = false
	if _closing or not is_inside_tree():
		return false
	if not res.ok:
		if res.code == "stale_action":
			# Another action got in first; GameState has re-read the state. The
			# roll itself never happened, so look at the soldier again and let
			# the run carry on from what is true.
			await _reread()
			_show_big(_tier)
			return true
		_show_big(_tier)
		_status.text = res.error if res.error != "" else "The roll was refused."
		return false
	var before := _tier
	var s: Variant = res.data.get("soldier", null)
	if s is Dictionary:
		_soldier = s
	_tier = _tier_of(_soldier)
	_cost = int(res.data.get("reroll_cost", _cost))
	_gold_left = int(str(res.data.get("gold_left", "-1")))
	_rolls += 1
	_spent += int(res.data.get("paid", 0))
	_best = maxi(_best, _tier)
	_history.push_front(_tier)
	_land(before, _tier)
	_paint()
	return true


## The soldier as the server has it now, after a roll that may not have landed.
func _reread() -> void:
	var res: Api.Response = await Api.get_json("/v1/army")
	if not res.ok or _closing:
		return
	for slot in res.data.get("slots", []):
		var s: Variant = slot.get("soldier", null)
		if s is Dictionary and str(s.get("id", "")) == str(_soldier.get("id", "")):
			_soldier = s
			_tier = _tier_of(s)
			_cost = int(s.get("reroll_cost", _cost))
	_paint()


## The game left the screen: the run stops where it is. A request already in
## the air still lands, and the loop sees it has been stopped when it does.
func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_PAUSED or what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		if _running:
			_stop("Paused — the game left the screen. Press AUTO ROLL to go on.")


func _close() -> void:
	if _closing:
		return
	_closing = true
	if _running:
		_running = false
		DisplayServer.screen_set_keep_on(_keep_on_before)
	closed.emit()
	_layer.queue_free()


# --- reading the server's numbers ------------------------------------------------

func _tier_of(s: Dictionary) -> int:
	return SoldierArt.tier_of(str(s.get("tier", "common")))


func _bp_of(tier: int) -> int:
	for o in _odds:
		if str(o.get("tier", "")) == TIER_IDS[tier - 1]:
			return int(o.get("bp", 0))
	return 0


## 7179 basis points as "72%", 17 as "0.17%": the rare tiers' chances are the
## ones a player most wants to read, and rounding them to 0% hides them.
static func percent(bp: int) -> String:
	if bp <= 0:
		return "—"
	if bp >= 1000:
		return "%.0f%%" % (bp / 100.0)
	if bp >= 100:
		return "%.1f%%" % (bp / 100.0)
	return "%.2f%%" % (bp / 100.0)
