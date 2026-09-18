extends Control
## THE THRONE -- Emperor of the Week, cut from art/reference/throne.png
## (art/slices/throne.json, layout client/layout/throne.json).
##
## Every Monday the kingdom that gained the most renown in the UTC week crowns
## its king Crowned Emperor for a reign. Once in it he declares ONE edict of
## sixty minutes, and EVERY LORD IN THE REALM feels it -- which is what makes
## the throne worth watching for a lord with no kingdom at all.
##
## Hosted over the Kingdom tab the way the Tax Cart is hosted over the COURT
## (Shell.VIEWS, Shell.open_view("throne")): the shell's rail and its three
## pills stay, the tab under it is hidden, and CourtBack goes back. It is a
## view and not a page because throne.png is a shell painting -- its own rail
## and pills are baked in, and a page's backdrop would black out the real ones.
##
## Every figure is the server's (GET /v1/throne): the reign's clock and the
## edict's count down from the answer's moment and are never written back.
## Only the Crowned Emperor sees DECLARE lit; everyone else reads what was
## declared. A declared edict is not drawn as a kingdom's bonus anywhere: it
## goes into snapshot.live.boosts like any timed event, so the Collect band and
## the rail's seal show it without this screen being open.
##
## POST /v1/throne/decree carries NO action_seq -- it writes nothing on the
## lord's own row -- so its answer is adopted the way a claimed letter's is.

signal back_requested

const SCREEN := "throne"
const DIMMED := Color(0.55, 0.55, 0.55)
## The crowned ring's opening, for the emperor's own look.
const FRAME_BAND := 210.0
const NAME_SIZE := 32
const NAME_MIN := 20
const LINE_SIZE := 24
const LINE_MIN := 17
## The red plate is 225 units wide and was painted for a NAME -- the layout's own
## sample, "Lord Darius", fits it at the full 32. "THE THRONE IS EMPTY" needs
## size 16 to fit, which is the fitter's floor and reads as a caption rather than
## a proclamation. "NO EMPEROR" fits at 26.
const EMPTY_NAME := "NO EMPEROR"
const NO_KINGDOM := "No kingdom"

var _ui: Dictionary = {}
var _data: Dictionary = {}
var _cards: Array = []
var _reigns: Array = []
var _chosen := ""
var _busy := false
var _at_ms := 0


func _ready() -> void:
	_ui = Layout.build(SCREEN, self)
	_cards = _ui["card"]
	_reigns = _ui["reign"]
	for i in _cards.size():
		var hit := UI.hotspot(Rect2(Vector2.ZERO, (_cards[i]["node"] as Control).size))
		hit.pressed.connect(_choose.bind(i))
		_cards[i]["node"].add_child(hit)
	(_ui["declare"] as BaseButton).pressed.connect(_declare)
	CourtBack.build(self)
	var tick := Timer.new()
	tick.wait_time = 1.0
	tick.timeout.connect(_clocks)
	add_child(tick)
	tick.start()
	_paint()


func refresh() -> void:
	var res: Api.Response = await Api.get_json("/v1/throne")
	if not is_inside_tree():
		return
	if res.ok and res.data is Dictionary:
		paint(res.data)


## Paints with a /v1/throne answer. Public for tests and captures.
func paint(v: Dictionary) -> void:
	_data = v
	_at_ms = Time.get_ticks_msec()
	if _chosen == "" :
		var ds: Array = v.get("decrees", [])
		if not ds.is_empty():
			_chosen = str((ds[0] as Dictionary).get("id", ""))
	_paint()


func _age() -> int:
	return int((Time.get_ticks_msec() - _at_ms) / 1000)


## The kingdom's plate carries the reign's clock with it: the painting leaves
## no band between its line and DECREE, and a clock beside the kingdom is in
## the place a reader is already looking.
func _clocks() -> void:
	if _data.is_empty() or _ui.is_empty():
		return
	var reign: Variant = _data.get("reign")
	var l: Label = _ui["kingdom"]
	if reign is Dictionary:
		var e: Dictionary = reign
		var name := str(e.get("kingdom_name", ""))
		if str(e.get("kingdom_tag", "")) != "":
			name = "%s  [%s]" % [name, str(e.get("kingdom_tag", ""))]
		l.text = "%s  ·  %s left" % [name,
			UI.time_left(maxi(0, int(e.get("ends_in", 0)) - _age()))]
	else:
		# No crown yet, so the plate says who is WINNING it. The race is the
		# server's own (`race`, sorted by the week's renown) and it is the whole
		# reason a lord with no kingdom watches this screen at all -- a plate
		# that only counted down to Monday said nothing about the contest.
		# 275 units: the tag, the verb and the clock fit at 22 and the sentence
		# "leads · crowned in" does not fit at all.
		var lead := _leader()
		var until := UI.time_left(maxi(0, int(_data.get("crowns_in", 0)) - _age()))
		if lead == "":
			l.text = "Crowned in " + until
		else:
			l.text = "%s leads  ·  %s" % [lead, until]
	UI.fit_line(l, 26, 16)
	_say_timer()


## The kingdom at the head of this week's race, by its tag where it has one:
## the plate is 275 units wide and a kingdom's full name is not.
func _leader() -> String:
	var race: Array = _data.get("race", [])
	if race.is_empty():
		return ""
	var top: Dictionary = race[0]
	var tag := str(top.get("kingdom_tag", ""))
	return ("[%s]" % tag) if tag != "" else str(top.get("kingdom_name", ""))


