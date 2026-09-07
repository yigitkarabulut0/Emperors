extends Node
## The client's cache of server truth, plus the optimistic action queue.
##
## A prediction is NEVER written into the snapshot. `snapshot` holds only what
## the server confirmed; what the UI shows is confirmed + replay(pending),
## computed on read. Nothing has to be rolled back because nothing was written.

signal changed
signal energy_changed(current: int)
signal action_failed(message: String)
signal level_up(new_level: int, levels: int, stat_points: int, diamonds: int)
signal mastery_reached(job_id: String, collects: int, bonus_bp: int)

var snapshot: Dictionary = {}
var loading := false

var _pending: Array[Dictionary] = []
const BATCH_MAX := 32
var _sending := false
var _energy_at_ms: int = 0
var _gold_at_ms: int = 0
var _energy_emitted := -1


func _ready() -> void:
	Session.signed_out.connect(func() -> void:
		snapshot = {}
		_pending.clear()
		changed.emit())


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
	snapshot = snap
	_energy_at_ms = Time.get_ticks_msec()
	_gold_at_ms = _energy_at_ms
	if levelled:
		level_up.emit(int(after.get("level", 1)), levels, points, gems)


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


func sections() -> Array:
	return snapshot.get("sections", [])


## Unlock level of a server section ("jobs", "hero", ...), 1 when unknown.
func unlock_level(section_id: String) -> int:
	for s in sections():
		if str(s.get("id", "")) == section_id:
			return int(s.get("unlock_level", 1))
	return 1


func display_gold() -> int:
	var g := int(str(player().get("gold", "0")))
	for a in _pending:
		g += int(a["gold"])
	return g + accrued_tax()


func accrued_tax() -> int:
	var rate := int(player().get("tax_milli_per_hour", 0))
	if rate <= 0:
		return 0
	var elapsed_ms := Time.get_ticks_msec() - _gold_at_ms
	return int(rate * elapsed_ms / 3600000 / 1000)


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


func _mastery_bonus_bp(job_id: String) -> int:
	for j in jobs():
		if str(j.get("id", "")) == job_id:
			return int(j.get("mastery_bonus_bp", 0))
	return 0


## One authenticated action with the sequence number attached. Adopts the
## returned snapshot when the server sends one, else refreshes.
func act(path: String, body: Dictionary = {}) -> Api.Response:
	var b := body.duplicate()
	b["action_seq"] = int(player().get("action_seq", 0)) + 1
	var res: Api.Response = await Api.post_json(path, b)
	if res.ok:
		if res.data.has("snapshot"):
			adopt(res.data["snapshot"])
			changed.emit()
		else:
			await refresh()
	else:
		if res.code == "stale_action":
			await refresh()
		else:
			action_failed.emit(res.error)
	return res
