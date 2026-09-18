extends Control
## KINGDOM — the realm when the player has one, the hall when they do not.
## Layout: layout/kingdom.json for the kingdom's own page (header, stats, the
## tab strip and REALM); scenes/kingdom/kingdom_section.gd builds LORDS, WORKS
## and RANKS under the strip; scenes/kingdom/kingdom_hall.gd builds the hall.
##
## The page is three layers, and what shows is decided per layer, never per
## node:
##   _top    the kingdom's header, stats and tab strip
##   _realm  everything the painting draws below the strip
##   _hall   what a player with no kingdom is offered instead of all of it
## They used to be one flat list of nodes, and painting REALM switched its rows
## back on whichever tab was showing -- the works rows and their UPGRADE buttons
## turned up on the Lords page whenever the tab was reopened. Painting a hidden
## layer draws nothing, so that cannot happen now.

const SCREEN := "kingdom"
## The roster's faces and the works' scenes, and the rules for choosing them,
## live with the section that also draws lords and works, so the two never
## disagree.
const Section := preload("res://scenes/kingdom/kingdom_section.gd")
const HallScript := preload("res://scenes/kingdom/kingdom_hall.gd")
## The sub-tabs that are their own screens rather than one of kingdom_section's
## three lists: the hall (chat.png) and the kingdom's help (help.png).
const SECTION_SCRIPT := {"chat": "res://scenes/kingdom/chat_section.gd",
	"help": "res://scenes/kingdom/help_section.gd",
	"boss": "res://scenes/kingdom/boss_section.gd",
	"war": "res://scenes/kingdom/war_section.gd"}
## Reputation ranks: name, threshold. The server stores a number; the ladder is presentation.
const RANKS := [["NEUTRAL", 0], ["RESPECTED", 10000], ["HONORED", 50000], ["LEGENDARY", 200000]]
## The ranks' hexagons, drawn over the card at the painting's own centres: the
## rank the kingdom holds lit, the others unlit (art/slices/numerals_rep.json).
## The card's baked hexagons and words are lifted out; the painting had only
## RESPECTED lit, and the other three were faked by tinting its crops.
const HEX_CENTRES := [Vector2(597.5, 1057.5), Vector2(684, 1057), Vector2(776.5, 1058), Vector2(871.5, 1058)]
## The ranks' words, set in the painting's type at its measured size, weight
## and colours -- Cinzel 12 sets NEUTRAL, RESPECTED and LEGENDARY 60, 72 and 76
## wide against the painted 58, 70 and 75, centred on the painted words (caps
## 1096..1105), in the strokes' own ivory -- gold for the rank held.
const WORD_CENTRES_X := [595.5, 682.5, 777.5, 871.0]
const WORD_Y := 1090.5
const WORD_SIZE := 12
const WORD_WEIGHT := 500
const WORD_COLOUR := Color("#E2E9EE")
const WORD_LIT := Color("#F5DB61")
const TAB_NAMES := ["realm", "lords", "works", "ranks"]
## The second row: the hall (chat.png), the kingdom's beast (boss.png), its
## wars (war.png) and its help (help.png). All four are open.
const TAB2_NAMES := ["chat", "boss", "war", "help"]
const SOON := {}
## What the second row pushes down: everything the painting has under the first
## row's rule moves by the height of the row that was added.
const ROW2_SHIFT := 70.0
## The kingdom's own header: the crest, the name, the stats and the strip.
const TOP_PARTS := ["header", "kingdom_name", "edit_name", "motto", "level", "level_bar_fill",
	"stat_renown", "stat_renown_value", "stat_treasury", "stat_treasury_value",
	"stat_members", "stat_members_value"]
## Everything the reference paints below the tab strip. All of it is REALM.
const REALM_PARTS := ["realm_card", "realm_bonuses", "bonus_income", "bonus_xp",
	"realm_notice", "treasury_card", "donate", "reputation_card", "rep_rank_name",
	"rep_bar_fill", "rep_progress", "rep_tiers", "lords_panel", "lords_view_all",
	"lord_row", "works_panel", "works_view_all", "work_row", "ranking_card", "rank",
	"view_rankings"]
