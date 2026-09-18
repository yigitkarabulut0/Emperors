extends RefCounted
## WHILE YOU WERE AWAY — the raids on the city since the game was last on the
## screen, said when the player comes back.
##
## A raided lord used to come back to less gold and nothing saying why. The
## server counts the raids since the moment this phone last saw the game
## (GET /v1/away?since=), with what they took, what holding them off paid, and
## how many raiders there is still time to answer.
##
## It is its own painting now (art/reference/away.png, layout
## client/layout/away.json) on the painted pages' host: RAIDS, GOLD LOST,
## RANSOM EARNED and TO AVENGE each in its card, the vault's note the
## painting's own, TAKE REVENGE only when there is someone to answer.

const SCREEN := "page:while_you_were_away"
const PAGE := "away"


## Asks the server and opens the page if anything happened. `revenge` is called
## to take the player to the Attack tab.
static func check(host: Node, since_unix: int, revenge: Callable) -> void:
	if since_unix <= 0:
		return
	var res: Api.Response = await Api.get_json("/v1/away?since=%d" % since_unix)
	if not res.ok or int(res.data.get("raids", 0)) <= 0 or not is_instance_valid(host):
		return
	open(host, res.data, revenge)


## The page for the server's away report {raids, gold_lost, ransom_earned,
## revenge}. `opts` goes to PaintedPage.open (a test's inset).
static func open(host: Node, d: Dictionary, revenge: Callable, opts: Dictionary = {}) -> PaintedPage:
	# The name the analytics has always had for it, from its Sheet days.
	var o := {"screen": SCREEN}
	o.merge(opts, true)
	var p := PaintedPage.open(host, PAGE, o)
	var raids := int(d.get("raids", 0))
	var lost := int(d.get("gold_lost", 0))
	var ransom := int(d.get("ransom_earned", 0))
	var waiting := int(d.get("revenge", 0))
	p.set_text("raids", UI.grouped(raids), 24)
	p.set_text("lost", ("-" + UI.grouped(lost)) if lost > 0 else "0", 24).label_settings.font_color = \
		UI.RED if lost > 0 else UI.DIM
	p.set_text("ransom", ("+" + UI.grouped(ransom)) if ransom > 0 else "0", 24).label_settings.font_color = \
		Color("#EFC53A") if ransom > 0 else UI.DIM
	p.set_text("avenge", UI.grouped(waiting), 24)
	# Nobody left to answer: no TAKE REVENGE, and CONTINUE alone in the middle
	# of the foot (both are erased from the painting and drawn as their own).
	p.set_shown("revenge", waiting > 0)
	if waiting <= 0:
		var go := p.node("continue")
		go.position.x = (PaintedPage.DESIGN.x - go.size.x) / 2.0
	p.on("revenge", func() -> void:
		p.close()
		revenge.call())
	return p
