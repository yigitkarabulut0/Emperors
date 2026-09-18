extends Control
## THE ROYAL CHARTER -- COURT ▸ SEASON PASS, cut from art/reference/pass.png
## (art/slices/pass.json, layout client/layout/pass.json).
##
## The season runs 28 days, and what a lord does in it -- the day's reward, the
## day's and the week's quests, energy spent, raids won, carts opened, Golden
## Hours -- earns Charter points, up to a cap a day. Every `points_per_tier`
## points is a tier, fifty of them, and each tier holds a reward in two lanes:
## the free lane, open to every lord, and the royal lane, opened for the season
## with diamonds or bought from the App Store (the Royal Store does not sell
## it: only this page does).
##
## The page is the painting's. The header's two plates hold the season's time
## and its name; the strip holds the tier reached in the laurel medallion, the
## bar toward the next tier and its points, and UNLOCK with its price -- or,
## once the lane is open, ROYAL. Below FREE and ROYAL, the fifty tiers run down
## the chain in the painting's rows, each tier's number in its medallion (a
## crowned tier wears the ROYAL heading's crown), each lane's reward in its
## tile: dimmed while not reached, CLAIM on it once reached, the tick seal once
## claimed, the padlock on a royal tile while the lane is shut. At the foot the
## pedestal holds tier 50's prize, the Charter's own frame round the lord's
## face, and CLAIM ALL.
##
## Every figure is the server's (GET /v1/season): the page draws the tiers,
## lanes, points and prices it is given, and the season's clock only counts
## down from the answer's moment. No action_seq: a claim and an unlock pay
## through the one reward path, outside the sequence the queued collects count
## on, and their snapshot is adopted through GameState.adopt_async.

signal back_requested

const SCREEN := "pass"
const TITLE := "THE ROYAL CHARTER"
## A tile not reached, drawn down as every plate that cannot be pressed now is
## (StorePrice.DIMMED).
const DIMMED := Color(0.55, 0.55, 0.55)
## A tier's number: the painting's gold once reached, the muted ink before.
const REACHED_INK := Color("#F2D38A")
const AHEAD_INK := Color("#B8AE9C")
const TIMER_FIT := Vector2i(28, 18)
const SEASON_FIT := Vector2i(24, 16)
const POINTS_FIT := Vector2i(26, 17)
const WORD_FIT := Vector2i(29, 20)
const PRICE_FIT := Vector2i(22, 14)
const AMOUNT_FIT := Vector2i(22, 15)
## Each lane's amount plate, named in full: a layout part is found by its own
## name here and in the layout, never by one the code spells out of pieces.
const AMOUNT := {"free": "amount_free", "royal": "amount_royal"}
const TIER_FIT := Vector2i(40, 26)
const MEDAL_FIT := Vector2i(30, 20)
## The picture's box in a tile, and how far it rises while CLAIM covers the
## tile's foot; the amount rises with it.
const PIC_CLAIM_H := 56.0
const AMOUNT_CLAIM_RISE := 36.0
## A gear prize not yet rolled, and gold and experience, in the painted
## pictures the Tax Cart shows them in (reward_icons.png).
const DRESS := {"gold": "rewards/purse_small", "xp": "rewards/xp_scroll"}
const GEAR := "rewards/gear_chest"
## The Charter's frame, the prize on the pedestal.
const FINAL_FRAME := "frames/charter"
## The royal lane's mark, when it opens.
const ROYAL_SEAL := "pass/royal_seal"

var _ui: Dictionary = {}
var _season: Dictionary = {}
var _season_at_ms := 0
var _rows: Array = []          ## [{node, parts, tier, framed: {lane: node}}], one per tier
var _busy := false
var _built := false
var _scrolled := false         ## the list has been brought to its tier once
var _prices_answered := false  ## the App Store has answered since the page asked
var _asked_again := false      ## the season's clock ran out and the page asked again
var _pedestal_face: Control


