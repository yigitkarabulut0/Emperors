extends Node
## The kingdom's hall, live.
##
## One websocket to GET /v1/realtime, which the server puts in the room of
## whichever kingdom this lord belongs to (internal/realtime). It carries only
## what ANOTHER lord did in the same room -- a line said, a call for aid, the
## shared goal's bar moving. Everything a lord does themselves arrives in the
## answer to their own tap, as it always has.
##
## Three things make this safe to leave running on a phone.
##
## It is OPT-IN per screen: `listen()` while a screen that wants it is open,
## `hush()` when it closes. A socket nobody is reading is a radio left on.
##
## It FALLS BACK. After three failed connections in a row it stops trying and
## says so (`degraded`), and the screens poll instead -- which is what they do
## on a server with no hall at all. A feature that is only live is a feature
## that is broken on a train.
##
## It never carries an ACTION. A line is said over HTTP, where the rate limit,
## the filter and the transaction are; anything this socket receives is a
## statement about the room, never a command, and anything it sends is nothing.

signal frame(kind: String, data: Dictionary)
## Raised when the socket gives up and the screens should poll instead, and
## again when it comes back.
signal degraded(on: bool)

## The close code the server sends when the token it was opened with has run
## out (realtime.StatusReauth). Not a failure: reconnect with a fresh one.
const REAUTH := 4001
## Tries before falling back to polling, and how long to wait between them.
const TRIES := 3
const RETRY_SECONDS := [1.0, 3.0, 8.0]
## A socket idle this long with no ping is treated as gone: the server pings
## every 20 seconds, so 50 is two missed pings and a margin.
const SILENCE := 50.0

var _ws: WebSocketPeer = null
var _listeners := 0
var _tries := 0
var _wait := 0.0
var _last := 0.0
var _fallback := false
var _epoch := ""


func _ready() -> void:
	set_process(false)


## A screen that wants the room live says so; the last one to leave hushes it.
func listen() -> void:
	_listeners += 1
	if _listeners == 1:
		_fallback = false
		_tries = 0
		_open()


func hush() -> void:
	_listeners = maxi(0, _listeners - 1)
	if _listeners == 0:
		_close()


## Whether the screens should poll: no socket, or it gave up.
func polling() -> bool:
	return _fallback or _ws == null


func _open() -> void:
	if Session.access_token == "":
		_give_up()
		return
	var url := Env.api_base_url.replace("https://", "wss://").replace("http://", "ws://") + "/v1/realtime"
	_ws = WebSocketPeer.new()
	# The token goes in the HEADER, like every other call: a token in a query
	# string is a token in a proxy log.
	_ws.handshake_headers = PackedStringArray(["Authorization: Bearer " + Session.access_token])
	var err := _ws.connect_to_url(url)
	if err != OK:
		_ws = null
		_retry()
		return
	_last = Time.get_ticks_msec() / 1000.0
	set_process(true)


func _close() -> void:
	set_process(false)
	if _ws != null:
		_ws.close(1000, "done")
		_ws = null


func _retry() -> void:
	_tries += 1
	if _tries > TRIES:
		_give_up()
		return
	_wait = RETRY_SECONDS[mini(_tries - 1, RETRY_SECONDS.size() - 1)]
	set_process(true)


func _give_up() -> void:
	_close()
	if not _fallback:
		_fallback = true
		degraded.emit(true)


func _process(delta: float) -> void:
	if _listeners == 0:
		_close()
		return
	if _ws == null:
		if _fallback:
			set_process(false)
			return
		_wait -= delta
		if _wait <= 0.0:
			_open()
		return

	_ws.poll()
	match _ws.get_ready_state():
		WebSocketPeer.STATE_OPEN:
			var now := Time.get_ticks_msec() / 1000.0
			while _ws.get_available_packet_count() > 0:
				_last = now
				_take(_ws.get_packet().get_string_from_utf8())
			if now - _last > SILENCE:
				# Nothing at all, not even a ping: the socket is half open.
				_ws = null
				_retry()
		WebSocketPeer.STATE_CLOSED:
			var code := _ws.get_close_code()
			_ws = null
			if code == REAUTH:
				# The token ran out. Session keeps it fresh; open again with
				# whatever it holds now, and count it as a try so a broken
				# refresh cannot spin.
				_retry()
			else:
				_retry()


func _take(raw: String) -> void:
	var parsed: Variant = JSON.parse_string(raw)
	if not (parsed is Dictionary):
		return
	var f: Dictionary = parsed
	var kind := str(f.get("t", ""))
	if kind == "hello":
		var d: Dictionary = f.get("data", {}) if f.get("data") is Dictionary else {}
		var e := str(d.get("epoch", ""))
		if _epoch != "" and e != _epoch:
			# The server was restarted while we were away: whatever a screen
			# holds may have a hole in it, so tell it to read the room again.
			frame.emit("resync", d)
		_epoch = e
		_tries = 0
		if _fallback:
			_fallback = false
			degraded.emit(false)
		return
	var data: Dictionary = f.get("data", {}) if f.get("data") is Dictionary else {}
	frame.emit(kind, data)
