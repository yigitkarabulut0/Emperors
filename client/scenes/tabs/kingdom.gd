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
## The roster's faces, and the rule for choosing one, live with the section that
## also draws lords, so the two never disagree.
const Faces := preload("res://scenes/kingdom/kingdom_section.gd")
const HallScript := preload("res://scenes/kingdom/kingdom_hall.gd")
const WORK_ART := ["kingdom/work_banner_hall", "kingdom/work_training_grounds", "kingdom/work_granary_law", "kingdom/work_royal_archives"]
## Reputation ranks: name, threshold. The server stores a number; the ladder is presentation.
const RANKS := [["NEUTRAL", 0], ["RESPECTED", 10000], ["HONORED", 50000], ["LEGENDARY", 200000]]
const HEX_ASSETS := ["kingdom/rep_hex_1", "kingdom/rep_hex_2_lit", "kingdom/rep_hex_3", "kingdom/rep_hex_4"]
const HEX_LABELS := ["kingdom/rep_label_neutral", "kingdom/rep_label_respected", "kingdom/rep_label_honored", "kingdom/rep_label_legendary"]
## Where the painting draws the four hexagons and their labels (the card keeps
## them baked, with tier II lit); overlays only where the live state differs.
const HEX_RECTS := [[574, 1028, 47, 59], [656, 1024, 56, 66], [752, 1028, 49, 60], [847, 1028, 49, 60]]
const LABEL_RECTS := [[562, 1090, 68, 22], [644, 1090, 78, 22], [744, 1090, 68, 22], [830, 1090, 82, 22]]
const TAB_NAMES := ["realm", "lords", "works", "ranks"]
## The kingdom's own header: the crest, the name, the stats and the strip.
const TOP_PARTS := ["header", "kingdom_name", "edit_name", "motto", "level", "level_bar_fill",
	"stat_renown", "stat_renown_value", "stat_treasury", "stat_treasury_value",
	"stat_members", "stat_members_value", "tabs"]
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
## Just under the tab strip, which ends at 624, and clear of the rail: it runs
## down x 0..160, and a section that started at 70 had the first ninety units of
## every row hidden behind it.
const SECTION_TOP := 646.0
const SECTION_X := 168.0
## The lit plate is 206x68 and the dark ones 63 tall; the strip is as tall as
## the tallest, and every instance stands on its top edge.
const TAB_H := 68.0
const ACTIVE_MARGIN := [14, 10, 14, 10]
const IDLE_MARGIN := [12, 8, 12, 8]
const MAX_NAME := 18
const MAX_TAG := 4
## The hall's header: the vista above the crest, then its title and a line
## under it, then the rows. The vista is the painting's own width, the rows the
## section's.
const HALL_VISTA := Rect2(150, 0, 791, 174)
const HALL_FADE := 76.0
const HALL_TITLE_Y := 184.0
const HALL_TOP := 318.0

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
var _widths: Array = []
var _label_spots: Dictionary = {}


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
		_content.custom_minimum_size.y = maxf(_page_height(), _scroll.size.y)
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
	# The layout carries a plate for each state and a label for each name; the
	# lit plate follows the selected tab.
	var tabs: Array = _ui["tabs"]
	var strip: Dictionary = Layout.find(SCREEN, "tabs")
	_widths = strip.get("widths", [206, 186, 197, 192])
	_label_spots = strip.get("labels", {})
	for i in tabs.size():
		var node: Control = tabs[i]["node"]
		var label: TextureRect = tabs[i]["parts"]["label"]
		label.texture = Art.tex("kingdom/tab_label_" + TAB_NAMES[i])
		var ls: Vector2 = label.texture.get_size()
		var w := _tab_width(i)
		# Where the painting sets each word, not where centring the plate would
		# put it: REALM, WORKS and RANKS are each a unit or three off centre in
		# the painting, and matching the painting is the whole rule here.
		var spot: Dictionary = _label_spots.get(TAB_NAMES[i], {})
		var lr: Array = spot.get("rect", [])
		if lr.size() == 4:
			UI.place(label, Rect2(float(lr[0]) - 151.0 - (tabs[i]["node"].position.x - 151.0),
				float(lr[1]) - 556.0, ls.x, ls.y))
		else:
			UI.place(label, Rect2((w - ls.x) / 2.0, (TAB_H - ls.y) / 2.0, ls.x, ls.y))
		var hit := UI.hotspot(Rect2(0, 0, w, TAB_H))
		hit.pressed.connect(_jump.bind(TAB_NAMES[i]))
		node.add_child(hit)
	_light_the_tab()
	# Reputation ladder overlays, drawn over the card's baked hexagons -- in the
	# realm layer, so they can never be left standing over another tab.
	for i in HEX_RECTS.size():
		var hr: Array = HEX_RECTS[i]
		var hex := UI.image(HEX_ASSETS[i], Rect2(hr[0], hr[1], hr[2], hr[3]))
		hex.visible = false
		_realm.add_child(hex)
		var lr: Array = LABEL_RECTS[i]
		var lab := UI.image(HEX_LABELS[i], Rect2(lr[0], lr[1], lr[2], lr[3]))
		lab.visible = false
		_realm.add_child(lab)
		_hexes.append({"hex": hex, "label": lab})
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
	var k := _kingdom()
	_ui["kingdom_name"].text = str(k.get("name", "")).to_upper()
	UI.fit_label(_ui["kingdom_name"], 48, 30)
	var n := int(k.get("members", 1))
	_ui["motto"].text = "[%s] · Kingdom of %d lord%s" % [str(k.get("tag", "")), n, "" if n == 1 else "s"]
	_ui["level"].text = "LEVEL %d" % int(k.get("level", 1))
	# Fitted to the plaque's box, which ends where the bar begins: at the
	# painting's size a two-digit level ran onto the bar.
	UI.fit_label(_ui["level"], 28, 20)
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
	# The painting shows tier II lit. When another tier is current, tier II is
	# dimmed with a darkened overlay and the current one lifted with a gold tint.
	for i in _hexes.size():
		var h: Dictionary = _hexes[i]
		var show := (idx != 1) and (i == 1 or i == idx)
		h["hex"].visible = show
		h["label"].visible = show
		if not show:
			continue
		if i == idx:
			h["hex"].modulate = Color(1.3, 1.15, 0.75)
			h["label"].modulate = Color(1.3, 1.1, 0.6)
		else:
			h["hex"].modulate = Color(0.45, 0.45, 0.5)
			h["label"].modulate = Color(0.55, 0.55, 0.6)


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
		for k in p:
			p[k].visible = k == "plate" or i < members.size()
		if i >= members.size():
			continue
		var m: Dictionary = members[i]
		p["portrait"].texture = Art.tex(Faces.face_for(str(m.get("player_id", "")), str(m.get("role", "member"))))
		p["online"].texture = Art.tex("icons/dot_online" if str(m.get("player_id", "")) == Session.player_id else "icons/dot_offline")
		p["name"].text = str(m.get("name", "")).to_upper()
		UI.fit_label(p["name"], 24, 14)
		var role := str(m.get("role", "member"))
		p["role_icon"].texture = Art.tex(str(ROLE_ICON.get(role, ROLE_ICON["member"])))
		p["role"].text = str(ROLE_WORD.get(role, "LORD"))
		p["might"].text = "LV %d" % int(m.get("level", 1))


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
		p["painting"].texture = Art.tex(WORK_ART[i % WORK_ART.size()])
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

