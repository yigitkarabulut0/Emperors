class_name Goods
extends RefCounted
## Buying a diamond good (GET /v1/store), wherever it is bought from.
##
## The Shop's Diamond Goods and the "+" on the energy pill sell the same
## refill, and they were two flows with two sets of words: one printed the
## server's blurb and checked the diamonds, the other did neither. Both come
## through here, so the same good reads the same and refuses the same way.
##
## A good can also be paid for with the token that stands for it -- an Energy
## Potion for the refill, a Protection Charter for the shield. While the player
## holds one, BUY asks which to spend. Every word about limits (how many of the
## day's refills are left, why a good would do nothing now) is the server's.


## Where diamonds come from, said the same way wherever a purse is short:
## play pays them, and the Royal Store sells them.
const WHERE_DIAMONDS := "Diamonds come with every level and the daily reward, and the Royal Store sells them."


## Asks, buys, and says what happened. True when the purchase went through.
static func buy(host: Node, good: Dictionary) -> bool:
	var ask := plan(good, int(GameState.player().get("diamonds", 0)))
	var pay := ""
	match str(ask["kind"]):
		"refuse":
			await Dialog.ask(host, {"title": ask["title"], "body": ask["body"], "confirm_text": "OK"})
			return false
		"confirm":
			if not await Dialog.ask(host, {"title": ask["title"], "body": ask["body"],
					"confirm_text": ask["confirm_text"]}):
				return false
			pay = str(ask["pay"])
		"choose":
			pay = await Dialog.choose(host, {"title": ask["title"], "body": ask["body"],
				"options": ask["options"]})
			if pay == "":
				return false
	var id := str(good.get("id", ""))
	var res: Api.Response = await GameState.act("/v1/store/buy", request(id, pay))
	if res.ok:
		GameState.toast("Energy refilled" if id == "energy_refill" else "Your city is protected")
	return res.ok


## What BUY asks, from the good as the server described it and the diamonds the
## player holds. Pure, so a test can read every branch:
##   {kind: "refuse", title, body}
##   {kind: "confirm", title, body, confirm_text, pay}
##   {kind: "choose", title, body, options: [{id, label, sub}]}
## where pay (and each option's id) is "diamonds" or "token".
static func plan(good: Dictionary, have: int) -> Dictionary:
	var price := int(good.get("diamonds", 0))
	var was := on_sale(good)
	var title := str(good.get("title", good.get("name", ""))).capitalize()
	var blurb := str(good.get("blurb", ""))
	var tokens := int(good.get("tokens", 0))
	var token_name := str(good.get("token_name", ""))
	var affordable := bool(good.get("affordable", have >= price))
	# While a sale (Quartermaster's Sale) has it cheaper, every price is said
	# with the one it had: "10 diamonds, not 20".
	var cost := "%d diamonds" % price if was == 0 else "%d diamonds, not %d" % [price, was]
	if not bool(good.get("useful", true)):
		return {"kind": "refuse", "title": title,
			"body": "%s\nNot now: %s." % [blurb, str(good.get("note", "it would do nothing"))]}
	if tokens > 0 and token_name != "":
		var held := "You hold %d." % tokens
		if not affordable:
			return {"kind": "confirm", "title": title, "body": "%s\n%s" % [blurb, held],
				"confirm_text": "Use %s" % token_name, "pay": "token"}
		return {"kind": "choose", "title": title, "body": blurb, "options": [
			{"id": "token", "label": "Use %s" % token_name, "sub": "%d left" % tokens},
			{"id": "diamonds", "label": "Pay %s" % cost, "sub": "You have %d" % have},
		]}
	if not affordable:
		return {"kind": "refuse", "title": title,
			"body": "%s\nCosts %s, and you have %d.\n%s" % [blurb, cost, have, WHERE_DIAMONDS]}
	var tail := "" if was == 0 else " while the sale lasts"
	return {"kind": "confirm", "title": title, "body": "%s\n%s%s. You have %d." % [blurb, cost, tail, have],
		"confirm_text": "Buy", "pay": "diamonds"}


