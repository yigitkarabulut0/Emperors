extends Control
## FAMILY — the hero: identity, stats, gear, and the upgrade ledger.
## Layout: layout/family.json. The ledger opens with the STOREHOUSE card, where
## the estates' income waits to be carried in, the ROYAL TREASURY card under it
## (the bank: the vault's gold, the purse's, DEPOSIT and WITHDRAW), and the
## TALENTS / DEEDS / ROAD strip (ROAD opens the Victory Road); estates
## (holdings) and the Legacy fold into the upgrade list below the GRANARY card,
## in the same card.

const SCREEN := "family"
const PITCH := 262.0
const BUCKET_LABEL := {
	"collect_income_bp": "COLLECT INCOME", "tax_income_bp": "ESTATE INCOME", "xp_bp": "HERO XP",
	"energy_regen_bp": "ENERGY REGEN", "max_energy_flat": "MAX ENERGY", "soldier_atk_bp": "SOLDIER ATTACK",
	"soldier_def_bp": "SOLDIER DEFENCE", "soldier_spd_bp": "SOLDIER SPEED", "shop_discount_bp": "SHOP DISCOUNT",
	"steal_cap_bp": "RAID STEAL CAP", "ransom_bp": "RANSOM",
}

## Each card's own scene. Every upgrade and holding has one, cut for it as
## family/ledger_<id> (art/slices/ledger_upgrades.json, ledger_holdings.json);
## the Granary keeps the painting the card was cut with, and the Legacy wears
## its gallery of ancestors (ledger_extra.json). The ledger used to wear the
## granary on every card, then three shared scenes; now no two cards share one.
const CARD_SCENE := "family/ledger_%s"
const OWN_SCENE := {"granary": "family/granary_art"}
const LEGACY_ART := "family/ledger_legacy"
## An upgrade or holding the server adds before its scene is cut wears its
## group's picture, never nothing. tests/ledger_scenes.gd keeps every one in the
## balance on its own.
const CARD_ART := {"income": "family/granary_art", "army": "family/art_army", "realm": "family/art_realm"}
const BUCKET_GROUP := {"soldier_atk_bp": "army", "soldier_def_bp": "army", "soldier_spd_bp": "army",
	"steal_cap_bp": "army", "ransom_bp": "army", "xp_bp": "realm", "energy_regen_bp": "realm"}
## And the mark beside the level, by what it raises.
const BUCKET_ICON := {"collect_income_bp": "icons/gold_stack", "tax_income_bp": "icons/gold_pile",
	"xp_bp": "icons/quest_scroll", "energy_regen_bp": "icons/energy", "max_energy_flat": "icons/energy_potion",
	"soldier_atk_bp": "icons/might_swords", "soldier_def_bp": "icons/shield_small",
	"soldier_spd_bp": "inventory/icon_speed", "shop_discount_bp": "icons/market_tent",
	"steal_cap_bp": "icons/gold_pile", "ransom_bp": "icons/coin"}
const ICON_BOX := Rect2(406, 75, 70, 78)
## A card's level line: the level on its left at the painting's 24, what the
## next level buys on its right (max, min size), this far apart at least, in a
## row this wide from the level's left edge.
const LEVEL_ROW_W := 246.0
const NEXT_FIT := Vector2i(19, 15)
const NEXT_CLEAR := 12.0
const NEXT_GREEN := Color("#A8E070")
## How far a button's word keeps from each end of its plate.
const BUTTON_MARGIN := 28.0
## What an empty gear slot shows (UI.empty_slot_face), as on the Army.
const GEAR_GHOSTS := ["items/army_spear", "items/army_leather_armor", "items/army_horse"]
const GEAR_WORDS := ["WEAPON", "ARMOR", "HORSE"]

## The STOREHOUSE card (family_storehouse.png), the ledger's first. The cards
## under it keep the ledger's own gap (PITCH less a card's 253).
const STORE_TEMPLATE := "storehouse_card"
const STORE_GAP := 9.0
const STORE_CARRY := "/v1/estates/storehouse/carry"
## The window's painting by how full it is (storehouse_state): swept clean
## under a third, sacks and crates until it is full, overflowing once it is.
const STORE_PICTURE := {"empty": "family/storehouse_empty", "half": "family/storehouse_half",
	"full": "family/storehouse_full"}
const STORE_HALF_AT := 1.0 / 3.0
## A carry refused, in the game's words, by the server's code. A vault not yet
## open is said before anything is asked (VAULT_SHUT).
const STORE_REFUSALS := {
	"storehouse_empty": "The storehouse is empty — your estates fill it by the hour",
	"bad_request": "The gold can go to your purse or the vault",
}
const VAULT_SHUT := "The vault opens at level %d"
## The vault's word rises this far to make room for its fee under it.
const VAULT_WORD_LIFT := 8.0
## A full storehouse says so in the warning red: it is filling no more.
const STORE_FULL_RED := Color("#F0524F")
## The amount and what it holds share the plate, the second on the first's
## baseline this far after it, both inside the plate's chamfers.
const STORE_CAP_GAP := 8.0
const STORE_AMOUNT_RIGHT := 700.0

## The ROYAL TREASURY card: the bank, right under the storehouse, the owner's
## painted card (family_treasury.png) laid out as the storehouse's is (its
## template in layout/family.json). The vault's gold is the snapshot's
## (player.treasury), the purse's is the pills' (display_gold, so a collect in
## flight shows at once), whether it is open and its fee are the storehouse
## view's (treasury_open, treasury_fee_bp) -- the same the storehouse card's To
## Vault reads. The window shows the vault shut, half open or wide open by its
## gold (treasury_picture). DEPOSIT and WITHDRAW open the treasury page ready for
## that move; below its level the card is dimmed and says when it opens, and
## what is already in the vault can always come out.
const TREASURY_TEMPLATE := "treasury_card"
const TREASURY_PAGE := "res://scenes/pages/treasury_page.gd"
const TREASURY_PICTURE := {"empty": "family/treasury_empty", "half": "family/treasury_half",
	"full": "family/treasury_full"}
