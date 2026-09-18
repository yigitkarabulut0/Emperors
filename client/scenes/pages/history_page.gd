extends RefCounted
## BATTLE HISTORY — every raid the player made and every raid on them, the last
## fifty, each one a tap from its replay.
##
## "View All" opened a dialog with twelve lines of text in it and no way to
## watch any of them. The rows here say it from the player's side -- a victory,
## a defeat, held off, raided by -- with the gold that moved and when, and a tap
## plays the fight.
##
## Now it is its own painting (art/reference/history.png, layout
## client/layout/history.json) on the painted pages' host. Each row is the one
## of the painting's four that says how the fight went: the gold seal of crossed
## swords for a raid won, the red sword for one lost, the silver shield for a
## raid held off, the red gauntlet for a raid that took gold. The opponent is on
## its upper plate as every screen draws a lord (Look.paint_name: the colour they
## wear, Royal Favour's seal beside the name), what happened and when on the
## lower, the gold that moved in its box. ALL, MY RAIDS and ON ME sort the list:
## the game's tab strip (TabStrip) on tabs_sheet_c.png's short plates, the words
## painted on them -- the painting's own plates, which spelled the second MY
## RADS, are lifted from the page.

const PAGE := "history"
const TABS := ["tab_all", "tab_mine", "tab_on_me"]
## Each tab's plate in the strip (tabs/short_<id>), by the tab it sorts to.
const PLATES := {"tab_all": "all", "tab_mine": "my_raids", "tab_on_me": "on_me"}
const ROW_ART := {"won": "history/row_won", "lost": "history/row_lost", "held": "history/row_held",
	"raided": "history/row_raided"}
const EMPTY := {
	"tab_all": "No battles yet. Every raid you make, and every raid on you, is written here.",
	"tab_mine": "You have raided nobody yet. The Attack tab has lords to choose from.",
	"tab_on_me": "Nobody has raided you yet.",
}
const GAIN := Color("#EFC53A")
## The name plate's own ivory, for a lord who wears no colour.
const INK := Color("#F1E9DA")


## `entries` is /v1/attack/history's list; `replay` is called with an entry to
## play it back. `opts` goes to PaintedPage.open (a test's inset).
static func open(host: Node, entries: Array, replay: Callable, opts: Dictionary = {}) -> PaintedPage:
	var p := PaintedPage.open(host, PAGE, opts)
	p.set_meta("entries", entries)
	p.set_meta("replay", replay)
	var spec := Layout.find(PAGE, "tabs")
	var r := Layout.rect_of(spec)
	# The plates at the painting's word size (the layout's plate_h), the tap
	# areas the band's full height.
	var painted := Art.tex(TabStrip.plate_name(PLATES["tab_all"], true)).get_height()
	var strip := TabStrip.make(PLATES.values(), Rect2(Vector2.ZERO, r.size), PLATES["tab_all"],
		float(spec.get("plate_h", painted)) / float(painted))
	p.place(strip, r)
	p.set_meta("tabs", strip)
	strip.changed.connect(func(id: String) -> void: show_tab(p, str(PLATES.find_key(id))))
	show_tab(p, "tab_all")
	return p


## The strip of ALL / MY RAIDS / ON ME, for tests.
static func tabs(p: PaintedPage) -> TabStrip:
	return p.get_meta("tabs", null)


## [what happened, the opponent, its colour], from the player's side. The
## Attack tab's own history rows say it the same way.
static func words(e: Dictionary) -> Array:
	var won := bool(e.get("won", false))
	var name := str(e.get("opponent_name", ""))
	if bool(e.get("raided", false)):
		return ["Held off" if won else "Raided by", name, UI.GREEN if won else UI.RED]
	return ["Victory" if won else "Defeat", "vs. " + name, UI.GREEN if won else UI.RED]


## won / lost (the player's raids), held / raided (raids on the player).
static func outcome(e: Dictionary) -> String:
	var won := bool(e.get("won", false))
	if bool(e.get("raided", false)):
		return "held" if won else "raided"
	return "won" if won else "lost"


