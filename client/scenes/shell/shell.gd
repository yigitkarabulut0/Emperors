extends Control
## The chrome around every screen: ground, the left rail, the currency pills,
## and the host the eight screens are mounted in.
##
## The rail is the eight-entry painting's (art/reference/court.png): the
## portrait, eight entries on one pitch, and the event seal at its foot. Its
## geometry is `rail_geometry(h)`, for a rail `h` units tall -- the screen less
## the notch -- so it fits every phone: the entries' pitch stretches to take a
## tall screen and draws the entries down on a short one, and the seal keeps to
## the rail's foot. Each entry lit is the rail_lit_sheet's cell (nav/<id>_lit).

const TABS := {
	"family": "res://scenes/tabs/family.gd",
	"collect": "res://scenes/tabs/collect.gd",
	"inventory": "res://scenes/tabs/inventory.gd",
	"shop": "res://scenes/tabs/shop.gd",
	"army": "res://scenes/tabs/army.gd",
	"attack": "res://scenes/tabs/attack.gd",
	"kingdom": "res://scenes/tabs/kingdom.gd",
	"court": "res://scenes/tabs/court.gd",
}
const ORDER := ["family", "collect", "inventory", "shop", "army", "attack", "kingdom", "court"]

## The rail, measured on court.png. The entries start under the portrait's
## divider (y 208..216) and the seal and its plate take the foot: court.png's
## last cell ends at 1472 and the seal's plate 45 units above the bottom, which
## leaves the eight cells 157 each on the 1672 design (the painting drifts
## between 142 and 168). A taller rail widens the pitch up to RAIL_PITCH_MAX
## (collect.png's seven entries sit up to 188 apart) and puts what is left over
## above the seal; a shorter one -- a 1624 screen under a notch is 1483 --
## narrows it and draws the entries down with it, never under RAIL_PITCH_MIN.
const RAIL_TOP := 216.0
const RAIL_FOOT := 200.0
const RAIL_PITCH := 157.0
const RAIL_PITCH_MAX := 190.0
const RAIL_PITCH_MIN := 120.0
## The tallest entry's ink (SHOP: its flag to its word), and what an entry
## keeps clear of the dividers above and below it at its full size.
const RAIL_INK_MAX := 130.0
const RAIL_INK_GAP := 13.5
## The unlit entries are cut round their ink with 8 units of ground above and
## below, 130 wide; at full size their centre line is x 77, the centre of the
## painting's words (x 72.5 on court.png's 5-unit narrower rail).
const RAIL_ENTRY_X := 77.0
## The painting sets its ink two units above its cell's middle.
const RAIL_ENTRY_LIFT := 2.0
## A lit cell (182x162) has its plate's rim at x 2..166, y 3..158; drawn with
## the rim 146 wide it spans x 5..151, where the old lit plates stood, inside
## the rail's border with its arrow over it.
const LIT_RIM := Rect2(2, 3, 164, 155)
const LIT_RIM_W := 146.0
## The seal at the foot: chrome/rail_seal and its plate, court.png's own, drawn
## two units right as the entries are, their tops these many units above the
## rail's bottom (court.png: 1484 and 1586 on the 1672 painting).
const SEAL_UP := 188.0
const SEAL_PLATE_UP := 86.0
const SEAL_X := 16.0
## The plate's inside on the painting (x 22..122, y 1591..1626), for the time.
const SEAL_TIME := Rect2(24, -81, 100, 35)
const SEAL_TIME_SIZE := 26
const LOCK_DIM := Color(0.45, 0.45, 0.45)
## The seal's three states (LiveEvents.seal): dark with nothing running or
## announced; lit, as painted, while an event is only announced; ablaze while
## one runs -- the kit's burning hour (events_kit/gauge_blazing) behind it, drawn
## at 0.40 about its hourglass (the crop's 159, 180) on the wreath's middle
## (57.5, 52.5 of the seal's 116x105), so its flames stand 20 round the wreath,
## clear of the COURT cell above and under the plate below.
const SEAL_FIRE := "events_kit/gauge_blazing"
const SEAL_FIRE_SCALE := 0.40
const SEAL_FIRE_CENTRE := Vector2(159, 180)
const SEAL_MID := Vector2(57.5, 52.5)

## Court views the shell hosts over the tabs: the rail and the pills stay, the
## tab under the view keeps its lit plate, and the view's own back button
## closes it. The COURT tab opens them; opened from it, they close back to it.
const VIEWS := {"mail": "res://scenes/court/mail_view.gd", "store": "res://scenes/court/store_view.gd",
	"throne": "res://scenes/court/throne_view.gd",
	"favour": "res://scenes/court/favour_view.gd", "wardrobe": "res://scenes/court/wardrobe_view.gd",
	"chests": "res://scenes/court/chests_view.gd", "events": "res://scenes/court/events_view.gd",
	"pass": "res://scenes/court/pass_view.gd",
	"offers": "res://scenes/court/offers_view.gd"}

## Which server section gates each tab. Estates and Bank fold into Family.
const SECTION_KEY := {"family": "hero", "collect": "jobs", "inventory": "items", "shop": "shop",
	"army": "army", "attack": "fight", "kingdom": "house"}

var _host: Control
var _rail: Control
var _plate: TextureRect
var _entries: Dictionary = {}       ## id -> TextureRect (unlit icon+label)
var _locks: Dictionary = {}         ## id -> Label
var _hits: Dictionary = {}          ## id -> the entry's tap area, its whole cell
var _badges: Dictionary = {}        ## id -> the count bubble over a rail entry
var _dividers: Array = []           ## the rules between the entries, top to bottom
var _seal: TextureRect              ## the event seal at the rail's foot
var _seal_fire: TextureRect         ## the burning hour behind it while an event runs
var _seal_breath: Tween
var _seal_plate: TextureRect
var _seal_time: Label               ## the event's time left, or to its start
var _seal_hit: Button
var _geo: Dictionary = {}           ## rail_geometry() for the rail as it stands
var _mail_bubble: TextureRect       ## letters waiting, on the portrait (the profile holds the mail)
var _daily_dot: TextureRect         ## the day's reward is waiting, on the diamond pill
var _energy_timer: Label            ## "+1 in 2:31" under the energy pill
var _shield_timer: Control          ## "Shielded 7h 59m" under the gold pill
var _offline: Control               ## the banner while the realm does not answer
var _tabs: Dictionary = {}          ## id -> Control (instantiated lazily)
var _current := ""
var _view: Control = null           ## the Court view hosted over the tabs, while one is open
var _gold: Label
var _diamonds: Label
var _energy: Label
var _level: Label
var _toast: Label
var _toast_plate: NinePatchRect
var _toast_tween: Tween


var _inset_top := 0.0
var _front_since := 0               ## ticks when the game last came to the front


