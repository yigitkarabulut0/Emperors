extends SceneTree
## The Family tab's ROYAL TREASURY card: the bank, where a lord will find it.
##
## The Treasury was a ledger row between the eleventh upgrade and the first
## holding, wearing the kingdom's castle, its figures on an upgrade's level line
## ("VAULT 1.2M"): easy to forget, and nothing about it said bank. The owner
## painted its card (family_treasury.png). What must hold now, on 941x1672 and
## 941x2040:
##  - the card sits right under the STOREHOUSE where the painting has it (9
##    under, the hairlines 11 apart), the TALENTS / DEEDS / ROAD strip 7 under
##    it; it wears the painted card (family/treasury_card), as wide as the
##    STOREHOUSE and as tall as painted, its window where the STOREHOUSE's is;
##  - the window shows the vault by its gold: shut and barred with none, half
##    open with some, wide open from three full storehouses' worth -- each
##    state at its painted size;
##  - the painted title and marks; RAID-PROOF under the window; the vault's
##    gold (the snapshot's player.treasury) with "in the vault" after it,
##    inside its plate at any size; the purse's gold; the fee under DEPOSIT,
##    FREE under WITHDRAW;
##  - open, DEPOSIT and WITHDRAW open the treasury page ready for that move
##    (its amount the whole purse, the whole vault);
##  - below its level with nothing banked, the card is dimmed, says when it
##    opens, and neither button opens a page; with gold still banked, WITHDRAW
##    stays lit and works;
##  - it repaints itself when the snapshot moves (a deposit, TO VAULT);
##  - the ledger has no Treasury row, and the Legacy wears its own scene.
##
## Run: godot --headless --path client --script tests/family_treasury_card.gd

const DIM := Color(0.55, 0.55, 0.55)
const PLATE_RIGHT := 722.0
const CAP := 9000

var _fails := 0
var _checked := 0
var _gs: Node
var _refused: Array = []


func _initialize() -> void:
	await process_frame
	_gs = root.get_node("GameState")
	root.get_node("Env").set("api_base_url", "http://127.0.0.1:9")
	_gs.connect("action_failed", func(m: String) -> void: _refused.append(m))
	var family: GDScript = load("res://scenes/tabs/family.gd")
	if not family.has_method("treasury_state"):
		print("FAIL  the Family has no ROYAL TREASURY card: the bank is a row lost in the ledger")
		quit(1)
		return
	_states(family)
	for canvas in [Vector2i(941, 1672), Vector2i(941, 2040)]:
		await _card(family, canvas)
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  %d checks: the ROYAL TREASURY is its own card under the storehouse, and reads as a bank" % _checked)
	quit()


func _expect(ok: bool, msg: String) -> void:
	_checked += 1
	if not ok:
		_fails += 1
		print("  FAIL  " + msg)


func _path(n: Variant) -> String:
	if n is TextureRect and (n as TextureRect).texture:
		return (n as TextureRect).texture.resource_path
	if n is NinePatchRect and (n as NinePatchRect).texture:
		return (n as NinePatchRect).texture.resource_path
	return "nothing"


func _wears(n: Variant, asset: String) -> bool:
	return _path(n).ends_with(asset + ".png")


## A button's plate: the texture of its normal stylebox.
func _wears_plate(b: Variant, asset: String) -> bool:
	if not (b is Button):
		return false
	var sb := (b as Button).get_theme_stylebox("normal")
	return sb is StyleBoxTexture and (sb as StyleBoxTexture).texture != null \
		and (sb as StyleBoxTexture).texture.resource_path.ends_with(asset + ".png")


func _snap(level: int, gold: String, vault: String, open: bool) -> Dictionary:
	return {"player": {"username": "Wwwwwwwwwwwwwwww", "level": level, "gold": gold, "treasury": vault,
		"action_seq": 1, "xp": 0, "xp_to_next": 100, "tax_milli_per_hour": 0},
		"energy": {"current": 10, "max": 10},
		"sections": [{"id": "bank", "unlock_level": 8, "unlocked": level >= 8}],
		"storehouse": {"gold": 0, "milli": 0, "cap": CAP, "cap_milli": CAP * 1000, "per_hour_milli": 1125000,
			"hours": 8.0, "full_in": 28800, "full": false, "treasury_fee_bp": 1000, "treasury_open": open}}


func _states(family: GDScript) -> void:
	for row in [[true, 0, "open"], [true, 5, "open"], [false, 0, "shut"], [false, 56000, "shut_held"]]:
		var got: String = family.call("treasury_state", row[0], row[1])
		_expect(got == row[2], "open %s with %d banked reads \"%s\", not \"%s\"" % [row[0], row[1], got, row[2]])
	# The picture: none, some, three full storehouses' worth and more; no
	# storehouse to measure by, any gold is some.
	for row in [[0, CAP, "empty"], [1, CAP, "half"], [CAP * 3 - 1, CAP, "half"], [CAP * 3, CAP, "full"],
			[9999999999, CAP, "full"], [5000, 0, "half"], [0, 0, "empty"]]:
		var pic: String = family.call("treasury_picture", row[0], row[1])
		_expect(pic == row[2], "%d in the vault, a storehouse of %d, shows \"%s\", not \"%s\"" % [row[0], row[1], pic, row[2]])