## The server's ranks, in the painting's words. The server says marshal and
## member; the painting says CAPTAIN and LORD, and the painting is what a
## player reads.
const ROLE_WORD := {"king": "KING", "marshal": "CAPTAIN", "member": "LORD"}
const ROLE_ICON := {"king": "icons/role_king", "marshal": "icons/role_captain", "member": "icons/role_lord"}
const ROLE_ORDER := {"king": 0, "marshal": 1, "member": 2}
## A lord row's title may run up to the might icon (x 269 of the row).
const TITLE_RIGHT := 264.0
## Just under the tab strip, which ends at 624, and clear of the rail: it runs
## down x 0..160, and a section that started at 70 had the first ninety units of
## every row hidden behind it.
const SECTION_TOP := 646.0 + ROW2_SHIFT
const SECTION_X := 168.0
## kingdom.png is FULL -- the stats end at 551, the tab plates run 561..615, the
## realm's content to 1479, the ranking card to 1619 and the foliage is pinned
## to the foot; the largest gap anywhere is ten units. A Throne banner laid
## along the page's foot fell below the fold on a 1672 screen, which is a
## banner nobody sees. So the Throne's entry is the first row of the RANKS
## section (kingdom_section.gd) and of the hall, where a lord already looks for
## where the realm stands, and not one painted pixel moves for it.
const FOLIAGE_H := 54.0
const MAX_NAME := 18
const MAX_TAG := 4
## The hall's header: the painting's vista, JOIN A KINGDOM and its line, baked
## (hall/header, art/slices/kingdom_hall.json), from the painting's content edge.
## The rows start under it (kingdom_hall.gd TOP).
const HALL_HEADER := Rect2(190, 0, 751, 460)

var _scroll: ScrollContainer
var _content: Control
var _top: Control
var _realm: Control
var _hall_layer: Control
var _hall: Control
var _ui: Dictionary = {}
var _lords: Array = []
var _works: Array = []
var _hexes: Array = []
var _data: Dictionary = {}
var _shop: Dictionary = {}
var _loaded_ms := -100000
var _loaded_once := false
var _busy := false
var _view := "realm"
var _section: Control
## What the section showing was built from, so a refresh that brings the same
## data leaves it alone rather than rebuilding it under the player's thumb.
var _section_sig := ""
## REALM / LORDS / WORKS / RANKS: the one tab row, in the kingdom's own layer.
var _tabs: TabStrip
var _tabs2: TabStrip