## The hall's own header, built once: the vista above the crest, fading into the
## ground, and the page's title. A kingdom's header shows its crest and its
## name; a player with neither is shown the realm they could join.
func _build_hall_header() -> void:
	var vista := UI.image("kingdom/hall_vista", HALL_VISTA)
	_hall_layer.add_child(vista)
	# The crop stops where the crest begins, so its foot is a straight cut
	# through the castle. It fades into the ground instead of ending on a line.
	var fade := TextureRect.new()
	var g := Gradient.new()
	g.set_color(0, Color(UI.GROUND, 0.0))
	g.set_color(1, UI.GROUND)
	var gt := GradientTexture2D.new()
	gt.gradient = g
	gt.fill_from = Vector2(0, 0)
	gt.fill_to = Vector2(0, 1)
	gt.width = 4
	gt.height = 64
	fade.texture = gt
	fade.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	fade.stretch_mode = TextureRect.STRETCH_SCALE
	fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UI.place(fade, Rect2(HALL_VISTA.position.x, HALL_VISTA.end.y - HALL_FADE, HALL_VISTA.size.x, HALL_FADE + 2))
	_hall_layer.add_child(fade)

	var title := UI.label("JOIN A KINGDOM", 50, UI.GOLD, "title", 700)
	UI.place(title, Rect2(SECTION_X + 16, HALL_TITLE_Y, 700, 64))
	_hall_layer.add_child(title)
	var line := UI.label("Stand with other lords and share their bonuses.", 26, UI.DIM, "body", 500)
	line.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	line.custom_minimum_size = Vector2(730, 0)
	UI.place(line, Rect2(SECTION_X + 18, HALL_TITLE_Y + 66, 730, 40))
	_hall_layer.add_child(line)


