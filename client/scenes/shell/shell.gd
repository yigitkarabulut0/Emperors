extends Control
## The game shell: left icon rail, top status bar, content area, bottom action.
##
## The rail is always visible and one tap from anywhere, which is what the
## reference game does too. The bottom strip is deliberately reserved for the
## primary action of the current section — it is the only part of a tall phone
## the thumb reaches comfortably, and this game is mostly one repeated tap.

## The navigation rail.
##
## Names are literal on purpose. "Keep", "Fields", "Armory", "War Gate" and "Map"
## are good flavour and tell a new player nothing about what is behind them --
## the reference game calls its screens Jobs, Properties, Crew, Bank, Fight, and
## you always know where you are. The flavour moved into the screens themselves.
##
## One entry does one thing. Bank and House used to be buttons buried inside the
## Keep, which made the Keep a grab bag of five unrelated things and put the
## clan system two taps deep behind a line of text.
## All nine, in the order SECTIONS declares them, which puts House last.
##
## They were six for a while, at the reference's full plate height of 119 units,
## with the other three behind a plate at the foot. Six is what fits at that
## height -- but a section you have to go looking for is worse than a slightly
## smaller plate, so the plates are 86 and every section is on the column.
const SECTIONS := [
	{"id": "hero", "icon": "keep", "glyph": "H", "label": "Hero"},
	{"id": "jobs", "icon": "fields", "glyph": "J", "label": "Jobs"},
	{"id": "shop", "icon": "market", "glyph": "S", "label": "Shop"},
	{"id": "items", "icon": "armory", "glyph": "I", "label": "Items"},
	{"id": "estates", "icon": "territory", "glyph": "E", "label": "Estates"},
	{"id": "army", "icon": "barracks", "glyph": "A", "label": "Army"},
	{"id": "bank", "icon": "bank", "glyph": "B", "label": "Bank"},
	{"id": "fight", "icon": "war_gate", "glyph": "F", "label": "Fight"},
	{"id": "house", "icon": "house", "glyph": "K", "label": "House"},
]

## Measured off the reference rather than chosen.
##
## The reference is 941 px wide and its rail is 213 -- 22.6% -- which on this
## project's 720-unit grid is 163. Everything below comes from the same
## measurement, at the same scale:
##
##   plate height  156 px -> 119 units
##   gap           8 px   -> 6 units
##   portrait      138 px -> 106 units
##
## 156 is what makes it look drawn rather than fitted, and it is why this is not
## simply the old rail made wider.
##
## 152, not 163: tabs_fit derives every tab's width budget from this, and the
## shell's own minimum is rail + content. 163 left five units of the screen
## spare, which is not a margin.
const RAIL_WIDTH := 160

## The rail's own tap height, separate from UI.TAP_MIN so that shrinking the
## rail does not shrink every button in the game.
##
## The FLOOR, not the height. Since the plates share out whatever the column has
## left, this is only what the shortest device we ship to -- an iPad 10.9 -- can
## afford. Every phone gives them more: on a 16 Pro Max they come out near 110.
##
## Lowering it therefore costs nothing on a phone and buys the iPad room, which
## is why it is 86 and not the 96 that once had to be the real height.
const RAIL_TAP := 78

## How often the client says it is still here.
##
## The server treats silence past 90 seconds as gone, so thirty is three beats
## of headroom -- one lost request on a train must not read as leaving.
const BEAT_SECONDS := 30.0
## The icon is the entry and the word under it is the caption -- which is the
## proportion the reference draws, and the one this kept getting backwards.
const ICON_SIZE := 52

## The gap between two carved plates.
##
## Small, and deliberately smaller than it was: the room is better spent inside
## the plates than between them. Each one still has its own carved edge, which is
## what separates them; the gap only has to stop two bevels touching.
const RAIL_GAP := 2

## The margin of bare stone down either side of a plate.
##
## Two numbers have to clear before a single unit of it is visible: the plate
## skin's own six-unit nine-slice bleed, and the eight the rail's carved frame
## occupies down each edge.
##
## Ten, down from twenty, because the twenty was compensating for a bug.
##
## The plate skin was drawing 14 units outside its button on every side -- see
## UI.SKIN_GEOM -- so the inset had to swallow that before it bought anything,
## and the plates came out small in the middle of the column. With the skin drawn
## in the rect it is given, ten is enough: the button is 140 wide, its body 134,
## sitting between the frame's inner lips at 8 and 152 with four units clear.
const RAIL_PAD := 10

## The margin every card and the action button keep from the screen's edge.
##
## It has to be at least UI.SKIN_BLEED, because a nine-slice is DRAWN that far
## outside the rect it is given. At ten and twelve every card in the game was
## being painted two to four units off-screen, and on a phone -- where the
## display's own corner radius eats the last few units as well -- that read as
## cards with their corners sliced off.
##
## SKIN_BLEED covers the over-draw; CORNER covers the display's radius. Both are
## in here rather than split between this and the row's inset, and that is the
## whole point: the rail absorbs the left-hand corner allowance by bleeding to
## the edge, so charging it to the ROW made the card's right-hand gap twelve
## units bigger than its left-hand one. Charged to the CARD instead, the two gaps
## either side of it are the same number.
const EDGE := UI.SKIN_BLEED + UI.CORNER

## Short enough that spamming Collect never leaves the counter visibly behind the
## real balance, long enough to read as movement.
const GOLD_ROLL_SECONDS := 0.30
## The portrait from the reference, scaled: 138 px of 941 is 106 units.
##
## The crest does not share out the column's spare height -- the nine sections do
## -- so this number IS the size it appears at, on every device. That is why it
## is set close to the reference's rather than trimmed for the iPad: the plates
## below absorb the difference by starting from a lower floor.
const AVATAR_SIZE := 98

## Floors, not fixed heights. The top bar sizes to its own content and the action
## host to the tallest bar any section mounts; these only stop them collapsing.
## The safe-area inset is added on top of both at runtime, so the numbers here
## stay device-independent.
##
## 76. The reference's banner is 75 px of 1672 -- 4.5% -- which is 57 units
## here; 76 is the floor its contents actually need, a coin chip plus padding
## plus the experience thread. The rail's plates are what the difference buys.
const TOPBAR_MIN_H := 76

## 116 for the button, a line of caption under it, and margins. Measured on an
## iPhone SE, which is the tightest device: at 164 the caption grazed the edge.
const ACTION_H := 134


var _avatar_btn: Button
var _avatar_img: TextureRect
var _diamonds: Label

