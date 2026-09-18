class_name LiveEvents
extends RefCounted
## The server's live events -- snapshot.live -- read one way everywhere: the
## Collect tab's event band, and the COURT tab's EVENTS card and the rail's seal.
##
## The server sends every figure resolved (server/internal/service/live.go):
## each event's bucket, what it gives (bp), what it is worth to this lord
## (effective_bp: the bucket's timed lane after its cap, with every other timed
## bonus they hold) and its seconds left, as of the snapshot. Nothing here
## computes a game number: a time is counted down from the snapshot's moment,
## as the energy and shield timers are, and never written back.
##
##   snapshot.live = {boosts: [{bucket, bp, effective_bp, ends_in}],
##                    upcoming: [{bucket, bp, effective_bp, starts_in, ends_in}]}

## The buckets an operator may run an event on, named as the game names them.
const NAMES := {"collect_income_bp": "Job payout", "xp_bp": "Experience", "luck_bp": "Fortune"}


## What each bucket's event moves, as the panel's Events page explains it to
## the operator (admin /boosts' help), in the game's words: a phrase to follow
## "+50% for you, ".
const WHAT := {
	"collect_income_bp": "on the gold of every collect",
	"xp_bp": "on experience from every source",
	"luck_bp": "on the shop's stock and your recruits",
}


## An event's name, from its bucket. An unknown bucket reads as its own words.
static func name(bucket: String) -> String:
	if NAMES.has(bucket):
		return str(NAMES[bucket])
	return bucket.trim_suffix("_bp").replace("_", " ").capitalize()


## What an event moves, a phrase; "" for a bucket the game has no words for.
static func what(bucket: String) -> String:
	return str(WHAT.get(bucket, ""))


## The events running now, the one that ends first first.
static func running(live: Dictionary) -> Array:
	var out: Array = (live.get("boosts", []) as Array).duplicate() if live.get("boosts") is Array else []
	out.sort_custom(func(a, b): return int(a.get("ends_in", 0)) < int(b.get("ends_in", 0)))
	return out


## The events scheduled to start within the day, the soonest first.
static func upcoming(live: Dictionary) -> Array:
	var out: Array = (live.get("upcoming", []) as Array).duplicate() if live.get("upcoming") is Array else []
	out.sort_custom(func(a, b): return int(a.get("starts_in", 0)) < int(b.get("starts_in", 0)))
	return out


## The running event that ends first, or {} when none is running.
static func soonest(live: Dictionary) -> Dictionary:
	var r := running(live)
	return r[0] if not r.is_empty() else {}


## Basis points as the game writes a bonus: "+50%", "-25%", "+12.5%".
static func percent(bp: int) -> String:
	var sign := "+" if bp >= 0 else "-"
	var a := absi(bp)
	if a % 100 == 0:
		return "%s%d%%" % [sign, a / 100]
	var s := ("%.2f" % (a / 100.0)).rstrip("0").rstrip(".")
	return "%s%s%%" % [sign, s]


## What an event is worth to this lord, in the band's words: "+50% for you".
## The server's figure, never the event's own: the bucket's whole timed lane,
## so another timed bonus they hold lifts it ("+70%"), the lane's cap stops it
## (a capped lord reads the cap), and a nerf in the same bucket cancels it --
## "+0% for you", or less, in which case it is said as a loss ("-25%"). A nerf
## never takes a payout under base, so a lord with nothing to lose reads +0%.
static func worth(event: Dictionary) -> String:
	return "%s for you" % percent(int(event.get("effective_bp", event.get("bp", 0))))


## Seconds left of an event -- until it ends (key "ends_in") or starts
## ("starts_in") -- counted down from the snapshot's moment, `elapsed_s` ago.
static func left(event: Dictionary, elapsed_s: int, key: String = "ends_in") -> int:
	return maxi(0, int(event.get(key, 0)) - elapsed_s)


