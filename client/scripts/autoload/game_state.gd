extends Node
## The client's cache of server truth, plus the optimistic action queue.
##
## A prediction is NEVER written into the snapshot. `snapshot` holds only what
## the server confirmed; what the UI shows is confirmed + replay(pending),
## computed on read. Nothing has to be rolled back because nothing was written.

signal changed
signal energy_changed(current: int)
signal action_failed(message: String)
## An action refused because the armory is full (409 inventory_full: a shop
## buy, a reroll, a deal). Not a toast: the shell says it with a dialog that
## offers MORE ROOM beside its OK (Armory.refused).
signal armory_full(message: String)
## Good news for the toast: "Bought ...", "Equipped 2 items". It used to go out
## on action_failed, which is why a success read like an error to anything
## that listened for errors.
signal notice(message: String)
signal level_up(new_level: int, levels: int, stat_points: int, diamonds: int)
signal mastery_reached(job_id: String, collects: int, bonus_bp: int)
signal badges_changed
## A collect answer the Golden Hour touched: the gold it added (0 on the answer
## that only lit it) and whether this answer lit it.
signal golden_hour(gold: int, started: bool)

var snapshot: Dictionary = {}
## What is waiting for the player, from the heartbeat: {quests, daily, revenge,
## requests, mail}. The rail's bubbles and the pages that clear them read this.
var badges: Dictionary = {}
var loading := false
## The sections the last level-up opened, for the ceremony to name.
var last_unlocked: Array = []

var _pending: Array[Dictionary] = []
const BATCH_MAX := 32
var _sending := false
## When the snapshot was adopted: every figure counted on from it (energy, the
## shield, the storehouse, what is live) has moved since by the time from here.
var _energy_at_ms: int = 0
var _energy_emitted := -1
var _refresh_after_pump := false


func _ready() -> void:
	Session.signed_out.connect(func() -> void:
		snapshot = {}
		badges = {}
		_pending.clear()
		changed.emit()
		badges_changed.emit())


## The single choke point for a snapshot replacement: restamps the projection
## anchors and notices a level-up for every path (collect, raid, purchase...).
func adopt(snap: Dictionary) -> void:
	var before: Dictionary = snapshot.get("player", {})
	var after: Dictionary = snap.get("player", {})
	var levelled := not before.is_empty() and int(after.get("level", 1)) > int(before.get("level", 1))
	var levels := 0
	var points := 0
	var gems := 0
	if levelled:
		levels = int(after.get("level", 1)) - int(before.get("level", 1))
		points = int(after.get("stat_points_unspent", 0)) - int(before.get("stat_points_unspent", 0))
		gems = int(after.get("diamonds", 0)) - int(before.get("diamonds", 0))
	var was_open := {}
	for sec in snapshot.get("sections", []):
		if bool(sec.get("unlocked", false)):
			was_open[str(sec.get("id", ""))] = true
	snapshot = snap
	_energy_at_ms = Time.get_ticks_msec()
	if levelled:
		last_unlocked = []
		for sec in snap.get("sections", []):
			if bool(sec.get("unlocked", false)) and not was_open.has(str(sec.get("id", ""))):
				last_unlocked.append(str(sec.get("id", "")))
		level_up.emit(int(after.get("level", 1)), levels, points, gems)


## A snapshot from an endpoint that does not advance action_seq -- a letter
## claimed, and later a purchase delivered. While a batch of collects is in
## flight its answer may land before or after this one, and either order could
## put an older purse on the screen; so the state is fetched again once the
## batch has landed rather than guessed at.
func adopt_async(snap: Dictionary) -> void:
	if _sending:
		_refresh_after_pump = true
		return
	adopt(snap)
	changed.emit()


## Replaces what is waiting, from a heartbeat or a page that just cleared some.
func set_badges(b: Dictionary) -> void:
	if b == badges:
		return
	badges = b
	badges_changed.emit()


func has_state() -> bool:
	return not snapshot.is_empty()