## The line beside DECLARE.
##
## With a decree running it is the decree and its clock. With an emperor and no
## decree, it says so. With NO throne there can be no decree at all, so rather
## than a vacuous "No decree yet" the box says where the lord's own kingdom
## stands in the race -- `my_place` and `my_renown`, which the server has always
## sent and nothing has ever drawn.
func _say_timer() -> void:
	var l: Label = _ui["timer"]
	var declared := str(_data.get("declared", ""))
	if declared != "":
		var d := _decree(declared)
		l.text = "%s  ·  %s" % [str(d.get("name", "")),
			UI.time_left(maxi(0, int(_data.get("decree_ends_in", 0)) - _age()))]
	elif _data.get("reign") is Dictionary:
		l.text = "No decree yet"
	else:
		l.text = _my_standing()
	UI.fit_label(l, 25, 17)


## Where this lord's kingdom stands in the week's race, in the server's words.
func _my_standing() -> String:
	var place := int(_data.get("my_place", 0))
	var race: Array = _data.get("race", [])
	if place <= 0 or race.is_empty():
		return "Join a kingdom to race for the crown"
	return "Your kingdom stands %s of %d\n%s renown this week" % [
		UI.ordinal(place), race.size(), UI.grouped(int(_data.get("my_renown", 0)))]


func _decree(id: String) -> Dictionary:
	for d in _data.get("decrees", []):
		if d is Dictionary and str(d.get("id", "")) == id:
			return d
	return {}


func _paint() -> void:
	if _ui.is_empty():
		return
	var reign: Variant = _data.get("reign")
	var seated := reign is Dictionary
	var e: Dictionary = reign if seated else {}
	var face: TextureRect = _ui["portrait"]
	face.texture = Art.tex(Art.avatar(str(e.get("avatar", "")))) if seated else null
	face.visible = seated
	# The emperor's own worn frame is NOT drawn here: the crowned ring is the
	# throne's regalia, and two frames on one portrait fight. Their colour,
	# title and seal show on the name plate instead.
	var name_box := Layout.rect_of(Layout.element(SCREEN, "emperor"))
	if seated:
		Look.paint_name(_ui["emperor"], e, str(e.get("emperor_name", "")), name_box, NAME_SIZE, NAME_MIN)
	else:
		(_ui["emperor"] as Label).text = EMPTY_NAME
		UI.fit_line(_ui["emperor"], NAME_SIZE, 16)
	_clocks()

	var decrees: Array = _data.get("decrees", [])
	var declared := str(_data.get("declared", ""))
	for i in _cards.size():
		var c: Dictionary = _cards[i]
		c["node"].visible = i < decrees.size()
		if i >= decrees.size():
			continue
		var d: Dictionary = decrees[i]
		(c["parts"]["face"] as TextureRect).texture = Art.tex(str(d.get("icon", "")))
		var plate: Label = c["parts"]["plate"]
		plate.text = "%s  ·  %dm" % [LiveEvents.percent(int(d.get("bp", 0))), int(d.get("minutes", 0))]
		UI.fit_label(plate, 23, 16)
		var lit := (declared == str(d.get("id", ""))) if declared != "" else (_chosen == str(d.get("id", "")))
		(c["node"] as CanvasItem).modulate = Color.WHITE if lit else DIMMED

	var can := bool(_data.get("can_declare", false))
	(_ui["declare"] as CanvasItem).modulate = Color.WHITE if can else DIMMED

	var past: Array = _data.get("past", [])
	for i in _reigns.size():
		var r: Dictionary = _reigns[i]
		var l: Label = r["parts"]["words"]
		# The four crowns and their plates are PAINTED into past_reigns.png --
		# only the words are ours -- so an unused row cannot be hidden, and the
		# first one says why the rest are bare rather than leaving the panel
		# mute. Filling them with anything but past reigns would make the
		# panel's own baked title a lie.
		if i < past.size():
			var p: Dictionary = past[i]
			l.text = "%s  ·  %s  ·  %s renown" % [str(p.get("kingdom_name", "")),
				str(p.get("emperor_name", "")), UI.grouped(int(p.get("renown", 0)))]
		elif i == 0:
			l.text = "No reign has ended yet."
		else:
			l.text = ""
		UI.fit_label(l, 23, 16)


func _choose(i: int) -> void:
	var decrees: Array = _data.get("decrees", [])
	if i >= decrees.size() or str(_data.get("declared", "")) != "":
		return
	_chosen = str((decrees[i] as Dictionary).get("id", ""))
	_paint()


func _declare() -> void:
	if _busy:
		return
	if not bool(_data.get("can_declare", false)):
		var reign: Variant = _data.get("reign")
		if reign is Dictionary and str(_data.get("declared", "")) != "":
			GameState.toast("This reign's decree has been declared")
		elif reign is Dictionary:
			GameState.toast("Only %s may declare it" % str((reign as Dictionary).get("emperor_name", "the Emperor")))
		else:
			GameState.toast("Nobody sits the throne yet")
		return
	var d := _decree(_chosen)
	if d.is_empty():
		return
	_busy = true
	if await Dialog.ask(self, {"title": "Declare the %s?" % str(d.get("name", "")),
			"body": "Every lord in the realm feels it for %d minutes. Once only, for this reign." % int(d.get("minutes", 0)),
			"confirm_text": "Declare"}):
		var res: Api.Response = await Api.post_json("/v1/throne/decree", {"decree": _chosen})
		if res.ok and res.data is Dictionary:
			paint(res.data)
	await refresh()
	_busy = false