# --- the hour's event and the festival (Wave 4) ------------------------------------
#
#   snapshot.live.hourly   = {id ("" in a quiet hour), name, blurb, icon, kind,
#                             bucket, bp, effective_bp, x, left, lines, active,
#                             ends_in, next_in, next {id, name, blurb, icon} | null}
#   snapshot.live.festival = {id, name, theme, blurb, bucket, bp, effective_bp,
#                             running, starts_in, ends_in, points} | null
#
# An hourly event lasts its minutes from the top of the hour: once they are
# over it is not running, though its id still names the hour. Every figure is
# the server's; the words are the game's.

## The hour's event while it runs -- its minutes not yet over, counted down
## from the snapshot. {} in a quiet hour or once its minutes are spent.
static func hourly_running(live: Dictionary, age_s: int) -> Dictionary:
	var h: Variant = live.get("hourly")
	if not (h is Dictionary) or str(h.get("id", "")) == "" or not bool(h.get("active", false)):
		return {}
	return h if left(h, age_s) > 0 else {}


## The next hour's event, announced: {id, name, blurb, icon}; {} when the next
## hour is quiet.
static func hourly_next(live: Dictionary) -> Dictionary:
	var h: Variant = live.get("hourly")
	if not (h is Dictionary):
		return {}
	var n: Variant = h.get("next")
	return n if n is Dictionary and str(n.get("id", "")) != "" else {}


## Seconds until the next hour -- and its event -- begins.
static func hourly_next_in(live: Dictionary, age_s: int) -> int:
	var h: Variant = live.get("hourly")
	return left(h, age_s, "next_in") if h is Dictionary else 0


## Which hour the snapshot's hour is, counted from the epoch: the next hour's
## top, less one. Two snapshots of the same hour say the same number, so a
## moment shown once an hour (the start popup) is shown once.
static func hour_index(live: Dictionary, age_s: int, now_unix: int) -> int:
	return (now_unix + hourly_next_in(live, age_s)) / 3600 - 1


## The festival while it runs, with time left; {}.
static func festival_running(live: Dictionary, age_s: int) -> Dictionary:
	var f: Variant = live.get("festival")
	if not (f is Dictionary) or not bool(f.get("running", false)):
		return {}
	return f if left(f, age_s) > 0 else {}


## The festival announced and not yet begun; {}.
static func festival_coming(live: Dictionary, age_s: int) -> Dictionary:
	var f: Variant = live.get("festival")
	if not (f is Dictionary) or bool(f.get("running", false)):
		return {}
	return f if left(f, age_s, "starts_in") > 0 else {}


## What the hour's event does for this lord, in the band's words. The kind's
## figure is the server's: a boost's effective_bp, a sale's bp, the free
## restocks and the courier's gift still left, Busy Hands' x.
static func hourly_worth(h: Dictionary) -> String:
	match str(h.get("kind", "")):
		"boost":
			return worth(h)
		"refill_discount":
			return "Refills %s" % percent(-int(h.get("bp", 0)))
		"free_reroll":
			var n := int(h.get("left", 0))
			if n <= 0:
				return "Free restock taken"
			return "%d free restock%s" % [n, "" if n == 1 else "s"]
		"quest_multiplier":
			return "Quests count ×%d" % maxi(1, int(h.get("x", 1)))
		"gift":
			if int(h.get("left", 0)) <= 0:
				return "Gift taken"
			return "%s for you" % gift_words(h)
	return ""


## What the courier brings, as its lines say it: "Cart Writ".
static func gift_words(h: Dictionary) -> String:
	var words: Array[String] = []
	for l in h.get("lines", []):
		if l is Dictionary and str(l.get("text", "")) != "":
			words.append(str(l.get("text", "")))
	return ", ".join(words) if not words.is_empty() else "A gift"


## Whether the hour's gift is there to take now.
static func gift_waiting(h: Dictionary) -> bool:
	return str(h.get("kind", "")) == "gift" and int(h.get("left", 0)) > 0


