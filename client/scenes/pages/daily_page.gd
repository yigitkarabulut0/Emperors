extends RefCounted
## DAILY REWARDS -- twenty-eight days, one square a day, a crown at the end of
## each week, and this week's chests under them.
##
## It is its painting (art/reference/calendar.png, layout client/layout/
## calendar.json) on the painted pages' host. Every square is the server's
## (GET /v1/daily): which day a claim takes, what each square gives -- its
## picture by `kind`, its amount on the plate, its whole `lines` on a tap --
## which are taken, and whether the streak is broken. The four crown squares
## wear the picture of what they give: the title's crown, the frame, the chest
## of gear, the crest. A broken streak shows the painting's BROKEN row: RESTORE
## for its diamonds, USE PARDON while a pardon is held, START ANEW; otherwise
## that row says what a pardon is and how many are held. THIS WEEK is the
## weekly quests' chest bar (GET /v1/weekly), its chests taken here too.
##
## Claims are not the lord's sequenced actions: no action_seq, the answer's
## snapshot adopted through GameState.adopt_async, what came in the painted
## delivery ceremony. Nothing here computes a reward: the plates say the
## server's amounts, and the bar only places the server's points between the
## painted markers.

const PAGE := "calendar"
## The name it has always had in the analytics.
const SCREEN := "page:daily"
const PLAIN := 6          ## plain squares to a row; the seventh is the crown
const DAYS := 28

## A plain square's picture by the square's `kind`.
const KIND_ICON := {"diamonds": "calendar/icon_diamond", "purse": "calendar/icon_purse",
	"flask": "calendar/icon_flask", "scroll": "calendar/icon_scroll", "cart": "calendar/icon_cart"}
## A crown square, whole, by what it gives.
const CROWN_ART := {"title": "calendar/crown_title", "frame": "calendar/crown_frame",
	"gear": "calendar/crown_gear", "crest": "calendar/crown_crest"}
const SQUARE := "calendar/square"
const SQUARE_TODAY := "calendar/square_today"
## The glowing square is painted two units wider and three taller than the
## plain one, one up and two left of it.
const TODAY_RECT := Rect2(-2, -1, 113, 140)
const PLAIN_RECT := Rect2(0, 0, 113, 137)
## A taken square's picture, as the painting's first row has them: darker.
const TAKEN := Color(0.6, 0.6, 0.64)
const TAKEN_CROWN := Color(0.74, 0.74, 0.77)

const CREAM := Color("#F2EADB")
const GOLD := Color("#E9C477")
const DIAMOND_BLUE := Color("#9FD8FF")
const SHORT := Color("#F0524F")

## The weekly bar: the channel's run between the rails, and the painted
## markers its three chests stand on.
const BAR := [201.0, 825.0]
const MARKERS := [451.0, 637.0, 832.0]
const CHESTS := 3
## Each chest's parts, by tier: its picture, its seal, the threshold on its
## plate, and the tap that takes it.
const CHEST_ART := ["chest_0", "chest_1", "chest_2"]
const CHEST_SEAL := ["chest_0_seal", "chest_1_seal", "chest_2_seal"]
const CHEST_AT := ["chest_0_at", "chest_1_at", "chest_2_at"]
const CHEST_WAITING := Color(0.5, 0.5, 0.56)
const CHEST_TAKEN := Color(0.78, 0.78, 0.8)


