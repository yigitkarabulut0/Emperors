class_name StorePrice
extends RefCounted
## What a paid plate says, and how it looks, wherever the game sells for money
## (the Royal Store, the offer popup).
##
## The price a player pays is the App Store's, in their own currency
## (Billing.price), and only a phone with StoreKit knows it. Where purchases are
## not open -- a computer, or a phone whose build does not carry the plugin yet
## -- a plate would be a bright green bar with nothing on it, which reads as
## broken rather than closed. So it is drawn the way every button that cannot
## be pressed is drawn (DIMMED: the painted plates' disabled look, UI.plate_face)
## and carries the catalogue's reference price in dollars, in the muted ink, so
## the ladder of prices still reads; the store's note says why. On a phone with
## StoreKit a plate says "…" until the App Store has answered.

## One dimmed look for every plate that cannot be pressed: UI.plate_face's
## disabled plate (tests/store_view_fit.gd holds the two together).
const DIMMED := Color(0.55, 0.55, 0.55)
## A price that can be paid now; and one that is only a reference, or waiting.
const INK := Color("#F6F3EE")
const MUTED := Color("#B8AE9C")
const LOADING := "…"


## {text, muted} for one product's plate. `available` is whether StoreKit is
## here; `app_price` the App Store's price ("" until known); `answered` whether
## the App Store has answered since the plate asked; `suffix` follows a price
## (" a month" for the patronage). Pure, for tests.
static func words(p: Dictionary, available: bool, app_price: String, answered: bool, suffix: String = "") -> Dictionary:
	if bool(p.get("owned", false)):
		return {"text": "OWNED", "muted": false}
	if not available:
		var ref := usd(int(p.get("usd_cents", 0)))
		return {"text": ref + suffix if ref != "" else "", "muted": true}
	if app_price != "":
		return {"text": app_price + suffix, "muted": false}
	# Asked and not yet answered; or answered without this one, which the App
	# Store does not sell here -- then there is nothing true to say.
	return {"text": "" if answered else LOADING, "muted": true}


## The catalogue's reference price, "$4.99"; "" when there is none.
static func usd(cents: int) -> String:
	if cents <= 0:
		return ""
	return "$%d.%02d" % [cents / 100, cents % 100]


## Paints a plate and the words on it. `live` is whether it can be pressed.
static func paint(button: CanvasItem, label: Label, shown: Dictionary, live: bool) -> void:
	label.text = str(shown.get("text", ""))
	label.label_settings.font_color = MUTED if bool(shown.get("muted", false)) else INK
	button.modulate = Color.WHITE if live else DIMMED
