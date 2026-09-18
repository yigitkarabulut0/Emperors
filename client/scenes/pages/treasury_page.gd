extends RefCounted
## THE ROYAL TREASURY — gold a raid cannot touch.
##
## It was a number prompt with two buttons, then a Sheet of kit rows. The
## vault's whole point is a decision -- how much to carry, how much to bank at
## a fee -- and the page puts the figures that decide it in front of the
## player: what is on hand, what is banked, the fee the server charges, with
## ALL and HALF a tap away. What a deposit burned is the server's answer
## (moved, fee, banked), said after it.
##
## Now it is its own painting (art/reference/treasury.png, layout
## client/layout/treasury.json) on the painted pages' host: the figures in the
## painting's boxes, the fee on its long plate, the amount typed into its box.

const SCREEN := "page:royal_treasury"
const PAGE := "treasury"


## `treasury` is the estates view's treasury: {vault, deposit_fee_bp,
## unlock_level, unlocked}. `opts` goes to PaintedPage.open (a test's inset),
## but for `mode`: "deposit" or "withdraw" opens the page ready for that move,
## its amount already the whole of what it would move (ALL ON HAND, ALL IN
## VAULT) -- the Family tab's TREASURY card opens it from its two buttons. The
## move itself is still the page's own button.
static func open(host: Node, treasury: Dictionary, opts: Dictionary = {}) -> PaintedPage:
	# The name the analytics has always had for it, from its Sheet days.
	var o := {"screen": SCREEN}
	o.merge(opts, true)
	var mode := str(o.get("mode", ""))
	o.erase("mode")
	var p := PaintedPage.open(host, PAGE, o)
	p.set_meta("t", treasury)
	var field := p.field("amount", "Amount of gold", true)
	p.set_meta("field", field)
	p.on("all_hand", func() -> void: field.text = str(GameState.display_gold()))
	p.on("half", func() -> void: field.text = str(GameState.display_gold() / 2))
	p.on("all_vault", func() -> void: field.text = str(_vault()))
	p.on("deposit", func() -> void: await _move(p, true, _amount(field)))
	p.on("withdraw", func() -> void: await _move(p, false, _amount(field)))
	match mode:
		"deposit":
			field.text = str(GameState.display_gold())
		"withdraw":
			field.text = str(_vault())
	_paint(p)
	return p


static func _vault() -> int:
	return int(str(GameState.player().get("treasury", "0")))


static func _amount(field: LineEdit) -> int:
	return int(field.text.strip_edges().replace(",", "").replace(".", ""))


static func _paint(p: PaintedPage) -> void:
	var t: Dictionary = p.get_meta("t")
	var open := bool(t.get("unlocked", true))
	var fee_bp := int(t.get("deposit_fee_bp", 0))
	var fee := (str(fee_bp / 100) if fee_bp % 100 == 0 else "%.1f" % (fee_bp / 100.0)) + "%"
	p.set_text("on_hand", UI.grouped(GameState.display_gold()), 28)
	p.set_text("vault", UI.grouped(_vault()), 28)
	if open:
		p.set_text("note", "A deposit costs %s, and the fee is gone for good. Taking gold out is free." % fee,
			18).label_settings.font_color = UI.INK
	else:
		p.set_text("note", "Deposits open at level %d. What is already in the vault is yours to take." % int(
			t.get("unlock_level", 1)), 18).label_settings.font_color = UI.GOLD
	# Closed below its level, DEPOSIT stays where the painting has it, dimmed:
	# what is already banked can still come out.
	p.set_enabled("deposit", open)


static func _move(p: PaintedPage, deposit: bool, amount: int) -> void:
	if amount <= 0:
		GameState.action_failed.emit("Say how much gold")
		return
	var res: Api.Response = await GameState.act("/v1/treasury/" + ("deposit" if deposit else "withdraw"), {"amount": amount})
	if not res.ok:
		return
	if deposit:
		var fee := int(res.data.get("fee", 0))
		GameState.toast("Banked %s%s" % [UI.grouped(int(res.data.get("banked", amount))),
			(" -- %s went in fees" % UI.grouped(fee)) if fee > 0 else ""])
	else:
		GameState.toast("Took %s from the vault" % UI.grouped(int(res.data.get("moved", amount))))
	if is_instance_valid(p):
		(p.get_meta("field") as LineEdit).text = ""
		_paint(p)
