extends RefCounted
## THE ROYAL TREASURY — gold a raid cannot touch.
##
## It was a number prompt with two buttons. The vault's whole point is a
## decision -- how much to carry, how much to bank at a fee -- and a page can
## put the figures that decide it in front of the player: what is on hand, what
## is banked, the fee the server charges, with ALL and HALF a tap away. What a
## deposit burned is the server's answer (moved, fee, banked), said after it.

const INFO_H := 110.0


## `treasury` is the estates view's treasury: {vault, deposit_fee_bp, unlock_level, unlocked}.
static func open(host: Node, treasury: Dictionary) -> Sheet:
	var s := Sheet.open(host, "ROYAL TREASURY", "Gold in the vault cannot be stolen.")
	s.set_meta("t", treasury)
	_paint(s)
	return s


static func _vault() -> int:
	return int(str(GameState.player().get("treasury", "0")))


static func _paint(s: Sheet) -> void:
	s.clear_body()
	for c in s.foot.get_children():
		c.queue_free()
	var t: Dictionary = s.get_meta("t")
	var open := bool(t.get("unlocked", true))
	var fee_bp := int(t.get("deposit_fee_bp", 0))
	var fee := (str(fee_bp / 100) if fee_bp % 100 == 0 else "%.1f" % (fee_bp / 100.0)) + "%"

	for pair in [["ON HAND", GameState.display_gold(), "icons/coin"], ["IN THE VAULT", _vault(), "icons/city_shield"]]:
		var row := s.slot(INFO_H)
		var icon := UI.image(str(pair[2]), Rect2(20, 14, 82, 82))
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		row.add_child(icon)
		Sheet.put(row, str(pair[0]), Rect2(118, 0, 300, INFO_H), 26, UI.DIM, "title", 700)
		Sheet.put(row, UI.grouped(int(pair[1])), Rect2(s.inner_w - 340, 0, 320, INFO_H), 36, UI.INK, "body", 700,
			HORIZONTAL_ALIGNMENT_RIGHT)

	if open:
		s.paragraph("A deposit costs %s, and the fee is gone for good. Taking gold out is free." % fee, 22, UI.DIM)
	else:
		s.paragraph("Deposits open at level %d. What is already in the vault is yours to take." % int(t.get("unlock_level", 1)),
			22, UI.GOLD)

	var field := UI.field("Amount of gold", 34, false, HORIZONTAL_ALIGNMENT_CENTER)
	field.virtual_keyboard_type = LineEdit.KEYBOARD_TYPE_NUMBER
	field.custom_minimum_size = Vector2(s.inner_w, 92)
	s.body.add_child(field)
	var chips := HBoxContainer.new()
	chips.add_theme_constant_override("separation", 12)
	chips.custom_minimum_size = Vector2(s.inner_w, 96)
	s.body.add_child(chips)
	var quick := [["ALL ON HAND", GameState.display_gold()], ["HALF", GameState.display_gold() / 2],
		["ALL IN VAULT", _vault()]]
	for q in quick:
		var c := Sheet.button(str(q[0]), Dialog.QUIET_PLATE, UI.INK, 96, 21)
		c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		c.pressed.connect(func() -> void: field.text = str(int(q[1])))
		chips.add_child(c)

	var amount := func() -> int:
		return int(field.text.strip_edges().replace(",", "").replace(".", ""))
	if open:
		s.add_button("DEPOSIT", "confirm", func() -> void: await _move(s, true, amount.call()))
	s.add_button("WITHDRAW", "quiet" if open else "confirm", func() -> void: await _move(s, false, amount.call()))
	s.add_close()


static func _move(s: Sheet, deposit: bool, amount: int) -> void:
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
	if is_instance_valid(s):
		_paint(s)
