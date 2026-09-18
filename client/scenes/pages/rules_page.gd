extends RefCounted
## THE RULES OF RAIDING — behind the (i) on the Attack page's notice.
##
## Every number is the server's (the Attack view's `rules`), the ones the raid
## itself is decided by, so the page cannot describe a game the server does
## not play.


static func open(host: Node, rules: Dictionary) -> Sheet:
	var s := Sheet.open(host, "THE RULES OF RAIDING", "", 60, "", "pages/header_rules")
	var r := rules
	var pct := func(bp: int) -> String:
		return (str(bp / 100) if bp % 100 == 0 else "%.1f" % (bp / 100.0)) + "%"
	var items := [
		["WHO", "Raiding opens at level %d. You are matched with lords up to %d levels either side of you, and never with anyone under level %d -- they cannot raid back." % [
			int(r.get("fight_level", 10)), int(r.get("band_levels", 4)), int(r.get("fight_level", 10))]],
		# The CAP, not just the rate. The server has sent `raid_cap` -- the ceiling
		# at this lord's own level -- since it was added for exactly this line,
		# and the page printed the rate alone, so nobody could see why three per
		# cent of a rich purse is not three per cent.
		["THE TAKE", "Win, and you carry off up to %s of the gold they hold on hand -- never what is in their vault.%s The War Chest raises that ceiling." % [
			pct.call(int(r.get("steal_rate_bp", 300))), _take_cap(r)]],
		["LOSING", "A raid you lose costs its energy and nothing else, and pays the defender a ransom of %d%% of what you would have taken. Ransom Coffers raise what a defence is paid." % int(r.get("ransom_pct", 40))],
		["THE SHIELD", "A lord who is robbed cannot be raided again for %d minutes.%s" % [int(r.get("shield_minutes", 30)),
			" Raiding anyone yourself ends your own shield, bought or earned; a revenge strike does not." if bool(r.get("shield_breaks", false)) else ""]],
		["ONE TARGET AT A TIME", "After raiding a lord you must wait %d minutes to raid them again." % int(r.get("cooldown_minutes", 30))],
		["REVENGE", "When someone raids you, you have %d hours to strike back: half the energy, up to %s of their gold, and their shield does not stop you." % [
			int(r.get("revenge_hours", 24)), pct.call(int(r.get("revenge_rate_bp", 400)))]],
		["YOUR KINGDOM", "Lords of one kingdom cannot raid each other."],
	]
	for it in items:
		s.heading(str(it[0]))
		s.paragraph(str(it[1]), 24, UI.INK)
	s.add_close()
	return s


## What one raid can take at this lord's level, in gold, when the server says.
## An older server sends no cap: then the sentence simply says a level caps it,
## as it did before, rather than printing a zero.
static func _take_cap(r: Dictionary) -> String:
	var cap := int(r.get("raid_cap", 0))
	if cap <= 0:
		return " Your level caps the take."
	return " At your level one raid takes at most %s gold, however rich they are." % UI.short_number(cap)
