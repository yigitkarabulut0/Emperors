extends SceneTree
## A new lord's first minutes are the steward's guide, not the old tour.
##
## The tour (scenes/pages/onboarding.gd) was five pages of a Sheet shown once,
## remembered on the phone (Prefs "tour_seen"), so a new phone showed it again
## and a lord who closed it early never saw it at all. The guide's step is the
## server's (snapshot.guide): the shell starts it on arrival while it is
## active, `--page guide` shows it for a capture, and nothing opens the tour.
##
## Run: godot --headless --path client --script tests/no_onboarding.gd

var _fails := 0
var _checked := 0


func _initialize() -> void:
	await process_frame
	_expect(not FileAccess.file_exists("res://scenes/pages/onboarding.gd"), "the old tour is gone (scenes/pages/onboarding.gd)")
	var shell := FileAccess.get_file_as_string("res://scenes/shell/shell.gd")
	_expect(shell != "", "the shell's script is readable")
	for gone in ["onboarding", "tour_seen", "\"tour\""]:
		_expect(not shell.contains(gone), "the shell no longer knows the tour (%s)" % gone)
	var arrive := _func(shell, "_arrive")
	_expect(arrive.contains("Guide.active()") and arrive.contains("Guide.start(self)"),
		"arriving starts the guide while the server says it runs")
	_expect(arrive.find("Guide.start(self)") < arrive.find("away_page"),
		"the guide comes before the away page on arrival")
	_expect(_func(shell, "_dev_page").contains("\"guide\": Guide.start(self)"), "--page guide shows it for a capture")
	_expect(_func(shell, "_daily_on_boot").contains("Guide.active()"),
		"the day's reward does not open over the guide on arrival: the steward brings the lord to it")
	_expect(_func(shell, "_is_locked").contains("Guide.bandit_step()"),
		"the Attack tab opens for Karel's card on the bandit step")
	var fit := FileAccess.get_file_as_string("res://tests/pages_fit.gd")
	_expect(not fit.contains("onboarding"), "the pages test does not open the tour")
	_done()


## The body of `name` in a script's source, up to the next top-level func.
func _func(src: String, name: String) -> String:
	var at := src.find("func %s(" % name)
	if at < 0:
		return ""
	var end := src.find("\nfunc ", at + 5)
	return src.substr(at, (end if end > 0 else src.length()) - at)


func _expect(ok: bool, what: String) -> void:
	_checked += 1
	if not ok:
		_fails += 1
		print("FAIL no_onboarding: " + what)


func _done() -> void:
	if _fails == 0:
		print("PASS no_onboarding: %d checks" % _checked)
	quit(1 if _fails > 0 else 0)