## Section id -> the tab node, and -> its action bar. Both are kept alive for
## the lifetime of the shell; see _open().
var _tabs: Dictionary = {}
var _rail_locks: Dictionary = {}
var _action_bars: Dictionary = {}

var _gold_shown := 0
var _gold_seen := false
var _gold_tween: Tween

var _current := "jobs"
var _rail_buttons: Dictionary = {}
var _content: Control
var _action_host: Control
var _toast: Label
var _dev_act := false

# top bar
var _level: Label
var _gold: Label
var _energy: Label
var _xp_bar: ProgressBar

## The screen's own title, retitled on every section change. The tabs never had
## one: the shell knew which section was open and the screen never said so.
var _title: Control

# Chrome that has to be re-inset whenever the safe area changes.
var _topbar_panel: PanelContainer
var _topbar_pad: MarginContainer
var _middle_pad: MarginContainer
var _rail_pad: MarginContainer


func _ready() -> void:
	# Parchment, tiled, running to every edge -- including behind the toast and
	# the action strip, so the ground is continuous rather than a panel floating
	# on a colour.
	var bg := TextureRect.new()
	bg.texture = ArtRegistry.ui_icon("tile/parchment")
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_TILE
	# Godot 4 carries repeat on the node rather than the import; without it the
	# tile is stretched once over the whole screen, silently.
	bg.texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 0)
	add_child(root)

	root.add_child(_build_top_bar())

	# The rail and the content share one inset from the screen's edges.
	#
	# They did not, and that is why the right margin looked bigger than the left:
	# the content carried the right-hand safe inset itself while the rail sat hard
	# against x=0, so on a phone the page had 38 units of ground down one side and
	# 20 down the other. Insetting the row instead means the two edges are the
	# same number by construction, on every device, whatever it reports.
	_middle_pad = MarginContainer.new()
	_middle_pad.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(_middle_pad)

	var middle := HBoxContainer.new()
	middle.size_flags_vertical = Control.SIZE_EXPAND_FILL
	middle.add_theme_constant_override("separation", 0)
	_middle_pad.add_child(middle)

	middle.add_child(_build_rail())

	# The title belongs to the shell, not to the nine tabs. It is one node here
	# against nine near-identical edits there, and the wording then has a single
	# source -- SECTIONS, which is the same table the rail is built from.
	var content_col := VBoxContainer.new()
	content_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content_col.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content_col.add_theme_constant_override("separation", UI.GAP_S)
	middle.add_child(content_col)

	_title = UI.screen_title("")
	content_col.add_child(_title)

	_content = MarginContainer.new()
	_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	for side in ["left", "right", "top", "bottom"]:
		(_content as MarginContainer).add_theme_constant_override("margin_" + side, EDGE)
	content_col.add_child(_content)

	_toast = UI.label("", UI.F_CAPTION, Palette.DANGER, HORIZONTAL_ALIGNMENT_CENTER)

	_action_host = MarginContainer.new()
	_action_host.custom_minimum_size = Vector2(0, ACTION_H)
	for side in ["left", "right"]:
		(_action_host as MarginContainer).add_theme_constant_override("margin_" + side, EDGE)
	(_action_host as MarginContainer).add_theme_constant_override("margin_bottom", EDGE)
	root.add_child(_action_host)

	# The toast is anchored over the action strip rather than given a row of its
	# own. It is empty for all but a couple of seconds at a time, and it was
	# holding thirty units open permanently to say nothing -- thirty units the
	# rail's plates now have. Added last so it draws over the button.
	_toast.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_toast.anchor_left = 0.0
	_toast.anchor_right = 1.0
	_toast.anchor_top = 1.0
	_toast.anchor_bottom = 1.0
	_toast.grow_vertical = Control.GROW_DIRECTION_BEGIN
	add_child(_toast)

	# Holds the player in place through an outage instead of letting them fall
	# back to the sign-in screen, which is where a lost connection used to end.
	add_child(load("res://scenes/shell/reconnect.gd").new())

	_apply_safe_insets()
	get_tree().root.size_changed.connect(_apply_safe_insets)
	if Env.fake_safe_area_on:
		get_tree().root.add_child.call_deferred(SafeArea.debug_overlay())

	GameState.changed.connect(_on_state_changed)
	GameState.action_failed.connect(_on_action_failed)
	GameState.level_up.connect(_celebrate_level)
	# Once on entry too: most sessions start cold rather than by resuming.
	_show_daily_if_due.call_deferred()
	GameState.mastery_reached.connect(_celebrate_mastery)

	# Dev-only: fire the section's primary action once the tab is open, so a
	# capture run (which disables input) can reach a screen that only exists
	# after an action — a battle replay, for instance.
	for i in OS.get_cmdline_user_args().size():
		var a2 := OS.get_cmdline_user_args()
		if a2[i] == "--dev-act":
			_dev_act = true

	# Dev-only: open a specific section for a proof capture.
	for i in OS.get_cmdline_user_args().size():
		var a := OS.get_cmdline_user_args()
		if a[i] == "--dev-tab" and i + 1 < a.size():
			_current = a[i + 1]

	_open(_current)
	_on_state_changed()

	# Dev-only: hammer the section switcher. This is the shape that crashed --
	# leaving a section while its HTTP request is still in the air -- so it is
	# worth being able to reproduce on demand.
	for i in OS.get_cmdline_user_args().size():
		var ta := OS.get_cmdline_user_args()
		if ta[i] == "--dev-thrash" and i + 1 < ta.size():
			_thrash(int(ta[i + 1]))
			return

	# Dev-only: open the portrait picker for a proof capture, since a capture run
	# disables input and cannot press the button itself.
	if OS.get_cmdline_user_args().has("--dev-avatars"):
		_open_avatar_picker()

	# Dev-only: put a sample confirmation up, for the same reason.
	if OS.get_cmdline_user_args().has("--dev-confirm"):
		Confirm.ask(self, {
			"title": "Sell this?",
			"body": "Guard's Breastplate (UNCOMMON) is gone for good.",
			"cost": {"amount": 103, "currency": "gold"},
			"confirm_text": "Sell", "danger": true})

	if _dev_act:
		await get_tree().create_timer(1.2).timeout
		for c in _action_host.get_children():
			_press_first_button(c)

	_prefetch()

	# A 4 Hz tick drives only the two numbers that move on their own (the energy
	# bar and its countdown). Everything else redraws on `changed`, so no node
	# polls state per frame.
	var t := Timer.new()
	t.wait_time = 0.25
	t.autostart = true
	t.timeout.connect(_tick)
	add_child(t)

	# And one call home every thirty seconds, which is the ONLY request this
	# client makes while nobody is touching it.
	#
	# That is the point. Everything above redraws from local projections, so a
	# player who opens the game and puts the phone down was, from the server's
	# side, indistinguishable from one who closed it -- and the live board had to
	# guess. This is what turns the guess into a fact.
	var beat := Timer.new()
	beat.wait_time = BEAT_SECONDS
	beat.autostart = true
	beat.timeout.connect(_beat)
	add_child(beat)


