extends SceneTree
## The purse holds only what the server confirmed; the storehouse fills beside it.
##
## Estate income used to be predicted into the purse by the hour
## (GameState.accrued_tax, from player.tax_milli_per_hour). Since Wave 2 it
## fills the storehouse instead, up to its capacity, and reaches the purse only
## when the lord carries it in. What must hold:
##  - display_gold() is the confirmed purse and the collects in flight, and does
##    not grow with time, whatever the snapshot says of an hourly rate;
##  - display_storehouse() is the snapshot's milli filled at per_hour_milli since
##    the snapshot, in whole gold, and is game/estates.Fill's sum to the milli
##    (the same floors, the same stop at cap_milli);
##  - a storehouse already over its capacity (a rate that fell) stays put;
##  - nothing of it is written into the snapshot;
##  - the full-in count runs down from the snapshot's, and reads 0 once full.
##
## Run: godot --headless --path client --script tests/storehouse_display.gd

var _fails := 0
var _checked := 0
var _gs: Node


func _initialize() -> void:
	await process_frame
	_gs = root.get_node("GameState")
	_purse_stays()
	if not _gs.has_method("display_storehouse") or not _gs.has_method("storehouse_milli"):
		_fail("GameState has no display_storehouse/storehouse_milli: the storehouse cannot be shown ticking")
	else:
		_fill_sums()
		_ticks_from_the_snapshot()
		_full_in()
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  %d checks: the purse keeps still, the storehouse fills as Fill does and stops at its capacity" % _checked)
	quit()


func _fail(msg: String) -> void:
	_fails += 1
	print("  FAIL  " + msg)


func _check(ok: bool, msg: String) -> void:
	_checked += 1
	if not ok:
		_fail(msg)


## Adopts a snapshot as if it had arrived `ago_ms` ago.
func _adopt(snap: Dictionary, ago_ms: int) -> void:
	_gs.call("adopt", snap)
	var then := Time.get_ticks_msec() - ago_ms
	# Every anchor a build has kept for its projections, so the old one is
	# measured over the same hour.
	for anchor in ["_energy_at_ms", "_gold_at_ms"]:
		if anchor in _gs:
			_gs.set(anchor, then)


func _snap(gold: String, tax: int, sh: Dictionary) -> Dictionary:
	return {"player": {"gold": gold, "tax_milli_per_hour": tax, "level": 12, "action_seq": 3},
		"energy": {"current": 10, "max": 10}, "storehouse": sh}


func _purse_stays() -> void:
	# An hourly rate of 3,600 gold left in the old field, and an hour gone.
	_adopt(_snap("1000", 3600000, {}), 3600000)
	var g := int(_gs.call("display_gold"))
	_check(g == 1000, "an hour after a snapshot of 1,000 gold the purse shows %d: estate income is predicted into it" % g)
	_check(not _gs.has_method("accrued_tax"), "GameState still has accrued_tax: the purse's old hourly prediction is alive")


func _fill_sums() -> void:
	var f := func(milli: int, rate: int, cap: int, ms: int) -> int:
		return int(_gs.call("storehouse_milli", {"milli": milli, "per_hour_milli": rate, "cap_milli": cap}, ms))
	# Worked through game/estates.Fill by hand: milli + rate * ms / 3,600,000,
	# floored, up to the capacity.
	for row in [
		[123456, 987654, 7901232, 1234567, 462157, "part of an hour"],
		[0, 1000, 8000, 3599, 0, "a milli not yet whole"],
		[0, 1000, 8000, 3600, 1, "the first milli"],
		[7900000, 987654, 7901232, 4000, 7901097, "just short of full"],
		[7900000, 987654, 7901232, 5000, 7901232, "full, and no further"],
		[0, 1000000, 8000000, 50 * 3600000, 8000000, "two days away: the capacity"],
		[9000000, 1000000, 8000000, 5 * 3600000, 9000000, "over the capacity: kept, not added to"],
		[500, 0, 0, 3600000, 500, "no estates: nothing fills"],
		[4000, 1000000, 8000000, 0, 4000, "no time gone"],
		[0, 2500000000, 30000000000, 5 * 3600000, 12500000000, "a late lord's five hours"],
	]:
		var got: int = f.call(row[0], row[1], row[2], row[3])
		_check(got == row[4], "%s: %d milli; Fill says %d" % [row[5], got, row[4]])