## "A lot" in the vault, for the picture only: as much as this many full
## storehouses (the storehouse view's cap). Nothing is computed from it.
const TREASURY_FULL_STOREHOUSES := 3
const TREASURY_SAFE := "RAID-PROOF"
const TREASURY_SHUT := "Opens at level %d"
const TREASURY_OPENS := "The vault opens at level %d"
const TREASURY_EMPTY := "The vault is empty"
const TREASURY_DIMMED := Color(0.55, 0.55, 0.55)
const TREASURY_AMOUNT_RIGHT := 710.0

## TALENTS, DEEDS and ROAD (family_storehouse.png's strip), under the treasury
## card where family_treasury.png puts it; the ledger follows it at the
## ledger's own gap.
## DEEDS opens the Deeds and ROAD the Victory Road (one page under two tabs);
## TALENTS opens the tree.
const HONOURS_TEMPLATE := "honours"
const HONOURS_STATUS := {"talents": "status_talents"}
const HONOURS_DIMMED := Color(0.55, 0.55, 0.55)
const HONOURS_STATUS_SIZE := 26
const HONOURS_STATUS_MIN := 17
const ROAD_PAGE := "res://scenes/pages/road_page.gd"
const DEEDS_PAGE := "res://scenes/pages/deeds_page.gd"
const TALENTS_PAGE := "res://scenes/pages/talents_page.gd"

var _scroll: ScrollContainer
var _content: Control
var _ui: Dictionary = {}
var _identity: Dictionary
var _stats: Dictionary
var _gear: Dictionary
var _empty_faces: Dictionary = {}     ## slot -> [ghost, word], shown while it is bare
var _cards: Array = []            ## [{node, parts, kind, data}]
var _store: Dictionary = {}       ## the storehouse card's {node, parts}
var _store_painted := ""          ## what it last showed, so the tick repaints on a change only
var _treasury: Dictionary = {}    ## the ROYAL TREASURY card's {node, parts}
var _treasury_painted := ""       ## what it last showed
var _honours: Dictionary = {}     ## the TALENTS / DEEDS / ROAD strip's {node, parts}
var _road: Dictionary = {}        ## GET /v1/road, for the ROAD card's plate
var _deeds: Dictionary = {}       ## GET /v1/achievements, for the DEEDS card's plate
var _talents: Dictionary = {}     ## GET /v1/talents, for the TALENTS card's plate
var _footer: Control
var _ground: Control
var _points_label: Label

var _inventory: Dictionary = {}
var _estates: Dictionary = {}
var _legacy: Dictionary = {}
var _loaded_ms := -100000
var _busy := false


func _ready() -> void:
	_scroll = ScrollContainer.new()
	_scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	_scroll.scroll_deadzone = 14
	add_child(_scroll)
	_content = Control.new()
	_content.custom_minimum_size = Vector2(941, 1672)
	_content.mouse_filter = Control.MOUSE_FILTER_PASS
	_scroll.add_child(_content)

	_ui = Layout.build(SCREEN, _content)
	# The measured layout carries a nested scroll for the upgrades and a portrait
	# source; the page itself scrolls, and cards are laid out below.
	for drop in ["upgrades", "portrait_source"]:
		if _ui.has(drop):
			_ui[drop].queue_free()
			_ui.erase(drop)
	_identity = _ui["identity"][0]["parts"]
	_stats = _ui["stats"][0]["parts"]
	_gear = _ui["gear"][0]["parts"]
	_footer = _ui["footer"]
	_ground = _ui["ground_bottom"]

	_identity["edit"].pressed.connect(_rename)
	_gear["equip_best"].pressed.connect(_equip_best)
	for i in 3:
		var slot: String = ["weapon", "armor", "horse"][i]
		var t := _gear_tile(slot)
		var tile: Control = t["node"]
		var hit := UI.hotspot(Rect2(Vector2.ZERO, tile.size))
		hit.pressed.connect(_choose_gear.bind(slot))
		GuideTargets.register("family.gear." + slot, hit)
		tile.add_child(hit)
		# An empty slot shows what goes in it, as the Army's gear tiles do.
		var paint: Control = t["parts"]["painting"]
		_empty_faces[slot] = UI.empty_slot_face(tile, Rect2(paint.position, paint.size), GEAR_GHOSTS[i],
			GEAR_WORDS[i], Rect2(0, tile.size.y - 46, tile.size.x, 24), hit)
	# Stat points: tapping a cell spends one there once the server has granted any.
	var strip: Control = _ui["stats"][0]["node"]
	GuideTargets.register("family.stats", strip)
	for entry in [["attack", Rect2(0, 0, 250, 190)], ["defense", Rect2(250, 0, 250, 190)], ["energy", Rect2(500, 0, 252, 190)]]:
		var hit := UI.hotspot(entry[1])
		hit.pressed.connect(_spend_point.bind(entry[0]))
		strip.add_child(hit)
	_points_label = UI.label("", 22, UI.GOLD, "title", 700, HORIZONTAL_ALIGNMENT_CENTER)
	UI.place(_points_label, Rect2(0, -2, 752, 30))
	_points_label.visible = false
	strip.add_child(_points_label)
	_build_storehouse()
	_build_treasury()
	_build_honours()
	GameState.badges_changed.connect(_paint_honours)


func refresh() -> void:
	_paint_identity()
	if Time.get_ticks_msec() - _loaded_ms > 3000:
		_load()
	else:
		_paint_all()


func _load() -> void:
	_loaded_ms = Time.get_ticks_msec()
	var inv: Api.Response = await Api.get_json("/v1/inventory")
	if inv.ok:
		_inventory = inv.data
	var est: Api.Response = await Api.get_json("/v1/estates")
	if est.ok:
		_estates = est.data
	var leg: Api.Response = await Api.get_json("/v1/legacy")
	if leg.ok:
		_legacy = leg.data
	var road: Api.Response = await Api.get_json("/v1/road")
	if road.ok and road.data is Dictionary:
		_road = road.data
	var deeds: Api.Response = await Api.get_json("/v1/achievements")
	if deeds.ok and deeds.data is Dictionary:
		_deeds = deeds.data
	_paint_all()