func _ready() -> void:
	# Pages over the game find the shell by this, to open a Court view from
	# a page (the profile's ROYAL MAIL).
	add_to_group("shell")
	var bg := ColorRect.new()
	bg.color = UI.GROUND
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	_host = Control.new()
	_host.set_anchors_preset(Control.PRESET_FULL_RECT)
	_host.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_host)

	_build_rail()
	_build_pills()
	_build_toast()
	_apply_safe_area()

	GameState.changed.connect(_on_changed)
	GameState.action_failed.connect(toast)
	# A full armory is said with a dialog, with MORE ROOM beside its OK while
	# the Quartermaster can be bought.
	GameState.armory_full.connect(func(message: String) -> void: Armory.refused(self, message))
	GameState.notice.connect(toast)
	GameState.level_up.connect(_on_level_up)
	GameState.mastery_reached.connect(_on_mastery)
	GameState.badges_changed.connect(_paint_badges)
	# Every purchase that lands -- bought here, approved by a parent later,
	# renewed while away -- has its moment, whichever screen is up.
	Billing.delivered.connect(_on_delivered)
	Session.signed_out.connect(_on_signed_out)
	# Offline is a state, not news: a banner that stays until the realm answers,
	# with a way to ask again, rather than a toast that says it once and goes.
	Api.offline.connect(func() -> void: _offline.visible = true)
	Api.online.connect(func() -> void:
		if _offline.visible:
			_offline.visible = false
			toast("Connected"))

	var tick := Timer.new()
	tick.wait_time = 0.25
	tick.timeout.connect(_tick)
	add_child(tick)
	tick.start()
	var heartbeat := Timer.new()
	heartbeat.wait_time = 30.0
	heartbeat.timeout.connect(_beat)
	add_child(heartbeat)
	heartbeat.start()

	_on_changed()
	_front_since = Time.get_ticks_msec()
	Api.track("app_open", {"cold": true})
	open(str(Env.args.get("tab", "collect")))
	# --sub <id>: one of the tab's own sub-tabs (the Attack tab's ARENA,
	# CAMPAIGN and BOUNTIES). --page is for pages OVER the game; a sub-tab is a
	# tab's body, and without this three of Wave 5's four surfaces could not be
	# captured at all.
	if Env.args.has("sub"):
		var opened: Control = _tabs.get(_current)
		if opened != null and opened.has_method("open_sub"):
			opened.call("open_sub", str(Env.args["sub"]))
	_preload_tabs.call_deferred()
	_daily_on_boot.call_deferred()
	_beat.call_deferred()
	_arrive.call_deferred()


# --- diamonds, energy, the daily reward ------------------------------------------------

var _busy_popup := false
var _daily_shown := false


## The diamond pill: the Royal Store, where diamonds are bought -- or, while
## the day's reward waits (the dot on the pill), the calendar that pays it, so
## the dot always leads to what it promises.
func _diamonds_pill() -> void:
	if bool(GameState.badges.get("daily", false)):
		_diamonds_popup()
	else:
		open_view("store")


## DAILY REWARDS: the twenty-eight-day calendar and this week's chests
## (scenes/pages/daily_page.gd). The heartbeat after a claim clears the dot.
func _diamonds_popup() -> void:
	if _busy_popup:
		return
	_busy_popup = true
	var res: Api.Response = await Api.get_json("/v1/daily")
	_busy_popup = false
	if not res.ok:
		toast(res.error)
		return
	var page: GDScript = load("res://scenes/pages/daily_page.gd")
	page.open(self, res.data, _beat)


## The "+" on energy sells the refill from the Diamond Goods, through the same
## flow the Shop's BUY uses -- and while a flask is held, offers it beside the
## refill (Goods.energy).
func _energy_popup() -> void:
	if _busy_popup:
		return
	_busy_popup = true
	var res: Api.Response = await Api.get_json("/v1/store")
	if res.ok:
		if Goods.find(res.data, "energy_refill").is_empty() and Goods.flask_options(res.data).is_empty():
			open("shop")
		else:
			await Goods.energy(self, res.data)
	else:
		toast(res.error)
	_busy_popup = false


## Once per session, when the day's reward is waiting, offer it on arrival.
func _daily_on_boot() -> void:
	# A new lord's steward brings them to the day's reward in its turn.
	if _daily_shown or Env.args.has("capture") or Guide.active():
		return
	_daily_shown = true
	var res: Api.Response = await Api.get_json("/v1/daily")
	if res.ok and bool(res.data.get("claimable", false)):
		_diamonds_popup()


## On a phone the display's safe area (notch, Dynamic Island) sits over the top
## of the canvas. Everything shifts down by that inset, in canvas units; the rail
## column is extended upward so the band above stays part of the rail.
func _apply_safe_area() -> void:
	if Env.args.has("inset"):
		# A dev capture's stand-in for the phone's safe area.
		apply_inset(float(Env.args["inset"]))
		return
	if not OS.has_feature("mobile"):
		return
	var sa := DisplayServer.get_display_safe_area()
	var win := DisplayServer.window_get_size()
	if win.x <= 0 or sa.position.y <= 0:
		return
	apply_inset(float(sa.position.y) * 941.0 / float(win.x))


## Moves the game down by `inset` canvas units, keeping its foot on the
## screen's. The tab host was moved with position.y, and a full-rect control
## moved that way keeps its height: on an iPhone with a Dynamic Island every
## tab ran 141 units past the bottom of the screen -- the Shop's and Collect's
## footers, the Army's ground and the end of every list were drawn where
## nobody could see them, and a list could not be scrolled to its last row.
func apply_inset(inset: float) -> void:
	_inset_top = inset
	_host.offset_top = _inset_top
	_host.offset_bottom = 0.0
	_rail.offset_top = _inset_top
	var band: TextureRect = _rail.get_child(0)
	band.offset_top = -_inset_top
	for c in get_children():
		if c != _host and c != _rail and c is Control and c.get_child_count() > 0 and c.get_child(0) is TextureRect:
			c.position.y = _inset_top
	# The rail is shorter by the notch: its entries take the pitch that fits.
	_layout_rail()
	print("[shell] safe-area top inset ", _inset_top)


# --- rail -------------------------------------------------------------------------

