extends SceneTree
## The guide finds its controls by name, and every name the server's steps
## give has a screen that registers it.
##
## Checked: GuideTargets finds a registered control only while it is in the
## tree and shown (a hidden tab's control is not found, a freed one is
## forgotten); the step's chain of names -- the control, the one it opens into
## (the chests card's OPEN), the way there (the tab's rail entry, the diamond
## pill for the day's reward), and Collect's first job while the step waits on
## a level; which offer the steward sends a lord to (the cheapest left) and
## which gear tile (a slot the hero has nothing in); the pointer mirrored off
## the right edge and turned over at the foot; and every target in
## balance/retention.json's guide steps is registered, in one line, by the
## screen that owns it.
##
## Run: godot --headless --path client --script tests/guide_targets.gd

## The screens that own each name, and the line that registers it.
const OWNERS := {
	"collect.job0": ["res://scenes/tabs/collect.gd", "GuideTargets.register(\"collect.job0\""],
	"rail.": ["res://scenes/shell/shell.gd", "GuideTargets.register(\"rail.\" + id"],
	"pill.diamonds": ["res://scenes/shell/shell.gd", "GuideTargets.register(\"pill.diamonds\""],
	"daily.claim": ["res://scenes/pages/daily_page.gd", "GuideTargets.register(\"daily.claim\""],
	"court.chests": ["res://scenes/tabs/court.gd", "GuideTargets.register(\"court.chests\""],
	"chests.open": ["res://scenes/court/chests_view.gd", "GuideTargets.register(\"chests.open\""],
	"shop.offer": ["res://scenes/tabs/shop.gd", "GuideTargets.register(\"shop.offer.%d\" % i"],
	"family.gear": ["res://scenes/tabs/family.gd", "GuideTargets.register(\"family.gear.\" + slot"],
	"family.stats": ["res://scenes/tabs/family.gd", "GuideTargets.register(\"family.stats\""],
	"family.estates": ["res://scenes/tabs/family.gd", "GuideTargets.register(\"family.estates\""],
	"army.recruit": ["res://scenes/tabs/army.gd", "GuideTargets.register(\"army.recruit\""],
	"attack.bandit": ["res://scenes/tabs/attack.gd", "GuideTargets.register(\"attack.bandit\""],
}

var _fails := 0
var _checked := 0


func _initialize() -> void:
	await process_frame
	var targets: GDScript = load("res://scripts/ui/guide_targets.gd")
	var guide: GDScript = load("res://scripts/ui/guide.gd")
	if targets == null or guide == null:
		_fail("the guide is missing (scripts/ui/guide.gd, scripts/ui/guide_targets.gd)")
		_done()
		return
	await _registry(targets)
	_chains(guide)
	_picks(guide)
	_pointer(guide)
	_owners()
	_done()


func _registry(targets: GDScript) -> void:
	targets.call("clear")
	var tab := Control.new()
	root.add_child(tab)
	var b := Control.new()
	tab.add_child(b)
	targets.call("register", "collect.job0", b)
	await process_frame
	_expect(targets.call("find", "collect.job0") == b, "a shown, registered control is found")
	tab.visible = false
	_expect(targets.call("find", "collect.job0") == null, "a control on a hidden tab is not found")
	_expect(bool(targets.call("known", "collect.job0")), "a hidden control is still known")
	tab.visible = true
	b.free()
	_expect(targets.call("find", "collect.job0") == null, "a freed control is forgotten")
	_expect(not bool(targets.call("known", "collect.job0")), "a freed control is not known")
	_expect(targets.call("find", "nobody.here") == null, "an unregistered name finds nothing")
	tab.free()


func _chains(guide: GDScript) -> void:
	var cases := [
		[{"target": "collect.job0", "tab": "collect"}, 1, ["collect.job0", "rail.collect"]],
		[{"target": "daily.claim", "tab": "collect"}, 2, ["daily.claim", "pill.diamonds"]],
		[{"target": "court.chests", "tab": "court", "min_level": 2}, 2, ["chests.open", "court.chests", "rail.court"]],
		[{"target": "court.chests", "tab": "court", "min_level": 2}, 1, ["collect.job0", "rail.collect"]],
		[{"target": "shop.offer", "tab": "shop"}, 2, ["shop.offer", "rail.shop"]],
		[{"target": "family.estates", "tab": "family", "min_level": 4}, 3, ["collect.job0", "rail.collect"]],
		[{"target": "attack.bandit", "tab": "attack"}, 5, ["attack.bandit", "rail.attack"]],
		[{"tab": "collect"}, 1, ["rail.collect"]],
	]
	for c in cases:
		var got: Array = guide.call("chain", c[0], c[1])
		_expect(got == c[2], "chain %s at level %d is %s, want %s" % [c[0], c[1], got, c[2]])
	_expect(bool(guide.call("is_approach", "rail.shop")) and bool(guide.call("is_approach", "pill.diamonds"))
		and not bool(guide.call("is_approach", "shop.offer.2")), "rail entries and the pill take the arrow; controls the gauntlet")