func _paint_all() -> void:
	_paint_identity()
	_paint_stats()
	_paint_gear()
	_paint_storehouse(true)
	_paint_treasury(true)
	_paint_honours()
	_paint_cards()


## The storehouse fills while the screen is open: its gold, its bar, its
## painting and its countdown follow, repainted only when one of them moves.
func _process(_dt: float) -> void:
	if visible:
		_paint_storehouse()
		_paint_treasury()


# --- identity -----------------------------------------------------------------------

func _paint_identity() -> void:
	var p := GameState.player()
	var name_label: Label = _identity["name"]
	name_label.text = str(p.get("username", "")).to_upper()
	# The plate's name slot fits about eight letters at the painting's size; a
	# longer name is set smaller rather than run under the quill.
	UI.fit_label(name_label, 60, 28)
	_identity["level"].text = "LEVEL %d" % int(p.get("level", 1))
	var need := GameState.xp_to_next()
	var xp := GameState.display_xp()
	if need > 0:
		_identity["xp_text"].text = "%s / %s XP" % [UI.grouped(xp), UI.grouped(need)]
		UI.fit_label(_identity["xp_text"], 22, 14)
		Layout.set_fill(_identity["xp_fill"], float(xp) / float(need))
	else:
		_identity["xp_text"].text = "LEVEL CAP"
		Layout.set_fill(_identity["xp_fill"], 1.0)
	var pts := int(p.get("stat_points_unspent", 0))
	_points_label.visible = pts > 0
	_points_label.text = "%d POINT%s TO SPEND · TAP A STAT" % [pts, "" if pts == 1 else "S"]


func _paint_stats() -> void:
	var hero: Dictionary = _inventory.get("hero", {})
	_stats["attack"].text = UI.grouped(int(hero.get("attack", 0)))
	_stats["defence"].text = UI.grouped(int(hero.get("defense", 0)))
	_stats["power"].text = UI.grouped(int(hero.get("power", 0)))


func _paint_gear() -> void:
	var eq: Dictionary = _inventory.get("equipped", {})
	for slot in ["weapon", "armor", "horse"]:
		var parts: Dictionary = _gear_tile(slot)["parts"]
		var item: Variant = eq.get(slot, null)
		# The tile is the painting's empty frame; the worn item's own design is
		# drawn inset into it, so the picture follows the gear.
		var painting: TextureRect = parts["painting"]
		painting.visible = item is Dictionary
		# The stone on the frame takes the worn item's tier colour, and sits
		# unlit when the slot is bare.
		parts["gem"].texture = Art.gem(str(item.get("tier", "")) if item is Dictionary else "")
		for n in _empty_faces.get(slot, []):
			n.visible = not (item is Dictionary)
		# The worn piece on its rarity's velvet; a bare slot keeps its empty tile.
		ItemGround.in_gear_tile(painting, parts["art"], "family/gear_tile_empty",
			str(item.get("tier", "common")) if item is Dictionary else "")
		if item is Dictionary:
			painting.texture = Art.item(str(item.get("art", "")))
			parts["lv"].text = "Lv. %d" % int(item.get("ilvl", 1))
			parts["art"].modulate = Color.WHITE
		else:
			parts["lv"].text = ""
			parts["art"].modulate = Color(0.8, 0.8, 0.8)


## The gear tiles are nested templates with one instance each.
func _gear_tile(slot: String) -> Dictionary:
	var wrap: Control = _gear["tile_" + slot]
	if wrap.has_meta("instances"):
		return wrap.get_meta("instances")[0]
	return {"node": wrap, "parts": wrap.get_meta("parts", {})}


# --- the storehouse -----------------------------------------------------------------------

## The STOREHOUSE card: the estates' income, waiting out of a raider's reach
## until it is carried in. Its figures are the snapshot's (snapshot.storehouse),
## filled on read by GameState.display_storehouse_milli; nothing here computes
## one of them.
func _build_storehouse() -> void:
	var tpl := Layout.find(SCREEN, STORE_TEMPLATE)
	_store = Layout.instantiate(tpl)
	var node: Control = _store["node"]
	node.position = Layout.rect_of(tpl).position
	_content.add_child(node)
	var p: Dictionary = _store["parts"]
	p["collect"].pressed.connect(_carry.bind("purse"))
	p["to_vault"].pressed.connect(_carry.bind("treasury"))
	# The vault's word rises to make room for its fee under it.
	_lift_word(p["to_vault"])


## Raises a plate's word by VAULT_WORD_LIFT to make room for the line under it,
## in every state of the plate (UI.inset_plate centred it in the painted plate).
static func _lift_word(b: Button) -> void:
	var seen := {}
	for state in ["normal", "hover", "focus", "pressed", "disabled"]:
		var sb := b.get_theme_stylebox(state)
		if sb == null or seen.has(sb):
			continue
		seen[sb] = true
		sb.content_margin_top -= VAULT_WORD_LIFT
		sb.content_margin_bottom += VAULT_WORD_LIFT


## Which painting the window wears for a storehouse holding `milli` of
## `cap_milli`: "empty" under a third, "half" until it is full, "full" at its
## capacity or over it.
static func storehouse_state(milli: int, cap_milli: int) -> String:
	if cap_milli <= 0:
		return "empty"
	if milli >= cap_milli:
		return "full"
	return "half" if float(milli) >= float(cap_milli) * STORE_HALF_AT else "empty"


## How long the storehouse holds, as the server says it (8, and 12 minutes
## more for each Tithe Barn level): "8h", "9h 36m".
static func hours_words(hours: float) -> String:
	var mins := int(round(hours * 60.0))
	if mins % 60 == 0:
		return "%dh" % (mins / 60)
	return "%dh %02dm" % [mins / 60, mins % 60]


