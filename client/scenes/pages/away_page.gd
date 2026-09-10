extends RefCounted
## WHILE YOU WERE AWAY — the raids on the city since the game was last on the
## screen, said when the player comes back.
##
## A raided lord used to come back to less gold and nothing saying why. The
## server counts the raids since the moment this phone last saw the game
## (GET /v1/away?since=), with what they took, what holding them off paid, and
## how many raiders there is still time to answer.


## Asks the server and opens the page if anything happened. `revenge` is called
## to take the player to the Attack tab.
static func check(host: Node, since_unix: int, revenge: Callable) -> void:
	if since_unix <= 0:
		return
	var res: Api.Response = await Api.get_json("/v1/away?since=%d" % since_unix)
	if not res.ok or int(res.data.get("raids", 0)) <= 0 or not is_instance_valid(host):
		return
	var d := res.data
	var s := Sheet.open(host, "WHILE YOU WERE AWAY")
	var raids := int(d.get("raids", 0))
	s.paragraph("Your city was raided %d time%s." % [raids, "" if raids == 1 else "s"], 34, UI.GOLD, HORIZONTAL_ALIGNMENT_CENTER)
	var lost := int(d.get("gold_lost", 0))
	var ransom := int(d.get("ransom_earned", 0))
	if lost > 0:
		var row := s.slot(96)
		row.add_child(UI.image("icons/sword_defeat", Rect2(20, 27, 46, 42)))
		Sheet.put(row, "Gold stolen", Rect2(84, 0, 400, 96), 28, UI.INK, "body", 600)
		Sheet.put(row, "-" + UI.grouped(lost), Rect2(s.inner_w - 300, 0, 280, 96), 32, UI.RED, "body", 800, HORIZONTAL_ALIGNMENT_RIGHT)
	if ransom > 0:
		var row := s.slot(96)
		row.add_child(UI.image("icons/sword_victory", Rect2(20, 27, 46, 42)))
		Sheet.put(row, "Ransom for raids held off", Rect2(84, 0, 440, 96), 28, UI.INK, "body", 600)
		Sheet.put(row, "+" + UI.grouped(ransom), Rect2(s.inner_w - 300, 0, 280, 96), 32, Color("#EFC53A"), "body", 800, HORIZONTAL_ALIGNMENT_RIGHT)
	s.paragraph("Gold in the Royal Treasury cannot be stolen.", 22, UI.DIM, HORIZONTAL_ALIGNMENT_CENTER)
	var waiting := int(d.get("revenge", 0))
	if waiting > 0:
		s.paragraph("%d raider%s can still be answered -- half the energy, and their shield will not stop you." % [
			waiting, "" if waiting == 1 else "s"], 24, UI.INK, HORIZONTAL_ALIGNMENT_CENTER)
		s.add_button("TAKE REVENGE", "danger", func() -> void:
			s.close()
			revenge.call())
	s.add_close("LATER" if waiting > 0 else "CLOSE")