## Builds the other sections in the background so opening one is instant.
##
## A tab is built on first open and fetches over HTTP, so the first tap on every
## section showed an empty screen for a round trip. They are all cached after
## that, which is why only the first tap felt slow -- and the first tap is the one
## that forms the impression.
##
## Staggered rather than fired at once: nine simultaneous requests would queue
## behind two lanes anyway and would delay the section the player is actually
## looking at. The order is the order people reach for.
func _prefetch() -> void:
	await get_tree().create_timer(0.4).timeout
	for id in ["hero", "shop", "items", "army", "estates", "bank", "fight", "house"]:
		if not is_instance_valid(self):
			return
		if _tabs.has(id) or not _unlocked(id):
			continue
		_build_tab(id)
		# A freshly built tab is visible by default and would land on top of the
		# section the player is actually looking at.
		_show_only(_current)
		# One at a time. The point is to be ready before the player asks, not to
		# be ready first.
		await get_tree().create_timer(0.35).timeout


## Opens the portrait picker over everything.
func _open_avatar_picker() -> void:
	var picker: CanvasLayer = load("res://scenes/shell/avatar_picker.gd").new(
		str(GameState.player().get("avatar", "knight")))
	add_child(picker)


## Cycles every section `rounds` times with barely a frame between, so requests
## are always still outstanding when the section changes, then quits.
func _thrash(rounds: int) -> void:
	var ids: Array[String] = []
	for sec in SECTIONS:
		ids.append(str(sec["id"]))
	for r in rounds:
		for id in ids:
			_open(id)
			await get_tree().process_frame
			await get_tree().process_frame
	print("[thrash] survived ", rounds * ids.size(), " section switches")
	get_tree().quit(0)


func _build_top_bar() -> Control:
	_topbar_panel = PanelContainer.new()
	# The panel bleeds all the way to y=0 on purpose. Insetting the chrome itself
	# would leave a strip of background under the Dynamic Island, which is the
	# most obvious "this is a port" tell there is; only the PADDING moves.
	_topbar_panel.add_theme_stylebox_override("panel", UI.skin("banner", Palette.BANNER, 0, 0))
	_topbar_panel.custom_minimum_size = Vector2(0, TOPBAR_MIN_H)

	_topbar_pad = MarginContainer.new()
	_topbar_panel.add_child(_topbar_pad)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", UI.GAP_M)
	_topbar_pad.add_child(row)

	# Experience, as a thread laid along the banner's bottom edge.
	#
	# It was a bar with its own groove under the coins, and an empty groove is
	# what it is for all of a new session -- a broken-looking strip across the
	# top of the game. The reference has nothing there at all. This keeps the one
	# figure that says "you are getting somewhere" without spending a row on it:
	# no background, three units tall, anchored to the panel rather than laid out
	# in it, so it costs the banner no height.
	_xp_bar = ProgressBar.new()
	_xp_bar.show_percentage = false
	_xp_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_xp_bar.anchor_left = 0.0
	_xp_bar.anchor_right = 1.0
	_xp_bar.anchor_top = 1.0
	_xp_bar.anchor_bottom = 1.0
	_xp_bar.offset_top = -5
	_xp_bar.offset_bottom = -2
	_xp_bar.add_theme_stylebox_override("background", StyleBoxEmpty.new())
	_xp_bar.add_theme_stylebox_override(
		"fill", UI.panel_box(Palette.GOLD, Color.TRANSPARENT, 0))
	_topbar_panel.add_child(_xp_bar)

	# The purse, centred between two laurels. One row, where it used to be two: a
	# portrait, a name and an experience bar over a full-width energy meter. The
	# portrait moved to the rail, the name to the portrait's tooltip and the Hero
	# card that already printed it, and the energy meter became the third coin.
	#
	# The wordmark is gone from here. It said SPQR on every screen of a game
	# called Emperors, which is the one thing the player never needs telling, and
	# it pushed the three figures they DO read off to one side.
	row.add_child(_ornament("orn/laurel_l", 64, 24))

	var lead := Control.new()
	lead.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(lead)

	_gold = _purse_chip(row, "coin", Palette.GOLD)
	_diamonds = _purse_chip(row, "gem", Palette.DIAMOND)
	_energy = _purse_chip(row, "bolt", Palette.ENERGY)

	var trail := Control.new()
	trail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(trail)

	row.add_child(_ornament("orn/laurel_r", 64, 24))

	return _topbar_panel


## Pushes the current safe-area insets into the four pieces of chrome that touch
## a screen edge.
##
## Panels keep bleeding to the edge; only their padding moves, so the dark bar
## still runs under the Dynamic Island and the rail still runs to x=0. The action
## host is the one that actually mattered: a 12-unit bottom margin put the
## primary button of every screen inside the home-indicator gesture zone.
func _apply_safe_insets() -> void:
	var i := SafeArea.insets()

	_topbar_pad.add_theme_constant_override("margin_left", UI.GUTTER + int(i.x))
	_topbar_pad.add_theme_constant_override("margin_right", UI.GUTTER + int(i.z))
	_topbar_pad.add_theme_constant_override("margin_top", 12 + int(i.y))
	_topbar_pad.add_theme_constant_override("margin_bottom", 12)
	_topbar_panel.custom_minimum_size.y = TOPBAR_MIN_H + int(i.y)

	# The row is already inset, so the rail's own padding is symmetric.
	_rail_pad.add_theme_constant_override("margin_left", RAIL_PAD)
	# Only what a device reports BEYOND the corner allowance -- a landscape notch,
	# an Android cutout. The ordinary rounded-corner case leaves this at zero, so
	# the rail's stone runs to the screen's edge the way the reference draws it,
	# and the corner clips stone rather than a card. EDGE carries the allowance
	# for anything that must not be clipped.
	_middle_pad.add_theme_constant_override("margin_left", maxi(0, int(i.x) - UI.CORNER))
	_middle_pad.add_theme_constant_override("margin_right", maxi(0, int(i.z) - UI.CORNER))

	(_content as MarginContainer).add_theme_constant_override("margin_right", EDGE)
	(_content as MarginContainer).add_theme_constant_override("margin_left", EDGE)

	(_action_host as MarginContainer).add_theme_constant_override(
		"margin_bottom", EDGE + int(i.w))
	(_action_host as MarginContainer).add_theme_constant_override("margin_left", EDGE + int(i.x))
	(_action_host as MarginContainer).add_theme_constant_override("margin_right", EDGE + int(i.z))
	_action_host.custom_minimum_size.y = ACTION_H + int(i.w)

	var above := ACTION_H + int(i.w)
	_toast.offset_top = -above - 34
	_toast.offset_bottom = -above


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_RESUMED:
		# The safe area can change while backgrounded: rotating the phone on the
		# home screen is the everyday case.
		if _topbar_pad != null:
			_apply_safe_insets.call_deferred()
		# Back in the player's hands. Say so now rather than up to thirty
		# seconds from now.
		_beat()
		# And it may be a new day where they are. The panel asks the server and
		# shows nothing if today's square is already taken.
		_show_daily_if_due()
	elif what == NOTIFICATION_APPLICATION_PAUSED:
		# Best effort, and it has to be: iOS stops the display link as this
		# fires, so an awaited request would never resume. Api.beacon writes and
		# returns. If it lands, the board shows the departure immediately; if it
		# does not, the presence timeout catches it a minute later.
		if Session.is_signed_in():
			Api.beacon("/v1/presence", {"state": "leaving"})