## What a carry says, from its answer: "+12,345 to the purse", "+11,110 to the
## vault (1,235 fee)".
static func carry_words(d: Dictionary) -> String:
	if str(d.get("to", "")) == "treasury":
		var fee := int(d.get("fee", 0))
		var said := "+%s to the vault" % UI.grouped(int(d.get("banked", 0)))
		return said + (" (%s fee)" % UI.grouped(fee) if fee > 0 else "")
	return "+%s to the purse" % UI.grouped(int(d.get("carried", 0)))


## Paints the card from the snapshot, now. `force` repaints even when nothing
## it shows has moved (a load, a new snapshot's rate or capacity).
func _paint_storehouse(force: bool = false) -> void:
	if _store.is_empty():
		return
	var p: Dictionary = _store["parts"]
	var sh := GameState.storehouse()
	var milli := GameState.display_storehouse_milli()
	var cap := int(sh.get("cap_milli", 0))
	var full := GameState.display_storehouse_full()
	var left := "" if full else UI.time_left(GameState.display_storehouse_full_in())
	var open := bool(sh.get("treasury_open", false))
	var key := "%d|%d|%s|%s|%s|%s|%d" % [milli / 1000, cap, full, left, sh.get("hours", 0), open,
		int(sh.get("treasury_fee_bp", 0))]
	if key == _store_painted and not force:
		return
	_store_painted = key
	p["picture"].texture = Art.tex(STORE_PICTURE[storehouse_state(milli, cap)])
	Layout.set_fill(p["fill"], float(milli) / float(cap) if cap > 0 else 0.0)
	p["amount"].text = UI.grouped(milli / 1000)
	var holds := cap / 1000
	p["capacity"].text = "/ " + (UI.grouped(holds) if holds < 1_000_000 else UI.short_number(holds))
	_fit_pair(p["amount"], p["capacity"], STORE_AMOUNT_RIGHT)
	p["holds"].text = "HOLDS " + hours_words(float(sh.get("hours", 0.0))).to_upper()
	UI.fit_label(p["holds"], 19, 14)
	var timer: Label = p["full_in"]
	if full:
		timer.text = "Full"
		timer.label_settings.font_color = STORE_FULL_RED
	else:
		# A storehouse the estates do not fill (no rate yet) has no time to give.
		timer.text = "Full in " + left if int(sh.get("per_hour_milli", 0)) > 0 else ""
		timer.label_settings.font_color = UI.INK
	UI.fit_label(timer, 24, 16)
	# The vault's plate says its fee always, and dims until the vault opens; a
	# tap on it then says the level (_carry).
	var dim := Color.WHITE if open else Color(0.55, 0.55, 0.55)
	p["to_vault"].modulate = dim
	p["vault_fee"].modulate = dim
	p["vault_fee"].text = "%s%% FEE" % _pct(int(sh.get("treasury_fee_bp", 0)))
	UI.fit_label(p["vault_fee"], 15, 12)


## A figure at the plate's size and the words after it on the same baseline
## (the gold waiting and what it holds; the vault's gold and "in the vault"),
## the pair kept inside the plate's chamfered ends, `right` its last unit: a
## late lord's figures are set smaller rather than run over the plate's edge.
func _fit_pair(amount: Label, capacity: Label, right: float) -> void:
	var left := amount.position.x
	var room := right - left
	UI.fit_label(capacity, 22, 16)
	var cs := capacity.label_settings
	var cap_w := cs.font.get_string_size(capacity.text, HORIZONTAL_ALIGNMENT_LEFT, -1, cs.font_size).x
	amount.set_meta("box_w", room - cap_w - STORE_CAP_GAP)
	UI.fit_label(amount, 32, 18)
	var s := amount.label_settings
	var amount_w := s.font.get_string_size(amount.text, HORIZONTAL_ALIGNMENT_LEFT, -1, s.font_size).x
	capacity.position.x = left + amount_w + STORE_CAP_GAP
	capacity.size.x = cap_w + 2.0
	# Both are centred in the same box, so their baselines differ by half what
	# their lines differ by above and below the baseline.
	var a_up := s.font.get_ascent(s.font_size)
	var a_down := s.font.get_descent(s.font_size)
	var c_up := cs.font.get_ascent(cs.font_size)
	var c_down := cs.font.get_descent(cs.font_size)
	capacity.position.y = amount.position.y + ((a_up - c_up) - (a_down - c_down)) / 2.0


## COLLECT and TO VAULT: the whole storehouse to the purse, or to the vault
## less the vault's fee. One carry at a time, held until the reload is in
## (`_busy`); a vault that is not open yet is said here, never asked of the
## server.
func _carry(to: String) -> void:
	if _busy:
		return
	var shut := VAULT_SHUT % GameState.unlock_level("bank")
	if to == "treasury" and not bool(GameState.storehouse().get("treasury_open", false)):
		GameState.action_failed.emit(shut)
		return
	var words := STORE_REFUSALS.duplicate()
	words["level_too_low"] = shut
	_busy = true
	var res: Api.Response = await GameState.act(STORE_CARRY, {"to": to}, words)
	if res.ok:
		GameState.toast(carry_words(res.data))
		await _load()
	_busy = false


# --- the royal treasury -----------------------------------------------------------------

func _build_treasury() -> void:
	var tpl := Layout.find(SCREEN, TREASURY_TEMPLATE)
	_treasury = Layout.instantiate(tpl)
	var node: Control = _treasury["node"]
	node.position = Layout.rect_of(tpl).position
	_content.add_child(node)
	var p: Dictionary = _treasury["parts"]
	p["deposit"].pressed.connect(_open_treasury.bind("deposit"))
	p["withdraw"].pressed.connect(_open_treasury.bind("withdraw"))
	# Both words rise for the line under them (the fee; that taking out is free).
	_lift_word(p["deposit"])
	_lift_word(p["withdraw"])


static func _vault_gold() -> int:
	return int(str(GameState.player().get("treasury", "0")))


## The card's state, from the snapshot: "open", "shut" (below the vault's
## level, nothing in it) or "shut_held" (below it, with gold still banked --
## a Legacy begun can put a lord back under the level with a full vault).
static func treasury_state(open: bool, vault: int) -> String:
	if open:
		return "open"
	return "shut_held" if vault > 0 else "shut"