func _build_rail() -> void:
	_rail = Control.new()
	_rail.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# The rail is as tall as the screen: a phone taller than the 1672 design
	# gets more rail, not ground showing under a rail that stopped short. Its
	# foot is the screen's foot, by offsets: sized before the shell had a size,
	# it ran 1672 units past the bottom, where nothing anchored to its foot was
	# ever seen.
	_rail.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	_rail.offset_left = 0.0
	_rail.offset_right = 160.0
	_rail.offset_top = 0.0
	_rail.offset_bottom = 0.0
	add_child(_rail)

	# The band runs to the rail's foot: the eight-entry paintings (court.png,
	# arena.png) draw the rail down to the bottom, the event seal on it.
	var band := TextureRect.new()
	band.texture = Art.tex("chrome/rail_band")
	band.texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
	band.stretch_mode = TextureRect.STRETCH_TILE
	UI.place(band, Rect2(0, 0, 160, 1672))
	band.anchor_bottom = 1.0
	band.offset_bottom = 0
	band.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rail.add_child(band)

	# The lit entry: nav/<id>_lit, placed by _layout_rail.
	_plate = TextureRect.new()
	_plate.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_plate.stretch_mode = TextureRect.STRETCH_SCALE
	_plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_plate.visible = false
	_rail.add_child(_plate)

	# The portrait's divider, then one between each two entries.
	for i in ORDER.size():
		var rule := UI.image("chrome/rail_divider", Rect2(20, 208, 110, 8))
		_rail.add_child(rule)
		_dividers.append(rule)

	_rail.add_child(UI.image("chrome/avatar", Rect2(14, 6, 132, 190)))
	# The portrait opens the lord's own page: the face others see, the name,
	# the rankings, signing out and deleting the account.
	var me := UI.hotspot(Rect2(0, 0, 156, 204))
	me.pressed.connect(func() -> void:
		var page: GDScript = load("res://scenes/pages/profile_page.gd")
		page.open(self))
	_rail.add_child(me)
	_level = UI.label("", 30, UI.INK, "body", 700, HORIZONTAL_ALIGNMENT_CENTER)
	# Centred on the plaque painted into chrome/avatar, measured off the source
	# image rather than guessed at from the crop's own middle -- the plaque is
	# not centred in its 132x190 tile, so "half the avatar" is six units right
	# of where the number belongs.
	#
	# Scanning avatar.png: the plaque's gold rim runs down to x 4..118 counting
	# the laurel, but the rim rows on the plaque's own centre column are y 134
	# and y 171, and the dark red interior between them centres on (61, 153).
	# The avatar is placed at (14, 6), so that centre lands at (75, 159) on the
	# rail. A 62x38 label centred there starts at (44, 140).
	UI.place(_level, Rect2(44, 140, 62, 38))
	_rail.add_child(_level)
	# Letters waiting, in the same count bubble the rail's entries wear, on the
	# portrait's upper corner: the portrait opens the profile, and the profile
	# holds the Royal Mail.
	_mail_bubble = UI.image("icons/count_bubble", Rect2(104, 4, 42, 42))
	var mail_n := UI.label("", 24, Color("#FFF4EC"), "title", 800, HORIZONTAL_ALIGNMENT_CENTER)
	UI.place(mail_n, Rect2(0, 0, 42, 40))
	_mail_bubble.add_child(mail_n)
	_mail_bubble.set_meta("count", mail_n)
	_mail_bubble.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_mail_bubble.visible = false
	_rail.add_child(_mail_bubble)

	for id in ORDER:
		var img := UI.image("nav/" + id, Rect2(0, 0, 130, 130))
		_rail.add_child(img)
		_entries[id] = img
		# A locked entry is dimmed and says the level that opens it, over its
		# own mark: eight entries leave no room under the words.
		var lock := UI.label("", 24, UI.GOLD, "title", 700, HORIZONTAL_ALIGNMENT_CENTER)
		UI.place(lock, Rect2(12, 0, 130, 33))
		lock.visible = false
		_rail.add_child(lock)
		_locks[id] = lock
		var hit := UI.hotspot(Rect2(0, 0, 156, RAIL_PITCH))
		hit.pressed.connect(open.bind(id))
		GuideTargets.register("rail." + id, hit)
		_rail.add_child(hit)
		_hits[id] = hit
		# What is waiting on this tab, in the painting's own count bubble.
		var bubble := UI.image("icons/count_bubble", Rect2(100, 0, 42, 42))
		var n := UI.label("", 24, Color("#FFF4EC"), "title", 800, HORIZONTAL_ALIGNMENT_CENTER)
		UI.place(n, Rect2(0, 0, 42, 40))
		bubble.add_child(n)
		bubble.set_meta("count", n)
		bubble.visible = false
		_rail.add_child(bubble)
		_badges[id] = bubble

	# The event seal: the running event's time left, or the next one's time to
	# start; dimmed, with its plate empty, while there is neither. A tap opens
	# the COURT's list of events.
	var fire_size := (Art.tex(SEAL_FIRE).get_size() * SEAL_FIRE_SCALE).round()
	_seal_fire = UI.image(SEAL_FIRE, Rect2(Vector2.ZERO, fire_size))
	_seal_fire.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_seal_fire.pivot_offset = SEAL_FIRE_CENTRE * SEAL_FIRE_SCALE
	_seal_fire.visible = false
	_rail.add_child(_seal_fire)
	_seal = UI.image("chrome/rail_seal", Rect2(SEAL_X, 0, 116, 105))
	_rail.add_child(_seal)
	_seal_plate = UI.image("chrome/rail_seal_plate", Rect2(SEAL_X, 0, 116, 47))
	_rail.add_child(_seal_plate)
	_seal_time = UI.label("", SEAL_TIME_SIZE, UI.INK, "body", 700, HORIZONTAL_ALIGNMENT_CENTER)
	UI.place(_seal_time, SEAL_TIME)
	_rail.add_child(_seal_time)
	_seal_hit = UI.hotspot(Rect2(8, 0, 144, 176))
	_seal_hit.pressed.connect(open_events)
	_rail.add_child(_seal_hit)

	_rail.resized.connect(_layout_rail)
	_layout_rail()


## Where everything on a rail `h` units tall goes: `pitch` between entries,
## `centres` (id -> the middle of its cell), `dividers` (the rules' middles,
## the portrait's first), how far the unlit entries (`entry_scale`) and the lit
## cell (`lit_scale`) are drawn down, and the seal's and its plate's tops.
static func rail_geometry(h: float) -> Dictionary:
	var n := ORDER.size()
	var pitch := clampf((h - RAIL_TOP - RAIL_FOOT) / float(n), RAIL_PITCH_MIN, RAIL_PITCH_MAX)
	var centres := {}
	var dividers: Array = [RAIL_TOP - 4.0]
	for i in n:
		centres[ORDER[i]] = RAIL_TOP + pitch * (float(i) + 0.5)
		if i > 0:
			dividers.append(RAIL_TOP + pitch * float(i))
	return {
		"pitch": pitch,
		"centres": centres,
		"dividers": dividers,
		"cells_end": RAIL_TOP + pitch * float(n),
		# The tallest ink keeps RAIL_INK_GAP clear of both its dividers.
		"entry_scale": minf(1.0, (pitch - 2.0 * RAIL_INK_GAP) / RAIL_INK_MAX),
		# The lit rim is LIT_RIM_W wide, and never taller than its cell less
		# the same clearance.
		"lit_scale": minf(LIT_RIM_W / LIT_RIM.size.x, (pitch - RAIL_INK_GAP) / LIT_RIM.size.y),
		"seal_y": h - SEAL_UP,
		"plate_y": h - SEAL_PLATE_UP,
	}