func _ready() -> void:
	_scroll = ScrollContainer.new()
	_scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	_scroll.scroll_deadzone = 14
	add_child(_scroll)
	_content = Control.new()
	_content.custom_minimum_size = Vector2(941, 1672)
	_content.mouse_filter = Control.MOUSE_FILTER_PASS
	_scroll.add_child(_content)
	# The page is at least as tall as the screen, so on a phone taller than the
	# design the bottom-anchored pieces sit at the screen's foot rather than at
	# the design's, with ground under them.
	# The scroll took its size when its anchors were set, above, so the hook is
	# applied once by hand as well as on every later resize.
	var fit_page := func() -> void:
		_fit_page()
	_scroll.resized.connect(fit_page)
	fit_page.call()
	_ui = Layout.build(SCREEN, _content)
	_layer_the_page()

	_lords = _ui["lord_row"]
	_works = _ui["work_row"]
	for i in _works.size():
		_works[i]["parts"]["upgrade"].pressed.connect(_upgrade.bind(i))
	_ui["donate"].pressed.connect(_donate)
	_ui["edit_name"].pressed.connect(_rename)
	_ui["lords_view_all"].pressed.connect(_show_section.bind("lords"))
	_ui["works_view_all"].pressed.connect(_show_section.bind("works"))
	_ui["view_rankings"].pressed.connect(_show_section.bind("ranks"))
	# The tab strip (scripts/ui/tab_strip.gd), standing on the painting's gold
	# rule under the stats; it belongs to the kingdom's own layer.
	_tabs = TabStrip.make(TAB_NAMES, Layout.rect_of(Layout.find(SCREEN, "tabs")), "realm")
	_tabs.changed.connect(_jump)
	_top.add_child(_tabs)
	# The second row, under the first: the hall, the boss, the war and the
	# kingdom's help. It is the same object at the same size, so the eight read
	# as one choice and not as two kinds of tab.
	_tabs2 = TabStrip.make(TAB2_NAMES, Layout.rect_of(Layout.find(SCREEN, "tabs2")))
	_tabs2.changed.connect(_jump)
	for id in SOON:
		_tabs2.set_off(str(id), str(SOON[id]))
	_tabs2.refused.connect(func(_id: String, words: String) -> void: GameState.toast(words))
	_top.add_child(_tabs2)
	# Everything the painting puts under the first row's rule moves down by the
	# row that was added.
	_realm.position.y += ROW2_SHIFT
	_light_the_tab()
	# The reputation ladder, over the card -- in the realm layer, so it can never
	# be left standing over another tab.
	for i in HEX_CENTRES.size():
		var hex := UI.image(rank_hex(i, false), Rect2())
		_realm.add_child(hex)
		var word := UI.label(str(RANKS[i][0]), WORD_SIZE, WORD_COLOUR, "title", WORD_WEIGHT,
			HORIZONTAL_ALIGNMENT_CENTER)
		UI.place(word, Rect2(WORD_CENTRES_X[i] - 50.0, WORD_Y, 100, 22))
		_realm.add_child(word)
		_hexes.append({"hex": hex, "word": word})
		_light_rank(i, false)
	_build_hall_header()
	# Nothing shows until the server has said whether there is a kingdom: the
	# first frame used to be the Realm dashboard filled with dashes.
	_top.visible = false
	_realm.visible = false
	_hall_layer.visible = false
	# Coming back to the tab is a reason to ask again. A state change is not --
	# the shell sends one on every collect -- and rebuilding a list under the
	# player's thumb because their gold moved is how a page jumps.
	visibility_changed.connect(func() -> void:
		if is_visible_in_tree():
			_loaded_ms = -100000)


## Moves what Layout built into the page's layers, keeping the painting's order.
func _layer_the_page() -> void:
	_top = _layer()
	_realm = _layer()
	_hall_layer = _layer()
	var top := _nodes_of(TOP_PARTS)
	var realm := _nodes_of(REALM_PARTS)
	for c in _content.get_children():
		if c == _top or c == _realm or c == _hall_layer:
			continue
		if top.has(c):
			c.reparent(_top)
		elif realm.has(c):
			c.reparent(_realm)
	# Whatever is left -- the foliage along the foot, which is anchored to the
	# screen's -- stays in the page and above every layer.
	for c in _content.get_children():
		if c != _top and c != _realm and c != _hall_layer:
			_content.move_child(c, -1)


## A full-page layer. It ignores the mouse, so the tab strip, the buttons and
## the drag that scrolls the page all reach what is underneath.
func _layer() -> Control:
	var l := Control.new()
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.position = Vector2.ZERO
	l.size = Vector2(941, 1672)
	_content.add_child(l)
	return l


func _nodes_of(ids: Array) -> Dictionary:
	var out := {}
	for id in ids:
		if not _ui.has(id):
			continue
		var v: Variant = _ui[id]
		if v is Control:
			out[v] = true
		elif v is Array:
			for inst in v:
				out[inst["node"]] = true
	return out


func refresh() -> void:
	if Time.get_ticks_msec() - _loaded_ms > 3000:
		_load()
	elif _loaded_once:
		_apply()


func _load() -> void:
	_loaded_ms = Time.get_ticks_msec()
	var res: Api.Response = await Api.get_json("/v1/kingdom")
	if res.ok:
		_data = res.data
		_loaded_once = true
	if _in_kingdom():
		var sh: Api.Response = await Api.get_json("/v1/kingdom/shop")
		if sh.ok:
			_shop = sh.data
	if _loaded_once:
		_apply()


func _kingdom() -> Dictionary:
	var k: Variant = _data.get("kingdom", null)
	return k if k is Dictionary else {}