## Which painting the window wears for `vault` gold, against a storehouse of
## `cap`: "empty" (shut and barred) with nothing in it, "full" (wide open,
## spilling) from TREASURY_FULL_STOREHOUSES storehouses' worth, "half" (half
## open on a modest pile) between. Presentation only, like storehouse_state.
static func treasury_picture(vault: int, cap: int) -> String:
	if vault <= 0:
		return "empty"
	if cap > 0 and vault >= cap * TREASURY_FULL_STOREHOUSES:
		return "full"
	return "half"


func _paint_treasury(force: bool = false) -> void:
	if _treasury.is_empty():
		return
	var p: Dictionary = _treasury["parts"]
	var sh := GameState.storehouse()
	var vault := _vault_gold()
	var hand := GameState.display_gold()
	var state := treasury_state(bool(sh.get("treasury_open", false)), vault)
	var fee_bp := int(sh.get("treasury_fee_bp", 0))
	var cap := int(sh.get("cap", 0))
	var key := "%d|%d|%s|%d|%d|%d" % [vault, hand, state, fee_bp, cap, GameState.unlock_level("bank")]
	if key == _treasury_painted and not force:
		return
	_treasury_painted = key
	(p["picture"] as TextureRect).texture = Art.tex(TREASURY_PICTURE[treasury_picture(vault, cap)])
	p["vault"].text = UI.grouped(vault)
	p["vault_word"].text = "in the vault"
	_fit_pair(p["vault"], p["vault_word"], TREASURY_AMOUNT_RIGHT)
	p["on_hand"].text = "On hand  " + UI.grouped(hand)
	UI.fit_label(p["on_hand"], 24, 16)
	# The plate under the window: RAID-PROOF, or, below the vault's level, when
	# it opens, in gold.
	var plate: Label = p["raid_proof"]
	if state == "open":
		plate.text = TREASURY_SAFE
		plate.label_settings.font_color = Color("#B9C2CC")
	else:
		plate.text = TREASURY_SHUT % GameState.unlock_level("bank")
		plate.label_settings.font_color = UI.GOLD
	UI.fit_label(plate, 19, 14)
	p["deposit_fee"].text = "%s%% FEE" % _pct(fee_bp)
	UI.fit_label(p["deposit_fee"], 15, 12)
	p["withdraw_note"].text = "FREE"
	# Shut, the picture and the moves are dimmed; what is banked can still
	# come out.
	var shut := state != "open"
	for id in ["picture", "vault_icon", "deposit", "deposit_fee"]:
		(p[id] as CanvasItem).modulate = TREASURY_DIMMED if shut else Color.WHITE
	for id in ["withdraw", "withdraw_note"]:
		(p[id] as CanvasItem).modulate = TREASURY_DIMMED if state == "shut" else Color.WHITE


## DEPOSIT and WITHDRAW: the treasury page, ready for the move (the page it
## opened, or null). What cannot be done is said here, before a page opens on it.
func _open_treasury(mode: String) -> Control:
	var state := treasury_state(bool(GameState.storehouse().get("treasury_open", false)), _vault_gold())
	if state == "shut" or (state == "shut_held" and mode == "deposit"):
		GameState.action_failed.emit(TREASURY_OPENS % GameState.unlock_level("bank"))
		return null
	if mode == "withdraw" and _vault_gold() <= 0:
		GameState.action_failed.emit(TREASURY_EMPTY)
		return null
	var page: GDScript = load(TREASURY_PAGE)
	var sheet: Control = page.open(self, _estates.get("treasury", {}), {"mode": mode})
	sheet.closed.connect(func() -> void: _load())
	return sheet


# --- TALENTS, DEEDS, ROAD ---------------------------------------------------------------

## The strip of three medallion cards under the storehouse: DEEDS opens the
## Deeds and counts the tiers waiting there (the heartbeat's `achievements`),
## ROAD the Victory Road and the milestones waiting on it (`road`), and TALENTS
## the tree, counting the points a lord has not spent.
func _build_honours() -> void:
	var tpl := Layout.find(SCREEN, HONOURS_TEMPLATE)
	_honours = Layout.instantiate(tpl)
	var node: Control = _honours["node"]
	node.position = Layout.rect_of(tpl).position
	_content.add_child(node)
	var p: Dictionary = _honours["parts"]
	(p["hit_road"] as BaseButton).pressed.connect(_open_road)
	(p["hit_deeds"] as BaseButton).pressed.connect(_open_deeds)
	(p["hit_talents"] as BaseButton).pressed.connect(_open_talents)


func _paint_honours() -> void:
	if _honours.is_empty():
		return
	var p: Dictionary = _honours["parts"]
	var open := GameState.is_unlocked("talents")
	(p["card_talents"] as CanvasItem).modulate = Color.WHITE if open else HONOURS_DIMMED
	_honours_status(p["status_talents"], talent_words(_talents, open), UI.INK if open else UI.DIM)
	_honours_count(p["badge_talents"], p["count_talents"], int(_talents.get("left", 0)) if open else 0)
	var waiting := road_count(GameState.badges, _road)
	_honours_status(p["status_road"], road_words(_road, waiting), UI.INK)
	_honours_count(p["badge_road"], p["count_road"], waiting)
	var owed := deeds_count(GameState.badges, _deeds)
	_honours_status(p["status_deeds"], deeds_words(_deeds, owed), UI.INK)
	_honours_count(p["badge_deeds"], p["count_deeds"], owed)


## A card's count: the COURT cards' red disc on its shoulder, 9+ past nine,
## gone at none.
func _honours_count(badge: CanvasItem, count: Label, n: int) -> void:
	badge.visible = n > 0
	count.visible = n > 0
	count.text = str(n) if n < 10 else "9+"


func _honours_status(l: Label, words: String, col: Color) -> void:
	if l.text == words and l.label_settings.font_color == col:
		return
	l.text = words
	l.label_settings.font_color = col
	UI.fit_line(l, HONOURS_STATUS_SIZE, HONOURS_STATUS_MIN)


