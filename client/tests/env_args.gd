extends SceneTree
## The dev flags parse, and every flag moves past exactly the words it read.
##
## --replay-last used to stay on its own word forever, so a capture that asked
## to replay the last battle hung before the first frame; --page moved one word
## instead of two, so the page's name was read again as a flag.
##
## Run: godot --headless --path client --script tests/env_args.gd

var _fails := 0


func _initialize() -> void:
	await process_frame
	var env: GDScript = load("res://scripts/autoload/env.gd")
	if not env.has_method("parse_args"):
		print("FAIL  Env.parse_args does not exist, so the flags cannot be tested")
		quit(1)
		return

	var got: Dictionary = env.parse_args(PackedStringArray([
		"--dev-login", "yigit", "secret", "--replay-last", "--page", "profile",
		"--tab", "attack", "--capture", "shot.png", "--capture-after", "6",
		"--capture-size", "941x2040", "--inset", "141", "--lord", "a-lord-id",
		"--scroll", "1200", "--sub", "arena", "--api=http://127.0.0.1:9090"]))
	_expect(got.get("dev_login", []) == ["yigit", "secret"], "dev login read: %s" % str(got.get("dev_login")))
	_expect(got.get("replay_last", false) == true, "--replay-last read")
	_expect(got.get("page", "") == "profile", "--page read its name: %s" % str(got.get("page")))
	_expect(got.get("tab", "") == "attack", "--tab after --page still read: %s" % str(got.get("tab")))
	_expect(got.get("capture", "") == "shot.png", "--capture read")
	_expect(is_equal_approx(float(got.get("capture_after", 0.0)), 6.0), "--capture-after read")
	_expect(got.get("capture_size", Vector2i.ZERO) == Vector2i(941, 2040), "--capture-size read")
	_expect(is_equal_approx(float(got.get("inset", 0.0)), 141.0), "--inset read: %s" % str(got.get("inset")))
	_expect(got.get("lord", "") == "a-lord-id", "--lord read: %s" % str(got.get("lord")))
	_expect(is_equal_approx(float(got.get("scroll", 0.0)), 1200.0), "--scroll read: %s" % str(got.get("scroll")))
	_expect(got.get("sub", "") == "arena", "--sub after --scroll still read: %s" % str(got.get("sub")))
	_expect(got.get("api", "") == "http://127.0.0.1:9090", "--api= read")

	# The page's name is not read again as a flag.
	got = env.parse_args(PackedStringArray(["--page", "--tab", "--tab", "army"]))
	_expect(got.get("page", "") == "--tab", "--page takes the next word whatever it is")
	_expect(got.get("tab", "") == "army", "the flag after --page's value is read: %s" % str(got.get("tab")))

	# A flag missing its value is ignored, not an error, and ends the list.
	got = env.parse_args(PackedStringArray(["--replay-last", "--tab"]))
	_expect(got.get("replay_last", false) == true and not got.has("tab"), "a flag with no value is skipped")
	_expect(env.parse_args(PackedStringArray([])).is_empty(), "no args, no flags")

	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  every dev flag parses and moves past exactly what it read")
	quit()


func _expect(cond: bool, what: String) -> void:
	if not cond:
		_fails += 1
		print("  FAIL  " + what)