## The list under one tab: all of it, the player's own raids, or the raids on them.
static func show_tab(p: PaintedPage, tab: String) -> void:
	var strip := tabs(p)
	if strip != null and PLATES.has(tab):
		strip.select(PLATES[tab])
	var shown: Array = []
	for e in p.get_meta("entries", []):
		var raided := bool(e.get("raided", false))
		if tab == "tab_all" or (tab == "tab_on_me") == raided:
			shown.append(e)
	var content := p.content("list")
	for c in content.get_children():
		c.queue_free()
	var tpl := Layout.find(PAGE, "row")
	var pitch := float(tpl.get("pitch", 121))
	var row_h := Layout.rect_of(tpl).size.y
	var replay: Callable = p.get_meta("replay")
	for i in shown.size():
		var built := Layout.instantiate(tpl)
		built["node"].position = Vector2(0, i * pitch)
		built["node"].set_meta("parts", built["parts"])
		content.add_child(built["node"])
		# Each plate's width as the layout measures it: a Label is built
		# around its sample and has already grown to it.
		for part in tpl.get("parts", []):
			if str(part.get("kind", "")) == "text":
				built["parts"][str(part["id"])].set_meta("box_w", Layout.rect_of(part).size.x)
		_paint_row(built["parts"], shown[i], Layout.rect_of(_part(tpl, "name")))
		var e: Dictionary = shown[i]
		# Not in the quarter second after the page opens, as the host's own
		# buttons: the tap that opened it cannot play a fight.
		(built["parts"]["tap"] as BaseButton).pressed.connect(func() -> void:
			if bool(p.get("_armed")):
				replay.call(e))
	var sc := p.node("list") as ScrollContainer
	content.custom_minimum_size.y = maxf(sc.size.y, shown.size() * pitch - (pitch - row_h))
	sc.scroll_vertical = 0
	p.set_shown("empty", shown.is_empty())
	if shown.is_empty():
		p.set_text("empty", EMPTY.get(tab, EMPTY["tab_all"]), 20)


static func _part(tpl: Dictionary, id: String) -> Dictionary:
	for part in tpl.get("parts", []):
		if str(part.get("id", "")) == id:
			return part
	return {}


static func _paint_row(parts: Dictionary, e: Dictionary, name_box: Rect2) -> void:
	(parts["art"] as TextureRect).texture = Art.tex(ROW_ART[outcome(e)])
	# The opponent as every screen draws a lord: the colour they wear (the
	# plate's ivory when none), Royal Favour's seal after the name when they
	# have it, the name shrunk to what the seal leaves.
	var look: Variant = e.get("opponent_look", {})
	Look.paint_name(parts["name"], look if look is Dictionary else {}, str(e.get("opponent_name", "")),
		name_box, 28, 18, INK)
	var lvl := int(e.get("opponent_level", 0))
	var what := str(words(e)[0])
	_fit(parts["detail"], "%s%s  ·  %s" % [what, ("  ·  Level %d" % lvl) if lvl > 0 else "",
		UI.ago(_seconds_since(str(e.get("at", ""))))], 15)
	var gold := int(str(e.get("gold", "0")))
	var g: Label = parts["gold"]
	g.label_settings.font_color = UI.RED if gold < 0 else GAIN
	var sign := "+" if gold > 0 else ("-" if gold < 0 else "")
	# Every figure while it fits the box at a size that reads; past that --
	# a raid that took a late-game purse -- the short form (+987.65M).
	if not _fit(g, sign + UI.grouped(absi(gold)), 20):
		_fit(g, sign + UI.short_number(absi(gold)), 20)


## Words set at the layout's size, down to `min_size` to fit the plate's width
## (the layout's, remembered: a Label grows to its text). A `line` that still
## runs long ends in an ellipsis. Returns whether the words fit whole.
static func _fit(l: Label, text: String, min_size: int, line: bool = false) -> bool:
	if not l.has_meta("box_w"):
		l.set_meta("box_w", l.size.x)
	var painted := int(l.get_meta("painted_size", l.label_settings.font_size))
	l.set_meta("painted_size", painted)
	l.label_settings.font_size = painted
	l.text = text
	if line:
		UI.fit_line(l, painted, min_size)
	else:
		UI.fit_label(l, painted, min_size)
		# Back to the box's own width, so centred words centre on the plate and
		# not on the sample the Label was built around.
		l.size.x = float(l.get_meta("box_w"))
	var s := l.label_settings
	return s.font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, s.font_size).x <= float(l.get_meta("box_w"))


static func _seconds_since(iso: String) -> int:
	if iso == "":
		return 0
	var then := Time.get_unix_time_from_datetime_string(iso.trim_suffix("Z"))
	return maxi(0, int(Time.get_unix_time_from_system()) - int(then))