func _ready() -> void:
	_ui = Layout.build(SCREEN, self)
	# The way back, the same plate and word on every Court view.
	_ui["back_hit"] = CourtBack.build(self)
	(_ui["back_hit"] as BaseButton).pressed.connect(func() -> void: back_requested.emit())
	(_ui["progress"] as BaseButton).pressed.connect(_how_to_earn)
	(_ui["info"] as BaseButton).pressed.connect(_how_to_earn)
	(_ui["unlock"] as BaseButton).pressed.connect(_unlock)
	(_ui["claim_all"] as BaseButton).pressed.connect(_claim_all)
	(_ui["pedestal_hit"] as BaseButton).pressed.connect(func() -> void: scroll_to_tier(tiers_of(_season)))
	Billing.products_changed.connect(func() -> void:
		_prices_answered = true
		_paint_unlock())
	Billing.busy_changed.connect(func(_b: bool) -> void: _paint_unlock())
	Billing.delivered.connect(_on_delivered)
	Billing.pending.connect(func(_id: String) -> void:
		if is_inside_tree():
			GameState.toast("Waiting for approval. The royal lane opens by itself once it is given."))
	Billing.failed.connect(func(_id: String, message: String) -> void:
		if is_inside_tree() and message != "":
			GameState.toast(message))
	var tick := Timer.new()
	tick.wait_time = 1.0
	tick.timeout.connect(_tick)
	add_child(tick)
	tick.start()
	_built = true
	# What the snapshot already says -- the tier and the lane -- until the
	# page's own answer comes.
	var live := GameState.season()
	if not live.is_empty():
		paint(from_live(live), GameState.live_age_s())


## The shell calls this when the view opens.
func refresh() -> void:
	if _built:
		_load()


func _load() -> void:
	var res: Api.Response = await Api.get_json("/v1/season")
	if not is_inside_tree():
		return
	if not res.ok:
		if res.code == "no_season":
			paint({})
			return
		GameState.action_failed.emit("The Royal Charter could not be read. " + res.error)
		return
	paint(res.data)


## Paints a season (a /v1/season answer) given `age` seconds ago. Public for
## tests and captures.
func paint(season: Dictionary, age: int = 0) -> void:
	_season = season
	_season_at_ms = Time.get_ticks_msec() - age * 1000
	_asked_again = false
	var sid := str(season.get("unlock", {}).get("store_id", ""))
	if sid != "":
		Billing.load_products(PackedStringArray([sid]))
	if not _built:
		return
	_paint_header()
	_paint_strip()
	_paint_unlock()
	_paint_rows()
	_paint_foot()
	if not _scrolled and not (season.get("charter", []) as Array).is_empty():
		_scrolled = true
		scroll_to_tier.call_deferred(focus_tier(season))


func _age() -> int:
	return (Time.get_ticks_msec() - _season_at_ms) / 1000


func _tick() -> void:
	if _season.is_empty():
		return
	_set_line(_ui["timer"], timer_words(_season, _age()), TIMER_FIT)
	# The season has ended while the page was open: ask what it is now, once.
	if int(_season.get("ends_in", 0)) > 0 and seconds_left(_season, _age()) <= 0 and not _asked_again and not _busy:
		_asked_again = true
		_load()


# --- painting -------------------------------------------------------------------------

func _paint_header() -> void:
	_set_line(_ui["timer"], timer_words(_season, _age()), TIMER_FIT)
	_set_line(_ui["season"], season_words(_season), SEASON_FIT)


func _paint_strip() -> void:
	_set_line(_ui["tier"], str(int(_season.get("tier", 0))) if not _season.is_empty() else "", TIER_FIT)
	Layout.set_fill(_ui["bar_fill"], fill_fraction(_season))
	_set_line(_ui["points"], points_words(_season), POINTS_FIT)