## What a festival is worth to this lord, in the band's words: gold and
## experience as "+25% for you"; renown as "+50% renown"; the market's discount
## as "10% off the market" (the whole of what it takes off for them).
static func festival_worth(f: Dictionary) -> String:
	var eff := int(f.get("effective_bp", f.get("bp", 0)))
	match str(f.get("bucket", "")):
		"reputation_bp":
			return "%s renown" % percent(eff)
		"shop_discount_bp":
			return "%s off the market" % percent(eff).trim_prefix("+")
	return worth(f)


## What the Collect band shows, the first of: the hour's event running; an
## operator's event running (the one ending first); the festival running; the
## next hour's event; the festival announced. {} when there is nothing to say.
##
##   {kind: hourly | boost | festival | next | coming, name, worth, red (a loss),
##    more (the others running), left (seconds, to its end or its start),
##    icon (hourly/<id> or ""), claim (the courier's gift is waiting)}
static func band(live: Dictionary, age_s: int) -> Dictionary:
	var h := hourly_running(live, age_s)
	var boosts := running(live).filter(func(e): return left(e, age_s) > 0)
	var fest := festival_running(live, age_s)
	var others := boosts.size() + (0 if fest.is_empty() else 1)
	if not h.is_empty():
		return {"kind": "hourly", "name": str(h.get("name", "")), "worth": hourly_worth(h),
			"red": str(h.get("kind", "")) == "boost" and int(h.get("effective_bp", 0)) < 0,
			"more": others, "left": left(h, age_s), "icon": str(h.get("icon", "")), "claim": gift_waiting(h)}
	if not boosts.is_empty():
		var e: Dictionary = boosts[0]
		return {"kind": "boost", "name": name(str(e.get("bucket", ""))), "worth": worth(e),
			"red": int(e.get("effective_bp", e.get("bp", 0))) < 0, "more": others - 1,
			"left": left(e, age_s), "icon": "", "claim": false}
	if not fest.is_empty():
		return {"kind": "festival", "name": str(fest.get("name", "")), "worth": festival_worth(fest),
			"red": false, "more": 0, "left": left(fest, age_s), "icon": "", "claim": false}
	var n := hourly_next(live)
	if not n.is_empty():
		return {"kind": "next", "name": str(n.get("name", "")), "worth": "Next hour", "red": false, "more": 0,
			"left": hourly_next_in(live, age_s), "icon": str(n.get("icon", "")), "claim": false}
	var c := festival_coming(live, age_s)
	if not c.is_empty():
		return {"kind": "coming", "name": str(c.get("name", "")), "worth": "Coming soon", "red": false, "more": 0,
			"left": left(c, age_s, "starts_in"), "icon": "", "claim": false}
	return {}


## The seal at the rail's foot: "blazing" while an event runs -- the hour's,
## an operator's or a festival -- "lit" while one is only announced, "dark"
## with neither; and its time: the running event's time left (the hour's
## first, then the one ending soonest), else "in ..." to the soonest start.
static func seal(live: Dictionary, age_s: int) -> Dictionary:
	var ends: Array[int] = []
	var h := hourly_running(live, age_s)
	if not h.is_empty():
		return {"state": "blazing", "text": UI.time_left(left(h, age_s))}
	for e in running(live):
		if left(e, age_s) > 0:
			ends.append(left(e, age_s))
	var f := festival_running(live, age_s)
	if not f.is_empty():
		ends.append(left(f, age_s))
	if not ends.is_empty():
		ends.sort()
		return {"state": "blazing", "text": UI.time_left(ends[0])}
	var starts: Array[int] = []
	if not hourly_next(live).is_empty():
		starts.append(hourly_next_in(live, age_s))
	for e in upcoming(live):
		starts.append(left(e, age_s, "starts_in"))
	var c := festival_coming(live, age_s)
	if not c.is_empty():
		starts.append(left(c, age_s, "starts_in"))
	if not starts.is_empty():
		starts.sort()
		return {"state": "lit", "text": "in " + UI.time_left(starts[0])}
	return {"state": "dark", "text": ""}