## The price a good had before a sale took from it (GET /v1/store's
## regular_diamonds, sent only while a sale runs); 0 when it is not on sale.
static func on_sale(good: Dictionary) -> int:
	var was := int(good.get("regular_diamonds", 0))
	return was if was > int(good.get("diamonds", 0)) else 0


## The body of POST /v1/store/buy. Diamonds are the server's default, so only a
## token is named.
static func request(id: String, pay: String) -> Dictionary:
	var body := {"good": id}
	if pay == "token":
		body["pay"] = "token"
	return body


## Whether BUY can lead anywhere but a refusal: the good would do something, and
## the player holds its price or its token.
static func buyable(good: Dictionary) -> bool:
	if not bool(good.get("useful", true)):
		return false
	return bool(good.get("affordable", true)) or int(good.get("tokens", 0)) > 0


## The good with this id from a /v1/store answer, or {}.
static func find(store: Dictionary, id: String) -> Dictionary:
	for g in store.get("goods", []):
		if str(g.get("id", "")) == id:
			return g
	return {}


# --- the flasks ----------------------------------------------------------------------
#
# The Small and Great Flasks come free -- from the Tax Cart, the calendar, a
# letter -- and are never sold, so the store lists them apart from its goods
# (GET /v1/store `flasks`: {id, name, blurb, icon, token_id, tokens, amount,
# useful}), where no screen can offer one for diamonds. The energy pill's "+"
# offers each one held beside the refill; `amount` is what one would add now,
# the server's figure, capped at the pool.

## The flasks the player holds, as the energy pill's "+" offers them: one
## option each ({id, label, sub}), in the store's order. Pure.
static func flask_options(store: Dictionary) -> Array:
	var out: Array = []
	for f in store.get("flasks", []):
		if not (f is Dictionary) or int(f.get("tokens", 0)) <= 0:
			continue
		var name := str(f.get("name", f.get("id", "")))
		var label := "Drink a %s" % name
		if bool(f.get("useful", true)) and int(f.get("amount", 0)) > 0:
			label += " (+%d)" % int(f.get("amount", 0))
		out.append({"id": str(f.get("id", "")), "label": label, "sub": "%d held" % int(f.get("tokens", 0))})
	return out


## The flask with this id from a /v1/store answer, or {}.
static func find_flask(store: Dictionary, id: String) -> Dictionary:
	for f in store.get("flasks", []):
		if f is Dictionary and str(f.get("id", "")) == id:
			return f
	return {}


## The energy pill's "+": the refill, through buy(); or, while a flask is held,
## a choice of each flask and the refill. True when energy was added.
static func energy(host: Node, store: Dictionary) -> bool:
	var refill := find(store, "energy_refill")
	var options := flask_options(store)
	if options.is_empty():
		return false if refill.is_empty() else await buy(host, refill)
	if not refill.is_empty():
		var sub := str(refill.get("caption", ""))
		if on_sale(refill) > 0:
			sub += " · %d diamonds, not %d" % [int(refill.get("diamonds", 0)), on_sale(refill)]
		options.append({"id": "energy_refill", "label": "Full refill", "sub": sub})
	var first := find_flask(store, str(options[0]["id"]))
	var pick: String = await Dialog.choose(host, {"title": "Energy",
		"body": str(first.get("blurb", "")), "options": options})
	match pick:
		"":
			return false
		"energy_refill":
			return await buy(host, refill)
	return await drink(host, find_flask(store, pick))


## Drinks one flask (POST /v1/tokens/use, sequenced: the pool is predicted).
static func drink(host: Node, flask: Dictionary) -> bool:
	var name := str(flask.get("name", "flask"))
	if not bool(flask.get("useful", true)):
		await Dialog.ask(host, {"title": name, "body": "Your energy is full: a %s would add nothing now." % name,
			"confirm_text": "OK"})
		return false
	var res: Api.Response = await GameState.act("/v1/tokens/use", {"token": str(flask.get("token_id", flask.get("id", "")))},
		{"energy_full": "Your energy is full: a %s would add nothing now." % name,
		"no_token": "You have no %s left." % name})
	if res.ok:
		GameState.toast("+%d energy" % int(res.data.get("energy_gained", 0)))
	return res.ok