func _layout_rail() -> void:
	if _rail == null or _dividers.is_empty():
		return
	var h := _rail.size.y if _rail.size.y > 0.0 else 1672.0
	_geo = rail_geometry(h)
	var pitch: float = _geo["pitch"]
	var centres: Dictionary = _geo["centres"]
	var dividers: Array = _geo["dividers"]
	for i in _dividers.size():
		(_dividers[i] as Control).position = Vector2(20, roundf(float(dividers[i]) - 4.0))
	var e: float = _geo["entry_scale"]
	for id in ORDER:
		var c: float = centres[id]
		var img: TextureRect = _entries[id]
		var sz: Vector2 = (img.texture.get_size() if img.texture != null else Vector2(130, 130)) * e
		img.size = sz.round()
		img.position = Vector2(roundf(RAIL_ENTRY_X - sz.x / 2.0), roundf(c - RAIL_ENTRY_LIFT - sz.y / 2.0))
		# The ink is the crop less its 8 units of ground above and below.
		var ink_top := c - RAIL_ENTRY_LIFT - (sz.y / 2.0 - 8.0 * e)
		(_locks[id] as Control).position = Vector2(12, roundf(c - RAIL_ENTRY_LIFT - 16.0 - 12.0 * e))
		(_hits[id] as Control).position = Vector2(0, roundf(c - pitch / 2.0))
		(_hits[id] as Control).size = Vector2(156, roundf(pitch))
		# On the mark's shoulder, never over the divider above.
		(_badges[id] as Control).position = Vector2(100, roundf(maxf(c - pitch / 2.0 + 4.0, ink_top - 14.0)))
	_seal.position.y = roundf(float(_geo["seal_y"]))
	_seal_fire.position = (Vector2(SEAL_X, _seal.position.y) + SEAL_MID - SEAL_FIRE_CENTRE * SEAL_FIRE_SCALE).round()
	_seal_plate.position.y = roundf(float(_geo["plate_y"]))
	_seal_time.position.y = roundf(float(_geo["plate_y"]) + SEAL_PLATE_UP + SEAL_TIME.position.y)
	_seal_hit.position.y = _seal.position.y - 6.0
	_place_plate()


func _set_active(id: String) -> void:
	for k in _entries:
		_entries[k].visible = k != id
	_plate.texture = Art.tex("nav/%s_lit" % id)
	_plate.set_meta("id", id)
	_plate.visible = true
	_place_plate()


## The lit cell, its rim centred on its entry's cell.
func _place_plate() -> void:
	var id := str(_plate.get_meta("id", ""))
	if id == "" or _geo.is_empty() or _plate.texture == null:
		return
	var s: float = _geo["lit_scale"]
	var rim_mid := LIT_RIM.position + LIT_RIM.size / 2.0
	var c: float = (_geo["centres"] as Dictionary)[id]
	_plate.size = (_plate.texture.get_size() * s).round()
	_plate.position = Vector2(roundf(RAIL_ENTRY_X + 1.0 - rim_mid.x * s), roundf(c - rim_mid.y * s))


## The seal at the rail's foot (LiveEvents.seal): ablaze while an event runs --
## the hour's, an operator's, a festival -- its time left on the plate, the
## hour's first; lit while one is only announced, "in 5h 20m" to the soonest
## start; dimmed, its plate empty, with neither.
func _paint_seal() -> void:
	var seal := LiveEvents.seal(GameState.live(), GameState.live_age_s())
	var state := str(seal["state"])
	var text := str(seal["text"])
	_seal.modulate = LOCK_DIM if state == "dark" else Color.WHITE
	_set_seal_fire(state == "blazing")
	if _seal_time.text != text:
		_seal_time.text = text
		UI.fit_line(_seal_time, SEAL_TIME_SIZE, 18)


## The burning hour behind the seal, breathing slowly about its middle while it
## shows (never in a capture, which must hold still).
func _set_seal_fire(on: bool) -> void:
	if _seal_fire == null or _seal_fire.visible == on:
		return
	_seal_fire.visible = on
	if _seal_breath != null:
		_seal_breath.kill()
		_seal_breath = null
	_seal_fire.scale = Vector2.ONE
	if on and not Env.args.has("capture"):
		_seal_breath = _seal_fire.create_tween().set_loops()
		_seal_breath.tween_property(_seal_fire, "scale", Vector2(1.04, 1.04), 1.6).set_trans(Tween.TRANS_SINE)
		_seal_breath.tween_property(_seal_fire, "scale", Vector2(0.97, 0.97), 1.6).set_trans(Tween.TRANS_SINE)


## The COURT tab with its list of events open: the rail's seal.
func open_events() -> Control:
	open("court")
	var court: Control = _tabs.get("court")
	if _current == "court" and court != null and court.has_method("open_events"):
		return court.call("open_events")
	return null


## The tab the player is on (a Court view opened from it lies over it).
func current_tab() -> String:
	return _current


# --- pills --------------------------------------------------------------------------

func _build_pills() -> void:
	var top := Control.new()
	top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(top)
	top.add_child(UI.image("chrome/pill_gold", Rect2(180, 21, 221, 58)))
	top.add_child(UI.image("chrome/pill_diamond", Rect2(439, 21, 209, 58)))
	top.add_child(UI.image("chrome/pill_energy", Rect2(666, 21, 225, 58)))
	_gold = UI.label("", 29, UI.INK, "body", 700, HORIZONTAL_ALIGNMENT_CENTER)
	UI.place(_gold, Rect2(236, 26, 112, 46))
	_diamonds = UI.label("", 29, UI.INK, "body", 700, HORIZONTAL_ALIGNMENT_CENTER)
	UI.place(_diamonds, Rect2(500, 26, 94, 46))
	_energy = UI.label("", 29, UI.INK, "body", 700, HORIZONTAL_ALIGNMENT_CENTER)
	UI.place(_energy, Rect2(732, 26, 110, 46))
	for l in [_gold, _diamonds, _energy]:
		top.add_child(l)
	# The whole pill is the button, a thumb tall. Only the painted "+" was, and
	# at 38x52 units that is 18x24 pt -- under half of what a thumb needs.
	var plus_gold := UI.hotspot(Rect2(180, 0, 225, 100))
	plus_gold.pressed.connect(open.bind("collect"))
	var plus_gems := UI.hotspot(Rect2(430, 0, 222, 100))
	plus_gems.pressed.connect(_diamonds_pill)
	GuideTargets.register("pill.diamonds", plus_gems)
	var plus_energy := UI.hotspot(Rect2(660, 0, 236, 100))
	plus_energy.pressed.connect(_energy_popup)
	for h in [plus_gold, plus_gems, plus_energy]:
		top.add_child(h)
	_daily_dot = UI.image("icons/count_bubble", Rect2(622, 12, 24, 24))
	_daily_dot.visible = false
	top.add_child(_daily_dot)

	# What the pills cannot say in their own space: when the next energy comes,
	# and how long the city is shielded. On the band under the pills, which
	# every header leaves clear above its title.
	_energy_timer = UI.label("", 19, UI.INK, "body", 700, HORIZONTAL_ALIGNMENT_RIGHT)
	UI.place(_energy_timer, Rect2(666, 80, 222, 26))
	top.add_child(_energy_timer)
	_shield_timer = Control.new()
	_shield_timer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UI.place(_shield_timer, Rect2(184, 80, 260, 26))
	_shield_timer.add_child(UI.image("icons/shield_small", Rect2(0, 1, 20, 24)))
	var sl := UI.label("", 19, UI.INK, "body", 700)
	UI.place(sl, Rect2(26, 0, 230, 26))
	_shield_timer.add_child(sl)
	_shield_timer.set_meta("label", sl)
	_shield_timer.visible = false
	top.add_child(_shield_timer)

	var banner := NinePatchRect.new()
	banner.texture = Art.tex(Dialog.DANGER_PLATE)
	for m in ["left", "top", "right", "bottom"]:
		banner.set("patch_margin_" + m, Dialog.PLATE_EDGE)
	UI.place(banner, Rect2(250, 84, 560, 56))
	banner.visible = false
	var bl := UI.label("NO CONNECTION  ·  TAP TO RETRY", 21, Color("#F3FBF3"), "title", 700, HORIZONTAL_ALIGNMENT_CENTER)
	UI.place(bl, Rect2(0, 0, 560, 56))
	banner.add_child(bl)
	var retry := UI.hotspot(Rect2(-20, -20, 600, 96))
	retry.pressed.connect(func() -> void: GameState.refresh())
	banner.add_child(retry)
	top.add_child(banner)
	_offline = banner