## UNLOCK and its price while the royal lane is shut; ROYAL and the lane's
## state once it is open.
func _paint_unlock() -> void:
	if not _built:
		return
	var sid := str(_season.get("unlock", {}).get("store_id", ""))
	var w := unlock_words(_season, Billing.available, Billing.price(sid), _prices_answered)
	_set_line(_ui["unlock_word"], str(w["word"]), WORD_FIT)
	var price: Label = _ui["unlock_price"]
	var gem: Control = _ui["unlock_gem"]
	gem.visible = bool(w["gem"])
	# The gem stands before the price's words, on the plate's middle with them.
	var box := Layout.rect_of(Layout.element(SCREEN, "unlock_price"))
	var gem_w := gem.size.x + 6.0 if gem.visible else 0.0
	price.position.x = box.position.x + gem_w
	price.set_meta("box_w", box.size.x - gem_w)
	price.size.x = box.size.x - gem_w
	_set_line(price, str(w["price"]), PRICE_FIT)
	price.label_settings.font_color = StorePrice.MUTED if bool(w["muted"]) else StorePrice.INK
	if gem.visible:
		# The words are centred in what is left of the plate; the gem sits just
		# before them.
		var used := price.get_theme_font("font").get_string_size(price.text, HORIZONTAL_ALIGNMENT_LEFT, -1,
			price.label_settings.font_size).x if price.label_settings == null else \
			price.label_settings.font.get_string_size(price.text, HORIZONTAL_ALIGNMENT_LEFT, -1,
			price.label_settings.font_size).x
		var start := box.position.x + (box.size.x - used - gem_w) / 2.0
		gem.position.x = start
		price.position.x = start + gem_w
		price.size.x = used + 2.0
		price.set_meta("box_w", used + 2.0)


## The fifty tiers down the chain, built once and dressed on every paint.
func _paint_rows() -> void:
	var sc: ScrollContainer = _ui["list"]
	var content: Control = sc.get_meta("content")
	var tpl := Layout.element(SCREEN, "tier_row")
	var pitch := float(tpl.get("pitch", 127))
	var charter: Array = _season.get("charter", [])
	while _rows.size() < charter.size():
		var i := _rows.size()
		var built := Layout.instantiate(tpl, [0, 0])
		built["node"].position = Vector2(0, i * pitch)
		built["tier"] = i + 1
		built["framed"] = {}
		content.add_child(built["node"])
		var p: Dictionary = built["parts"]
		(p["hit_free"] as BaseButton).pressed.connect(_tap.bind(i + 1, "free"))
		(p["hit_royal"] as BaseButton).pressed.connect(_tap.bind(i + 1, "royal"))
		_rows.append(built)
	for i in _rows.size():
		var r: Dictionary = _rows[i]
		(r["node"] as Control).visible = i < charter.size()
		if i < charter.size() and charter[i] is Dictionary:
			_dress_row(r, charter[i])
	# The chain runs a little past the last tier, under the pedestal's rim.
	content.custom_minimum_size.y = maxf(sc.size.y, charter.size() * pitch)


func _dress_row(r: Dictionary, t: Dictionary) -> void:
	var p: Dictionary = r["parts"]
	var reached := bool(t.get("reached", false))
	var medal: Label = p["medal"]
	medal.label_settings.font_color = REACHED_INK if reached else AHEAD_INK
	_set_line(medal, str(int(t.get("tier", r["tier"]))), MEDAL_FIT)
	(p["crown"] as CanvasItem).visible = bool(t.get("crown", false))
	var royal := bool(_season.get("royal", false))
	for lane in ["free", "royal"]:
		var state := tile_state(t, lane, royal)
		var lines: Array = t.get(lane, [])
		var dim := state == "ahead" or state == "locked_ahead"
		var look := DIMMED if dim else Color.WHITE
		(p["tile_" + lane] as CanvasItem).modulate = look
		var claiming := state == "claim"
		# The picture: its box rises clear of CLAIM while CLAIM is on the tile.
		var pic: TextureRect = p["pic_" + lane]
		var box := Layout.rect_of(Layout.find(SCREEN, "pic_" + lane))
		if claiming:
			box.size.y = PIC_CLAIM_H
		pic.position = box.position
		pic.size = box.size
		var old: Variant = r["framed"].get(lane)
		if old is Control and is_instance_valid(old):
			(old as Control).queue_free()
		r["framed"].erase(lane)
		var first := primary_line(lines)
		if first.is_empty():
			pic.visible = false
		else:
			var framed := RewardArt.dress(pic, dressed(first), str(GameState.player().get("avatar", "")))
			if framed != null:
				r["framed"][lane] = framed
				framed.modulate = look
		pic.modulate = look
		# What it pays, in the corner; a crowned tier's diamonds with their gem.
		var amount: Label = p[AMOUNT[lane]]
		var gem: Control = p["gem_" + lane]
		var abox := Layout.rect_of(Layout.find(SCREEN, AMOUNT[lane]))
		var gbox := Layout.rect_of(Layout.find(SCREEN, "gem_" + lane))
		var rise := AMOUNT_CLAIM_RISE if claiming else 0.0
		var extra := extra_diamonds(lines)
		gem.visible = extra > 0
		gem.position = gbox.position - Vector2(0, rise)
		amount.position.y = abox.position.y - rise
		var aw := abox.size.x - (gbox.size.x + 4.0 if gem.visible else 0.0)
		amount.size.x = aw
		amount.set_meta("box_w", aw)
		_set_line(amount, amount_words(lines), AMOUNT_FIT)
		amount.modulate = look
		gem.modulate = look
		(p["seal_" + lane] as CanvasItem).visible = state == "claimed"
		(p["claim_" + lane] as CanvasItem).visible = claiming and not _busy
		if lane == "royal":
			(p["lock_royal"] as CanvasItem).visible = state == "locked" or state == "locked_ahead"