func _picks(guide: GDScript) -> void:
	var offers := [{"price": 900}, {"price": 120, "purchased": true}, {"price": 150}, {"price": 400}]
	_expect(int(guide.call("cheapest_offer", offers)) == 2, "the cheapest offer not yet bought is the third")
	_expect(int(guide.call("cheapest_offer", [])) == 0, "with no offers, the first card")
	var bag := [{"slot": "weapon", "equipped_on": "hero"}, {"slot": "weapon", "equipped_on": ""},
		{"slot": "armor", "equipped_on": ""}]
	_expect(str(guide.call("gear_slot", bag)) == "armor", "the hero has a weapon on: the armour's tile")
	_expect(str(guide.call("gear_slot", [{"slot": "horse", "equipped_on": ""}])) == "horse", "a horse in the bag: the horse's tile")
	_expect(str(guide.call("gear_slot", [])) == "weapon", "nothing held: the weapon's tile")
	_expect(str(guide.call("gear_slot", [{"slot": "weapon", "equipped_on": "s1"}])) == "weapon", "gear on a soldier is not in the bag")


func _pointer(guide: GDScript) -> void:
	var canvas := Vector2(941, 1672)
	var size := Vector2(200, 250)
	var tip := Vector2(6, 6)
	var p: Dictionary = guide.call("point_at", Vector2(300, 600), size, tip, canvas)
	_expect(not p["flip_h"] and not p["flip_v"] and (p["pos"] as Vector2) == Vector2(294, 594),
		"a pointer in the open lands its fingertip on the point: %s" % p)
	p = guide.call("point_at", Vector2(850, 600), size, tip, canvas)
	_expect(bool(p["flip_h"]) and (p["pos"] as Vector2).x + size.x - tip.x == 850.0 and (p["pos"] as Vector2).x + size.x <= canvas.x,
		"near the right edge it is mirrored, the fingertip still on the point: %s" % p)
	p = guide.call("point_at", Vector2(300, 1600), size, tip, canvas)
	_expect(bool(p["flip_v"]) and (p["pos"] as Vector2).y + size.y - tip.y == 1600.0 and (p["pos"] as Vector2).y >= 0.0,
		"near the foot it is turned over, the fingertip still on the point: %s" % p)
	var r := Rect2(700, 500, 200, 80)
	_expect(not bool(guide.call("speech_high", r, canvas)), "a control in the upper half: the scroll goes low")
	_expect(bool(guide.call("speech_high", Rect2(300, 1300, 200, 80), canvas)), "a control in the lower half: the scroll goes high")
	_expect(bool(guide.call("steward_left", r, canvas)), "a control on the right: the steward stands left, looking at it")
	_expect(not bool(guide.call("steward_left", Rect2(20, 500, 130, 150), canvas)), "a rail entry: the steward stands right")


## Every target the server's steps name has its owner's registration line.
func _owners() -> void:
	for name in OWNERS:
		var o: Array = OWNERS[name]
		var path := str(o[0])
		_expect(FileAccess.file_exists(path), "%s's owner %s is missing" % [name, path])
		if FileAccess.file_exists(path):
			var src := FileAccess.get_file_as_string(path)
			_expect(src.count(str(o[1])) == 1, "%s registers %s once (%s)" % [path, name, o[1]])
	var steps := _steps()
	_expect(steps.size() >= 11, "balance/retention.json lists the guide's steps (%d)" % steps.size())
	for s in steps:
		var t := str((s as Dictionary).get("target", ""))
		if t == "":
			_expect(str(s.get("kind", "")) == "tap", "step %s has no target and is not a tap step" % s.get("id", ""))
			continue
		_expect(OWNERS.has(t), "step %s's target %s has no owner" % [s.get("id", ""), t])
		var tab := str(s.get("tab", ""))
		_expect(tab == "" or load("res://scenes/shell/shell.gd").get_script_constant_map()["TABS"].has(tab),
			"step %s's tab %s is a rail entry" % [s.get("id", ""), tab])


func _steps() -> Array:
	var path := ProjectSettings.globalize_path("res://").path_join("../balance/retention.json")
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return []
	var d: Variant = JSON.parse_string(f.get_as_text())
	return (d as Dictionary).get("guide", {}).get("steps", []) if d is Dictionary else []


func _expect(ok: bool, what: String) -> void:
	_checked += 1
	if not ok:
		_fail(what)


func _fail(what: String) -> void:
	_fails += 1
	print("FAIL guide_targets: " + what)


func _done() -> void:
	if _fails == 0:
		print("PASS guide_targets: %d checks" % _checked)
	quit(1 if _fails > 0 else 0)