func _tick() -> void:
	GameState.tick_projection()
	_paint_pills()
	_paint_seal()
	_hourly_tick()


## The hour's event, as it begins while the lord is in the game: the hour they
## came into the game is remembered with their first snapshot (and again each
## time the game comes back to the front), and an event of a later hour comes
## to them once, at a calm moment (scenes/court/hourly_popup.gd).
func _hourly_tick() -> void:
	if not GameState.has_state() or Env.args.has("capture"):
		return
	if not has_meta("hourly_arrived"):
		set_meta("hourly_arrived", LiveEvents.hour_index(GameState.live(), GameState.live_age_s(),
			int(Time.get_unix_time_from_system())))
		return
	load("res://scenes/court/hourly_popup.gd").maybe_show(self)


func _paint_pills() -> void:
	if not GameState.has_state():
		return
	_gold.text = UI.short_number(GameState.display_gold())
	_diamonds.text = UI.grouped(int(GameState.player().get("diamonds", 0)))
	_energy.text = "%d/%d" % [GameState.display_energy(), GameState.max_energy()]
	var next := GameState.display_seconds_to_next()
	_energy_timer.visible = next > 0 and not _offline.visible
	_energy_timer.text = "+1 in %d:%02d" % [next / 60, next % 60]
	var shield := GameState.display_shield_seconds()
	_shield_timer.visible = shield > 0 and not _offline.visible
	if shield > 0:
		(_shield_timer.get_meta("label") as Label).text = "Shielded  " + UI.short_duration(shield)


# --- tabs -------------------------------------------------------------------------

## The heartbeat, which answers with the rail's badges. It also marks the
## game as seen, which is where "while you were away" is counted from.
func _beat() -> void:
	var res: Api.Response = await Api.post_json("/v1/presence", {})
	if res.ok and res.data.get("badges", null) is Dictionary:
		GameState.set_badges(res.data["badges"])
	if res.ok:
		Prefs.set_value("last_seen", int(Time.get_unix_time_from_system()))


## Arriving: what happened while the game was closed, and for a new lord the
## steward's guide through the first ten minutes.
func _arrive() -> void:
	if Env.args.has("page"):
		_dev_page(str(Env.args["page"]))
		return
	if Env.args.has("capture"):
		return
	var since := int(Prefs.get_value("last_seen", 0))
	Prefs.set_value("last_seen", int(Time.get_unix_time_from_system()))
	# A new lord's first minutes are the steward's (scripts/ui/guide.gd); the
	# server holds the step, so a relaunch comes back to it.
	if Guide.active():
		Guide.start(self)
		return
	var away: GDScript = load("res://scenes/pages/away_page.gd")
	away.check(self, since, _revenge)


## Away's TAKE REVENGE: the Attack tab on its REVENGE view, whichever view it
## was last left on. It opened the tab as it stood, so a player who had last
## looked at TARGETS was taken to a list of strangers instead of the raiders
## the report was about.
func _revenge() -> void:
	open("attack")
	var tab: Control = _tabs.get("attack")
	if _current == "attack" and tab != null and tab.has_method("_set_view"):
		tab.call("_set_view", "revenge")