func _in_kingdom() -> bool:
	return bool(_data.get("in_kingdom", false)) and not _kingdom().is_empty()


## Shows the page the data calls for: the kingdom, or the hall.
func _apply() -> void:
	if not _in_kingdom():
		_top.visible = false
		_realm.visible = false
		_free_section()
		_view = "realm"
		_show_hall()
		return
	if _hall != null:
		# The hall gives way to the kingdom it just joined, which opens on REALM.
		_hall.queue_free()
		_hall = null
		_view = "realm"
	_hall_layer.visible = false
	_top.visible = true
	_paint()
	if _view == "realm":
		_realm.visible = true
		_fit_page()
	elif _section == null or _signature(_view) != _section_sig:
		_show_section(_view)


func _paint() -> void:
	# The second row says WHICH of the four the rail's bubble meant: lines said
	# in the hall since this lord last read it, and calls for aid waiting on an
	# answer. Both are the server's own counts (service/badges.go); the rail
	# adds them up and this row points at them.
	_tabs2.set_count("chat", int(GameState.badges.get("chat", 0)))
	_tabs2.set_count("help", int(GameState.badges.get("aid_calls", 0)))
	var k := _kingdom()
	_ui["kingdom_name"].text = str(k.get("name", "")).to_upper()
	# A name may be 24 characters; the band ends before the quill. Shrunk first,
	# then cut: at 30 points "WWWW..." ran on under the quill to x 900.
	UI.fit_line(_ui["kingdom_name"], 48, 26)
	var n := int(k.get("members", 1))
	_ui["motto"].text = "[%s] · Kingdom of %d lord%s" % [str(k.get("tag", "")), n, "" if n == 1 else "s"]
	_ui["level"].text = "LEVEL %d" % int(k.get("level", 1))
	# Fitted to the plaque's box, which ends where the bar begins: at the
	# painting's size a two-digit level ran onto the bar.
	UI.fit_label(_ui["level"], 28, 20)
	# Back to its box: the layout built it around its sample and it kept that
	# width; the plaque's box is what it stands in.
	var level: Label = _ui["level"]
	if level.has_meta("box_w"):
		level.size.x = maxf(float(level.get_meta("box_w")), level.get_minimum_size().x)
	var need := int(k.get("xp_to_next", 0))
	Layout.set_fill(_ui["level_bar_fill"], (float(int(k.get("xp", 0))) / float(need)) if need > 0 else 1.0)
	_ui["stat_renown_value"].text = UI.grouped(int(k.get("reputation", 0)))
	_ui["stat_treasury_value"].text = UI.short_number(int(str(k.get("treasury", "0"))))
	_ui["stat_members_value"].text = "%d/%d" % [int(k.get("members", 0)), int(k.get("member_cap", 0))]

	var by_bucket := {}
	for u in _data.get("upgrades", []):
		by_bucket[str(u.get("bucket", ""))] = int(u.get("effect_now", 0))
	_ui["bonus_income"].text = "+%d%%" % (int(by_bucket.get("collect_income_bp", 0)) / 100)
	_ui["bonus_xp"].text = "+%d%%" % (int(by_bucket.get("xp_bp", 0)) / 100)

	_paint_reputation(int(k.get("reputation", 0)))
	_paint_lords()
	_paint_works()
	var rank := 0
	var top: Array = _data.get("leaderboard", [])
	for i in top.size():
		if str(top[i].get("id", "")) == str(k.get("id", "")):
			rank = i + 1
	_ui["rank"].text = "#%d" % rank if rank > 0 else "#-"


func _paint_reputation(rep: int) -> void:
	var idx := 0
	for i in RANKS.size():
		if rep >= int(RANKS[i][1]):
			idx = i
	var next_at: int = int(RANKS[idx + 1][1]) if idx + 1 < RANKS.size() else 0
	_ui["rep_rank_name"].text = RANKS[idx][0]
	if next_at > 0:
		_ui["rep_progress"].text = "%s / %s" % [UI.grouped(rep), UI.grouped(next_at)]
		var floor_at := int(RANKS[idx][1])
		Layout.set_fill(_ui["rep_bar_fill"], float(rep - floor_at) / float(next_at - floor_at))
	else:
		_ui["rep_progress"].text = UI.grouped(rep)
		Layout.set_fill(_ui["rep_bar_fill"], 1.0)
	for i in _hexes.size():
		_light_rank(i, i == idx)


