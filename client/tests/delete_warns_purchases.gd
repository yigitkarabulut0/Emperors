extends SceneTree
## DELETE ACCOUNT says what happens to what the lord paid for.
##
## Deleting the account does not cancel Crown Patronage -- Apple bills it, and
## goes on billing -- and what was bought stays with the Apple ID but leaves
## this game account for good. The confirmation said neither: a patron who
## deleted would have been charged the next month for a lord that no longer
## exists. So the patron's dialog names the subscription and where it is
## cancelled (Settings > your name > Subscriptions), a lord who bought anything
## is told it cannot be moved, and a lord who never paid sees neither line.
## (The dialog stays the painted kit's Dialog, the password prompt after it.)
##
## Run: godot --headless --path client --script tests/delete_warns_purchases.gd

var _fails := 0


func _initialize() -> void:
	await process_frame
	var page: GDScript = load("res://scenes/pages/profile_page.gd")
	if page == null or not page.get_script_method_list().any(func(m: Dictionary) -> bool:
			return str(m.get("name", "")) == "delete_words"):
		print("FAIL  the profile has no delete_words: the dialog cannot say what happens to purchases")
		quit(1)
		return

	# A patron who has bought: both lines, the subscription's first.
	var patron: String = page.call("delete_words", {"patron_seconds": 23 * 86400, "vip_level": 4})
	_want(patron, "Crown Patronage", "the patron's dialog does not name the subscription")
	_want(patron, "does not cancel", "the patron's dialog does not say deleting leaves the subscription running")
	_want(patron, "Settings › your name › Subscriptions", "the patron's dialog does not say where to cancel")
	_want(patron, "Apple ID", "the buyer's dialog does not say purchases stay with the Apple ID")
	_want(patron, "cannot be moved", "the buyer's dialog does not say purchases cannot be moved")
	_want(patron, "cannot be undone", "the dialog lost its last line")
	if patron.find("Crown Patronage") > patron.find("Apple ID"):
		_fail("the subscription's warning comes after the purchases' line; it is the one that costs money")

	# A lord who bought once and let the patronage lapse: the purchases only.
	var lapsed: String = page.call("delete_words", {"patron_seconds": 0, "vip_level": 1})
	_not(lapsed, "Subscriptions", "a lord with no running patronage is told to cancel one")
	_want(lapsed, "cannot be moved", "a lord who bought is not told the purchases cannot be moved")

	# A patron at level 0 (a gifted or pending patronage): the subscription only.
	var gifted: String = page.call("delete_words", {"patron_seconds": 3600, "vip_level": 0})
	_want(gifted, "Subscriptions", "a patron at Royal Favour 0 is not told to cancel")
	_not(gifted, "Apple ID, but", "a lord who never bought is told about purchases")

	# A lord who never paid: neither line, and no figures read from nowhere.
	for p in [{}, {"patron_seconds": 0, "vip_level": 0}]:
		var free: String = page.call("delete_words", p)
		_not(free, "Crown Patronage", "a lord who never paid sees the subscription's line")
		_not(free, "Apple ID", "a lord who never paid sees the purchases' line")
		_want(free, "deleted for good", "the dialog lost what deleting does")
		_want(free, "cannot be undone", "the dialog lost its last line")

	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  the delete dialog names the patronage and where to cancel it, and purchases' fate, only to those who paid")
	quit()


func _want(text: String, part: String, why: String) -> void:
	if not text.contains(part):
		_fail("%s (no \"%s\")" % [why, part])


func _not(text: String, part: String, why: String) -> void:
	if text.contains(part):
		_fail("%s (\"%s\")" % [why, part])


func _fail(msg: String) -> void:
	_fails += 1
	print("  FAIL  " + msg)
