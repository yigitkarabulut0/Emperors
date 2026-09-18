extends SceneTree
## The offer popup shows the right offer, counts its hours down, and goes away.
##
## - pick() chooses the live offer that ends soonest -- the one about to be
##   lost -- and never one that has ended, one that cannot be bought, or a
##   product that is not an offer.
## - Its timer is the server's seconds counted down a second at a time, red in
##   the last hour.
## - LATER and the close button put it away; the green button carries the App
##   Store's price.
##
## Run: godot --headless --path client --script tests/offer_popup_timer.gd

var _fails := 0
var _checked := 0


func _initialize() -> void:
	await process_frame
	var popup_script: GDScript = load("res://scenes/court/offer_popup.gd")

	var offer_a := {"id": "offer_l10", "store_id": "com.emperors.game.offer.l10", "shelf": "offers", "ends_in": 5000, "available": true}
	var offer_b := {"id": "offer_defeat", "store_id": "com.emperors.game.offer.defeat", "shelf": "offers", "ends_in": 300, "available": false}
	var offer_c := {"id": "starter", "store_id": "com.emperors.game.starter.299", "shelf": "offers", "ends_in": 1200, "available": true,
		"title": "The Founder's Crate", "lines": [
			{"kind": "diamonds", "amount": 300, "text": "300 diamonds", "icon": "diamond"},
			{"kind": "token", "amount": 3, "text": "3 Energy Potions", "icon": "energy_potion"},
			{"kind": "cosmetic", "amount": 1, "text": "Founder (frame)", "icon": "frames/founder"},
			{"kind": "cosmetic", "amount": 1, "text": "the Founder (title)", "icon": "title:title_founder"}]}
	var ended := {"id": "offer_empty", "store_id": "com.emperors.game.offer.empty", "shelf": "offers", "ends_in": 0, "available": true}
	var pack := {"id": "gems_60", "store_id": "com.emperors.game.gems.60", "shelf": "diamonds", "ends_in": 0}
	_checked += 1
	var picked: Dictionary = popup_script.pick([offer_a, offer_b, offer_c, ended, pack])
	_expect(str(picked.get("id", "")) == "starter", "pick chose %s, want the soonest live offer (starter)" % picked.get("id", "nothing"))
	_expect((popup_script.pick([pack, ended]) as Dictionary).is_empty(), "pick found an offer where none is live")
	_expect((popup_script.pick([]) as Dictionary).is_empty(), "pick found an offer in an empty store")

	# The popup itself: an offer with two minutes and five seconds left.
	var host := Control.new()
	host.size = Vector2(941, 1672)
	root.add_child(host)
	var soon := offer_c.duplicate(true)
	soon["ends_in"] = 125
	var p: CanvasLayer = popup_script.new()
	p.call("setup", soon, host)
	root.add_child(p)
	for i in 3:
		await process_frame
	var ui: Dictionary = p.get("_ui")
	var timer: Label = ui["timer"]
	_checked += 1
	_expect(timer.text == "2m 05s" or timer.text == "2m 04s", "the timer starts at %s, want 2m 05s" % timer.text)
	_expect(timer.label_settings.font_color == Color("#F0524F"), "under an hour left, the timer is not red")
	var before := timer.text
	await create_timer(2.2).timeout
	_expect(timer.text != before and timer.text.begins_with("2m 0"), "the timer did not count down: %s then %s" % [before, timer.text])
	_expect((ui["title"] as Label).text == "The Founder's Crate", "the banner does not carry the offer's title")
	_expect((ui["words_3"] as Label).text == "Founder (frame)", "the third tile does not say what it holds")
	_expect((ui["price"] as Label).text == "", "a price was shown before the App Store named one")
	var gone := [false]
	p.connect("closed", func() -> void: gone[0] = true)
	(ui["later"] as BaseButton).pressed.emit()
	await process_frame
	await process_frame
	_checked += 1
	_expect(gone[0] and not is_instance_valid(p), "LATER did not put the offer away")

	# The close button does too.
	var p2: CanvasLayer = popup_script.new()
	p2.call("setup", soon, host)
	root.add_child(p2)
	for i in 3:
		await process_frame
	((p2.get("_ui") as Dictionary)["close"] as BaseButton).pressed.emit()
	await process_frame
	await process_frame
	_checked += 1
	_expect(not is_instance_valid(p2), "the close button did not put the offer away")

	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  %d offer popup checks: the soonest offer, its hours counted down, LATER and X" % _checked)
	quit()


func _expect(ok: bool, why: String) -> void:
	if not ok:
		_fails += 1
		printerr("  ", why)