## Opens the page for the server's calendar. `on_claimed` runs after a claim
## (the shell's heartbeat, which clears the pill's dot). `opts`: "inset" (a
## test's notch), "weekly" (the weekly view to paint instead of asking).
static func open(host: Node, daily: Dictionary, on_claimed: Callable = Callable(), opts: Dictionary = {}) -> PaintedPage:
	var o := {"screen": SCREEN}
	o.merge(opts, true)
	var p := PaintedPage.open(host, PAGE, o)
	p.set_meta("host", host)
	p.set_meta("on_claimed", on_claimed)
	p.set_meta("busy", false)
	paint(p, daily)
	p.on("claim", func() -> void: _claim(p, ""))
	GuideTargets.register("daily.claim", p.node("claim"))
	p.on("restore", func() -> void: _claim(p, "diamonds"))
	p.on("pardon", func() -> void: _claim(p, "pardon"))
	p.on("anew", func() -> void: _anew(p))
	for i in CHESTS:
		p.on("chest%d" % i, func() -> void: _chest(p, i))
	for inst in _all_squares(p):
		var hit: BaseButton = inst["parts"]["hit"]
		hit.pressed.connect(func() -> void:
			if hit.has_meta("square"):
				GameState.toast(detail(hit.get_meta("square"))))
	if opts.has("weekly"):
		paint_weekly(p, opts["weekly"])
	else:
		_load_weekly(p)
	return p


# --- the calendar ---------------------------------------------------------------------------

## Paints the server's calendar (GET /v1/daily, or a claim's `daily`).
static func paint(p: PaintedPage, d: Dictionary) -> void:
	p.set_meta("daily", d)
	var squares: Array = d.get("squares", [])
	var plain: Array = p.parts.get("square", [])
	var crowns: Array = p.parts.get("crown", [])
	for i in DAYS:
		var sq: Dictionary = squares[i] if i < squares.size() and squares[i] is Dictionary else {}
		var row := i / 7
		var col := i % 7
		if col == PLAIN:
			if row < crowns.size():
				_paint_crown(crowns[row]["parts"], sq)
		elif row * PLAIN + col < plain.size():
			_paint_square(plain[row * PLAIN + col]["parts"], sq)

	var broken: Variant = d.get("broken", null)
	var is_broken := broken is Dictionary
	p.set_text("streak", header(d), 16)
	for id in ["broken", "restore", "restore_price", "pardon", "anew"]:
		p.set_shown(id, is_broken)
	p.set_shown("row_title", not is_broken)
	p.set_shown("row_note", not is_broken)
	var pardons := int(d.get("pardons", 0))
	if is_broken:
		var b: Dictionary = broken
		var price := int(b.get("restore_diamonds", 0))
		var short := int(d.get("diamonds", 0)) < price
		p.set_text("restore_price", UI.grouped(price), 16).label_settings.font_color = SHORT if short else CREAM
		p.set_enabled("restore", bool(b.get("can_restore", false)))
		p.set_enabled("pardon", bool(b.get("can_pardon", false)) and pardons > 0)
		p.set_enabled("anew", true)
	else:
		p.set_text("row_title", "ROYAL PARDONS  %d OF %d" % [pardons, int(d.get("pardons_max", 0))], 18)
		p.set_text("row_note", "Miss a day and the streak breaks. For two days a pardon, or a few diamonds, mends it; a new pardon comes with each new month of days.", 18)
	# The pardons held, in the rail's count bubble on USE PARDON's corner.
	p.set_shown("pardon_bubble", is_broken and pardons > 0)
	p.set_shown("pardon_count", is_broken and pardons > 0)
	p.set_text("pardon_count", str(pardons), 14)

	# CLAIM while a plain claim can be made; the page's CLOSE otherwise.
	var can_claim := bool(d.get("claimable", false)) and not is_broken
	p.set_shown("claim", can_claim)
	p.set_shown("close", not can_claim)


## The header plate's words.
static func header(d: Dictionary) -> String:
	var day := int(d.get("day", 1))
	var streak := int(d.get("streak", 0))
	if d.get("broken", null) is Dictionary:
		var missed := int((d["broken"] as Dictionary).get("missed", 1))
		return "THE STREAK IS BROKEN · %d DAY%s MISSED" % [missed, "" if missed == 1 else "S"]
	if not bool(d.get("claimable", false)):
		return "COME BACK TOMORROW FOR DAY %d" % (day % DAYS + 1)
	if streak > 1:
		return "DAY %d OF %d · %d DAYS IN A ROW" % [day, DAYS, streak]
	return "DAY %d OF %d" % [day, DAYS]