## The pedestal: tier 50's frame round the lord's face, its tick once it is
## theirs; CLAIM ALL lit while something waits.
func _paint_foot() -> void:
	var holder: Control = _ui["pedestal"]
	if _pedestal_face == null or not is_instance_valid(_pedestal_face):
		var square := FramedFace.square_of(FINAL_FRAME)
		if square != "":
			_pedestal_face = FramedFace.build(square, Rect2(Vector2.ZERO, holder.size),
				str(GameState.player().get("avatar", "")))
			holder.add_child(_pedestal_face)
	var charter: Array = _season.get("charter", [])
	var last: Dictionary = charter[charter.size() - 1] if not charter.is_empty() and charter[-1] is Dictionary else {}
	(_ui["pedestal_seal"] as CanvasItem).visible = bool(last.get("royal_claimed", false))
	(_ui["claim_all"] as CanvasItem).modulate = Color.WHITE if int(_season.get("claimable", 0)) > 0 and not _busy else DIMMED


func _set_line(l: Label, words: String, fit: Vector2i) -> void:
	if l.text == words and l.label_settings.font_size <= fit.x:
		return
	l.text = words
	UI.fit_line(l, fit.x, fit.y)


## Brings a tier's row into view, with the one before it above it.
func scroll_to_tier(tier: int) -> void:
	if not is_inside_tree():
		return
	var sc: ScrollContainer = _ui["list"]
	# The list takes its content's height a frame late; set before then, the
	# scroll is clamped to the old one.
	await get_tree().process_frame
	if not is_inside_tree():
		return
	var pitch := float(Layout.element(SCREEN, "tier_row").get("pitch", 127))
	sc.scroll_vertical = int(maxf(0.0, (tier - 2) * pitch))


# --- what each part says ----------------------------------------------------------
# Pure, from the season as the server described it, so a test reads every case.

## The snapshot's season ({number, ends_in, tier, tiers, royal}) as a page's
## answer, until the page's own comes.
static func from_live(live: Dictionary) -> Dictionary:
	return {"number": int(live.get("number", 0)), "name": "Season %d" % int(live.get("number", 0)) if int(live.get("number", 0)) > 0 else "",
		"ends_in": int(live.get("ends_in", 0)), "tier": int(live.get("tier", 0)), "tiers": int(live.get("tiers", 0)),
		"royal": bool(live.get("royal", false))}


static func tiers_of(season: Dictionary) -> int:
	var n := int(season.get("tiers", 0))
	var charter: Array = season.get("charter", [])
	return maxi(n, charter.size())


## Seconds left in the season, counted down `age` seconds from the answer.
static func seconds_left(season: Dictionary, age: int) -> int:
	return maxi(0, int(season.get("ends_in", 0)) - age)


## The plate beside the hourglass: the season's time left.
static func timer_words(season: Dictionary, age: int) -> String:
	if season.is_empty() or int(season.get("number", 0)) <= 0:
		return ""
	var left := seconds_left(season, age)
	if left <= 0:
		return "Closing"
	return UI.time_left(left)