## One currency readout: its glyph, then its number, stamped into stone.
##
## chip_box, not panel_box: panel_box carries 10 units of padding above and
## below for a card, and two of these stacked came to 142 units, which is what
## pushed the shell's column past the viewport on an iPhone SE. They are side by
## side now, which is what the single-row banner bought.
func _purse_chip(host: Control, icon: String, tint: Color) -> Label:
	var box := PanelContainer.new()
	# The small nine-slice family. The standard one slices at 42 units a side,
	# and a chip is about 36 tall -- two 42s do not fit inside 36 and Godot
	# resolves that by squashing both into mush.
	box.add_theme_stylebox_override("panel", UI.skin("chip", Palette.RAIL, 10, 2))
	box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", 6)
	box.add_child(line)
	line.add_child(_glyph("currency/" + icon, UI.ICON_SM, tint))
	# Tabular figures. Without them this reflows horizontally every time it
	# rolls 1,199 -> 1,200, and it is redrawn four times a second.
	var value := UI.number_label("0", UI.F_BODY, Palette.TEXT, HORIZONTAL_ALIGNMENT_RIGHT)
	line.add_child(value)
	host.add_child(box)
	return value


## A rail glyph with a shadow under it, so it reads as cut into the plate.
##
## The reference's icons are painted objects with their own light; these are one
## flat path each, which is the right call at this size and is what lets the
## client tint a single texture gold when a section is open. Drawing the same
## texture twice -- once dark and offset, once in its real colour -- buys most of
## that depth back for six lines and keeps the tinting.
func _relief_icon(tex: Texture2D, size: int) -> Control:
	var host := Control.new()
	host.custom_minimum_size = Vector2(size, size)
	host.mouse_filter = Control.MOUSE_FILTER_IGNORE

	for pass_index in 2:
		var t := TextureRect.new()
		t.texture = tex
		t.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		t.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		t.set_anchors_preset(Control.PRESET_FULL_RECT)
		t.mouse_filter = Control.MOUSE_FILTER_IGNORE
		if pass_index == 0:
			# The shadow, down and right by a unit and a half.
			t.offset_left = 2
			t.offset_top = 2
			t.offset_right = 2
			t.offset_bottom = 2
			t.modulate = Color(0, 0, 0, 0.28)
		host.add_child(t)
	return host


## A gold ornament that never takes a tap and never forces a row taller.
func _ornament(key: String, w: int, h: int) -> TextureRect:
	var t := TextureRect.new()
	t.texture = ArtRegistry.ui_icon(key)
	# expand_mode first: without it a TextureRect reports the SOURCE texture's
	# size as its minimum, and a 288 px branch would set the banner's height.
	t.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	t.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	t.custom_minimum_size = Vector2(w, h)
	t.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	t.modulate = Palette.GOLD
	t.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return t


func _glyph(name: String, size: int, tint: Color) -> TextureRect:
	var t := TextureRect.new()
	t.texture = ArtRegistry.ui_icon(name)
	t.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	t.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	t.custom_minimum_size = Vector2(size, size)
	t.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	t.modulate = tint
	return t