func refresh() -> void:
	if loading:
		return
	loading = true
	var res: Api.Response = await Api.get_json("/v1/state")
	loading = false
	if res.ok:
		adopt(res.data)
		changed.emit()
	else:
		action_failed.emit(res.error)


# --- displayed values: confirmed + replay(pending) ----------------------------

func player() -> Dictionary:
	return snapshot.get("player", {})


func jobs() -> Array:
	return snapshot.get("jobs", [])


## What is running for everyone (snapshot.live; read it through LiveEvents),
## and how many seconds ago the snapshot said so -- its times count down from
## then.
func live() -> Dictionary:
	var l: Variant = snapshot.get("live", {})
	return l if l is Dictionary else {}


func live_age_s() -> int:
	return (Time.get_ticks_msec() - _energy_at_ms) / 1000


## The hour's event (live.hourly): {id ("" in a quiet hour), name, blurb,
## icon, kind (boost | refill_discount | free_reroll | quest_multiplier |
## gift), bucket, bp, effective_bp, x, left, lines, active, ends_in, next_in,
## next {id, name, blurb, icon} or null}. ends_in and next_in count down from
## live_age_s().
func hourly() -> Dictionary:
	var h: Variant = live().get("hourly", {})
	return h if h is Dictionary else {}


## The festival running, or the next one announced (live.festival): {id, name,
## theme, blurb, bucket, bp, effective_bp, running, starts_in, ends_in,
## points}; {} when neither.
func festival() -> Dictionary:
	var f: Variant = live().get("festival")
	return f if f is Dictionary else {}


## The season and this lord's Royal Charter (live.season): {number, ends_in,
## tier, tiers, royal}.
func season() -> Dictionary:
	var s: Variant = live().get("season", {})
	return s if s is Dictionary else {}


## The Tax Cart as the snapshot last said: {unlocked, unlock_level, stock,
## cap, tokens, next_in, interval}. next_in counts down from live_age_s().
func cart() -> Dictionary:
	var c: Variant = snapshot.get("cart", {})
	return c if c is Dictionary else {}


## The Golden Hour: {unlocked, meter, active, ends_in, energy_left, used,
## per_day, ready_in, window, bp}. Confirmed state only -- it is never
## predicted; each collect answer brings the next one.
func frenzy() -> Dictionary:
	var f: Variant = snapshot.get("frenzy", {})
	return f if f is Dictionary else {}


## The guide through the first ten minutes: {active, step, index, count,
## ready, tab, target, min_level, title, text, tap}; {active: false} when done.
func guide() -> Dictionary:
	var g: Variant = snapshot.get("guide", {})
	return g if g is Dictionary else {}


func sections() -> Array:
	return snapshot.get("sections", [])


## Unlock level of a server section ("jobs", "hero", ...), 1 when unknown.
func unlock_level(section_id: String) -> int:
	for s in sections():
		if str(s.get("id", "")) == section_id:
			return int(s.get("unlock_level", 1))
	return 1


## Whether the server has opened a section for this player. Its answer, not a
## level comparison made here: a lord in a kingdom keeps its tab below the
## level that first opened it (after a Legacy, say).
func is_unlocked(section_id: String) -> bool:
	for s in sections():
		if str(s.get("id", "")) == section_id:
			if s.has("unlocked"):
				return bool(s["unlocked"])
			return int(player().get("level", 1)) >= int(s.get("unlock_level", 1))
	return true


## Says something good on the toast.
func toast(message: String) -> void:
	notice.emit(message)


## The purse: what the server confirmed and the collects still on their way.
## Nothing else moves it between snapshots. The estates' income used to be
## added here by the hour; it fills the storehouse now (display_storehouse), and
## reaches the purse only when the lord carries it in.
func display_gold() -> int:
	var g := int(str(player().get("gold", "0")))
	for a in _pending:
		g += int(a["gold"])
	return g


# --- the storehouse -------------------------------------------------------------

## One settlement's elapsed time at most, as game/estates.Fill bounds it.
const STOREHOUSE_MAX_FILL_MS := 400 * 24 * 3600 * 1000