## What waits on the road: the heartbeat's count, or -- before the first beat
## after a claim elsewhere -- the road's own.
static func road_count(badges: Dictionary, road: Dictionary) -> int:
	if badges.has("road"):
		return int(badges.get("road", 0))
	return int(road.get("claimable", 0))


## The ROAD card's plate: what waits, else the next milestone's level, else
## that the road is walked. Before the road has been read, nothing.
static func road_words(road: Dictionary, waiting: int) -> String:
	if waiting > 0:
		return "%d reward%s waiting" % [waiting, "" if waiting == 1 else "s"]
	var stones: Array = road.get("milestones", [])
	if stones.is_empty():
		return ""
	for m in stones:
		if not bool(m.get("reached", false)):
			return "Next at level %d" % int(m.get("level", 0))
	return "The road is walked"


## What waits in the Deeds: the heartbeat's count, or -- before the first beat
## after a claim elsewhere -- the page's own.
static func deeds_count(badges: Dictionary, deeds: Dictionary) -> int:
	if badges.has("achievements"):
		return int(badges.get("achievements", 0))
	return int(deeds.get("claimable", 0))


## The DEEDS card's plate: the tiers waiting, else the medals won of all there
## are ("12 of 96 medals"). Before the deeds have been read, nothing.
static func deeds_words(deeds: Dictionary, waiting: int) -> String:
	if waiting > 0:
		return "%d medal%s to claim" % [waiting, "" if waiting == 1 else "s"]
	var all: Array = deeds.get("achievements", [])
	if all.is_empty():
		return ""
	var won := 0
	var tiers := 0
	for a in all:
		if a is Dictionary:
			won += int(a.get("claimed", 0))
			tiers += (a.get("tiers", []) as Array).size()
	if tiers > 0 and won >= tiers:
		return "Every medal won"
	return "%d of %d medals" % [won, tiers]


## The TALENTS card's plate: the points waiting to be spent, else what has been.
static func talent_words(tree: Dictionary, unlocked: bool) -> String:
	if not unlocked:
		return "Opens at level %d" % maxi(1, int(tree.get("unlock_level", GameState.unlock_level("talents"))))
	var left := int(tree.get("left", 0))
	if left > 0:
		return "%d point%s to spend" % [left, "" if left == 1 else "s"]
	var spent := int(tree.get("spent", 0))
	if spent > 0:
		return "%d rank%s taken" % [spent, "" if spent == 1 else "s"]
	return "Choose your three"


## The tree, after the page changed it: the card follows without a reload.
func talents_changed(tree: Dictionary) -> void:
	_talents = tree
	_paint_honours()


func _open_talents() -> void:
	if not GameState.is_unlocked("talents"):
		GameState.action_failed.emit("The talent tree opens at level %d" % GameState.unlock_level("talents"))
		return
	var res: Api.Response = await Api.get_json("/v1/talents")
	if not res.ok or not (res.data is Dictionary):
		GameState.action_failed.emit(res.error)
		return
	_talents = res.data
	var page: Sheet = load(TALENTS_PAGE).open(self, self, _talents)
	page.closed.connect(func() -> void: _paint_honours())


func _open_deeds() -> void:
	var page: Control = load(DEEDS_PAGE).open(self)
	# Claims on the page move the count; the DEEDS card follows when it closes
	# (or when the Victory Road that took its place does).
	page.connect("closed", func() -> void:
		_loaded_ms = -100000
		if is_inside_tree():
			refresh())


func _open_road() -> void:
	var page: Control = load(ROAD_PAGE).open(self)
	# Claims on the page move the count; the ROAD card follows when it closes.
	page.connect("closed", func() -> void:
		_loaded_ms = -100000
		if is_inside_tree():
			refresh())


# --- the card ledger --------------------------------------------------------------------

func _card_specs() -> Array:
	var out: Array = []
	for u in _estates.get("upgrades", []):
		out.append({"kind": "upgrade", "data": u})
	for h in _estates.get("holdings", []):
		out.append({"kind": "holding", "data": h})
	out.append({"kind": "legacy", "data": _legacy})
	return out


func _paint_cards() -> void:
	var specs := _card_specs()
	var tpl := Layout.find(SCREEN, "upgrade_card")
	var origin := Layout.rect_of(tpl).position
	# The painting's first card (GRANARY) stood where the storehouse now does:
	# the ledger follows the storehouse and the TALENTS / DEEDS / ROAD strip
	# under it, at the ledger's own gap.
	origin.y = Layout.rect_of(Layout.find(SCREEN, HONOURS_TEMPLATE)).end.y + STORE_GAP
	while _cards.size() < specs.size():
		var built := Layout.instantiate(tpl)
		_content.add_child(built["node"])
		var i := _cards.size()
		built["node"].position = origin + Vector2(0, i * PITCH)
		built["parts"]["button"].pressed.connect(_on_card_button.bind(i))
		if i == 0: GuideTargets.register("family.estates", built["parts"]["button"])
		# Live button text over the erased plate (the MAX LEVEL plate keeps its label).
		var btxt := UI.label("", 26, UI.INK, "title", 700, HORIZONTAL_ALIGNMENT_CENTER)
		UI.place(btxt, Rect2(Layout.rect_of(Layout.find(SCREEN, "button")).position, Vector2(326, 90)))
		btxt.mouse_filter = Control.MOUSE_FILTER_IGNORE
		# The word keeps clear of the plate's chamfered ends.
		btxt.set_meta("box_w", 326.0 - 2.0 * BUTTON_MARGIN)
		built["node"].add_child(btxt)
		built["btxt"] = btxt
		# What the next level buys, at the right of the level line and in the
		# green the paintings give a bonus. It shared one box with the level
		# ("LEVEL 12 / 20  ·  NEXT +3%"), and the two were fitted together down
		# to sixteen units.
		var lv: Control = built["parts"]["level"]
		var nxt := UI.label("", NEXT_FIT.x, NEXT_GREEN, "title", 600, HORIZONTAL_ALIGNMENT_RIGHT)
		UI.place(nxt, Rect2(lv.position, Vector2(LEVEL_ROW_W, lv.size.y)))
		built["node"].add_child(nxt)
		built["next"] = nxt
		_cards.append(built)
	for i in _cards.size():
		var c: Dictionary = _cards[i]
		if i >= specs.size():
			c["node"].visible = false
			continue
		c["node"].visible = true
		c["kind"] = specs[i]["kind"]
		c["data"] = specs[i]["data"]
		_paint_card(c)
	var bottom := origin.y + specs.size() * PITCH
	_ground.position.y = bottom - 10
	_footer.position.y = bottom + 8
	_content.custom_minimum_size = Vector2(941, maxf(1672, bottom + 120))