func _show_hall() -> void:
	_hall_layer.visible = true
	if _hall != null:
		_hall.update(_data)
		return
	_hall = HallScript.new()
	_hall.setup("hall", _data, {})
	_hall.position = Vector2(SECTION_X, HALL_TOP)
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
				GameState.action_failed.emit("Your request is with %s" % name)
			else:
				GameState.action_failed.emit("Welcome to %s" % name)
		"/v1/kingdom/accept":
			GameState.action_failed.emit("Welcome to %s" % name)
		"/v1/kingdom/request/cancel":
			GameState.action_failed.emit("Request withdrawn")
		"/v1/kingdom/decline":
			GameState.action_failed.emit("Invitation declined")


## How tall the page has to be for whatever it is showing.
func _page_height() -> float:
	if _hall != null and _hall_layer.visible:
		return HALL_TOP + _hall.size.y + 150.0
	if _section != null:
		return SECTION_TOP + _section.size.y + 140.0
	return 1672.0


func _fit_page() -> void:
	_content.custom_minimum_size.y = maxf(_page_height(), _scroll.size.y)


# --- actions ------------------------------------------------------------------------

## Lights the tab whose section is showing.
func _light_the_tab() -> void:
	var at := maxi(0, TAB_NAMES.find(_view))
	var tabs: Array = _ui["tabs"]
	for i in tabs.size():
		var chip: NinePatchRect = tabs[i]["parts"]["chip"]
		var on := i == at
		chip.texture = Art.tex("kingdom/tab_active_empty" if on else "kingdom/tab_inactive_empty")
		# The lit plate is painted taller than the dark ones and stands two units
		# higher; both are drawn at their own height and nine-patched to the
		# tab's own width, so the gold rule under the strip stays one line.
		var m: Array = ACTIVE_MARGIN if on else IDLE_MARGIN
		chip.patch_margin_left = int(m[0])
		chip.patch_margin_top = int(m[1])
		chip.patch_margin_right = int(m[2])
		chip.patch_margin_bottom = int(m[3])
		UI.place(chip, Rect2(0, 0 if on else 2, _tab_width(i), TAB_H if on else 63))


## The painted width of tab i. The strip is not four equal chips: the painting
## cut each plate to its own word.
func _tab_width(i: int) -> float:
	return float(_widths[i]) if i < _widths.size() else 186.0


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

	_section = load("res://scenes/kingdom/kingdom_section.gd").new()
	_section.setup(which, _data, _shop)
	_section_sig = _signature(which)
	_section.position = Vector2(SECTION_X, SECTION_TOP)
	# A success reloads, and the reload rebuilds the section from the new data.
	# A refusal changes nothing, but the section went busy when it asked, so it
	# is rebuilt as it was -- otherwise every button in it would stay dead.
	_section.acted.connect(func(path: String, body: Dictionary) -> void:
		var res := await _act(path, body)
		if not res.ok:
			_show_section(_view))
	_section.grew.connect(func(_h: float) -> void: _fit_page())
	_content.add_child(_section)
	# Above the layers, below the foliage along the foot.
	_content.move_child(_section, _hall_layer.get_index() + 1)
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
		GameState.action_failed.emit("Long live %s" % text)


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
	_busy = false
	if res.ok:
		# Whatever the answer changed -- a section rebuilds from the new data
		# because its signature has moved.
		_section_sig = ""
		await _load()
	return res
