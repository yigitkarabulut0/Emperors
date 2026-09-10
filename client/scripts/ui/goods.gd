class_name Goods
extends RefCounted
## Buying a diamond good (GET /v1/store), wherever it is bought from.
##
## The Shop's Diamond Goods and the "+" on the energy pill sell the same
## refill, and they were two flows with two sets of words: one printed the
## server's blurb and checked the diamonds, the other did neither. Both come
## through here, so the same good reads the same and refuses the same way.


## Asks, buys, and says what happened. True when the purchase went through.
static func buy(host: Node, good: Dictionary) -> bool:
	var id := str(good.get("id", ""))
	var price := int(good.get("diamonds", 0))
	var have := int(GameState.player().get("diamonds", 0))
	var title := str(good.get("title", good.get("name", ""))).capitalize()
	var blurb := str(good.get("blurb", ""))
	if not bool(good.get("useful", true)):
		await Dialog.ask(host, {"title": title,
			"body": "%s\nNot now: %s." % [blurb, str(good.get("note", "it would do nothing"))],
			"confirm_text": "OK"})
		return false
	if not bool(good.get("affordable", have >= price)):
		await Dialog.ask(host, {"title": title,
			"body": "%s\nCosts %d diamonds, and you have %d.\nDiamonds come with every level and with the daily reward." % [blurb, price, have],
			"confirm_text": "OK"})
		return false
	if not await Dialog.ask(host, {"title": title,
			"body": "%s\n%d diamonds. You have %d." % [blurb, price, have], "confirm_text": "Buy"}):
		return false
	var res: Api.Response = await GameState.act("/v1/store/buy", {"good": id})
	if res.ok:
		GameState.toast("Energy refilled" if id == "energy_refill" else "Your city is protected")
	return res.ok


## The good with this id from a /v1/store answer, or {}.
static func find(store: Dictionary, id: String) -> Dictionary:
	for g in store.get("goods", []):
		if str(g.get("id", "")) == id:
			return g
	return {}