## Dev: --page <name> opens a page on arrival, so a capture can show it with
## the live server's data.
func _dev_page(name: String) -> void:
	var pg := "res://scenes/pages/%s.gd"
	match name:
		"profile": load(pg % "profile_page").open(self)
		"ranks": load(pg % "leaderboard_page").open(self)
		# The week's and the season's boards, as their period chips open them.
		"ranks_week": load(pg % "leaderboard_page").open(self, {"board": "week_raids"})
		"ranks_season": load(pg % "leaderboard_page").open(self, {"board": "season_renown"})
		"road": load(pg % "road_page").open(self)
		"deeds": load(pg % "deeds_page").open(self)
		# The Deeds with a deed's page open over it: the first with a tier
		# waiting, else the first.
		"deed": load(pg % "deeds_page").open(self, {"detail": "first"})
		"stats": load(pg % "stats_page").open(self)
		"guide": Guide.start(self)
		"guide_deep":
			# The step's control where it lives -- the day's page, the cart's
			# view, its tab -- with the guide over it, for a capture.
			var g := GameState.guide()
			match str(g.get("target", "")):
				"daily.claim":
					await _diamonds_popup()
				"court.chests":
					open("court")
					open_view("chests")
				_:
					open(str(g.get("tab", "collect")))
			Guide.start(self)
		"daily": _diamonds_popup()
		"mail": open_view("mail")
		"store": open_view("store")
		"court": open("court")
		# Collect on its week's page, and the whole week over it.
		"week", "weekly":
			open("collect")
			var tab: Control = _tabs.get("collect")
			if tab != null and tab.has_method("turn_page"):
				tab.call("turn_page", 1, false)
				if name == "weekly":
					tab.call("open_week")
		"chests":
			# The Tax Cart over the COURT, as its card opens it.
			open("court")
			open_view("chests")
		"cart_odds":
			open("court")
			var cv: Control = open_view("chests")
			var cart: Api.Response = await Api.get_json("/v1/cart")
			if cv != null and cart.ok:
				cv.call("paint", cart.data)
				load(pg % "cart_odds_page").open(self, cart.data)
		"events": open_events()
		"festival":
			# The Events page with the festival's own page over it.
			var ev: Control = open_events()
			if ev != null and ev.has_method("open_festival"):
				await ev.call("open_festival")
		"hours":
			# The published odds of every hour, as the ROYAL HOURS strip opens them.
			var evh: Control = open_events()
			if evh != null and evh.has_method("open_hours"):
				await evh.call("open_hours")
		"pass":
			# The Charter over the COURT, as its card opens it.
			open("court")
			open_view("pass")
		"hourly":
			# The hour's event as it begins, over the Collect tab.
			open("collect")
			load("res://scenes/court/hourly_popup.gd").maybe_show(self, true)
		"throne":
			# THE THRONE over the Kingdom tab, as its banner opens it.
			open("kingdom")
			open_view("throne")
		"arena", "bounties", "campaign":
			# The Attack tab on one of its sub-tabs (the same as --sub).
			open("attack")
			var at: Control = _tabs.get("attack")
			if at != null and at.has_method("open_sub"):
				at.call("open_sub", name)
		"bounty":
			# The board with WHOSE HEAD? open over it, for a capture.
			open("attack")
			var bb: Control = _tabs.get("attack")
			if bb != null and bb.has_method("open_sub"):
				bb.call("open_sub", "bounties")
				await get_tree().process_frame
				await get_tree().process_frame
				var body: Control = bb.call("sub")
				if body != null and body.has_method("open_target_picker"):
					await body.call("open_target_picker")
		"talents":
			# The talent tree over the Family tab, as its own card opens it.
			open("family")
			var fam: Control = _tabs.get("family")
			var tree: Api.Response = await Api.get_json("/v1/talents")
			if fam != null and tree.ok:
				load(pg % "talents_page").open(self, fam, tree.data)
		"hunt":
			# The roads for the first soldier in the yard, as HUNT opens them.
			open("army")
			var mine: Api.Response = await Api.get_json("/v1/army")
			var who: Dictionary = {}
			for sl in (mine.data.get("slots", []) if mine.ok else []):
				var sd: Variant = sl.get("soldier", null)
				if sd is Dictionary and not (sd as Dictionary).has("away"):
					who = sd
					break
			if not who.is_empty():
				var roads: Api.Response = await Api.get_json("/v1/hunt?soldier=%s" % str(who.get("id", "")))
				if roads.ok:
					load(pg % "hunt_page").open(self, _tabs.get("army"), {
						"id": str(who.get("id", "")), "name": str(who.get("name", "")),
						"tier": str(who.get("tier", "")), "type": str(who.get("type", "peasant")),
					}, roads.data)
		"forge":
			# The anvil for the first piece the bag can forge, as the Armory's
			# FORGE opens it.
			open("inventory")
			var bag: Api.Response = await Api.get_json("/v1/inventory")
			var rules: Dictionary = bag.data.get("forge", {}) if bag.ok else {}
			for it in (bag.data.get("items", []) if bag.ok else []):
				var of: Variant = (it as Dictionary).get("forge", null)
				if of is Dictionary and ((of as Dictionary).get("items", []) as Array).size() >= int(rules.get("pieces", 3)):
					load(pg % "forge_page").open(self, _tabs.get("inventory"), it, of, rules,
						bag.data.get("items", []))
					break
		"favour": open_view("favour")
		"offers": open_view("offers")
		"wardrobe": open_view("wardrobe")
		"offer": load("res://scenes/court/offer_popup.gd").maybe_show(self, true)
		"redeem": load(pg % "redeem_page").open(self)
		"invite": load(pg % "invite_page").open(self)
		"letter":
			# The inbox with its first letter open over it.
			var box: Api.Response = await Api.get_json("/v1/mail")
			var view: Control = open_view("mail", box.data if box.ok else {})
			var letters: Array = box.data.get("mail", []) if box.ok else []
			if view != null and not letters.is_empty():
				view.read_letter(letters[0])
		"wall":
			var inv: Api.Response = await Api.get_json("/v1/inventory")
			load(pg % "collection_page").open(self, inv.data if inv.ok else {})
		"history":
			var h: Api.Response = await Api.get_json("/v1/attack/history")
			load(pg % "history_page").open(self, h.data.get("entries", []) if h.ok else [], func(_e): pass)
		"away":
			load(pg % "away_page").check(self, int(Time.get_unix_time_from_system()) - 7 * 86400, _revenge)
		"treasury":
			var est: Api.Response = await Api.get_json("/v1/estates")
			load(pg % "treasury_page").open(self, est.data.get("treasury", {}) if est.ok else {})
		"rules":
			var targets: Api.Response = await Api.get_json("/v1/attack/targets")
			load(pg % "rules_page").open(self, targets.data.get("rules", {}) if targets.ok else {})
		"odds":
			var odds: Api.Response = await Api.get_json("/v1/army/odds")
			load(pg % "odds_page").open(self, odds.data if odds.ok else {}, ["peasant", "mercenary", "gladiator"],
				{"peasant": "VILLAGER", "mercenary": "MERCENARY", "gladiator": "GLADIATOR"})
		"gear":
			# The hero's weapons, as the Family's weapon tile offers them.
			var bag: Api.Response = await Api.get_json("/v1/inventory")
			var pieces: Array = []
			var worn := {}
			for it in (bag.data.get("items", []) if bag.ok else []):
				if str(it.get("slot", "")) != "weapon":
					continue
				if str(it.get("equipped_on", "")) == "hero":
					worn = it
				else:
					pieces.append(it)
			load(pg % "item_picker").pick(self, "YOUR WEAPON", pieces, worn)
		"friends":
			# The roll of friends, as the profile's first row opens it.
			load(pg % "friends_page").open(self)
		"settings":
			load(pg % "settings_page").open(self)
		"rival":
			# A lord's page, as the hall, the rankings or a target card opens
			# it: the first lord the raid list offers.
			var ts: Api.Response = await Api.get_json("/v1/attack/targets")
			var them: Array = ts.data.get("targets", []) if ts.ok else []
			var whom := str((them[0] as Dictionary).get("player_id", "")) if not them.is_empty() else ""
			var asked := str(Env.args.get("lord", ""))
			if asked != "":
				whom = asked
			load(pg % "rival_page").open(self, {"player_id": whom})
		"hall_rules":
			# THE RULES OF THE HALL, as the hall opens it before a lord speaks.
			# A lord who has already agreed gets no rules with the room, so the
			# page reads them from the realm's own copy.
			var room: Api.Response = await Api.get_json("/v1/chat/rules")
			var rules: Variant = room.data.get("rules", null) if room.ok else null
			load(pg % "rules_of_the_hall").open(self, {"rules": rules if rules is Dictionary else {}})
		"reroll":
			# The first soldier in the army, with its type's odds.
			var army: Api.Response = await Api.get_json("/v1/army")
			var odds: Api.Response = await Api.get_json("/v1/army/odds")
			for slot in (army.data.get("slots", []) if army.ok else []):
				var s: Variant = slot.get("soldier", null)
				if not (s is Dictionary):
					continue
				var type := str(s.get("type", "peasant"))
				var table: Array = []
				for t in (odds.data.get("types", []) if odds.ok else []):
					if str(t.get("type_id", "")) == type:
						table = t.get("odds", [])
				load("res://scenes/army/reroll_panel.gd").open(self, {"soldier": s, "odds": table,
					"name": {"peasant": "VILLAGER"}.get(type, type.to_upper()), "type": type})
				break


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_APPLICATION_PAUSED, NOTIFICATION_APPLICATION_FOCUS_OUT:
			if GameState.has_state():
				Prefs.set_value("last_seen", int(Time.get_unix_time_from_system()))
			# Only a pause is the phone putting the game away; focus leaves a
			# desktop window every time another is clicked.
			if what == NOTIFICATION_APPLICATION_PAUSED and _front_since > 0:
				Api.track("app_close", {"seconds": (Time.get_ticks_msec() - _front_since) / 1000})
				_front_since = 0
				Api.flush_events_now()
		NOTIFICATION_APPLICATION_RESUMED:
			_front_since = Time.get_ticks_msec()
			# An hour's event already running when the lord comes back is not
			# one that began while they were here.
			remove_meta("hourly_arrived")
			Api.track("app_open", {"cold": false})
			# Back from the background: the purse and the pool moved while the
			# phone slept, and raids may have landed.
			if GameState.has_state() and is_inside_tree():
				var since := int(Prefs.get_value("last_seen", 0))
				await GameState.refresh()
				_beat()
				if since > 0 and int(Time.get_unix_time_from_system()) - since > 60:
					var away: GDScript = load("res://scenes/pages/away_page.gd")
					away.check(self, since, _revenge)


