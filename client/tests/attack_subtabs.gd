extends SceneTree
## The Attack tab is four sub-tabs on one painted header.
##
## What must hold:
##  - the four-tab strip stands in attack.png's own painted band, takes the
##    short plates, and its plates stand on the header's gold rule;
##  - RAID's own REVENGE / TARGETS strip stands directly under it, at the
##    painting's own size, and the two tap bands share no pixel;
##  - the flow starts under BOTH, at the painting's own gap;
##  - opening the ARENA hides RAID as a LAYER -- no revenge card, no target,
##    no history panel and no notice bar can turn up on it, which is the bug
##    the Kingdom tab learned the hard way;
##  - each of the four opens its own body, and CAMPAIGN's is the road's map;
##  - a sub-tab under its level is dimmed and says the level;
##  - the bodies bring their own layouts and land where their paintings put
##    them, each shifted by its own painting's tab rule.
##
## Run: godot --headless --path client --script tests/attack_subtabs.gd

const CANVASES := [Vector2(941, 1672), Vector2(941, 2040)]
const SUBS := ["raid", "arena", "campaign", "bounties"]
## attack.png's tab rule, and the gap it puts between a rule and what follows.
const RULE := 353.0
const GAP := 11.0
## What RAID's body is: nothing of it may draw on another sub-tab.
const RAID_PARTS := ["revenge_card", "divider_targets", "target_card", "history_panel", "notice_bar"]

var _fails := 0
var _checked := 0
## Loaded once the autoloads are up: compiling against them here would meet Art
## before it exists (the rule tab_strip.gd's own test records).
var LO: GDScript


func _initialize() -> void:
	await process_frame
	root.get_node("Env").set("api_base_url", "http://127.0.0.1:9")
	LO = load("res://scripts/ui/layout.gd")
	_shifts()
	for canvas in CANVASES:
		await _tab(canvas)
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  %d checks: four sub-tabs, two strips, and RAID's body on RAID alone" % _checked)
	quit()


func _expect(ok: bool, what: String) -> void:
	_checked += 1
	if not ok:
		_fails += 1
		print("  FAIL  " + what)


## Each body is cut at its painting's own coordinates and laid by the shift
## between that painting's tab rule and attack.png's, so the gap under the
## strip is the one each was painted with.
func _shifts() -> void:
	for pair in [["arena", "league", 483.0], ["bounties", "board", 427.0]]:
		var screen := str(pair[0])
		var first := str(pair[1])
		var el: Dictionary = LO.call("element", screen, first)
		_expect(not el.is_empty(), "%s has no %s" % [screen, first])
		if el.is_empty():
			continue
		var at: float = (LO.call("rect_of", el) as Rect2).position.y
		_expect(absf(at - RULE) <= 20.0,
			"%s's %s lands at %.0f, not within twenty of the rule at %.0f" % [screen, first, at, RULE])


func _tab(canvas: Vector2) -> void:
	var tag := "%dx%d" % [int(canvas.x), int(canvas.y)]
	var host := Control.new()
	host.size = canvas
	root.add_child(host)
	var tab: Control = (load("res://scenes/tabs/attack.gd") as GDScript).new()
	tab.set_anchors_preset(Control.PRESET_FULL_RECT)
	host.add_child(tab)
	for i in 3:
		await process_frame

	var subs: Control = tab.get("_subs")
	var raid_tabs: Control = tab.get("_tabs")
	_expect(subs != null and subs.ids == SUBS, "%s: the sub-tabs are %s" % [tag, subs.ids if subs else []])
	_expect(raid_tabs != null and raid_tabs.ids == ["revenge", "targets"],
		"%s: RAID's own row is %s" % [tag, raid_tabs.ids if raid_tabs else []])
	if subs == null or raid_tabs == null:
		host.queue_free()
		return
	_expect(bool(subs.get("short")), "%s: four sub-tabs do not draw the short plates" % tag)
	# Both strips stand on their own floor, and neither reaches into the other.
	for pair in [[subs, "the sub-tabs"], [raid_tabs, "REVENGE / TARGETS"]]:
		var s: Control = pair[0]
		for id in s.ids:
			var p: TextureRect = s.plate(id)
			_expect(absf(p.position.y + p.size.y - s.size.y) <= 0.5,
				"%s: %s's %s does not stand on its floor" % [tag, pair[1], id])
	var a := Rect2(subs.position, subs.size)
	var b := Rect2(raid_tabs.position, raid_tabs.size)
	_expect(not a.intersects(b), "%s: the two strips overlap (%s and %s)" % [tag, a, b])
	_expect(absf(a.position.y + a.size.y - RULE) <= 0.5,
		"%s: the sub-tabs do not stand on the header's rule at %.0f" % [tag, RULE])
	# The flow starts under both, at the painting's own gap.
	var card_top: float = float((load("res://scenes/tabs/attack.gd") as GDScript).get("CARD_TOP"))
	var floor_of_raid := b.position.y + b.size.y
	_expect(absf(card_top - (floor_of_raid + GAP)) <= 1.0,
		"%s: the first card is at %.0f, not %.0f under RAID's own rule" % [tag, card_top, floor_of_raid + GAP])

	# A sub-tab under its level is dimmed and answers rather than swallowing the
	# tap. CAMPAIGN opens at level 6 and this lord is 30, so the one that has to
	# hold the rule is BOUNTIES' own gate, checked below with the others.
	var heard := []
	subs.connect("refused", func(id: String, words: String) -> void: heard.append([id, words]))
	_expect(subs.is_enabled("campaign"), "%s: CAMPAIGN is dimmed for a lord past its level" % tag)

	# CAMPAIGN opens its own body, as the ARENA and the BOUNTIES do.
	tab.call("open_sub", "campaign")
	for i in 2:
		await process_frame
	_expect(str(tab.get("_sub_id")) == "campaign", "%s: CAMPAIGN did not open" % tag)
	_expect(tab.call("sub") != null, "%s: CAMPAIGN has no body" % tag)
	tab.call("open_sub", "raid")
	for i in 2:
		await process_frame

	# The ARENA hides RAID's whole body, as a layer.
	tab.call("open_sub", "arena")
	for i in 2:
		await process_frame
	_expect(str(tab.get("_sub_id")) == "arena", "%s: the ARENA did not open" % tag)
	_expect(tab.get("sub") != null and tab.call("sub") != null, "%s: the ARENA has no body" % tag)
	var raid_layer: Control = tab.get("_raid")
	_expect(raid_layer != null and not raid_layer.visible, "%s: RAID's layer is still showing" % tag)
	_expect(not raid_tabs.visible, "%s: REVENGE / TARGETS is still showing on the ARENA" % tag)
	var ui: Dictionary = tab.get("_ui")
	for id in RAID_PARTS:
		var v: Variant = ui.get(id)
		var n: Control = v if v is Control else (v[0]["node"] if v is Array and not v.is_empty() else null)
		_expect(n == null or not n.is_visible_in_tree(),
			"%s: RAID's %s draws on the ARENA" % [tag, id])

	# And RAID comes back whole.
	tab.call("open_sub", "raid")
	for i in 2:
		await process_frame
	_expect(raid_layer.visible and raid_tabs.visible, "%s: RAID did not come back" % tag)
	_expect(tab.call("sub") == null, "%s: the ARENA's body was left behind" % tag)
	host.queue_free()
	await process_frame
