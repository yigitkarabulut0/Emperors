extends RefCounted
## THE FORGE -- three pieces of one slot and one rank, and gold, make one of the
## rank above.
##
## Built from the owner's own painting (art/reference/forge.png, slices
## art/slices/forge.json, layout client/layout/forge.json). It was a Dialog.ask
## with its numbers written out in a sentence, because the painting sat unused
## in the design pack; this is the page the painting asks for -- the three
## pieces on the anvil's sockets, the arrow, what comes out in its own light,
## the fee beside the coin and the odds on their own plate.
##
## Every figure here is the SERVER'S. Which three pieces go in is the server's
## offer, ids and all (service.ForgeOffer): the fee follows the best mark of the
## three, so choosing them is part of pricing the work, and the two a lord gives
## up are always the plainest they have. The fee, the rank that comes out, the
## quality band and the masterwork chance are the server's too, and they are on
## the screen before the tap.
##
## `opts` is PaintedPage's (a test's own notch height, an instant open).
##
## A piece in a socket is the ARMORY'S object and not a second kind: the tier's
## rarity ring, the tier's velvet under it and the piece's own painting, placed
## by ItemGround.in_ringed_tile. The result socket takes the ring alone --
## WHICH piece the anvil makes is rolled when it strikes, so the painting's own
## anvil engraving is left showing rather than a guess.

const PAGE := "forge"
## The pieces that go in, in the server's own order: the piece the lord tapped
## first, then its two plainest companions.
const SOCKETS := ["1", "2", "3"]


## Opens the anvil for one piece. `armory` is the Armory tab, which reloads when
## the anvil has struck. `offer` is item["forge"], `rules` inventory["forge"],
## and `bag` every item the lord owns, so the three ids the offer names can be
## drawn as the pieces they are.
static func open(host: Node, armory: Node, item: Dictionary, offer: Dictionary,
		rules: Dictionary, bag: Array, opts: Dictionary = {}) -> PaintedPage:
	var p := PaintedPage.open(host, PAGE, opts)
	p.set_meta("armory", armory)
	p.set_meta("item", item)
	p.set_meta("offer", offer)
	p.set_meta("rules", rules)
	p.set_meta("bag", bag)
	p.on("forge", func() -> void: _strike(p))
	p.on("info", func() -> void: _rule(p))
	_paint(p)
	return p


static func _paint(p: PaintedPage) -> void:
	var offer: Dictionary = p.get_meta("offer", {})
	var rules: Dictionary = p.get_meta("rules", {})
	var going: Array = _going(p)

	for i in SOCKETS.size():
		var ring := p.node("ring_%s" % SOCKETS[i]) as TextureRect
		var art := p.node("art_%s" % SOCKETS[i]) as TextureRect
		if ring == null or art == null:
			continue
		if i >= going.size():
			# The anvil never opens with a socket empty -- the Armory only
			# offers it when the bag holds all three -- but a piece sold in
			# another window is a piece the offer no longer has.
			ring.visible = false
			art.visible = false
			ItemGround.under(art, "", Rect2(), false, ring)
			continue
		var it: Dictionary = going[i]
		var tier := str(it.get("tier", "common"))
		ring.visible = true
		art.visible = true
		ring.texture = Art.tex("inventory/frame_" + tier)
		art.texture = Art.item(str(it.get("art", "")))
		ItemGround.in_ringed_tile(art, ring, Rect2(ring.position, ring.size), tier)

	# What comes out: its rank, as its ring on that rank's own cloth. No
	# painting -- see the note above -- so the cloth is what fills the socket.
	var out := p.node("out_ring") as TextureRect
	var out_art := p.node("out_art") as TextureRect
	if out != null and out_art != null:
		var made_tier := str(offer.get("tier", "rare"))
		out.texture = Art.tex("inventory/frame_" + made_tier)
		out_art.texture = null
		ItemGround.in_ringed_tile(out_art, out, Rect2(out.position, out.size), made_tier)
	# Its rank in the Armory's own badge, centred on the cloth: the ring says it
	# in colour, and this says it in the word the bag uses.
	var badge := p.node("out_badge") as TextureRect
	if badge != null and out != null:
		badge.texture = Art.tex("inventory/badge_" + str(offer.get("tier", "rare")))
		if badge.texture != null:
			badge.size = badge.texture.get_size()
			badge.position = out.position + (out.size - badge.size) / 2.0

	p.set_text("fee", UI.grouped(int(offer.get("fee", 0))), 20)
	p.set_text("odds_label", "Masterwork", 13)
	p.set_text("odds", _in_a_hundred(int(rules.get("masterwork_chance_bp", 0))), 18)
	# FORGE stays lit whatever the purse holds: a button that swallows the tap
	# teaches nothing, and the server's own refusal says what is missing.
	p.set_enabled("forge", going.size() >= int(rules.get("pieces", 3)))