## The plate under it: the season's name and its day.
static func season_words(season: Dictionary) -> String:
	if season.is_empty() or int(season.get("number", 0)) <= 0:
		return "No season is running"
	var name := str(season.get("name", ""))
	if name == "":
		name = "Season %d" % int(season.get("number", 0))
	var day := int(season.get("day", 0))
	var days := int(season.get("days", 0))
	if day > 0 and days > 0:
		return "%s · Day %d of %d" % [name, day, days]
	return name


## The points plate: the points into the tier being worked on, of the tier's.
static func points_words(season: Dictionary) -> String:
	if season.is_empty() or not season.has("points_per_tier"):
		return ""
	var tiers := tiers_of(season)
	if tiers > 0 and int(season.get("tier", 0)) >= tiers:
		return "All %d tiers" % tiers
	return "%s / %s" % [UI.grouped(int(season.get("tier_points", 0))), UI.grouped(int(season.get("points_per_tier", 0)))]


## How far the bar runs: the points into the tier over the tier's, full once
## every tier is reached.
static func fill_fraction(season: Dictionary) -> float:
	var per := int(season.get("points_per_tier", 0))
	var tiers := tiers_of(season)
	if tiers > 0 and int(season.get("tier", 0)) >= tiers:
		return 1.0
	if per <= 0:
		return 0.0
	return clampf(float(season.get("tier_points", 0)) / float(per), 0.0, 1.0)


## A tile's state: "claimed", "claim" (reached and waiting), "ahead" (not
## reached); a royal tile while the lane is shut, "locked" (reached) or
## "locked_ahead".
static func tile_state(t: Dictionary, lane: String, royal_open: bool) -> String:
	var reached := bool(t.get("reached", false))
	if lane == "royal" and not royal_open:
		return "locked" if reached else "locked_ahead"
	if bool(t.get(lane + "_claimed", false)):
		return "claimed"
	return "claim" if reached else "ahead"


## The line whose picture a tile shows: the one that is not diamonds, when a
## crowned tier pays diamonds beside a look, a charter or gear.
static func primary_line(lines: Array) -> Dictionary:
	for l in lines:
		if l is Dictionary and str(l.get("kind", "")) != "diamonds":
			return l
	for l in lines:
		if l is Dictionary:
			return l
	return {}


## The diamonds a tile pays beside its picture's reward, else 0.
static func extra_diamonds(lines: Array) -> int:
	var first := primary_line(lines)
	if str(first.get("kind", "")) == "diamonds":
		return 0
	for l in lines:
		if l is Dictionary and str(l.get("kind", "")) == "diamonds":
			return int(l.get("amount", 0))
	return 0


## The corner's words: the picture's reward counted when it is more than one
## (196 gold, 20 diamonds), or the diamonds beside it ("+20").
static func amount_words(lines: Array) -> String:
	var extra := extra_diamonds(lines)
	if extra > 0:
		return "+" + UI.grouped(extra)
	var first := primary_line(lines)
	var n := int(first.get("amount", 0))
	return UI.grouped(n) if n > 1 else ""


## A line in the picture a tile shows it with: gold as the purse and experience
## as the scroll, gear not yet rolled as the gear chest, as the Tax Cart shows
## them; everything else as its own.
static func dressed(line: Dictionary) -> Dictionary:
	var c := line.duplicate()
	var kind := str(c.get("kind", ""))
	if DRESS.has(kind):
		c["icon"] = DRESS[kind]
	elif kind == "item" and str(c.get("icon", "")).begins_with("item:"):
		c["icon"] = GEAR
	return c


## The tier the list opens at: the first with a reward waiting in a lane the
## lord holds, else the one being worked on.
static func focus_tier(season: Dictionary) -> int:
	var royal := bool(season.get("royal", false))
	var charter: Array = season.get("charter", [])
	for t in charter:
		if not (t is Dictionary):
			continue
		if tile_state(t, "free", royal) == "claim" or tile_state(t, "royal", royal) == "claim":
			return int(t.get("tier", 1))
	return clampi(int(season.get("tier", 0)) + 1, 1, maxi(1, charter.size()))