static func _paint_square(parts: Dictionary, sq: Dictionary) -> void:
	var state := str(sq.get("state", "ahead"))
	var today := state == "today"
	var taken := state == "claimed"
	var frame: TextureRect = parts["frame"]
	frame.texture = Art.tex(SQUARE_TODAY if today else SQUARE)
	UI.place(frame, TODAY_RECT if today else PLAIN_RECT)
	(parts["glow"] as Control).visible = today
	var icon: TextureRect = parts["icon"]
	icon.texture = Art.tex(str(KIND_ICON.get(str(sq.get("kind", "")), KIND_ICON["diamonds"])))
	icon.modulate = TAKEN if taken else Color.WHITE
	(parts["seal"] as Control).visible = taken
	_plate(parts["amount"], sq, taken)
	(parts["hit"] as Control).set_meta("square", sq)


static func _paint_crown(parts: Dictionary, sq: Dictionary) -> void:
	var state := str(sq.get("state", "ahead"))
	var taken := state == "claimed"
	var frame: TextureRect = parts["frame"]
	frame.texture = Art.tex(str(CROWN_ART[crown_of(sq)]))
	frame.modulate = TAKEN_CROWN if taken else Color.WHITE
	(parts["glow"] as Control).visible = state == "today"
	(parts["seal"] as Control).visible = taken
	_plate(parts["amount"], sq, taken)
	(parts["hit"] as Control).set_meta("square", sq)


static func _plate(l: Label, sq: Dictionary, taken: bool) -> void:
	var kind := str(sq.get("kind", ""))
	var col := CREAM
	if kind == "diamonds" or (kind == "crown" and plate_text(sq).begins_with("+")):
		col = DIAMOND_BLUE
	elif kind == "purse":
		col = GOLD
	var painted := int(l.get_meta("painted_size", l.label_settings.font_size))
	l.set_meta("painted_size", painted)
	l.label_settings.font_size = painted
	l.label_settings.font_color = Color(col, 0.55) if taken else col
	l.text = plate_text(sq)
	UI.fit_label(l, painted, 14)
	if l.has_meta("box_w"):
		l.size.x = maxf(float(l.get_meta("box_w")), l.get_minimum_size().x)


## What a square's plate says: its amount, short. The picture says what it is;
## a tap says it whole.
static func plate_text(sq: Dictionary) -> String:
	var n := int(sq.get("amount", 0))
	match str(sq.get("kind", "")):
		"diamonds":
			return UI.grouped(n)
		"purse", "scroll":
			return UI.short_number(n)
		"flask", "cart":
			return "×%d" % maxi(n, 1)
		"crown":
			return _crown_words(sq)
	return str(sq.get("text", ""))


## A crown square's plate: the diamonds that come with its prize, else the kind
## of prize -- TITLE, FRAME, CREST, or the gear's rarity.
static func _crown_words(sq: Dictionary) -> String:
	var gems := 0
	var what := ""
	for l in sq.get("lines", []):
		if not (l is Dictionary):
			continue
		match str(l.get("kind", "")):
			"diamonds":
				gems += int(l.get("amount", 0))
			"cosmetic":
				if what == "":
					what = crown_of({"lines": [l]}).to_upper()
			"item":
				if what == "":
					what = str(l.get("tier", "gear")).to_upper()
	if gems > 0 and what != "" and what != "GEAR":
		return "+%s" % UI.grouped(gems)
	if what != "":
		return what
	return "+%s" % UI.grouped(gems) if gems > 0 else str(sq.get("text", ""))


## Which crown picture a crown square wears, by what its lines give: a title,
## a frame, a crest or gear. A crown of diamonds alone wears the title's crown.
static func crown_of(sq: Dictionary) -> String:
	var found := "title"
	for l in sq.get("lines", []):
		if not (l is Dictionary):
			continue
		var icon := str(l.get("icon", ""))
		var kind := str(l.get("kind", ""))
		if kind == "cosmetic":
			if icon.begins_with("title:"):
				return "title"
			if icon.begins_with("frames/") or icon.begins_with("frame:"):
				return "frame"
			if icon.begins_with("icons/crest") or icon.begins_with("crest:"):
				return "crest"
		elif kind == "item":
			found = "gear"
	return found