func _ticks_from_the_snapshot() -> void:
	var sh := {"gold": 0, "milli": 500, "cap": 8000, "cap_milli": 8000000, "per_hour_milli": 1000000,
		"hours": 8.0, "full_in": 28800, "full": false, "treasury_fee_bp": 1000, "treasury_open": true}
	_adopt(_snap("50", 0, sh.duplicate()), 0)
	_check(int(_gs.call("display_storehouse")) == 0, "at the snapshot the storehouse shows %d, not 0" % int(_gs.call("display_storehouse")))
	_adopt(_snap("50", 0, sh.duplicate()), 3600000)
	var an_hour := int(_gs.call("display_storehouse"))
	# 500 + 1,000,000 milli for the hour, give or take the frame the test took.
	_check(an_hour == 1000, "an hour at 1,000 gold an hour shows %d gold" % an_hour)
	_check(int(_gs.call("display_gold")) == 50, "the purse moved with the storehouse: %d" % int(_gs.call("display_gold")))
	var stored: Dictionary = _gs.get("snapshot")["storehouse"]
	_check(int(stored["milli"]) == 500 and int(stored["gold"]) == 0,
		"the prediction was written into the snapshot: %s" % str(stored))
	_adopt(_snap("50", 0, sh.duplicate()), 11 * 3600000)
	_check(int(_gs.call("display_storehouse")) == 8000, "eleven hours on an eight-hour storehouse shows %d, not its 8,000" % int(_gs.call("display_storehouse")))
	_check(bool(_gs.call("display_storehouse_full")), "a storehouse at its capacity does not say it is full")
	var over := sh.duplicate()
	over["milli"] = 9500000
	over["gold"] = 9500
	over["full"] = true
	over["full_in"] = 0
	_adopt(_snap("50", 0, over), 3 * 3600000)
	_check(int(_gs.call("display_storehouse")) == 9500, "a storehouse over its capacity moved to %d" % int(_gs.call("display_storehouse")))
	# A lord with no snapshot yet, or a server without the storehouse.
	_adopt({"player": {"gold": "0"}}, 3600000)
	_check(int(_gs.call("display_storehouse")) == 0 and not bool(_gs.call("display_storehouse_full")),
		"a snapshot without a storehouse shows one")


func _full_in() -> void:
	var sh := {"gold": 0, "milli": 0, "cap": 8000, "cap_milli": 8000000, "per_hour_milli": 1000000,
		"hours": 8.0, "full_in": 28800, "full": false, "treasury_fee_bp": 1000, "treasury_open": true}
	_adopt(_snap("0", 0, sh.duplicate()), 3600000)
	var left := int(_gs.call("display_storehouse_full_in"))
	_check(left >= 25199 and left <= 25200, "an hour into eight the full-in says %d s, not 7 hours" % left)
	_adopt(_snap("0", 0, sh.duplicate()), 9 * 3600000)
	_check(int(_gs.call("display_storehouse_full_in")) == 0, "a full storehouse still counts down: %d" % int(_gs.call("display_storehouse_full_in")))
	# The server rounds up to the second: one second left is not yet zero.
	var near := sh.duplicate()
	near["milli"] = 7999999
	near["full_in"] = 1
	_adopt(_snap("0", 0, near), 0)
	_check(int(_gs.call("display_storehouse_full_in")) == 1, "a milli short of full reads %d s" % int(_gs.call("display_storehouse_full_in")))