func _paint_badges() -> void:
	var b := GameState.badges
	for id in _badges:
		var n: int = rail_count(b, id)
		var bubble: TextureRect = _badges[id]
		bubble.visible = n > 0 and not _is_locked(id)
		(bubble.get_meta("count") as Label).text = str(n) if n < 10 else "9+"
	var portrait := portrait_count(b)
	_mail_bubble.visible = portrait > 0
	(_mail_bubble.get_meta("count") as Label).text = str(portrait) if portrait < 10 else "9+"
	_daily_dot.visible = bool(b.get("daily", false))
	# An offer the lord has not been shown waits for a calm moment (the popup
	# decides when, and shows one a session).
	if int(b.get("offers_unseen", 0)) > 0 and not Guide.active():
		load("res://scenes/court/offer_popup.gd").maybe_show(self)


## WHAT WAITS ON EACH RAIL ENTRY.
##
## The server counts these (service/badges.go) and this is the only thing that
## turns one into a bubble -- so a counter the rail does not name is a thing the
## lord is never told. Six were: the hall's unread lines, a friend's request, a
## draught waiting to be taken, a call for aid, a scout home with a haul, and a
## chapter's chest. "A hall nobody knows has spoken is a hall nobody opens
## twice", and the game has no push notifications, so this rail IS the telling.
static func rail_count(b: Dictionary, id: String) -> int:
	match id:
		# Tasks to claim and the week's chests to open.
		"collect": return int(b.get("quests", 0)) + int(b.get("weekly", 0))
		# Scores to settle, and a chapter's chest whose stars are earned.
		"attack": return int(b.get("revenge", 0)) + int(b.get("campaign", 0))
		# A soldier at the gate with a haul nobody has let in.
		"army": return int(b.get("hunt", 0))
		# Lords asking to join, the hall's unread lines, a call for aid, and the
		# one that waits for nobody else: an emperor who has not spent their
		# reign's decree.
		"kingdom": return int(b.get("requests", 0)) + int(b.get("chat", 0)) + int(b.get("aid_calls", 0)) \
			+ (1 if bool(b.get("decree", false)) else 0)
		"court": return court_count(b)
		"family": return family_count(b)
	return 0


## What waits behind the lord's own portrait: the Royal Mail, and the two things
## the profile's FRIENDS page holds -- a request to answer and a draught to take.
static func portrait_count(b: Dictionary) -> int:
	return int(b.get("mail", 0)) + int(b.get("friends", 0)) + int(b.get("gifts", 0))


## What waits behind the Family: the Victory Road's milestones and the Deeds'
## tiers reached and not claimed -- the DEEDS and ROAD cards' own counts.
static func family_count(b: Dictionary) -> int:
	return int(b.get("road", 0)) + int(b.get("achievements", 0))


## What the COURT holds for the lord: letters waiting, offers not yet seen,
## the Store's free thing (the Stipend's share, the Favour's gift or the day's
## free deal), which counts one, the Tax Carts waiting with the writs held, the
## Royal Courier's gift (one), the running festival's tasks and milestones to
## claim, and the Royal Charter's tiers to claim.
static func court_count(b: Dictionary) -> int:
	return int(b.get("mail", 0)) + int(b.get("offers_unseen", 0)) + (1 if bool(b.get("store_free", false)) else 0) \
		+ int(b.get("cart", 0)) + (1 if bool(b.get("hourly", false)) else 0) + int(b.get("events", 0)) \
		+ int(b.get("season", 0))


func open(id: String) -> void:
	if not TABS.has(id):
		id = "collect"
	if _is_locked(id):
		toast("Unlocks at level %d" % _unlock_level(id))
		return
	# A rail entry leaves a Court view for its tab, the one under it included.
	if _view != null:
		close_view()
	if _current == id:
		return
	if _current != "" and _tabs.has(_current):
		var old: Control = _tabs[_current]
		old.visible = false
		old.process_mode = Node.PROCESS_MODE_DISABLED
		# Whatever was done on the tab being left may have cleared a badge.
		_beat.call_deferred()
	var cur: Control = _ensure_tab(id)
	cur.visible = true
	cur.process_mode = Node.PROCESS_MODE_INHERIT
	_current = id
	Api.track("screen", {"name": id})
	_set_active(id)
	if cur.has_method("refresh"):
		cur.refresh()


## A raid asked for from a lord's page: the Attack tab opened on that lord, in
## the tab's own flow. The page is closed by then, so this is the one road from
## a face to a fight.
func raid_lord(player_id: String, lord_name := "") -> void:
	if _is_locked("attack"):
		toast("Unlocks at level %d" % _unlock_level("attack"))
		return
	open("attack")
	var tab: Control = _ensure_tab("attack")
	if tab.has_method("raid_lord"):
		await tab.call("raid_lord", player_id, lord_name)


## Opens a Court view over the tab host. `data`, when given, is painted without
## asking the server (the dev page `letter`, which has already asked).
func open_view(id: String, data: Dictionary = {}) -> Control:
	if not VIEWS.has(id):
		return null
	var script: GDScript = load(VIEWS[id])
	if script.get_script_constant_map().has("PAGE"):
		# A Court view painted as a whole page (THE CROWN'S FAVOUR, SPLENDOUR)
		# opens on the painted pages' host over whatever is open -- the tab, a
		# Court view, the profile -- and closes back to exactly that.
		return script.call("open", self)
	if _view != null:
		close_view()
	var v: Control = script.new()
	v.set_anchors_preset(Control.PRESET_FULL_RECT)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_host.add_child(v)
	_view = v
	if _current != "" and _tabs.has(_current):
		var under: Control = _tabs[_current]
		under.visible = false
		under.process_mode = Node.PROCESS_MODE_DISABLED
	if v.has_signal("back_requested"):
		v.back_requested.connect(close_view)
	Api.track("screen", {"name": "court:" + id})
	if not data.is_empty() and v.has_method("paint"):
		v.paint(data)
	elif v.has_method("refresh"):
		v.refresh()
	return v


## Closes the Court view and shows the tab it was opened over.
func close_view() -> void:
	if _view == null:
		return
	_view.queue_free()
	_view = null
	if _current != "" and _tabs.has(_current):
		var under: Control = _tabs[_current]
		under.visible = true
		under.process_mode = Node.PROCESS_MODE_INHERIT
		if under.has_method("refresh"):
			under.refresh()
	# Whatever was done in the view (a letter claimed) may have cleared a badge.
	_beat.call_deferred()