## A square said whole, for a tap: "Day 14: Loyal Vassal (frame)".
static func detail(sq: Dictionary) -> String:
	var words := PackedStringArray()
	for l in sq.get("lines", []):
		if l is Dictionary and str(l.get("text", "")) != "":
			words.append(str(l["text"]))
	if words.is_empty():
		words.append(str(sq.get("text", "")))
	var what := ", ".join(words)
	match str(sq.get("state", "")):
		"claimed":
			return "Day %d, taken: %s" % [int(sq.get("day", 0)), what]
		"today":
			return "Day %d, today: %s" % [int(sq.get("day", 0)), what]
	return "Day %d: %s" % [int(sq.get("day", 0)), what]


static func _all_squares(p: PaintedPage) -> Array:
	var out: Array = []
	for id in ["square", "crown"]:
		var list: Variant = p.parts.get(id, [])
		if list is Array:
			out.append_array(list)
	return out


# --- claiming -------------------------------------------------------------------------------

## CLAIM, RESTORE, USE PARDON and START ANEW: one claim, with how the streak is
## mended ("" for a plain claim).
static func _claim(p: PaintedPage, mend: String) -> void:
	if bool(p.get_meta("busy", false)):
		return
	p.set_meta("busy", true)
	var d: Dictionary = p.get_meta("daily", {})
	var body := {} if mend == "" else {"mend": mend}
	var res: Api.Response = await Api.post_json("/v1/daily/claim", body)
	if not is_instance_valid(p):
		return
	if res.ok:
		if res.data.get("snapshot", null) is Dictionary:
			GameState.adopt_async(res.data["snapshot"])
		var after: Variant = res.data.get("daily", null)
		if after is Dictionary:
			paint(p, after)
		var lines: Array = res.data.get("lines", [])
		var host: Node = p.get_meta("host") if p.has_meta("host") else null
		if not lines.is_empty() and host != null and is_instance_valid(host):
			var ceremony: GDScript = load("res://scenes/pages/ceremony.gd")
			ceremony.delivery(host, {"lines": lines, "title": "Day %d" % int(d.get("day", 1))})
		var cb: Callable = p.get_meta("on_claimed", Callable())
		if cb.is_valid():
			cb.call()
		# The day's claim counts toward this week's task.
		await _load_weekly(p)
	else:
		match res.code:
			"already_claimed", "calendar_broken":
				await _reload(p)
			"inventory_full":
				GameState.armory_full.emit(res.error)
			"not_enough_diamonds":
				GameState.toast("You have too few diamonds to restore the streak.")
			"no_token":
				GameState.toast("You hold no Royal Pardon.")
			_:
				GameState.toast(res.error)
	if is_instance_valid(p):
		p.set_meta("busy", false)


## START ANEW ends the streak: asked first, since it cannot be undone.
static func _anew(p: PaintedPage) -> void:
	var d: Dictionary = p.get_meta("daily", {})
	var streak := int(d.get("streak", 0))
	if not await Dialog.ask(p, {"title": "Start anew?",
			"body": "The calendar goes back to day one%s. The rewards already taken are kept." % \
				(" and the streak of %d days ends" % streak if streak > 1 else ""),
			"confirm_text": "Start anew"}):
		return
	await _claim(p, "anew")


static func _reload(p: PaintedPage) -> void:
	var res: Api.Response = await Api.get_json("/v1/daily")
	if res.ok and is_instance_valid(p):
		paint(p, res.data)


# --- this week ------------------------------------------------------------------------------

static func _load_weekly(p: PaintedPage) -> void:
	var res: Api.Response = await Api.get_json("/v1/weekly")
	if not is_instance_valid(p):
		return
	if res.ok:
		paint_weekly(p, res.data)
	else:
		paint_weekly(p, {})