## A rank's hexagon: lit for the rank held, unlit otherwise.
static func rank_hex(i: int, lit: bool) -> String:
	return "kingdom/rep_hex_%d%s" % [i + 1, "_lit" if lit else ""]


## Lights one rank or puts it out: its own painted hexagon, centred where the
## painting draws it (a lit one is a little larger, by its glow), and its word in
## gold or in the card's grey.
func _light_rank(i: int, lit: bool) -> void:
	var h: Dictionary = _hexes[i]
	var hex: TextureRect = h["hex"]
	hex.texture = Art.tex(rank_hex(i, lit))
	var sz := hex.texture.get_size()
	UI.place(hex, Rect2((HEX_CENTRES[i] - sz / 2.0).round(), sz))
	(h["word"] as Label).label_settings.font_color = WORD_LIT if lit else WORD_COLOUR


func _paint_lords() -> void:
	var members: Array = _data.get("members", []).duplicate()
	members.sort_custom(func(a, b):
		var ra: int = ROLE_ORDER.get(str(a.get("role", "member")), 2)
		var rb: int = ROLE_ORDER.get(str(b.get("role", "member")), 2)
		if ra != rb:
			return ra < rb
		return int(a.get("level", 0)) > int(b.get("level", 0)))
	for i in _lords.size():
		var r: Dictionary = _lords[i]
		var p: Dictionary = r["parts"]
		# The panel keeps four painted rows; an empty row shows the blank plate only.
		var used := i < members.size()
		for k in p:
			p[k].visible = k == "plate" or used
		for extra in _lord_extras(r):
			extra.visible = extra.visible and used
		if not used:
			continue
		var m: Dictionary = members[i]
		var role := str(m.get("role", "member"))
		# The king's medallion is painted with its crown above the ring, 76 tall;
		# it stands on the same foot as the others rather than being squeezed.
		var face_rect := _part_rect("lord_row", "portrait")
		if role == "king":
			face_rect = Rect2(face_rect.position.x, face_rect.end.y - 76.0, 76.0, 76.0)
		UI.place(p["portrait"], face_rect)
		Section.paint_lord_face(p["portrait"], m)
		p["online"].texture = Art.tex("icons/dot_online" if str(m.get("player_id", "")) == Session.player_id else "icons/dot_offline")
		# As everyone sees them (scripts/ui/look.gd): their colour, their seal, the
		# title they wear on the rank's line after the rank.
		Look.paint_name(p["name"], m, str(m.get("name", "")).to_upper(), _part_rect("lord_row", "name"),
			24, 14, Color("#D8DCE0"))
		p["role_icon"].texture = Art.tex(str(ROLE_ICON.get(role, ROLE_ICON["member"])))
		p["role"].text = str(ROLE_WORD.get(role, "LORD"))
		p["might"].text = "LV %d" % int(m.get("level", 1))
		if not r.has("title"):
			var t := UI.label("", 17, UI.GOLD_DIM, "body", 600)
			(p["role"] as Control).get_parent().add_child(t)
			r["title"] = t
		var rr := _part_rect("lord_row", "role")
		var after := rr.position.x + (p["role"] as Label).label_settings.font.get_string_size(
			p["role"].text, HORIZONTAL_ALIGNMENT_LEFT, -1, (p["role"] as Label).label_settings.font_size).x + 10.0
		Look.paint_title(r["title"], m, Rect2(after, rr.position.y, TITLE_RIGHT - after, rr.size.y), 17, 12)


## What a lord's look adds to their painted row: their face, the frame over it,
## the seal after the name, the title after the rank.
func _lord_extras(r: Dictionary) -> Array:
	var out: Array = []
	var p: Dictionary = r["parts"]
	var face: Node = p["portrait"].get_meta("lord_face") if p["portrait"].has_meta("lord_face") else null
	if face != null:
		out.append(face)
		if face.has_meta("look_frame"):
			out.append(face.get_meta("look_frame"))
	if p["name"].has_meta("look_seal"):
		out.append(p["name"].get_meta("look_seal"))
	if r.has("title"):
		out.append(r["title"])
	return out


