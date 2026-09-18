extends RefCounted
## THE RULES OF THE HALL -- chat_rules.png, the page a lord agrees to before
## they may speak.
##
## App Review 1.2 asks a game with talking in it for three things where the
## talking is: the rules, a way to report, and a way to reach a person. The
## hall's own rows carry the report; this page carries the other two.
##
## The rules come from the BALANCE (social.chat.rules, sent with the room), so
## changing what the realm asks of its lords is a publish and not a build -- and
## the version a lord agreed to is stored, so raising it asks everybody again.

const PAGE := "chat_rules"
const SCREEN := "page:chat_rules"


## Opens the page over `host`. opts.rules is the server's own rules block.
static func open(host: Node, opts: Dictionary = {}) -> PaintedPage:
	var o := {"screen": SCREEN}
	o.merge(opts, true)
	var p := PaintedPage.open(host, PAGE, o)
	var rules: Dictionary = opts.get("rules", {}) if opts.get("rules") is Dictionary else {}
	_paint(p, rules)
	p.on("agree", func() -> void: _agree(p, rules))
	p.on("close", func() -> void: p.close())
	return p


static func _paint(p: PaintedPage, rules: Dictionary) -> void:
	var lines: Array = rules.get("lines", [])
	var words := ""
	for l in lines:
		words += "•  " + str(l) + "\n"
	p.set_text("rules", words.strip_edges(), 20)
	var support := str(rules.get("support", ""))
	p.set_text("support", "Write to the crown at " + support if support != "" else "", 18)


static func _agree(p: PaintedPage, rules: Dictionary) -> void:
	var version := int(rules.get("version", 0))
	var res: Api.Response = await Api.post_json("/v1/chat/rules", {"version": version})
	if res.ok:
		p.close()
		return
	GameState.toast(res.error if res.error != "" else "The crown did not take that.")