## Builds a tab's screen, hidden and paused, without opening it.
func _ensure_tab(id: String) -> Control:
	if not _tabs.has(id):
		var script: GDScript = load(TABS[id])
		var tab: Control = script.new()
		tab.set_anchors_preset(Control.PRESET_FULL_RECT)
		tab.mouse_filter = Control.MOUSE_FILTER_IGNORE
		tab.visible = false
		tab.process_mode = Node.PROCESS_MODE_DISABLED
		_host.add_child(tab)
		_tabs[id] = tab
	return _tabs[id]


## Every screen is built and its data fetched right after arrival, one per
## frame behind the one that is showing, so the first tap on any tab lands on
## a finished screen rather than on frames filling in while the server answers.
## Locked tabs are built too -- unlocking later is a level-up, not a load.
func _preload_tabs() -> void:
	for id in ORDER:
		if id == _current:
			continue
		await get_tree().process_frame
		if not is_inside_tree():
			return
		var tab := _ensure_tab(id)
		if tab.has_method("refresh"):
			tab.refresh()


func _unlock_level(id: String) -> int:
	return GameState.unlock_level(SECTION_KEY.get(id, id))


func _is_locked(id: String) -> bool:
	# The steward's bandit step opens the Attack tab for Karel's card alone.
	if id == "attack" and Guide.bandit_step():
		return false
	return not GameState.is_unlocked(SECTION_KEY.get(id, id))


func _on_changed() -> void:
	_paint_pills()
	_level.text = str(int(GameState.player().get("level", 1)))
	for id in ORDER:
		var locked := _is_locked(id)
		_entries[id].modulate = Color(0.45, 0.45, 0.45) if locked else Color.WHITE
		_locks[id].visible = locked
		_locks[id].text = "LV %d" % _unlock_level(id)
	# The Attack tab opened below its level for Karel's card goes back to
	# Collect once his fight is over.
	if _current == "attack" and _is_locked("attack") and _view == null:
		open("collect")
		return
	if _current != "" and _tabs.has(_current) and _tabs[_current].has_method("refresh"):
		_tabs[_current].refresh()


# --- toast --------------------------------------------------------------------------

## The toast wears the dialogs' plate: a flat navy box with a drawn border was
## the one thing on the game screens not cut from a painting. It sizes itself
## to what it says, sits over the page (clear of the rail), and fades.
const TOAST_MAX_W := 720.0
const TOAST_PAD := Vector2(34, 18)


func _build_toast() -> void:
	var plate := NinePatchRect.new()
	plate.texture = Art.tex(Dialog.PLATE)
	for m in ["left", "top", "right", "bottom"]:
		plate.set("patch_margin_" + m, Dialog.PLATE_MARGIN)
	plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Pinned to the bottom of the screen the player actually has: a taller phone
	# gets more canvas below the 1672 design, and the toast belongs at its foot.
	plate.anchor_top = 1.0
	plate.anchor_bottom = 1.0
	plate.grow_vertical = Control.GROW_DIRECTION_BEGIN
	plate.visible = false
	# On a layer of its own above every page and dialog: what a page's action
	# did is said here, and a toast under the page it came from is not said.
	var layer := CanvasLayer.new()
	layer.layer = 110
	add_child(layer)
	var frame := Control.new()
	frame.set_anchors_preset(Control.PRESET_FULL_RECT)
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(frame)
	frame.add_child(plate)
	_toast = UI.label("", 28, UI.INK, "body", 600, HORIZONTAL_ALIGNMENT_CENTER)
	_toast.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	plate.add_child(_toast)
	_toast_plate = plate


func toast(message: String) -> void:
	if message == "":
		return
	var plate := _toast_plate
	_toast.text = message
	var s := _toast.label_settings
	var one_line := s.font.get_string_size(message, HORIZONTAL_ALIGNMENT_LEFT, -1, s.font_size).x
	var text_w := minf(one_line + 4.0, TOAST_MAX_W - TOAST_PAD.x * 2.0)
	_toast.custom_minimum_size = Vector2(text_w, 0)
	_toast.size = Vector2(text_w, 0)
	var text_h := s.font.get_multiline_string_size(message, HORIZONTAL_ALIGNMENT_CENTER, text_w, s.font_size).y
	var sz := Vector2(text_w + TOAST_PAD.x * 2.0, text_h + TOAST_PAD.y * 2.0)
	plate.offset_top = -40.0 - sz.y
	plate.offset_bottom = -40.0
	plate.offset_left = 550.0 - sz.x / 2.0
	plate.offset_right = 550.0 + sz.x / 2.0
	_toast.position = TOAST_PAD
	_toast.size = Vector2(text_w, text_h)
	plate.visible = true
	if _toast_tween != null:
		_toast_tween.kill()
	plate.modulate.a = 0.0
	_toast_tween = create_tween()
	_toast_tween.tween_property(plate, "modulate:a", 1.0, 0.14)
	_toast_tween.tween_interval(2.4)
	_toast_tween.tween_property(plate, "modulate:a", 0.0, 0.3)
	_toast_tween.tween_callback(func() -> void: plate.visible = false)


## A level is a moment, not a toast: the ceremony says what it brought --
## points, diamonds, a refilled pool, any tab it opened.
func _on_level_up(level: int, levels: int, points: int, gems: int) -> void:
	var ceremony: GDScript = load("res://scenes/pages/ceremony.gd")
	# Each section the level opened has a ceremony of its own, after this one,
	# so the level's list leaves them out rather than say it twice.
	ceremony.level_up({"level": level, "levels": levels, "points": points, "gems": gems, "unlocked": []})
	for id in GameState.last_unlocked:
		ceremony.new_lands(Nav.overlay_parent(), str(id), "")


## A purchase landed: the Royal Delivery says what it brought. One that brought
## nothing new (delivered before, the phone asking again) is only acknowledged.
func _on_delivered(d: Dictionary) -> void:
	if bool(d.get("already", false)) or (d.get("lines", []) as Array).is_empty():
		toast("Delivered")
		return
	var ceremony: GDScript = load("res://scenes/pages/ceremony.gd")
	ceremony.delivery(self, d)


## A mastery milestone is a permanent raise on one job. The server has reported
## it with every batch for months; nothing listened, so it arrived in silence.
func _on_mastery(job_id: String, collects: int, bonus_bp: int) -> void:
	var job: Dictionary = {"id": job_id, "name": job_id.replace("_", " ").capitalize()}
	var index := 0
	var jobs := GameState.jobs()
	for i in jobs.size():
		if str(jobs[i].get("id", "")) == job_id:
			job = jobs[i]
			index = i
	var collect: GDScript = load("res://scenes/tabs/collect.gd")
	var ceremony: GDScript = load("res://scenes/pages/ceremony.gd")
	ceremony.mastery({"job": job, "collects": collects, "bonus_bp": bonus_bp,
		"art": collect.painting_for(job, index)})


## The server ended the session (a refresh it refused). The shell is left with
## no state to draw, so the game goes back to the sign-in screen and says why,
## rather than sitting on empty frames.
func _on_signed_out() -> void:
	if not is_inside_tree():
		return
	Nav.go.call_deferred("res://scenes/auth/auth.tscn")