func _build_rail() -> Control:
	# A plain Control, NOT a PanelContainer.
	#
	# A Container lays its children out itself and ignores their anchors, so the
	# marble, the carved edge and the eagle were all stretched to the full rail
	# whatever anchors they carried. The eagle in particular was being drawn a
	# hundred and twenty units wide down the middle of the column, faint enough
	# to read as a stone panel with a gear sitting on it rather than as a bug.
	#
	# A plain Control positions nothing, so anchors mean what they say -- which
	# is also what keeps these three decorations out of the vertical budget.
	var panel := Control.new()
	panel.custom_minimum_size = Vector2(RAIL_WIDTH, 0)

	# The marble, and the eagle at its foot, are ANCHORED SIBLINGS of the padding
	# rather than rows in the column. A PanelContainer sizes to the largest
	# minimum among its children, and a TextureRect with EXPAND_IGNORE_SIZE
	# reports only its own custom_minimum_size -- so both of these cost the
	# column no height at all. That is what pays for the portrait above.
	var marble := TextureRect.new()
	marble.texture = ArtRegistry.ui_icon("tile/marble")
	marble.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	marble.stretch_mode = TextureRect.STRETCH_TILE
	# Godot 4 carries repeat on the node, not on the import. Without this the
	# tile is stretched once across the whole rail, silently and with no error.
	marble.texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
	marble.set_anchors_preset(Control.PRESET_FULL_RECT)
	marble.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(marble)

	# The carved edge. Its centre is transparent, so the marble tiles through it
	# and the frame stretches to any height without smearing the stone.
	var frame := NinePatchRect.new()
	frame.texture = ArtRegistry.ui_icon("chrome/rail_frame")
	frame.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "top", "right", "bottom"]:
		frame.set("patch_margin_" + side, 8)
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(frame)

	# No eagle at the foot any more.
	#
	# It was anchored to the bottom of the rail, which worked only because the
	# column ended well short of it -- and that gap of bare stone is exactly what
	# looked wrong. The plates fill the column now, so there is nowhere for it to
	# stand.

	# The rail panel bleeds to x=0; only its buttons move in from a left inset,
	# which is zero in portrait but not on an Android cutout or in landscape.
	_rail_pad = MarginContainer.new()
	_rail_pad.set_anchors_preset(Control.PRESET_FULL_RECT)
	# Room down both sides for the plates' own bleed.
	#
	# The plate skin is a nine-slice with a six-unit expand margin, which draws it
	# SIX UNITS WIDER THAN ITS BUTTON on each side. With the buttons filling the
	# rail edge to edge, every plate was being drawn 12 units past the column and
	# over the content beside it -- which is what "the buttons do not sit in their
	# area" was.
	#
	# And a little air at the top, so the portrait is not jammed against the
	# banner's lower edge.
	_rail_pad.add_theme_constant_override("margin_right", RAIL_PAD)
	# The top gets the same margin as the sides, and for the same reason: the
	# frame's carved band is eight units deep there too -- see patch_margin_top
	# above -- and RAIL_PAD is the number that clears it with a little air left.
	#
	# It was RAIL_GAP, the two units the plates keep from EACH OTHER, which is a
	# different measurement doing a different job. At two the crest plate started
	# inside the frame's top lip, so its own stone edge was drawn over the rail's
	# border and the portrait read as having slid up out of the column.
	_rail_pad.add_theme_constant_override("margin_top", RAIL_PAD)
	_rail_pad.add_theme_constant_override("margin_bottom", UI.GAP_S)
	panel.add_child(_rail_pad)

	# NOT a ScrollContainer.
	#
	# The rail was briefly wrapped in one so that overflow would degrade to
	# scrolling instead of clipping. On a phone that is a trap: a scroll view
	# running the full height of the left edge captures vertical drags, so every
	# swipe that starts anywhere near it scrolls a rail that does not need
	# scrolling instead of the list the player is trying to move. The cure was
	# worse than the disease, and shell_fits.gd already guarantees the whole rail
	# fits on every device we ship to.
	var col := VBoxContainer.new()
	col.name = "RailColumn"    # shell_fits.gd measures this node by name
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# One rhythm the whole way down: the crest is the first plate in the stack,
	# not a header above it.
	col.add_theme_constant_override("separation", RAIL_GAP)
	_rail_pad.add_child(col)

	# The crest takes a share of the spare column, WEIGHTED.
	#
	# Not expanding at all left it stuck at its minimum while the nine plates grew
	# into the leftover height, so it came out smaller than every one of them.
	# Expanding it unweighted was worse: one item against a box of nine took half
	# the column and made a tall empty plate with a small portrait in it.
	#
	# The ratio is what settles it. The nav box carries nine plates and asks for
	# nine shares; the crest asks for 1.4, so it ends up half again as tall as a
	# section -- which is what a portrait wants and what the reference draws.
	var crest_plate := _build_crest()
	crest_plate.size_flags_vertical = Control.SIZE_EXPAND_FILL
	crest_plate.size_flags_stretch_ratio = 1.4
	col.add_child(crest_plate)

	var nav := VBoxContainer.new()
	# A gap now, where there was none. Nine plates with marble between them read
	# as stones set into a column; nine flush buttons read as one strip with
	# lines drawn on it, which is what this was.
	nav.add_theme_constant_override("separation", RAIL_GAP)
	nav.size_flags_vertical = Control.SIZE_EXPAND_FILL
	nav.size_flags_stretch_ratio = float(SECTIONS.size())
	col.add_child(nav)

	for s in SECTIONS:
		var b := Button.new()
		b.custom_minimum_size = Vector2(0, RAIL_TAP)
		# RAIL_TAP is a FLOOR, and the rest of the column is shared out.
		#
		# It used to be the fixed height, so on anything taller than the iPad the
		# nine plates ended partway down and left a hand's width of bare stone
		# under them. The floor is what the shortest device we ship to can afford;
		# every device with more gives it to the plates.
		b.size_flags_vertical = Control.SIZE_EXPAND_FILL
		b.focus_mode = Control.FOCUS_NONE
		b.tooltip_text = str(s["label"])
		b.pressed.connect(_open.bind(str(s["id"])))

		var inner := VBoxContainer.new()
		inner.mouse_filter = Control.MOUSE_FILTER_IGNORE
		inner.set_anchors_preset(Control.PRESET_FULL_RECT)
		inner.alignment = BoxContainer.ALIGNMENT_CENTER
		inner.add_theme_constant_override("separation", 2)
		# EXPAND_IGNORE_SIZE matters: without it a TextureRect reports the source
		# texture's own size as its minimum, and a 96 px icon would force the
		# 72 px rail button to grow.
		var tex := ArtRegistry.ui_icon(str(s["icon"]))
		if tex != null:
			inner.add_child(_relief_icon(tex, ICON_SIZE))
		else:
			# An unshipped icon must not leave an unlabelled button. Both branches
			# tint through the same call below, so _style_rail needs no branch.
			var glyph := UI.label(str(s["glyph"]), UI.F_H1, Color.WHITE, HORIZONTAL_ALIGNMENT_CENTER)
			glyph.modulate = Palette.TEXT_DIM
			glyph.custom_minimum_size = Vector2(0, ICON_SIZE)
			inner.add_child(glyph)
		# Mixed case, and the body serif rather than the display face. Small
		# capitals at F_MICRO read as a legend under a diagram; the reference
		# labels these the way it labels everything else.
		inner.add_child(UI.label(str(s["label"]), UI.F_CAPTION, Palette.TEXT_DIM,
			HORIZONTAL_ALIGNMENT_CENTER))
		b.add_child(inner)

		nav.add_child(b)
		_rail_buttons[str(s["id"])] = b

		# The unlock level rides in the corner rather than as a third line. Icon
		# plus name plus level came to 98 units inside an 88-unit button, so the
		# rail overflowed and "House" sat on top of "lv 20". Seeing what is coming
		# is worth keeping -- it just cannot cost vertical space.
		var lock := PanelContainer.new()
		lock.mouse_filter = Control.MOUSE_FILTER_IGNORE
		lock.add_theme_stylebox_override("panel", UI.skin("plaque", Palette.RAIL, 6, 1))
		lock.anchor_left = 1.0
		lock.anchor_right = 1.0
		lock.offset_left = -40
		lock.offset_top = 0
		lock.grow_horizontal = Control.GROW_DIRECTION_BEGIN
		b.add_child(lock)
		var lock_text := UI.number_label("", UI.F_MICRO, Palette.TEXT_DIM, HORIZONTAL_ALIGNMENT_CENTER)
		lock.add_child(lock_text)
		_rail_locks[str(s["id"])] = lock

	return panel


## One entry of SECTIONS by id.
func _section(id: String) -> Dictionary:
	for sec in SECTIONS:
		if str(sec["id"]) == id:
			return sec
	return {}