## UNLOCK's plate: {word, price, gem, muted}. Shut: UNLOCK, and the lane's two
## prices -- its diamonds (the gem before them) and the App Store's price, "…"
## while it has not answered, the catalogue's dollars in the muted ink where
## purchases are not open. Open: ROYAL, and that it is the lord's.
static func unlock_words(season: Dictionary, available: bool, app_price: String, answered: bool) -> Dictionary:
	if bool(season.get("royal", false)):
		return {"word": "ROYAL", "price": "Yours this season", "gem": false, "muted": false}
	var u: Dictionary = season.get("unlock", {})
	var gems := int(u.get("diamonds", 0))
	if gems <= 0 and u.is_empty():
		return {"word": "UNLOCK", "price": "", "gem": false, "muted": false}
	var money := StorePrice.words({"usd_cents": int(u.get("usd_cents", 0))}, available, app_price, answered)
	var said := str(money.get("text", ""))
	var words := UI.grouped(gems)
	if said != "":
		words += " · " + said
	return {"word": "UNLOCK", "price": words, "gem": gems > 0, "muted": false}


## What a tile holds, said when it is tapped and has nothing to claim.
static func tile_words(t: Dictionary, lane: String, royal_open: bool) -> String:
	var lines: Array = t.get(lane, [])
	var what: Array = []
	for l in lines:
		if l is Dictionary and str(l.get("text", "")) != "":
			what.append(str(l["text"]))
	var head := "Tier %d, %s: %s" % [int(t.get("tier", 0)), "royal lane" if lane == "royal" else "free lane",
		", ".join(what)]
	match tile_state(t, lane, royal_open):
		"claimed":
			return head + ". Claimed."
		"ahead", "locked_ahead":
			return head + ". Not reached yet."
		"locked":
			return head + ". Open the royal lane to claim it."
	return head + "."


# --- claiming -----------------------------------------------------------------------

func _tier(tier: int) -> Dictionary:
	var charter: Array = _season.get("charter", [])
	if tier < 1 or tier > charter.size() or not (charter[tier - 1] is Dictionary):
		return {}
	return charter[tier - 1]


## A tap on a tile: its claim when it has one, the royal lane's offer while it
## is shut, else what it holds.
func _tap(tier: int, lane: String) -> void:
	var t := _tier(tier)
	if t.is_empty():
		return
	var royal := bool(_season.get("royal", false))
	match tile_state(t, lane, royal):
		"claim":
			_claim(tier, lane)
		"locked", "locked_ahead":
			_unlock()
		_:
			GameState.toast(tile_words(t, lane, royal))


func _claim(tier: int, lane: String) -> void:
	if _busy:
		return
	await _send_claim({"tier": tier, "lane": lane})


func _claim_all() -> void:
	if _busy:
		return
	if int(_season.get("claimable", 0)) <= 0:
		await Dialog.ask(self, {"title": "Nothing waits on the Charter",
			"body": "Every tier reached is claimed. What you do earns the next: see how the Charter fills.",
			"confirm_text": "OK"})
		return
	await _send_claim({})


func _send_claim(body: Dictionary) -> void:
	_busy = true
	_paint_rows()
	_paint_foot()
	var res: Api.Response = await Api.post_json("/v1/season/claim", body)
	if not is_inside_tree():
		return
	if res.ok:
		if res.data.get("snapshot", null) is Dictionary:
			GameState.adopt_async(res.data["snapshot"])
		var after: Variant = res.data.get("season", null)
		if after is Dictionary:
			paint(after)
			_set_badge(after)
		var lines: Array = res.data.get("lines", [])
		if not lines.is_empty():
			var shell := get_tree().get_first_node_in_group("shell")
			Ceremony.delivery(shell if shell != null else self, {"title": TITLE, "lines": lines})
		var skipped: Array = res.data.get("skipped", [])
		if not skipped.is_empty():
			GameState.toast(skipped_words(skipped))
	else:
		match res.code:
			"inventory_full":
				await Armory.refused(self, res.error, Armory.sentence(res.error)
					+ " The tier's gear waits; sell or wear something, then claim it.")
			"charter_locked":
				_unlock()
			"nothing_to_claim", "already_claimed", "no_season":
				GameState.toast(res.error)
			_:
				GameState.action_failed.emit(res.error)
		# A refusal reloads: the screen may be behind the server's answer.
		await _load()
	# The guard is held to the end, through the reload a refusal makes: a second
	# tap on a tier the first has already taken would answer a row that no
	# longer says what it says.
	_busy = false