## Paints the weekly chest bar (GET /v1/weekly). With no weekly view (an older
## server, a failed read) the bar stays empty and the chests closed and dim.
static func paint_weekly(p: PaintedPage, w: Dictionary) -> void:
	p.set_meta("weekly", w)
	var chests: Array = w.get("chests", [])
	var points := int(w.get("points", 0))
	var most := int(w.get("points_max", 0))
	p.set_text("points", "%d/%d" % [points, most] if not w.is_empty() else "—", 16)
	var fill := p.node("week_fill")
	if fill != null:
		Layout.set_fill(fill, bar_fraction(points, most, chests))
	for i in CHESTS:
		var c: Dictionary = chests[i] if i < chests.size() and chests[i] is Dictionary else {}
		var taken := bool(c.get("claimed", false))
		var ready := bool(c.get("ready", false)) and not taken
		var chest := p.node(CHEST_ART[i])
		if chest != null:
			chest.modulate = CHEST_TAKEN if taken else (Color.WHITE if ready else CHEST_WAITING)
			_bob(chest, ready)
		p.set_shown(CHEST_SEAL[i], taken)
		p.set_text(CHEST_AT[i], str(int(c.get("at", 0))) if not c.is_empty() else "", 14)
		p.set_enabled("chest%d" % i, ready)


## Where the bar's fill ends, as a share of its channel: each threshold on its
## painted marker, the points between them in proportion; the week's last
## point fills the channel.
static func bar_fraction(points: int, most: int, chests: Array) -> float:
	if points <= 0:
		return 0.0
	if most > 0 and points >= most:
		return 1.0
	var at: Array = [0]
	var xs: Array = [BAR[0]]
	for i in mini(chests.size(), MARKERS.size()):
		if chests[i] is Dictionary:
			at.append(int(chests[i].get("at", 0)))
			xs.append(MARKERS[i])
	if most > at[-1]:
		at.append(most)
		xs.append(BAR[1])
	var x: float = xs[-1]
	for i in range(1, at.size()):
		if points <= int(at[i]):
			var span := maxf(1.0, float(int(at[i]) - int(at[i - 1])))
			x = lerpf(xs[i - 1], xs[i], float(points - int(at[i - 1])) / span)
			break
	return clampf((x - BAR[0]) / (BAR[1] - BAR[0]), 0.0, 1.0)


## A chest that can be taken rises and settles, over and over, until taken.
static func _bob(chest: Control, on: bool) -> void:
	if chest.has_meta("bob"):
		var tw: Tween = chest.get_meta("bob")
		if tw != null and tw.is_valid():
			tw.kill()
	var home: float = chest.get_meta("home_y", chest.position.y)
	chest.set_meta("home_y", home)
	chest.position.y = home
	if not on or Env.args.has("capture"):
		return
	var t := chest.create_tween().set_loops()
	t.tween_property(chest, "position:y", home - 6.0, 0.55).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	t.tween_property(chest, "position:y", home, 0.55).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	chest.set_meta("bob", t)


static func _chest(p: PaintedPage, tier: int) -> void:
	if bool(p.get_meta("busy", false)):
		return
	p.set_meta("busy", true)
	var res: Api.Response = await Api.post_json("/v1/weekly/chest", {"tier": tier})
	if not is_instance_valid(p):
		return
	if res.ok:
		if res.data.get("snapshot", null) is Dictionary:
			GameState.adopt_async(res.data["snapshot"])
		if res.data.get("weekly", null) is Dictionary:
			paint_weekly(p, res.data["weekly"])
		var lines: Array = res.data.get("lines", [])
		var host: Node = p.get_meta("host") if p.has_meta("host") else null
		if not lines.is_empty() and host != null and is_instance_valid(host):
			var ceremony: GDScript = load("res://scenes/pages/ceremony.gd")
			ceremony.delivery(host, {"lines": lines, "title": ["The bronze chest", "The silver chest", "The gold chest"][clampi(tier, 0, 2)]})
	elif res.code == "inventory_full":
		GameState.armory_full.emit(res.error)
	else:
		if res.code == "already_claimed" or res.code == "quest_unfinished":
			await _load_weekly(p)
		GameState.toast(res.error)
	if is_instance_valid(p):
		p.set_meta("busy", false)
