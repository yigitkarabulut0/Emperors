extends SceneTree
## A shielded lord is told, before the tap, that raiding ends their shield --
## and a revenge strike, which keeps it, is not.
##
## Run: godot --headless --path client --script tests/attack_shield_warning.gd

var _fails := 0


func _initialize() -> void:
	await process_frame
	var attack: GDScript = load("res://scenes/tabs/attack.gd")
	if not attack.has_method("raid_warning"):
		print("FAIL  the Attack tab has no raid_warning, so a shielded raid is not warned of")
		quit(1)
		return
	var rules := {"shield_breaks": true}
	var w: String = attack.raid_warning(false, 7 * 3600 + 59 * 60, rules)
	_expect(w == "Attacking ends your shield (7h 59m left).", "a shielded raid is warned: \"%s\"" % w)
	_expect(attack.raid_warning(true, 7 * 3600, rules) == "", "a revenge strike keeps the shield, so no warning")
	_expect(attack.raid_warning(false, 0, rules) == "", "no shield, no warning")
	_expect(attack.raid_warning(false, 3600, {}) == "", "a server that does not break shields gets no warning")

	# The rules page says it too, when the server does.
	var host := Control.new()
	host.size = Vector2(941, 1672)
	root.add_child(host)
	var sheet: Control = load("res://scenes/pages/rules_page.gd").open(host, {"shield_breaks": true, "shield_minutes": 30})
	await process_frame
	_expect(_text_of(sheet).contains("Raiding anyone yourself ends your own shield"), "the rules page states that raiding ends your shield")
	sheet.call("close")
	sheet = load("res://scenes/pages/rules_page.gd").open(host, {"shield_minutes": 30})
	await process_frame
	_expect(not _text_of(sheet).contains("ends your own shield"), "and says nothing of it when the server does not")
	sheet.call("close")

	# THE TAKE says the CAP, not only the rate. The server has sent `raid_cap`
	# since it was added for this line -- "the sheet printed the rate and not the
	# cap, so nobody could see why three per cent of a rich purse is not three
	# per cent" (service/attack.go) -- and the page never read it.
	sheet = load("res://scenes/pages/rules_page.gd").open(host, {"steal_rate_bp": 300, "raid_cap": 1_250_000})
	await process_frame
	var take := _text_of(sheet)
	_expect(take.contains("3%"), "the rules page does not say the rate")
	_expect(take.contains("at most") and not take.contains("at most 0"),
		"the rules page does not say what one raid can take at all: \"%s\"" % take)
	_expect(not take.contains("Your level caps the take"), "the page still hedges instead of naming the cap")
	sheet.call("close")

	# And it is the SERVER'S number on the page, not a word about one: a
	# different cap must read differently.
	sheet = load("res://scenes/pages/rules_page.gd").open(host, {"steal_rate_bp": 300, "raid_cap": 4_000})
	await process_frame
	var small := _text_of(sheet)
	_expect(small != take, "two very different caps put the same sentence on the page")
	sheet.call("close")

	# An older server sends no cap, and the sentence falls back rather than
	# printing a zero.
	sheet = load("res://scenes/pages/rules_page.gd").open(host, {"steal_rate_bp": 300})
	await process_frame
	take = _text_of(sheet)
	_expect(take.contains("Your level caps the take"), "with no cap the page does not fall back")
	_expect(not take.contains("at most"), "with no cap the page still claims a ceiling")
	sheet.call("close")

	# THE NOTICE'S LIVE LINE. `scouted_today` is sent so a lord FEELS being looked
	# over where the raiding is (service/attack.go, and the query's own comment).
	# Nothing said it anywhere until the bar learned its painted blank plate.
	var notice: Callable = attack.notice_line
	_expect(notice.call({}) == "", "a lord nobody scouted is told something")
	_expect(notice.call({"scouted_today": 0}) == "", "a count of none is still said")
	var one: String = notice.call({"scouted_today": 1})
	_expect(one.contains("A lord") and not one.contains("1 lords"), "one scout reads as a plural: \"%s\"" % one)
	var many: String = notice.call({"scouted_today": 3})
	_expect(many.contains("3 lords"), "three scouts are not counted: \"%s\"" % many)

	host.queue_free()
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  a shielded raider is told the raid ends the shield, and being scouted is said")
	quit()


func _text_of(n: Node) -> String:
	var out := ""
	if n is Label:
		out += (n as Label).text + "\n"
	for c in n.get_children():
		out += _text_of(c)
	return out


func _expect(cond: bool, what: String) -> void:
	if not cond:
		_fails += 1
		print("  FAIL  " + what)