## The storehouse as the snapshot settled it (snapshot.storehouse): {gold,
## milli, cap, cap_milli, per_hour_milli, hours, full_in, full,
## treasury_fee_bp, treasury_open}.
func storehouse() -> Dictionary:
	var s: Variant = snapshot.get("storehouse", {})
	return s if s is Dictionary else {}


## Whole gold waiting in the storehouse now: the snapshot's, filled since at its
## rate up to its capacity. Computed on read and never written; the server
## settles the same sum when the lord carries it in.
func display_storehouse() -> int:
	return display_storehouse_milli() / 1000


func display_storehouse_milli() -> int:
	return storehouse_milli(storehouse(), Time.get_ticks_msec() - _energy_at_ms)


## Whether it is full now, and so filling no more.
func display_storehouse_full() -> bool:
	var cap := int(storehouse().get("cap_milli", 0))
	return cap > 0 and display_storehouse_milli() >= cap


## Seconds until it is full, counted down from the snapshot's; 0 once it is.
func display_storehouse_full_in() -> int:
	if display_storehouse_full():
		return 0
	var secs := int(storehouse().get("full_in", 0))
	if secs <= 0:
		return 0
	# The server rounds up to the second, so the count reads 1 until the fill says full.
	return maxi(1, secs - (Time.get_ticks_msec() - _energy_at_ms) / 1000)


## game/estates.Fill over a snapshot's storehouse: what it holds elapsed_ms
## after the snapshot, in milli-gold. Below the capacity the rate fills it, up
## to the capacity and no further; what is already over it (a rate that fell
## since it filled) stays as it is.
static func storehouse_milli(sh: Dictionary, elapsed_ms: int) -> int:
	var milli := int(sh.get("milli", 0))
	var cap := int(sh.get("cap_milli", 0))
	var rate := int(sh.get("per_hour_milli", 0))
	if elapsed_ms <= 0 or rate <= 0 or milli >= cap:
		return milli
	return mini(cap, milli + rate * mini(elapsed_ms, STOREHOUSE_MAX_FILL_MS) / 3600000)


func display_xp() -> int:
	var xp := int(player().get("xp", 0))
	for a in _pending:
		xp += int(a.get("xp", 0))
	var need := xp_to_next()
	if need <= 0:
		return xp
	return mini(xp, maxi(0, need - 1))


func xp_to_next() -> int:
	return int(player().get("xp_to_next", 0))


func _energy_progress_ms() -> int:
	var e: Dictionary = snapshot.get("energy", {})
	var cur := int(e.get("current", 0))
	var mx := int(e.get("max", 0))
	var period := int(e.get("regen_period_ms", 0))
	if period <= 0 or cur >= mx:
		return 0
	var to_full_ms := int(e.get("seconds_to_full", 0)) * 1000
	var banked: int = maxi(0, (mx - cur) * period - to_full_ms)
	return banked + (Time.get_ticks_msec() - _energy_at_ms)


func display_energy() -> int:
	var e: Dictionary = snapshot.get("energy", {})
	var v := int(e.get("current", 0))
	var mx := int(e.get("max", 0))
	var period := int(e.get("regen_period_ms", 0))
	if period > 0 and v < mx:
		v = mini(mx, v + _energy_progress_ms() / period)
	for a in _pending:
		v -= int(a["energy_cost"])
	return maxi(v, 0)


func display_seconds_to_next() -> int:
	var e: Dictionary = snapshot.get("energy", {})
	var period := int(e.get("regen_period_ms", 0))
	if period <= 0 or display_energy() >= max_energy():
		return 0
	return int(ceil(float(period - _energy_progress_ms() % period) / 1000.0))


func display_seconds_to_full() -> int:
	var secs := int(snapshot.get("energy", {}).get("seconds_to_full", 0))
	if secs <= 0:
		return 0
	var gone := (Time.get_ticks_msec() - _energy_at_ms) / 1000
	return maxi(0, secs - gone)


## Seconds of protection left, counted down from the snapshot.
func display_shield_seconds() -> int:
	var secs := int(player().get("shield_seconds", 0))
	if secs <= 0:
		return 0
	return maxi(0, secs - (Time.get_ticks_msec() - _energy_at_ms) / 1000)