## Tiers whose gear could not come for want of room, said as the toast says it.
static func skipped_words(tiers: Array) -> String:
	var names: Array = []
	for t in tiers:
		names.append(str(int(t)))
	var which: String = "tier " + str(names[0]) if names.size() == 1 else "tiers " + ", ".join(names)
	return "No room in the armory for %s: the gear waits there. Sell or wear something, then claim it." % which


## The Charter's disc on the COURT and the rail, set now rather than at the
## next heartbeat.
static func _set_badge(season: Dictionary) -> void:
	var b := GameState.badges.duplicate()
	b["season"] = int(season.get("claimable", 0))
	GameState.set_badges(b)


# --- the royal lane ------------------------------------------------------------------

## UNLOCK: the lane's two ways in, diamonds or the App Store; ROYAL: what the
## lane is.
func _unlock() -> void:
	if _busy or _season.is_empty():
		return
	var number := int(_season.get("number", 0))
	if bool(_season.get("royal", false)):
		GameState.toast("The royal lane is yours until Season %d closes." % number)
		return
	var u: Dictionary = _season.get("unlock", {})
	var sid := str(u.get("store_id", ""))
	var money := StorePrice.words({"usd_cents": int(u.get("usd_cents", 0))}, Billing.available, Billing.price(sid),
		_prices_answered)
	var options: Array = [{"id": "diamonds", "label": "%s DIAMONDS" % UI.grouped(int(u.get("diamonds", 0))),
		"sub": "You hold %s" % UI.grouped(int(GameState.player().get("diamonds", 0)))}]
	if sid != "":
		options.append({"id": "money", "label": str(money.get("text", "")) if str(money.get("text", "")) != "" else "THE APP STORE",
			"sub": "Bought through the App Store"})
	var pick := await Dialog.choose(self, {"title": "OPEN THE ROYAL LANE",
		"body": royal_body(_season), "options": options, "cancel_text": "NOT NOW"})
	if not is_inside_tree():
		return
	match pick:
		"diamonds":
			await _unlock_with_diamonds()
		"money":
			buy()


## What the royal lane holds, in the server's numbers, and that it ends with
## the season.
static func royal_body(season: Dictionary) -> String:
	var number := int(season.get("number", 0))
	var gems := int(season.get("royal_diamonds", 0))
	var out := "The royal lane's fifty rewards"
	if gems > 0:
		out += " -- %s diamonds among them, with potions, pardons, a name colour, a title and the Charter's own frame --" % UI.grouped(gems)
	out += " are yours to claim as your tiers reach them"
	if number > 0:
		out += ", until Season %d closes" % number
	return out + ". Tiers you have already reached open at once."


func _unlock_with_diamonds() -> void:
	_busy = true
	var res: Api.Response = await Api.post_json("/v1/season/unlock", {})
	if not is_inside_tree():
		return
	if res.ok:
		if res.data.get("snapshot", null) is Dictionary:
			GameState.adopt_async(res.data["snapshot"])
		var after: Variant = res.data.get("season", null)
		if after is Dictionary:
			paint(after)
			_set_badge(after)
		var shell := get_tree().get_first_node_in_group("shell")
		Ceremony.delivery(shell if shell != null else self, {"title": TITLE, "lines": [
			{"kind": "charter", "amount": int(_season.get("number", 0)), "icon": ROYAL_SEAL,
				"text": "The royal lane of Season %d's Charter is open" % int(_season.get("number", 0))}]})
	else:
		match res.code:
			"not_enough_diamonds":
				var need := int(_season.get("unlock", {}).get("diamonds", 0))
				if await Dialog.ask(self, {"title": "Not enough diamonds",
						"body": "The royal lane costs %s diamonds, and you hold %s." % [UI.grouped(need),
							UI.grouped(int(GameState.player().get("diamonds", 0)))],
						"confirm_text": "ROYAL STORE", "cancel_text": "NOT NOW"}):
					var shell := get_tree().get_first_node_in_group("shell")
					if shell != null:
						shell.call("open_view", "store")
			"royal_open":
				GameState.toast(res.error)
			_:
				GameState.action_failed.emit(res.error)
		await _load()
	# Held to the end: the lane opens once, and a second tap would pay twice.
	_busy = false