## The picture on a ledger card: the upgrade's, holding's or Legacy's own
## scene. Static, so a test can ask it.
static func card_scene(kind: String, d: Dictionary) -> String:
	match kind:
		"legacy":
			return LEGACY_ART
	var id := str(d.get("id", ""))
	if OWN_SCENE.has(id):
		return OWN_SCENE[id]
	var own := CARD_SCENE % id
	if Art.has(own):
		return own
	if kind == "upgrade":
		return CARD_ART[str(BUCKET_GROUP.get(str(d.get("bucket", "")), "income"))]
	return CARD_ART["income"]


func _paint_card(c: Dictionary) -> void:
	var p: Dictionary = c["parts"]
	var d: Dictionary = c["data"]
	var icon := "icons/gold_stack"
	match c["kind"]:
		"upgrade":
			icon = str(BUCKET_ICON.get(str(d.get("bucket", "")), icon))
		"legacy":
			icon = "icons/crown_small"
	p["art"].texture = Art.tex(card_scene(str(c["kind"]), d))
	_set_icon(p["icon"], icon)
	match c["kind"]:
		"upgrade":
			p["name"].text = str(d.get("name", "")).to_upper()
			var bucket := str(d.get("bucket", ""))
			var label: String = BUCKET_LABEL.get(bucket, bucket.replace("_bp", "").replace("_", " ").to_upper())
			var flat := bucket.ends_with("_flat")
			var maxed := bool(d.get("maxed", false))
			var per := int(d.get("per_level", 0))
			# The level line says what the next level buys, so the price has
			# something to be weighed against.
			p["level"].text = "LEVEL %d / %d" % [int(d.get("level", 0)), int(d.get("max_level", 0))]
			c["next"].text = "" if maxed else "NEXT +%s" % (str(per) if flat else _pct(per) + "%")
			var effect := int(d.get("effect_now", 0))
			p["bonus"].text = ("+%d %s" % [effect, label]) if flat else ("+%s%% %s" % [_pct(effect), label])
			if not bool(_estates.get("upgrades_unlocked", true)):
				_set_button(c, false, "OPENS AT LEVEL %d" % int(_estates.get("upgrades_unlock_level", 1)), true)
			else:
				_set_button(c, maxed, "UPGRADE   %s" % UI.short_number(int(d.get("next_cost", 0))), false)
		"holding":
			p["name"].text = str(d.get("name", "")).to_upper()
			p["level"].text = "LEVEL %d / %d" % [int(d.get("level", 0)), int(d.get("max_level", 0))]
			c["next"].text = ""
			var per_hour := int(d.get("yield_per_hour_milli", 0)) / 1000
			var next_add := int(d.get("yield_per_level_milli", 0)) / 1000
			if int(d.get("level", 0)) > 0:
				p["bonus"].text = "+%s GOLD / HOUR" % UI.grouped(per_hour)
			else:
				p["bonus"].text = "NEXT: +%s GOLD / HOUR" % UI.grouped(next_add)
			if not bool(d.get("unlocked", true)):
				_set_button(c, false, "OPENS AT LEVEL %d" % int(d.get("unlock_level", 1)), true)
			else:
				_set_button(c, bool(d.get("maxed", false)), "UPGRADE   %s" % UI.short_number(int(d.get("next_cost", 0))), false)
		"legacy":
			p["name"].text = "LEGACY"
			p["level"].text = "STACKS %d / %d" % [int(d.get("stacks", 0)), int(d.get("max_stacks", 0))]
			c["next"].text = "NEXT +%s%%" % _pct(int(d.get("next_bp", 0))) if int(d.get("next_bp", 0)) > 0 else ""
			p["bonus"].text = "+%s%% INCOME" % _pct(int(d.get("income_bp", 0)))
			if bool(d.get("available", false)):
				_set_button(c, false, "BEGIN A LEGACY", false)
			elif int(d.get("stacks", 0)) >= int(d.get("max_stacks", 1)):
				_set_button(c, true, "", true)
			else:
				_set_button(c, false, "AT LEVEL %d" % int(d.get("level_cap", 60)), true)
	UI.fit_label(p["name"], 36, 16)
	var nxt: Label = c["next"]
	UI.fit_label(nxt, NEXT_FIT.x, NEXT_FIT.y)
	var ns := nxt.label_settings
	var next_w := ns.font.get_string_size(nxt.text, HORIZONTAL_ALIGNMENT_LEFT, -1, ns.font_size).x if nxt.text != "" else 0.0
	p["level"].set_meta("box_w", LEVEL_ROW_W - (next_w + NEXT_CLEAR if next_w > 0.0 else 0.0))
	UI.fit_label(p["level"], 24, 18)
	UI.fit_label(p["bonus"], 22, 15)


## An icon in the card's slot at no more than one and a half times its own
## size: the marks are painted small, and filling the slot with a 32-unit sword
## blew it up into a smear.
func _set_icon(img: TextureRect, asset: String) -> void:
	var tex := Art.tex(asset)
	img.texture = tex
	var native := tex.get_size()
	var k := minf(minf(ICON_BOX.size.x / native.x, ICON_BOX.size.y / native.y), 1.5)
	var sz := native * k
	img.position = ICON_BOX.position + (ICON_BOX.size - sz) / 2.0
	img.size = sz