## A part's rect in its template, as the layout measured it.
func _part_rect(element: String, part: String) -> Rect2:
	for q in Layout.find(SCREEN, element).get("parts", []):
		if str(q.get("id", "")) == part:
			return Layout.rect_of(q)
	return Rect2()


func _paint_works() -> void:
	var ups: Array = _data.get("upgrades", [])
	for i in _works.size():
		var w: Dictionary = _works[i]
		if i >= ups.size():
			w["node"].visible = false
			continue
		w["node"].visible = true
		var u: Dictionary = ups[i]
		var p: Dictionary = w["parts"]
		p["painting"].texture = Art.tex(Section.work_art(str(u.get("id", ""))))
		p["name"].text = str(u.get("name", "")).to_upper()
		UI.fit_label(p["name"], 18, 12)
		p["level"].text = "Lv. %d" % int(u.get("level", 0))
		p["bonus"].text = "%s · %s" % [_bonus_text(u), UI.short_number(int(u.get("next_cost", 0)))] if not bool(u.get("maxed", false)) else _bonus_text(u) + " · MAX"
		UI.fit_label(p["bonus"], 18, 12)
		var maxed := bool(u.get("maxed", false))
		p["upgrade"].modulate = Color(0.5, 0.5, 0.5) if maxed else Color.WHITE
		# A dimmed button that still answers is a button that lies.
		p["upgrade"].disabled = maxed


func _bonus_text(u: Dictionary) -> String:
	var bucket := str(u.get("bucket", ""))
	var eff := int(u.get("effect_now", 0))
	var label := bucket.replace("_bp", "").replace("_flat", "").replace("_", " ").capitalize()
	if bucket.ends_with("_flat"):
		return "+%d %s" % [eff, label]
	return "+%d%% %s" % [eff / 100, label]


# --- the hall -----------------------------------------------------------------------

## The hall's own header, built once: the painting's vista with its title and
## its line. A kingdom's header shows its crest and its name; a player with
## neither is shown the realm they could join.
func _build_hall_header() -> void:
	_hall_layer.add_child(UI.image("hall/header", HALL_HEADER))


func _show_hall() -> void:
	_hall_layer.visible = true
	if _hall != null:
		_hall.update(_data)
		return
	_hall = HallScript.new()
	_hall.setup("hall", _data, {})
	_hall.position = Vector2(0, HallScript.TOP)
	_hall.acted.connect(_hall_act)
	_hall.found_pressed.connect(_found)
	_hall.reload_wanted.connect(func() -> void: _load())
	_hall.grew.connect(func(_h: float) -> void: _fit_page())
	_hall_layer.add_child(_hall)
	await get_tree().process_frame
	_fit_page()


## A hall action, with the word the player should hear afterwards.
func _hall_act(path: String, body: Dictionary) -> void:
	var name := str(body.get("_name", ""))
	body.erase("_name")
	var res := await _act(path, body)
	if not res.ok:
		# Refused -- the toast has said why. The hall went busy when it asked.
		if _hall != null:
			_hall.update(_data)
		return
	match path:
		"/v1/kingdom/join":
			if str(res.data.get("result", "")) == "requested":
				GameState.toast("Your request is with %s" % name)
			else:
				GameState.toast("Welcome to %s" % name)
		"/v1/kingdom/accept":
			GameState.toast("Welcome to %s" % name)
		"/v1/kingdom/request/cancel":
			GameState.toast("Request withdrawn")
		"/v1/kingdom/decline":
			GameState.toast("Invitation declined")


## Where the page's own body ends, before the Throne's banner and the foliage.
func _body_bottom() -> float:
	if _hall != null and _hall_layer.visible:
		return HallScript.TOP + _hall.size.y + 96.0
	if _section != null and _section.has_method("fill_height"):
		# It was given the page's own room: there is nothing under it to reach.
		return SECTION_TOP + _section.size.y
	if _section != null:
		return SECTION_TOP + _section.size.y + 86.0
	return 1618.0   # the foliage's own top, as kingdom.png paints it