## Buys the Charter from the App Store. The lane opens when the purchase is
## delivered (Billing.delivered); a lord whose lane is already open is paid
## its diamonds instead, which the server decides.
func buy() -> void:
	var sid := str(_season.get("unlock", {}).get("store_id", ""))
	if sid == "":
		return
	if not Billing.available:
		GameState.toast(Billing.unavailable_reason())
		return
	if Billing.busy:
		return
	Billing.buy(sid)


## A purchase landed. The shell plays the Royal Delivery; the page is read
## again, since a Charter opens the lane.
func _on_delivered(_d: Dictionary) -> void:
	if is_inside_tree():
		await _load()


# --- how the Charter fills -----------------------------------------------------------

func _how_to_earn() -> void:
	how_to_earn(self, _season)


## HOW THE CHARTER FILLS: every way to earn points with what each earns, and
## the day's points against the day's cap. A plain page, as the cart's odds are.
static func how_to_earn(host: Node, season: Dictionary) -> Sheet:
	var per := int(season.get("points_per_tier", 0))
	var sub := "Every %s points is a tier." % UI.grouped(per) if per > 0 else ""
	var s := Sheet.open(host, "HOW THE CHARTER FILLS", sub)
	if season.is_empty() or not season.has("sources"):
		s.paragraph("The Charter could not be read. Close this and try again in a moment.", 22, UI.DIM)
		s.add_close()
		return s
	s.paragraph(today_words(season), 24, UI.INK, HORIZONTAL_ALIGNMENT_CENTER)
	var row_h := 84.0
	var icon := 60.0
	for src in season.get("sources", []):
		if not (src is Dictionary):
			continue
		var row := s.slot(row_h)
		var mark := TextureRect.new()
		mark.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		mark.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		mark.mouse_filter = Control.MOUSE_FILTER_IGNORE
		mark.texture = Art.tex(str(QuestTile.WEEKLY_ICON.get(str(src.get("icon", "")), "icons/quest_scroll_lg")))
		UI.place(mark, Rect2(18, (row_h - icon) / 2.0, icon, icon))
		row.add_child(mark)
		var x := 18.0 + icon + 18.0
		var pts_w := 120.0
		Sheet.put(row, str(src.get("text", "")), Rect2(x, 0, s.inner_w - x - pts_w - 18.0, row_h), 24, UI.INK, "body", 600)
		Sheet.put(row, "+" + UI.grouped(int(src.get("points", 0))), Rect2(s.inner_w - pts_w - 18.0, 0, pts_w, row_h), 28,
			UI.GOLD, "title", 700, HORIZONTAL_ALIGNMENT_RIGHT)
	s.paragraph(terms_words(season), 21, UI.DIM, HORIZONTAL_ALIGNMENT_CENTER)
	s.add_close()
	return s


## Today's points against the day's cap.
static func today_words(season: Dictionary) -> String:
	var cap := int(season.get("day_cap", 0))
	var got := int(season.get("day_points", 0))
	if cap <= 0:
		return "Today: %s points" % UI.grouped(got)
	if got >= cap:
		return "Today: %s of %s points -- the day's are all earned" % [UI.grouped(got), UI.grouped(cap)]
	return "Today: %s of the day's %s points" % [UI.grouped(got), UI.grouped(cap)]


## The terms under the table, in the server's numbers.
static func terms_words(season: Dictionary) -> String:
	var parts: Array = []
	var cap := int(season.get("day_cap", 0))
	if cap > 0:
		parts.append("Points stop at %s a day." % UI.grouped(cap))
	var knight := int(season.get("knight_tier", 0))
	if knight > 0:
		parts.append("Reach tier %d and the Crown names you a Knight when the season closes." % knight)
	parts.append("Anything reached and not claimed is sent to you by letter when the season ends.")
	return " ".join(parts)