func max_energy() -> int:
	return int(snapshot.get("energy", {}).get("max", 0))


## Called from the shell's 4 Hz tick; emits only when the whole number moves.
func tick_projection() -> void:
	if snapshot.is_empty():
		return
	var v := display_energy()
	if v != _energy_emitted:
		_energy_emitted = v
		energy_changed.emit(v)


## Optimistic collects queued for one job: what a row adds to its confirmed
## count so the counter and the mastery track move on the tap, not on the reply.
func pending_collects(job_id: String) -> int:
	var n := 0
	for a in _pending:
		if str(a.get("job_id", "")) == job_id:
			n += 1
	return n


func pending_count() -> int:
	return _pending.size()


# --- actions ------------------------------------------------------------------

## Queues one collect; false when it is not affordable right now.
func collect(job: Dictionary) -> bool:
	if not bool(job.get("unlocked", false)):
		return false
	var cost := int(job.get("energy_cost", 0))
	if display_energy() < cost:
		return false
	_pending.append({
		"job_id": job.get("id", ""),
		"gold": int(job.get("gold_payout", 0)),
		"xp": int(job.get("xp_payout", 0)),
		"energy_cost": cost,
	})
	changed.emit()
	_pump()
	return true


## Sends the whole queue in one request; only the applied ones leave the queue.
func _pump() -> void:
	if _sending or _pending.is_empty() or snapshot.is_empty():
		return
	_sending = true
	while not _pending.is_empty():
		var batch: Array[String] = []
		for a in _pending:
			if batch.size() >= BATCH_MAX:
				break
			batch.append(str(a["job_id"]))
		var seq := int(player().get("action_seq", 0)) + 1
		var res: Api.Response = await Api.post_json("/v1/collect/batch", {"job_ids": batch, "action_seq": seq})
		if res.ok:
			var applied: int = mini(int(res.data.get("applied", 0)), _pending.size())
			adopt(res.data.get("snapshot", snapshot))
			for i in applied:
				_pending.pop_front()
			var hit := int(res.data.get("milestone_hit", 0))
			if hit > 0:
				var job_id := str(res.data.get("milestone_job", ""))
				mastery_reached.emit(job_id, hit, _mastery_bonus_bp(job_id))
			var golden := int(res.data.get("frenzy_gold", 0))
			if golden > 0 or bool(res.data.get("frenzy_started", false)):
				golden_hour.emit(golden, bool(res.data.get("frenzy_started", false)))
			changed.emit()
			if applied == 0:
				_pending.clear()
				changed.emit()
				break
			continue
		_pending.clear()
		changed.emit()
		if res.code != "stale_action":
			action_failed.emit(res.error)
		await refresh()
		break
	_sending = false
	if _refresh_after_pump:
		_refresh_after_pump = false
		await refresh()


func _mastery_bonus_bp(job_id: String) -> int:
	for j in jobs():
		if str(j.get("id", "")) == job_id:
			return int(j.get("mastery_bonus_bp", 0))
	return 0


## One authenticated action with the sequence number attached. Adopts the
## returned snapshot when the server sends one, else refreshes. `refusals`
## says a refusal in the screen's own words, {code: sentence}; a code it does
## not name is said as the server put it.
func act(path: String, body: Dictionary = {}, refusals: Dictionary = {}) -> Api.Response:
	var b := body.duplicate()
	b["action_seq"] = int(player().get("action_seq", 0)) + 1
	var res: Api.Response = await Api.post_json(path, b)
	if res.ok:
		if res.data.get("snapshot", null) is Dictionary:
			adopt(res.data["snapshot"])
			changed.emit()
		elif res.data.has("player") and res.data.has("energy"):
			# A few actions answer with the snapshot itself (stats, rename).
			adopt(res.data)
			changed.emit()
		else:
			await refresh()
	else:
		if res.code == "stale_action":
			await refresh()
		elif res.code == "inventory_full":
			armory_full.emit(res.error)
		else:
			action_failed.emit(str(refusals.get(res.code, res.error)))
	return res