## The player, at the head of their own rail: portrait in a gold ring, with the
## level stamped on a stone plate under it.
##
## It was in the top bar, which is where this genre usually puts it, and which
## cost the bar a whole row. In asynchronous PvP you never meet an opponent --
## they are a row on a list -- so the portrait is most of the identity either
## side has, and the rail is where it is seen on every screen rather than
## competing with the purse.
func _build_crest() -> Control:
	# The crest sits on a plate like every section does.
	#
	# It did not, and the bare marble under it read as a grey box at the head of
	# the column that lined up with nothing below it. The reference frames its
	# portrait the same way it frames everything else, and that is most of what
	# makes the rail read as one carved thing rather than as a picture with a
	# list under it.
	var plate_bg := PanelContainer.new()
	# Twelve units of vertical padding, not six. The level plate inside is itself
	# a nine-slice with a six-unit bleed, so at six it sat exactly on the crest
	# plate's lower edge and hung out of it.
	plate_bg.add_theme_stylebox_override("panel", UI.skin("nav", Palette.RAIL, 8, 8))

	var crest := VBoxContainer.new()
	crest.add_theme_constant_override("separation", 0)
	# Centred in the plate rather than stacked from its top edge.
	crest.alignment = BoxContainer.ALIGNMENT_CENTER
	crest.size_flags_vertical = Control.SIZE_EXPAND_FILL
	plate_bg.add_child(crest)

	var face := Control.new()
	face.custom_minimum_size = Vector2(AVATAR_SIZE, AVATAR_SIZE)
	face.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	face.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	crest.add_child(face)

	_avatar_btn = Button.new()
	_avatar_btn.set_anchors_preset(Control.PRESET_FULL_RECT)
	_avatar_btn.focus_mode = Control.FOCUS_NONE
	_avatar_btn.tooltip_text = "Change your portrait"
	_avatar_btn.add_theme_stylebox_override(
		"normal", UI.panel_box(Color.TRANSPARENT, Color.TRANSPARENT, 0))
	_avatar_btn.add_theme_stylebox_override(
		"hover", UI.panel_box(Palette.PANEL_HIGH, Color.TRANSPARENT, AVATAR_SIZE / 2))
	_avatar_btn.add_theme_stylebox_override(
		"pressed", UI.panel_box(Palette.PANEL, Color.TRANSPARENT, AVATAR_SIZE / 2))
	_avatar_btn.pressed.connect(_open_avatar_picker)
	face.add_child(_avatar_btn)

	# The art is inset inside the button rather than drawn at the button's size:
	# the whole tap target stays tappable while the portrait keeps its weight.
	_avatar_img = TextureRect.new()
	_avatar_img.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_avatar_img.set_anchors_preset(Control.PRESET_FULL_RECT)
	_avatar_img.offset_left = 7
	_avatar_img.offset_top = 7
	_avatar_img.offset_right = -7
	_avatar_img.offset_bottom = -7
	_avatar_img.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_avatar_img.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_avatar_btn.add_child(_avatar_img)

	# The collar sits OVER the portrait rather than behind it, and its middle is
	# transparent -- so the face shows through the hole instead of being clipped
	# to it. Added after the image so it draws on top.
	var ring := TextureRect.new()
	ring.texture = ArtRegistry.ui_icon("chrome/portrait_ring")
	ring.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	ring.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	ring.set_anchors_preset(Control.PRESET_FULL_RECT)
	ring.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_avatar_btn.add_child(ring)

	# The level rides on the portrait's lower edge rather than sitting under it.
	# A row of its own cost thirty-eight units, and those units are worth more
	# spread across nine plates than spent on a badge.
	var plate := PanelContainer.new()
	plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
	plate.add_theme_stylebox_override("panel", UI.skin("plaque", Palette.RAIL, 8, 1))
	plate.anchor_left = 0.5
	plate.anchor_right = 0.5
	plate.anchor_top = 1.0
	plate.anchor_bottom = 1.0
	plate.grow_horizontal = Control.GROW_DIRECTION_BOTH
	plate.grow_vertical = Control.GROW_DIRECTION_BOTH
	plate.offset_top = -14
	face.add_child(plate)
	_level = UI.number_label("1", UI.F_MICRO, Palette.TEXT, HORIZONTAL_ALIGNMENT_CENTER)
	plate.add_child(_level)

	return plate_bg


const TABS := {
	"jobs": "res://scenes/tabs/collect.gd",
	"hero": "res://scenes/tabs/keep.gd",
	"shop": "res://scenes/tabs/shop.gd",
	"items": "res://scenes/tabs/inventory.gd",
	"estates": "res://scenes/tabs/territory.gd",
	"army": "res://scenes/tabs/barracks.gd",
	"bank": "res://scenes/tabs/bank.gd",
	"fight": "res://scenes/tabs/attack.gd",
	"house": "res://scenes/tabs/kingdom.gd",
}


## Switches sections. Tabs are built once and then hidden, never freed.
##
## Freeing them was crashing the game. Every tab loads over HTTP, and GDScript's
## await resumes wherever it left off -- so leaving a section while its request
## was still in the air resumed the coroutine inside a freed node and took the
## process down with it. There are ~58 await sites across the scenes; guarding
## each one would leave the next one someone writes unguarded. Keeping the node
## alive removes the whole class of bug, and it is what the design asked for
## anyway: instant switching, and no reload of a list you just looked at.
func _open(id: String) -> void:
	_current = id
	_style_rail()
	_retitle(id)

	_show_only(id)

	if _tabs.has(id) and is_instance_valid(_tabs[id]):
		# A cached tab has to re-fetch, or reopening the Market shows the offers
		# from the last time you looked and the Barracks a soldier you dismissed.
		# Collect has no _reload: it renders straight from GameState, which the
		# shell keeps current.
		var shown: Node = _tabs[id]
		if shown.has_method("_reload"):
			shown.call("_reload")
		return

	_build_tab(id)
	_show_only(id)


## Puts the open section's name over it, in the shell's own words.
func _retitle(id: String) -> void:
	if _title == null:
		return
	for sec in SECTIONS:
		if str(sec["id"]) == id:
			UI.set_screen_title(_title, str(sec["label"]))
			return


## Shows one section and hides every other, including the ones built ahead of
## time by _prefetch which have never been on screen.
func _show_only(id: String) -> void:
	for other_id in _tabs:
		var node: Node = _tabs[other_id]
		if not is_instance_valid(node):
			continue
		var on: bool = other_id == id
		(node as CanvasItem).visible = on
		# A hidden tab must stop ticking, or seven of them poll at once.
		node.process_mode = Node.PROCESS_MODE_INHERIT if on else Node.PROCESS_MODE_DISABLED
		if _action_bars.has(other_id) and is_instance_valid(_action_bars[other_id]):
			(_action_bars[other_id] as CanvasItem).visible = on


