extends RefCounted
## Calendars and weeks as the server sends them (docs: the Wave 3 contract,
## GET /v1/daily and GET /v1/weekly), for the calendar's tests and previews.
## The squares follow the balance's calendar: diamonds, purse, flask, scroll
## and cart in the painting's order, a crown at the end of each week -- the
## Steadfast's title, the Loyal Vassal's frame, rare gear, and the Crown of
## Constancy's crest with a hundred diamonds.

const ROWS := [
	["diamonds", "purse", "flask", "scroll", "cart", "diamonds", "crown"],
	["diamonds", "purse", "flask", "scroll", "cart", "diamonds", "crown"],
	["purse", "flask", "scroll", "cart", "diamonds", "purse", "crown"],
	["flask", "scroll", "cart", "diamonds", "purse", "flask", "crown"],
]
const DIAMONDS := {1: 10, 6: 20, 7: 25, 8: 15, 13: 25, 14: 30, 19: 30, 21: 35, 25: 50, 28: 100}


## One square's lines, as rewards.Line: the amounts are the late game's, so
## the plates carry their longest figures.
static func lines_for(day: int, kind: String) -> Array:
	var gems := int(DIAMONDS.get(day, 0))
	match kind:
		"diamonds":
			return [{"kind": "diamonds", "amount": gems, "text": "%d diamonds" % gems, "icon": "diamond"}]
		"purse":
			return [{"kind": "gold", "amount": 9876543, "text": "9,876,543 gold", "icon": "gold"}]
		"scroll":
			return [{"kind": "xp", "amount": 123456, "text": "123,456 experience", "icon": "xp"}]
		"flask":
			var big := day > 14
			return [{"kind": "token", "id": "flask_large" if big else "flask_small", "amount": 1,
				"text": "Great Flask" if big else "Small Flask", "icon": "flask_large" if big else "flask_small"}]
		"cart":
			return [{"kind": "token", "id": "cart", "amount": 2 if day > 14 else 1,
				"text": "2 Cart Writs" if day > 14 else "Cart Writ", "icon": "cart"}]
		"crown":
			var prize: Dictionary = {
				7: {"kind": "cosmetic", "id": "title_steadfast", "amount": 1, "text": "The Steadfast (title)", "icon": "title:title_steadfast"},
				14: {"kind": "cosmetic", "id": "frame_loyal_vassal", "amount": 1, "text": "Loyal Vassal (frame)", "icon": "frames/loyal_vassal"},
				21: {"kind": "item", "id": "rare", "amount": 1, "text": "Rare gear", "icon": "item:rare", "tier": "rare"},
				28: {"kind": "cosmetic", "id": "crest_constancy", "amount": 1, "text": "Crown of Constancy (crest)", "icon": "icons/crest_constancy"},
			}.get(day, {})
			return [{"kind": "diamonds", "amount": gems, "text": "%d diamonds" % gems, "icon": "diamond"}, prize]
	return []


## The calendar with `day` the square a claim takes (or took, when
## `claimed_today`), everything before it taken.
static func daily(day: int, claimable: bool = true, streak: int = 0, broken: Variant = null,
		pardons: int = 1, diamonds: int = 127) -> Dictionary:
	var squares: Array = []
	for i in 28:
		var n := i + 1
		var kind: String = ROWS[i / 7][i % 7]
		var lines := lines_for(n, kind)
		var state := "ahead"
		if n < day or (n == day and not claimable):
			state = "claimed"
		elif n == day:
			state = "today"
		if n == day and not claimable:
			state = "claimed"
		var amount := int(lines[0].get("amount", 0)) if not lines.is_empty() else 0
		squares.append({"day": n, "crown": kind == "crown", "state": state, "kind": kind,
			"icon": str(lines[0].get("icon", "")) if not lines.is_empty() else "",
			"amount": amount, "text": str(lines[0].get("text", "")) if not lines.is_empty() else "", "lines": lines})
	var rewards: Array = []
	for i in 28:
		rewards.append(int(DIAMONDS.get(i + 1, 0)))
	return {"day": day, "claimable": claimable, "claimed_today": not claimable, "streak": streak,
		"cycle": 0, "broken": broken, "pardons": pardons, "pardons_max": 2, "diamonds": diamonds,
		"squares": squares, "reward": int(DIAMONDS.get(day, 0)), "rewards": rewards}


## A broken streak: `missed` days missed.
static func broken(missed: int, can_pardon: bool) -> Dictionary:
	return {"missed": missed, "restore_diamonds": 20 if missed == 1 else 50, "can_restore": true,
		"can_pardon": can_pardon}


## This week at `points`, chests `taken` (tier numbers) already claimed.
static func weekly(points: int, taken: Array = []) -> Dictionary:
	var chests: Array = []
	for i in 3:
		var at: int = [80, 160, 240][i]
		chests.append({"tier": i, "at": at, "ready": points >= at, "claimed": i in taken,
			"lines": [{"kind": "diamonds", "amount": 20, "text": "20 diamonds", "icon": "diamond"}]})
	return {"week": "2026-09-14", "ends_in": 345600, "points": points, "points_max": 240, "tasks": [], "chests": chests}