func _estates(vault: String, open: bool) -> Dictionary:
	return {"upgrades": [{"id": "granary", "name": "Granary", "bucket": "collect_income_bp", "level": 0,
		"max_level": 20, "per_level": 300, "effect_now": 0, "next_cost": 400}], "upgrades_unlocked": true,
		"holdings": [], "treasury": {"vault": vault, "deposit_fee_bp": 1000, "unlock_level": 8, "unlocked": open}}


func _card(family: GDScript, canvas: Vector2i) -> void:
	var tag := "%dx%d" % [canvas.x, canvas.y]
	var vp := SubViewport.new()
	vp.size = canvas
	root.add_child(vp)
	root.get_node("Nav").set("host", vp)
	_gs.call("adopt", _snap(57, "987654321", "9999999999", true))
	var tab: Control = family.new()
	tab.size = Vector2(canvas)
	vp.add_child(tab)
	await process_frame
	var bank: Dictionary = tab.get("_treasury")
	var store: Dictionary = tab.get("_store")
	_expect(not bank.is_empty(), "%s: the Family has no treasury card" % tag)
	if bank.is_empty():
		vp.queue_free()
		return
	tab.set("_estates", _estates("9999999999", true))
	tab.call("_paint_all")
	await process_frame
	var node: Control = bank["node"]
	var p: Dictionary = bank["parts"]
	var sp: Dictionary = store["parts"]
	var above: Control = store["node"]

	# Where it sits, and that it is the painted card, as wide as the storehouse.
	_expect(absf(node.position.y - above.position.y - above.size.y - 9.0) < 0.5,
		"%s: the card starts at %.0f, not 9 under the storehouse (%.0f)" % [tag, node.position.y, above.position.y + above.size.y])
	_expect(node.position.x == above.position.x and node.size == Vector2(above.size.x, 252),
		"%s: the card is %s at x %.0f, not %.0fx252 at the storehouse's x %.0f" % [tag, node.size, node.position.x, above.size.x, above.position.x])
	var strip: Control = (tab.get("_honours") as Dictionary)["node"]
	_expect(absf(strip.position.y - node.position.y - node.size.y - 7.0) < 0.5,
		"%s: the strip starts at %.0f, not 7 under the treasury (%.0f)" % [tag, strip.position.y, node.position.y + node.size.y])
	for id in ["frame", "window", "raid_plate", "vault_plate", "hand_plate"]:
		_expect(p.has(id), "%s: the card has no %s" % [tag, id])
	for row in [["frame", "family/treasury_card"], ["window", "family/treasury_window"], ["title", "family/treasury_title"],
			["vault_icon", "family/treasury_icon_vault"], ["hand_icon", "family/treasury_icon_coins"]]:
		_expect(_wears(p.get(row[0]), row[1]), "%s: the %s is not the painted %s" % [tag, row[0], row[1]])
	_expect(_wears_plate(p.get("deposit"), "family/treasury_deposit") and _wears_plate(p.get("withdraw"), "family/treasury_withdraw"),
		"%s: DEPOSIT and WITHDRAW are not the painted plates" % tag)
	var pic: TextureRect = p["picture"]
	_expect(_wears(pic, "family/treasury_full"), "%s: 9,999,999,999 banked, the window wears %s, not the vault wide open" % [tag, _path(pic)])
	_expect(pic.texture != null and pic.size.is_equal_approx(pic.texture.get_size()),
		"%s: the vault is drawn %s, painted %s" % [tag, pic.size, pic.texture.get_size() if pic.texture else Vector2.ZERO])
	var win: Control = p["window"]
	_expect(win.position == (sp["window"] as Control).position and pic.position - win.position == Vector2(5, 6),
		"%s: the window is at %s (the storehouse's at %s), the vault %s inside it" % [tag, win.position, (sp["window"] as Control).position, pic.position - win.position])

	# What it says, a late lord's figures kept inside their plates.
	_expect((p["raid_proof"] as Label).text == "RAID-PROOF", "%s: the plate under the window says \"%s\"" % [tag, (p["raid_proof"] as Label).text])
	var vault: Label = p["vault"]
	var word: Label = p["vault_word"]
	_expect(vault.text == "9,999,999,999" and word.text == "in the vault",
		"%s: the vault plate says \"%s %s\"" % [tag, vault.text, word.text])
	var ws := word.label_settings
	var word_w := ws.font.get_string_size(word.text, HORIZONTAL_ALIGNMENT_LEFT, -1, ws.font_size).x
	_expect(word.position.x + word_w <= PLATE_RIGHT - 8.0,
		"%s: \"in the vault\" runs to %.0f, past the plate's chamfer (%.0f)" % [tag, word.position.x + word_w, PLATE_RIGHT - 8.0])
	_expect((p["on_hand"] as Label).text == "On hand  987,654,321", "%s: the purse reads \"%s\"" % [tag, (p["on_hand"] as Label).text])
	_expect((p["withdraw"] as Button).text == "WITHDRAW" and (p["deposit"] as Button).text == "DEPOSIT",
		"%s: the buttons say %s / %s" % [tag, (p["deposit"] as Button).text, (p["withdraw"] as Button).text])
	_expect((p["deposit_fee"] as Label).text == "10% FEE" and (p["withdraw_note"] as Label).text == "FREE",
		"%s: under the buttons: \"%s\" / \"%s\"" % [tag, (p["deposit_fee"] as Label).text, (p["withdraw_note"] as Label).text])
	for id in ["deposit", "withdraw", "picture"]:
		_expect((p[id] as CanvasItem).modulate.is_equal_approx(Color.WHITE), "%s: open, %s is dimmed" % [tag, id])

	# Open: each button opens the page ready for its move.
	var page: Control = tab.call("_open_treasury", "deposit")
	_expect(page != null and (page.get_meta("field") as LineEdit).text == "987654321",
		"%s: DEPOSIT opens %s" % [tag, "a page with %s" % (page.get_meta("field") as LineEdit).text if page else "no page"])
	if page:
		page.call("close")
	page = tab.call("_open_treasury", "withdraw")
	_expect(page != null and (page.get_meta("field") as LineEdit).text == "9999999999",
		"%s: WITHDRAW opens %s" % [tag, "a page with %s" % (page.get_meta("field") as LineEdit).text if page else "no page"])
	if page:
		page.call("close")

	# A deposit elsewhere: the next frame shows it, no reload needed.
	_gs.call("adopt", _snap(57, "887654321", "10089999999", true))
	await process_frame
	await process_frame
	_expect(vault.text == "10,089,999,999", "%s: after a deposit the vault still reads %s" % [tag, vault.text])
	# Some gold, not three storehouses' worth: the door half open.
	_gs.call("adopt", _snap(57, "887654321", "12000", true))
	await process_frame
	_expect(_wears(pic, "family/treasury_half"), "%s: 12,000 banked, the window wears %s" % [tag, _path(pic)])

	# Shut, nothing banked: dimmed, says when, and neither button opens a page.
	_gs.call("adopt", _snap(1, "240", "0", false))
	tab.set("_estates", _estates("0", false))
	tab.call("_paint_all")
	await process_frame
	_expect((p["raid_proof"] as Label).text == "Opens at level 8", "%s: shut, the plate says \"%s\"" % [tag, (p["raid_proof"] as Label).text])
	_expect(_wears(pic, "family/treasury_empty"), "%s: shut and empty, the window wears %s" % [tag, _path(pic)])
	for id in ["deposit", "withdraw", "picture"]:
		_expect((p[id] as CanvasItem).modulate.is_equal_approx(DIM), "%s: shut, %s is not dimmed" % [tag, id])
	for mode in ["deposit", "withdraw"]:
		_refused.clear()
		page = tab.call("_open_treasury", mode)
		_expect(page == null and _refused.size() == 1 and _refused[0] == "The vault opens at level 8",
			"%s: shut, %s opened %s and said %s" % [tag, mode, page, _refused])

	# Shut with gold still banked: what is banked can come out.
	_gs.call("adopt", _snap(3, "1200", "56000", false))
	tab.call("_paint_all")
	await process_frame
	_expect((p["withdraw"] as CanvasItem).modulate.is_equal_approx(Color.WHITE)
		and (p["deposit"] as CanvasItem).modulate.is_equal_approx(DIM),
		"%s: shut with gold banked, WITHDRAW %s and DEPOSIT %s" % [tag, (p["withdraw"] as CanvasItem).modulate, (p["deposit"] as CanvasItem).modulate])
	page = tab.call("_open_treasury", "withdraw")
	_expect(page != null and (page.get_meta("field") as LineEdit).text == "56000",
		"%s: shut with gold banked, WITHDRAW opened %s" % [tag, page])
	if page:
		page.call("close")

	# The ledger: no Treasury row; the Legacy in its own scene.
	var kinds: Array = []
	for spec in tab.call("_card_specs"):
		kinds.append(str(spec["kind"]))
	_expect(not ("treasury" in kinds), "%s: the ledger still has a Treasury row: %s" % [tag, kinds])
	_expect(family.call("card_scene", "legacy", {}) == "family/ledger_legacy",
		"%s: the Legacy wears %s" % [tag, family.call("card_scene", "legacy", {})])
	vp.queue_free()
	await process_frame