## Builds one section and its action bar, hidden. Called both when the player
## opens a section and, ahead of time, by _prefetch.
func _build_tab(id: String) -> void:
	if _tabs.has(id) and is_instance_valid(_tabs[id]):
		return

	# The action bar is cached alongside its tab, because the tab holds direct
	# references into it -- rebuilding it on every switch would hand the tab a
	# freed button and reintroduce the same crash from the other side.
	var bar := VBoxContainer.new()
	bar.set_anchors_preset(Control.PRESET_FULL_RECT)
	# Centred rather than filled. A Button in a filled VBox absorbs all the spare
	# height and shoves the caption under it hard against the bottom margin, which
	# on an iPhone SE put it a couple of units from the screen edge.
	bar.alignment = BoxContainer.ALIGNMENT_CENTER
	bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_action_host.add_child(bar)
	_action_bars[id] = bar

	if TABS.has(id):
		var tab: Node = load(TABS[id]).new()
		_content.add_child(tab)
		_tabs[id] = tab
		tab.mount_action_bar(bar)
		return

	var section: Dictionary = {}
	for sec in SECTIONS:
		if sec["id"] == id:
			section = sec
	var ph := _placeholder(str(section.get("label", id)), str(section.get("milestone", "")))
	_content.add_child(ph)
	_tabs[id] = ph


func _placeholder(title: String, milestone: String) -> Control:
	var col := VBoxContainer.new()
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override("separation", 10)
	col.add_child(UI.label(title.to_upper(), UI.F_H1, Palette.TEXT_DIM, HORIZONTAL_ALIGNMENT_CENTER))
	col.add_child(UI.label("arrives in " + milestone, UI.F_BODY, Palette.TEXT_DIM, HORIZONTAL_ALIGNMENT_CENTER))
	return col


## Which sections the player has reached. Nine tabs handed to a new player at
## once is the single biggest reason this was hard to read: most of them do
## nothing yet -- no gold to spend, no army to gear, no house to join. Locked
## ones stay VISIBLE but dim with their level on them, because seeing what is
## coming is most of what makes levelling feel like progress.
func _unlocked(id: String) -> bool:
	for sec in GameState.snapshot.get("sections", []):
		if str(sec.get("id", "")) == id:
			return bool(sec.get("unlocked", false))
	return true   # before the first snapshot arrives, assume open rather than hide everything


func _unlock_level(id: String) -> int:
	for sec in GameState.snapshot.get("sections", []):
		if str(sec.get("id", "")) == id:
			return int(sec.get("unlock_level", 0))
	return 0


func _style_rail() -> void:
	for id in _rail_buttons:
		var b: Button = _rail_buttons[id]
		var open := _unlocked(str(id))
		b.disabled = not open
		if _rail_locks.has(id):
			var lock: PanelContainer = _rail_locks[id]
			(lock.get_child(0) as Label).text = "" if open else str(_unlock_level(str(id)))
			lock.visible = not open
		var active: bool = id == _current
		# Every entry is a carved plate; the OPEN one is an imperial plate -- deep
		# red, gold-framed, gold icon, light ink. It was a lit parchment slab
		# among flat buttons, which said "highlighted" where this says "this is
		# the room you are standing in".
		var face := "nav_active" if active else "nav"
		b.add_theme_stylebox_override(
			"normal", UI.skin(face, Palette.BANNER if active else Palette.RAIL, 4, 4))
		b.add_theme_stylebox_override("hover", UI.skin(face, Palette.RAIL, 4, 4))
		b.add_theme_stylebox_override("pressed", UI.skin("nav_active", Palette.BANNER, 4, 4))
		b.add_theme_stylebox_override("disabled", UI.skin("nav", Palette.RAIL, 4, 4))
		var inner := b.get_child(0)
		# The rail icons are painted objects with their own colour, so state is
		# NOT carried by tinting them any more -- it is carried by the plate,
		# red when the section is open and stone when it is not, which is how the
		# reference does it. The only tint left is the one a locked section needs:
		# drained and half faded, so you can see what is coming without being
		# invited to tap it.
		var tint := Color.WHITE if open else Color(0.72, 0.69, 0.63, 0.5)
		# Child 1 of the relief host is the icon; child 0 is its shadow and must
		# stay dark or it loses its footing on the stone.
		var glyph_host := inner.get_child(0)
		if glyph_host.get_child_count() > 1:
			glyph_host.get_child(1).modulate = tint
			glyph_host.get_child(0).modulate = Color(0, 0, 0, 0.28 if open else 0.10)
		else:
			glyph_host.modulate = tint
		inner.get_child(1).add_theme_color_override("font_color",
			Palette.BANNER_INK if active else (Palette.TEXT_DIM if open else Palette.EMPTY_SLOT))


func _on_state_changed() -> void:
	if not GameState.has_state():
		return
	var p := GameState.player()
	# The username is the portrait's tooltip now rather than a line of chrome.
	# The Hero card prints it in full, which is where you go to read it.
	_avatar_btn.tooltip_text = str(p.get("username", ""))
	_level.text = "Lv %d" % int(p.get("level", 1))
	_update_xp()
	_diamonds.text = UI.number(int(p.get("diamonds", 0)))
	_avatar_img.texture = ArtRegistry.portrait(str(p.get("avatar", "knight")))
	_show_gold(GameState.display_gold())
	_update_energy()
	_style_rail()


## Rolls the gold counter to `target` instead of snapping to it.
##
## Gold going up IS the game, so it is the one number worth animating. Two rules
## keep the animation from ever lying:
##
##  - the roll always starts from what is currently on screen, not from the last
##    target, so a change arriving mid-roll continues from where the eye is;
##  - `_gold_shown` is set to the target immediately. The tween only drives the
##    LABEL. If anything interrupts it the next change still starts from the true
##    figure, and a stalled tween can never leave a stale number on screen.
##
## display_gold() is confirmed + replayed pending, so it also moves DOWN when a
## prediction is rolled back. Rolling down reads as an honest correction; only
## the flash is suppressed, because a gain cue on a loss would be a lie.
func _show_gold(target: int) -> void:
	var from := _gold_shown
	_gold_shown = target

	# First paint: no roll. Spinning up from zero on every sign-in is theatre.
	if not _gold_seen:
		_gold_seen = true
		_gold.text = UI.number(target)
		return
	if from == target:
		return

	if _gold_tween != null and _gold_tween.is_valid():
		_gold_tween.kill()
	_gold_tween = create_tween()
	_gold_tween.tween_method(
		func(v: float) -> void: _gold.text = UI.number(int(v)),
		float(from), float(target), GOLD_ROLL_SECONDS)
	_gold_tween.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)

	if target > from:
		_gold_tween.parallel().tween_property(_gold, "modulate", Color(1.35, 1.3, 1.1), 0.08)
		_gold_tween.chain().tween_property(_gold, "modulate", Color.WHITE, 0.22)