func _set_button(c: Dictionary, maxed: bool, text: String, disabled: bool) -> void:
	var b: TextureButton = c["parts"]["button"]
	var t: Label = c["btxt"]
	if maxed:
		b.texture_normal = Art.tex("family/btn_max_level")
		t.text = ""
		b.disabled = true
		b.modulate = Color.WHITE
	else:
		b.texture_normal = Art.tex("family/btn_upgrade_plate")
		t.text = text
		b.disabled = disabled
		b.modulate = Color(0.6, 0.6, 0.6) if disabled else Color.WHITE
	UI.fit_label(t, 26, 18)


func _pct(bp: int) -> String:
	if bp % 100 == 0:
		return str(bp / 100)
	return "%.1f" % (bp / 100.0)


func _on_card_button(i: int) -> void:
	if _busy or i >= _cards.size():
		return
	var c: Dictionary = _cards[i]
	var d: Dictionary = c["data"]
	match c["kind"]:
		"upgrade":
			if not await Dialog.ask(self, {"title": "Upgrade %s?" % str(d.get("name", "")),
					"body": "Level %d → %d for %s gold." % [int(d.get("level", 0)), int(d.get("level", 0)) + 1, UI.grouped(int(d.get("next_cost", 0)))],
					"confirm_text": "Upgrade"}):
				return
			await _act("/v1/estates/upgrade", {"id": str(d.get("id", ""))})
		"holding":
			if not await Dialog.ask(self, {"title": "Expand %s?" % str(d.get("name", "")),
					"body": "Level %d → %d for %s gold." % [int(d.get("level", 0)), int(d.get("level", 0)) + 1, UI.grouped(int(d.get("next_cost", 0)))],
					"confirm_text": "Expand"}):
				return
			await _act("/v1/estates/holding", {"id": str(d.get("id", ""))})
		"legacy":
			var resets: Array = d.get("resets", [])
			var keeps: Array = d.get("keeps", [])
			var body := "A permanent +%s%% income, for good." % _pct(int(d.get("next_bp", 0)))
			if not resets.is_empty():
				body += "\n\nBack to the start:\n" + "\n".join(resets)
			if not keeps.is_empty():
				body += "\n\nYou keep:\n" + "\n".join(keeps)
			if not await Dialog.ask(self, {"title": "Begin a Legacy?", "body": body + "\n\nThis cannot be undone.",
					"confirm_text": "Begin", "danger": true}):
				return
			await _act("/v1/legacy/begin", {})


## Every change on this screen goes through GameState.act, which numbers the
## action and adopts what the server sends back. Several went straight to the
## API with a sequence number of their own and never adopted a snapshot, so the
## pills lagged behind the purchase. `_busy` is held until the reload is in,
## so a second tap cannot land on the card the first one already changed.
func _act(path: String, body: Dictionary, done: String = "") -> Api.Response:
	_busy = true
	var res: Api.Response = await GameState.act(path, body)
	if res.ok:
		if done != "":
			GameState.toast(done)
		await _load()
	_busy = false
	return res


# --- stats, gear, name ---------------------------------------------------------------------

## Tapping a stat, when there are points to place, opens the page that places
## them -- all three stats side by side with what a point buys.
func _spend_point(_stat: String) -> void:
	if _busy or int(GameState.player().get("stat_points_unspent", 0)) <= 0:
		return
	var page: GDScript = load("res://scenes/pages/stats_page.gd")
	var sheet: Control = page.open(self)
	sheet.closed.connect(func() -> void: _load())


func _equip_best() -> void:
	if _busy:
		return
	var res := await _act("/v1/army/autoequip", {"scope": "hero"})
	if res.ok:
		var n := int(res.data.get("equipped", 0))
		GameState.toast("Nothing better to wear" if n == 0 else "Equipped %d item%s" % [n, "" if n == 1 else "s"])


## The hero's gear for one slot: everything that fits and is not on the hero
## already, best first. A piece a soldier is wearing is offered too, named as
## theirs, and taking it asks first -- it used to be offered as if it were free,
## and equipping it silently stripped the soldier.
func _choose_gear(slot: String) -> void:
	if _busy:
		return
	var items: Array = []
	for it in _inventory.get("items", []):
		if str(it.get("slot", "")) == slot and str(it.get("equipped_on", "")) != "hero":
			items.append(it)
	items.sort_custom(func(a, b): return int(a.get("power", 0)) > int(b.get("power", 0)))
	var worn_now: Variant = _inventory.get("equipped", {}).get(slot, null)
	var worn: Dictionary = worn_now if worn_now is Dictionary else {}
	var picker: GDScript = load("res://scenes/pages/item_picker.gd")
	var pick: String = await picker.pick(self, "YOUR %s" % slot.to_upper(), items, worn)
	if pick == "":
		return
	if pick == "__unequip":
		await _act("/v1/inventory/unequip", {"item_id": str(worn.get("id", ""))})
		return
	for it in items:
		if str(it.get("id", "")) == pick and str(it.get("worn_by", "")) != "":
			if not await Dialog.ask(self, {"title": "Take it from them?",
					"body": "%s is worn by your %s. They will fight without it." % [str(it.get("name", "")), str(it.get("worn_by", ""))],
					"confirm_text": "Take it"}):
				return
	await _act("/v1/inventory/equip", {"item_id": pick})


## The quill beside the name. A new name costs diamonds; the price is the
## server's (snapshot.prices) and the rules for what a name may be are the
## server's too -- this screen only asks and shows the answer.
func _rename() -> void:
	if _busy:
		return
	var price := int(GameState.snapshot.get("prices", {}).get("rename_diamonds", 0))
	var have := int(GameState.player().get("diamonds", 0))
	var r: Dictionary = await Dialog.prompt_text(self, {
		"title": "Change your name",
		"body": "3 to 16 letters, digits or underscore.\nCosts %d diamonds. You have %d." % [price, have],
		"placeholder": str(GameState.player().get("username", "")),
		"max_length": 16,
		"confirm_text": "Rename for %d diamonds" % price,
	})
	if str(r.get("action", "")) != "confirm":
		return
	var name := str(r.get("text", ""))
	if name == "":
		return
	await _act("/v1/profile/rename", {"name": name}, "You are now %s" % name)