## The three pieces the offer names, as the bag knows them.
static func _going(p: PaintedPage) -> Array:
	var offer: Dictionary = p.get_meta("offer", {})
	var bag: Array = p.get_meta("bag", [])
	var by_id := {}
	for it in bag:
		if it is Dictionary:
			by_id[str((it as Dictionary).get("id", ""))] = it
	var out: Array = []
	for id in offer.get("items", []):
		if by_id.has(str(id)):
			out.append(by_id[str(id)])
	return out


## Basis points as the plate says them: 300 -> "3 in 100", 25 -> "0.3 in 100".
static func _in_a_hundred(bp: int) -> String:
	var pct := bp / 100.0
	if is_equal_approx(pct, roundf(pct)):
		return "%d in 100" % int(roundf(pct))
	return "%.1f in 100" % pct


## The whole rule in words, for the painting's own round i.
static func _rule(p: PaintedPage) -> void:
	if not p.armed():
		return
	var offer: Dictionary = p.get_meta("offer", {})
	var rules: Dictionary = p.get_meta("rules", {})
	var item: Dictionary = p.get_meta("item", {})
	# "3 rare pieces", never "3 rare weapon": the slot is on the sockets, and
	# armor and horse have no plural that reads.
	var lines := PackedStringArray([
		"%d %s pieces go on the anvil, and one %s comes out at mark %d." % [
			int(rules.get("pieces", 3)), str(item.get("tier", "")),
			str(offer.get("tier", "")), int(offer.get("ilvl", 0))],
		"",
		"Its quality is rolled fresh, between %d%% and %d%%, with %s to come out a masterwork." % [
			int(rules.get("quality_min_pct", 0)), int(rules.get("quality_max_pct", 0)),
			_in_a_hundred(int(rules.get("masterwork_chance_bp", 0)))],
		"",
		"The pieces that go in are gone for good.",
	])
	# No cancel_text and a confirm word of "Close": Dialog reads that as a
	# notice and gives it one way out instead of a decision.
	await Dialog.ask(p, {"title": "The anvil's rule", "body": "\n".join(lines),
		"confirm_text": "Close"})


static func _strike(p: PaintedPage) -> void:
	if bool(p.get_meta("busy", false)) or not p.armed():
		return
	var offer: Dictionary = p.get_meta("offer", {})
	var ids: Array = offer.get("items", [])
	if ids.is_empty():
		return
	p.set_meta("busy", true)
	p.set_enabled("forge", false)
	var res: Api.Response = await GameState.act("/v1/forge", {"item_ids": ids})
	p.set_meta("busy", false)
	if not res.ok:
		if is_instance_valid(p):
			p.set_enabled("forge", true)
		GameState.action_failed.emit(res.error)
		return
	var made: Dictionary = res.data.get("item", {}) if res.data is Dictionary else {}
	GameState.toast("The anvil made %s%s." % [str(made.get("name", "a piece")),
		"  ·  MASTERWORK" if bool(made.get("masterwork", false)) else ""])
	var armory: Variant = p.get_meta("armory") if p.has_meta("armory") else null
	if armory is Node and is_instance_valid(armory) and (armory as Node).has_method("reload_now"):
		await (armory as Node).call("reload_now")
	if is_instance_valid(p):
		p.close()