## The experience bar. Driven from `changed` rather than the 4 Hz tick: unlike
## energy, experience only moves when the player does something.
func _update_xp() -> void:
	var need := GameState.xp_to_next()
	var have := GameState.display_xp()
	if need <= 0:
		# The level cap. A full bar, rather than a division by nothing.
		_xp_bar.max_value = 1.0
		_xp_bar.value = 1.0
		return
	_xp_bar.max_value = float(need)
	_xp_bar.value = float(have)


func _update_energy() -> void:
	if not GameState.has_state():
		return
	var cur := GameState.display_energy()
	var mx := GameState.max_energy()
	if cur >= mx:
		_energy.text = "%d/%d" % [cur, mx]
		return
	# The next point, not the full pool. "1h 04m" is the answer to a question
	# nobody asked; the countdown is the one that decides whether you wait.
	#
	# It has to fit a coin now rather than a full-width bar, so the words are
	# gone and the separator carries them: "42/60 · 0:23".
	_energy.text = "%d/%d \u00b7 %s" % [
		cur, mx, UI.short_duration(GameState.display_seconds_to_next())]


func _tick() -> void:
	GameState.tick_projection()
	_update_energy()
	# Estate income is continuous, so the purse moves without anyone touching it.
	# Set directly rather than through _show_gold: that one tweens, and a tween
	# restarted four times a second would stutter instead of counting. The tween
	# stays for discrete gains -- a collect, a sale, a raid -- which are the ones
	# worth celebrating.
	var g := GameState.display_gold()
	if g != _gold_shown:
		_gold_shown = g
		_gold.text = UI.number(g)


func _on_action_failed(message: String) -> void:
	_flash(message, Palette.DANGER)


## Levelling is the biggest thing that happens to a player, and it used to be a
## two-second line of text.
##
## It quietly hands over stat points, diamonds and a full energy bar. None of
## those were mentioned, so a player could reach level twenty without ever
## learning they had diamonds to spend -- and the stat points, which are the
## only permanent choice in the game, sat unspent behind a screen nobody had a
## reason to open.
func _celebrate_level(level: int, levels: int, points: int, gems: int) -> void:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UI.panel_box(Palette.PANEL_HIGH, Palette.GOLD_DEEP))
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var margin := MarginContainer.new()
	for side in ["left", "right"]:
		margin.add_theme_constant_override("margin_" + side, 28)
	for side in ["top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 18)
	panel.add_child(margin)

	var col := VBoxContainer.new()
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override("separation", 4)
	margin.add_child(col)

	var title := "LEVEL %d" % level
	if levels > 1:
		title = "LEVEL %d   (+%d)" % [level, levels]
	col.add_child(UI.label(title, UI.F_H1, Palette.GOLD_INK, HORIZONTAL_ALIGNMENT_CENTER))

	# Only what actually arrived. A line promising diamonds on a build where the
	# reward was zero would be worse than saying nothing.
	var gains: Array[String] = []
	if points > 0:
		gains.append("%d stat point%s" % [points, "" if points == 1 else "s"])
	if gems > 0:
		gains.append("%d diamond%s" % [gems, "" if gems == 1 else "s"])
	gains.append("energy restored")
	col.add_child(UI.label("  ·  ".join(gains), UI.F_CAPTION, Palette.TEXT,
		HORIZONTAL_ALIGNMENT_CENTER))
	if points > 0:
		col.add_child(UI.label("spend them on the Hero screen", UI.F_MICRO,
			Palette.TEXT_FAINT, HORIZONTAL_ALIGNMENT_CENTER))

	add_child(panel)
	panel.modulate.a = 0.0
	panel.scale = Vector2(0.92, 0.92)
	panel.pivot_offset = panel.size / 2.0

	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(panel, "modulate:a", 1.0, 0.18)
	tween.tween_property(panel, "scale", Vector2.ONE, 0.24).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.set_parallel(false)
	tween.tween_interval(2.0)
	tween.tween_property(panel, "modulate:a", 0.0, 0.3)
	tween.tween_callback(panel.queue_free)


## A job crossing a mastery threshold. Smaller than a level-up on purpose -- it
## happens more often -- but it is a PERMANENT payout increase and it used to
## produce nothing at all on screen.
func _celebrate_mastery(job_id: String, collects: int, bonus_bp: int) -> void:
	var name := job_id.capitalize()
	for j in GameState.snapshot.get("jobs", []):
		if str(j.get("id", "")) == job_id:
			name = str(j.get("name", name))
			break
	_flash("%s mastery — %d done, +%d%% forever" % [name, collects, bonus_bp / 100],
		Palette.SUCCESS)


## Shows the login calendar if today's square is still there.
##
## Preloaded rather than reached through a class_name, which is how the other
## overlays in this shell are opened.
func _show_daily_if_due() -> void:
	var res: Api.Response = await Api.get_json("/v1/daily")
	if not res.ok or not bool(res.data.get("claimable", false)):
		return
	var panel: CanvasLayer = preload("res://scenes/shell/daily_reward.gd").new()
	panel.setup(res.data)
	get_tree().root.add_child(panel)


func _flash(message: String, color: Color) -> void:
	_toast.add_theme_color_override("font_color", color)
	_toast.text = message
	var tween := create_tween()
	tween.tween_interval(2.2)
	tween.tween_callback(func() -> void: _toast.text = "")


## Dev-only helper: presses the first enabled button it finds in a subtree.
func _press_first_button(node: Node) -> bool:
	if node is Button and not (node as Button).disabled:
		(node as Button).pressed.emit()
		return true
	for child in node.get_children():
		if _press_first_button(child):
			return true
	return false


## Tells the server the app is still open.
##
## Costs one request with an empty body and no database work; it exists purely
## so an idle player is not mistaken for an absent one.
func _beat() -> void:
	if not Session.is_signed_in():
		return
	# Fire and forget. Nothing on screen depends on the answer, and a failed
	# heartbeat is not worth telling the player about -- the next one is thirty
	# seconds away.
	Api.post_json("/v1/presence", {"state": "foreground"})
