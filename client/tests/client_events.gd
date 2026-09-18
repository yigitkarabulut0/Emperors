extends SceneTree
## What the phone reports, and how a snapshot from outside the action sequence
## is taken.
##
## Api.track queues an event with the phone's clock, keeps only the newest
## hundred while it cannot send, and records nothing in a dev capture. A page's
## screen id is its title's words, as short as the server's ids allow. A
## snapshot a letter claim answers with is not adopted while a batch of collects
## is in flight -- either could land first -- and the state is fetched again
## once the batch is done instead.
##
## Run: godot --headless --path client --script tests/client_events.gd

var _fails := 0


func _initialize() -> void:
	await process_frame
	var api: Node = root.get_node("Api")
	var env: Node = root.get_node("Env")
	var gs: Node = root.get_node("GameState")
	for m in ["track", "queued_events", "flush_events", "flush_events_now"]:
		if not api.has_method(m):
			print("FAIL  Api.%s does not exist" % m)
			quit(1)
			return

	var before: int = (api.call("queued_events") as Array).size()
	api.call("track", "screen", {"name": "collect"})
	var q: Array = api.call("queued_events")
	_expect(q.size() == before + 1, "a tracked event is queued")
	if not q.is_empty():
		var e: Dictionary = q[q.size() - 1]
		_expect(e.get("name", "") == "screen" and e.get("props", {}) == {"name": "collect"}, "it keeps its name and properties")
		_expect(absi(int(e.get("at", 0)) - int(Time.get_unix_time_from_system())) <= 2, "it carries the phone's clock")

	for i in 150:
		api.call("track", "screen", {"name": "n%d" % i})
	q = api.call("queued_events")
	_expect(q.size() == 100, "an unsendable queue keeps 100, not %d" % q.size())
	_expect(q[q.size() - 1].get("props", {}).get("name", "") == "n149", "and the newest of them")

	env.get("args")["capture"] = "shot.png"
	var n: int = (api.call("queued_events") as Array).size()
	api.call("track", "app_open", {"cold": true})
	_expect((api.call("queued_events") as Array).size() == n, "a dev capture tracks nothing")
	env.get("args").erase("capture")

	var sheet: GDScript = load("res://scripts/ui/sheet.gd")
	_expect(sheet.screen_id("THE DAILY REWARD") == "page:the_daily_reward", "a title becomes its words: %s" % sheet.screen_id("THE DAILY REWARD"))
	_expect(sheet.screen_id("THE RULES OF RAIDING") == "page:the_rules_of_raiding", "every word is kept")
	_expect(sheet.screen_id("Lord's  Hall -- #1!") == "page:lords_hall_1", "anything but letters and digits is dropped: %s" % sheet.screen_id("Lord's  Hall -- #1!"))
	_expect(sheet.screen_id("W".repeat(80)).length() <= 48, "an id is never longer than the server keeps")

	# A claim's snapshot waits for a batch in flight.
	gs.set("snapshot", {"player": {"gold": "100", "level": 3, "action_seq": 4}, "energy": {"current": 1, "max": 10}})
	gs.set("_sending", true)
	gs.call("adopt_async", {"player": {"gold": "999", "level": 3, "action_seq": 4}, "energy": {"current": 1, "max": 10}})
	_expect(str(gs.call("player").get("gold", "")) == "100", "a snapshot arriving mid-batch is not adopted over it")
	_expect(bool(gs.get("_refresh_after_pump")), "and the state is to be fetched once the batch lands")
	gs.set("_sending", false)
	gs.set("_refresh_after_pump", false)
	gs.call("adopt_async", {"player": {"gold": "999", "level": 3, "action_seq": 4}, "energy": {"current": 1, "max": 10}})
	_expect(str(gs.call("player").get("gold", "")) == "999", "with nothing in flight it is adopted at once")

	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  events queue as the server expects, and an outside snapshot waits for the batch")
	quit()


func _expect(cond: bool, what: String) -> void:
	if not cond:
		_fails += 1
		print("  FAIL  " + what)