func _fit_page() -> void:
	_content.custom_minimum_size.y = maxf(_body_bottom() + FOLIAGE_H, _scroll.size.y)


# --- actions ------------------------------------------------------------------------

## Lights the tab whose section is showing.
func _light_the_tab() -> void:
	if TAB2_NAMES.has(_view):
		_tabs.unlight()
		_tabs2.select(_view)
		return
	_tabs2.unlight()
	_tabs.select(_view if TAB_NAMES.has(_view) else "realm")


## Opens one of the four sections. The name the shell and --sub use, so one
## flag reaches every tab that has sub-tabs.
func open_sub(which: String) -> void:
	if TAB_NAMES.has(which) or TAB2_NAMES.has(which):
		_jump(which)


func _jump(section: String) -> void:
	_scroll.scroll_vertical = 0
	_show_section(section)


## Shows one section and hides the rest, in the page it is already on.
##
## REALM is the page the reference painted, and it is a summary -- the other
## three tabs are where the whole roster, the whole build list and the whole
## table live. Everything below the strip belongs to REALM, so switching away is
## hiding that one layer and putting a section in its place.
func _show_section(which: String) -> void:
	_view = which
	_free_section()
	var realm := which == "realm"
	_realm.visible = realm and _in_kingdom()
	_light_the_tab()
	if realm:
		_paint()
		_fit_page()
		return

	_section = load(SECTION_SCRIPT.get(which, "res://scenes/kingdom/kingdom_section.gd")).new()
	if _section.has_method("setup"):
		_section.setup(which, _data, _shop)
	_section_sig = _signature(which)
	_section.position = Vector2(SECTION_X, SECTION_TOP)
	# A success reloads, and the reload rebuilds the section from the new data.
	# A refusal changes nothing, but the section went busy when it asked, so it
	# is rebuilt as it was -- otherwise every button in it would stay dead.
	if _section.has_signal("acted"):
		_section.acted.connect(func(path: String, body: Dictionary) -> void:
			var res := await _act(path, body)
			if not res.ok:
				_show_section(_view))
	_section.grew.connect(func(_h: float) -> void: _fit_page())
	_content.add_child(_section)
	# Above the layers, below the foliage along the foot.
	_content.move_child(_section, _hall_layer.get_index() + 1)
	# A section that fills the page rather than growing down it -- the hall,
	# whose bar stands at the foot as the painting has it -- is told how much
	# room there is, from under the strips to the foliage.
	if _section.has_method("fill_height"):
		_section.call("fill_height", _scroll.size.y - SECTION_TOP - FOLIAGE_H - 12.0)
	await get_tree().process_frame
	_fit_page()


func _free_section() -> void:
	if _section != null:
		_section.queue_free()
		_section = null
	_section_sig = ""


## What a section draws, as one string: a refresh that brings the same data
## leaves the section standing.
func _signature(which: String) -> String:
	match which:
		"lords":
			return JSON.stringify([_data.get("members", []), _data.get("requests", []),
				_data.get("me", {}), _kingdom().get("join_policy", "")])
		"works":
			return JSON.stringify([_data.get("upgrades", []), _shop])
		"ranks":
			return JSON.stringify(_data.get("leaderboard", []))
	return ""


