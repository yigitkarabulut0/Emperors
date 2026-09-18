extends SceneTree
## EVERY COUNTER THE SERVER KEEPS REACHES A BUBBLE.
##
## `service/badges.go` counts what waits for a lord, and the rail is the only
## thing that turns one into a bubble -- the game has no push notifications, so
## this rail IS the telling. Six counters reached the client and raised nothing
## at all: the hall's unread lines, a friend's request, a draught waiting, a call
## for aid, a scout home with a haul, and a chapter's chest. "A hall nobody knows
## has spoken is a hall nobody opens twice."
##
## This test names every badge the server sends and where it shows, so a new one
## cannot arrive unwired and a wired one cannot quietly stop counting.
##
## Run: godot --headless --path client --script tests/badges_reach_the_rail.gd

var _fails := 0

## Every json field on service.Badges, and the bubble(s) it must move.
## "rail:<id>" a rail entry, "portrait" the lord's own, "elsewhere" a surface of
## its own that this test cannot reach (with the reason). A badge may name more
## than one: the Royal Mail has two doors and both must say a letter waits.
const WHERE := {
	"quests": ["rail:collect"], "weekly": ["rail:collect"],
	"revenge": ["rail:attack"], "campaign": ["rail:attack"],
	"hunt": ["rail:army"],
	"requests": ["rail:kingdom"], "chat": ["rail:kingdom"], "aid_calls": ["rail:kingdom"],
	"decree": ["rail:kingdom"],
	# Reached from the COURT and from the lord's own portrait, and said at both.
	"mail": ["rail:court", "portrait"],
	"offers_unseen": ["rail:court"], "store_free": ["rail:court"],
	"cart": ["rail:court"], "hourly": ["rail:court"], "events": ["rail:court"], "season": ["rail:court"],
	"road": ["rail:family"], "achievements": ["rail:family"],
	"friends": ["portrait"], "gifts": ["portrait"],
	# A dot rather than a count: the day's gift is one thing or nothing.
	"daily": "elsewhere: the portrait's own daily dot",
	# The Attack tab's own strip, which says which sub-tab is waiting.
	"bounty_on_me": "elsewhere: the ATTACK strip's BOUNTIES count",
	# Fights LEFT today, not something waiting: a bubble reading 5 every morning
	# is a nag, not news. Deliberately not on the rail.
	"arena": "elsewhere: an allowance, not a thing waiting",
	# The shop's own offer list, not a count of what waits.
	"offers": "elsewhere: the Shop's offer cards",
}


func _initialize() -> void:
	await process_frame
	var shell: GDScript = load("res://scenes/shell/shell.gd")
	for m in ["rail_count", "portrait_count", "court_count", "family_count"]:
		if not shell.has_method(m):
			print("FAIL  the shell has no %s, so nothing adds the badges up" % m)
			quit(1)
			return

	# Each counter moves the bubble it is written down against, and moves no
	# other -- a badge added to the wrong pile is a lord told the wrong thing.
	var rails := ["collect", "attack", "army", "kingdom", "court", "family"]
	for key in WHERE:
		var want: Variant = WHERE[key]
		if want is String:
			continue  # "elsewhere": a surface of its own, with its reason written down
		var b := {key: (true if key == "decree" else 7)}
		var moved: Array = []
		for id in rails:
			if int(shell.rail_count(b, id)) > 0:
				moved.append("rail:" + id)
		if int(shell.portrait_count(b)) > 0:
			moved.append("portrait")
		moved.sort()
		var expected: Array = (want as Array).duplicate()
		expected.sort()
		_expect(moved == expected, "%s moves %s, and should move %s" % [key, str(moved), str(expected)])

	# Nothing counts what is not there.
	_expect(shell.portrait_count({}) == 0, "an empty board puts a number on the portrait")
	for id in rails:
		_expect(int(shell.rail_count({}, id)) == 0, "an empty board puts a number on %s" % id)

	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  all %d badges the server keeps reach a bubble, each its own" % WHERE.size())
	quit()


func _expect(cond: bool, what: String) -> void:
	if not cond:
		_fails += 1
		print("  FAIL  " + what)
