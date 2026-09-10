extends RefCounted
## THE RULES OF RAIDING — behind the (i) on the Attack page's notice.
##
## Every number is the server's (the Attack view's `rules`), the ones the raid
## itself is decided by, so the page cannot describe a game the server does
## not play.


static func open(host: Node, rules: Dictionary) -> Sheet:
	var s := Sheet.open(host, "THE RULES OF RAIDING")
	var r := rules
	var pct := func(bp: int) -> String:
		return (str(bp / 100) if bp % 100 == 0 else "%.1f" % (bp / 100.0)) + "%"
	var items := [
		["WHO", "Raiding opens at level %d. You are matched with lords up to %d levels either side of you, and never with anyone under level %d -- they cannot raid back." % [
			int(r.get("fight_level", 10)), int(r.get("band_levels", 4)), int(r.get("fight_level", 10))]],
		["THE TAKE", "Win, and you carry off up to %s of the gold they hold on hand -- never what is in their vault. Your level caps the take, and the War Chest raises that cap." % pct.call(int(r.get("steal_rate_bp", 300)))],
		["LOSING", "A raid you lose costs its energy and nothing else, and pays the defender a ransom of %d%% of what you would have taken. Ransom Coffers raise what a defence is paid." % int(r.get("ransom_pct", 40))],
		["THE SHIELD", "A lord who is robbed cannot be raided again for %d minutes." % int(r.get("shield_minutes", 30))],
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