## Founding: a name, a tag, and the price, each asked for in turn.
func _found() -> void:
	if _busy:
		return
	if not bool(_data.get("can_found", true)):
		GameState.action_failed.emit(str(_data.get("found_reason", "You cannot found a kingdom yet")))
		return
	# The name is the player's to choose, and it is typed rather than picked
	# from anything: nothing here supplies a prefix or a pattern.
	var named: Dictionary = await Dialog.prompt_text(self, {
		"title": "Name your kingdom",
		"body": "Up to %d characters. Yours to choose." % MAX_NAME,
		"placeholder": "Kingdom name", "max_length": MAX_NAME, "confirm_text": "Next"})
	if named["action"] != "confirm" or str(named["text"]) == "":
		return
	var text := str(named["text"])
	var tagged: Dictionary = await Dialog.prompt_text(self, {
		"title": "And a tag",
		"body": "Two to four letters, shown beside the name.",
		"placeholder": "TAG", "max_length": MAX_TAG, "confirm_text": "Found"})
	if tagged["action"] != "confirm" or str(tagged["text"]) == "":
		return
	var tag := str(tagged["text"])
	if not await Dialog.ask(self, {"title": "Found %s?" % text,
			"body": "Costs %s gold. You will be its king." % UI.grouped(int(_data.get("found_cost", 0))),
			"confirm_text": "Found"}):
		return
	var res := await _act("/v1/kingdom/found", {"name": text, "tag": tag.to_upper()})
	if res.ok:
		GameState.toast("Long live %s" % text)


## A kingdom's name outlives the moment it was chosen -- it is on the
## leaderboard, in every battle log and over the gate -- and founding used to be
## the only chance to set it, so a typo was permanent. The king can change it.
##
## MAX_NAME is what the plate holds. The band runs 372..772 -- 400 units, all
## the clean plate there is before the painted pillar -- and Cinzel at 700 sets
## an average capital in 35 units at size 48, so eighteen characters fit once
## the name has shrunk to 30, which is 14 pt and still reads. The server allows
## 24 and answers for anything longer.
func _rename() -> void:
	if _busy or _kingdom().is_empty():
		return
	var mine: Variant = _data.get("me", null)
	if not (mine is Dictionary) or str((mine as Dictionary).get("role", "")) != "king":
		GameState.action_failed.emit("Only the king may rename the kingdom")
		return
	var r: Dictionary = await Dialog.prompt_text(self, {
		"title": "Name the kingdom",
		"body": "Up to %d characters. It is on the leaderboard and in every battle log." % MAX_NAME,
		"placeholder": "Kingdom name", "preset": str(_kingdom().get("name", "")),
		"max_length": MAX_NAME, "confirm_text": "Rename"})
	if r["action"] != "confirm" or str(r["text"]) == "":
		return
	await _act("/v1/kingdom/rename", {"name": str(r["text"])})


func _donate() -> void:
	if _busy or _kingdom().is_empty():
		return
	var me: Dictionary = _data.get("me", {}) if _data.get("me", null) is Dictionary else {}
	# There is no daily ceiling any more, so the line says what has been given
	# rather than what is left to give.
	var today := int(me.get("donated_today", 0))
	var body := "A hundred gold earns one Favour, and the treasury takes whatever you have."
	if today > 0:
		body += "\nGiven today: %s gold." % UI.grouped(today)
	var r := await Dialog.prompt_amount(self, {"title": "Donate to the treasury",
		"body": body, "placeholder": "Gold", "confirm_text": "Donate"})
	if r["action"] != "confirm" or int(r["value"]) <= 0:
		return
	await _act("/v1/kingdom/donate", {"amount": int(r["value"])})


func _upgrade(i: int) -> void:
	var ups: Array = _data.get("upgrades", [])
	if _busy or i >= ups.size():
		return
	var u: Dictionary = ups[i]
	if bool(u.get("maxed", false)):
		return
	if not await Dialog.ask(self, {"title": "Fund %s?" % str(u.get("name", "")),
			"body": "%s\nLevel %d → %d from the treasury for %s gold." % [str(u.get("blurb", "")), int(u.get("level", 0)), int(u.get("level", 0)) + 1, UI.grouped(int(u.get("next_cost", 0)))],
			"confirm_text": "Fund"}):
		return
	await _act("/v1/kingdom/upgrade", {"id": str(u.get("id", ""))})


## One action, then the page as the server now has it.
func _act(path: String, body: Dictionary) -> Api.Response:
	_busy = true
	var res: Api.Response = await GameState.act(path, body)
	if res.ok:
		# Whatever the answer changed -- a section rebuilds from the new data
		# because its signature has moved.
		_section_sig = ""
		await _load()
	# Held until the page is the new one, so a second tap cannot act on a row
	# the first already changed.
	_busy = false
	return res
