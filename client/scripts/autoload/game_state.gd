extends Node
## The client's cache of server truth, plus the optimistic action queue.
##
## The rule that keeps this honest: a prediction is NEVER written into the
## snapshot. `snapshot` only ever holds what the server confirmed. What the UI
## displays is `confirmed + replay(pending)`, computed on read. That way a failed
## or reordered action cannot leave a phantom number behind — there is nothing to
## roll back, because nothing was ever written.

signal changed                      ## snapshot or pending queue moved
signal action_failed(message: String)
signal level_up(new_level: int)

var snapshot: Dictionary = {}
var loading := false

## Queued collects that have not been confirmed yet. Each is
## {job_id, gold, xp, energy_cost}.
var _pending: Array[Dictionary] = []
var _sending := false


func _ready() -> void:
	Session.signed_out.connect(func() -> void:
		snapshot = {}
		_pending.clear()
		changed.emit())


func has_state() -> bool:
	return not snapshot.is_empty()


func refresh() -> void:
	if loading:
		return
	loading = true
	var res: Api.Response = await Api.get_json("/v1/state")
	loading = false
	if res.ok:
		snapshot = res.data
		changed.emit()
	else:
		action_failed.emit(res.error)


# --- displayed values: confirmed + replay(pending) ----------------------------

func display_gold() -> int:
	var g := int(str(snapshot.get("player", {}).get("gold", "0")))
	for a in _pending:
		g += int(a["gold"])
	return g


func display_energy() -> int:
	var e := int(snapshot.get("energy", {}).get("current", 0))
	for a in _pending:
		e -= int(a["energy_cost"])
	return maxi(e, 0)


func max_energy() -> int:
	return int(snapshot.get("energy", {}).get("max", 0))


func player() -> Dictionary:
	return snapshot.get("player", {})


func jobs() -> Array:
	return snapshot.get("jobs", [])


func pending_count() -> int:
	return _pending.size()


# --- actions ------------------------------------------------------------------

## Queues one collect. Returns false when it is not affordable right now, so the
## caller can give immediate feedback without a round trip.
func collect(job: Dictionary) -> bool:
	if not bool(job.get("unlocked", false)):
		return false
	var cost := int(job.get("energy_cost", 0))
	if display_energy() < cost:
		return false

	_pending.append({
		"job_id": job.get("id", ""),
		# The server ships RESOLVED payouts, so predicting is a table lookup
		# rather than a second implementation of the economy that could drift.
		"gold": int(job.get("gold_payout", 0)),
		"xp": int(job.get("xp_payout", 0)),
		"energy_cost": cost,
	})
	changed.emit()
	_pump()
	return true


## Sends queued actions strictly one at a time.
##
## action_seq is a per-player monotonic counter, so requests cannot overlap:
## two in flight would race for the same number and one would be rejected.
func _pump() -> void:
	if _sending or _pending.is_empty() or snapshot.is_empty():
		return
	_sending = true

	while not _pending.is_empty():
		var action: Dictionary = _pending[0]
		var seq := int(player().get("action_seq", 0)) + 1

		var res: Api.Response = await Api.post_json("/v1/collect", {
			"job_id": action["job_id"],
			"action_seq": seq,
		})

		if res.ok:
			_pending.pop_front()
			var before := int(player().get("level", 1))
			snapshot = res.data.get("snapshot", snapshot)
			var after := int(player().get("level", 1))
			if after > before:
				level_up.emit(after)
			changed.emit()
			continue

		# Any failure drops the whole queue and resyncs. Keeping the rest would
		# mean sending actions the player may no longer be able to afford, and
		# each would fail in turn.
		_pending.clear()
		changed.emit()
		if res.code != "stale_action":
			action_failed.emit(res.error)
		await refresh()
		break

	_sending = false
