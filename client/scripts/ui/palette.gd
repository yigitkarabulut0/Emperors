class_name Palette
extends RefCounted
## The one place colours are defined.
##
## This is a LIGHT theme: dark ink on parchment. It used to be the other way
## round, which is why the names read oddly at first glance -- BG is the palest
## thing here and TEXT the darkest. The names are semantic (what a colour is FOR)
## rather than literal (what it looks like), so they survived the inversion
## unchanged and so did the ~500 call sites that use them.
##
## Every text/ground pair below is measured against WCAG AA by
## scripts/check-contrast.py, which runs in the client lint. Three colours in the
## first draft of this palette failed it.

const BG          := Color("#E8DCC0")  ## parchment, the app ground
const PANEL       := Color("#F2E8D2")  ## cards and surfaces -- LIGHTER than BG
const PANEL_HIGH  := Color("#FBF4E4")  ## hover / raised
const RAIL        := Color("#D9CFBA")  ## the marble navigation column
const LINE        := Color("#B9A87E")  ## dividers and borders

const TEXT        := Color("#2E1F14")  ## ink
const TEXT_DIM    := Color("#5C4632")
## 6.10:1 on PANEL, 5.45:1 on BG, 4.80:1 on RAIL. It is the colour of every
## caption and every rail label in the game, so it clears AA on all three
## grounds rather than just the one it is most often seen on.
const TEXT_FAINT  := Color("#665238")
## Tints an unfilled equipment slot and a locked rail section. That last one is
## why it is this dark: on the marble rail a paler stone measured 1.33:1, which
## is not "dim", it is gone. 3.21:1 there, 4.08:1 on a card.
const EMPTY_SLOT  := Color("#7E6E4E")

## GOLD is ORNAMENT, not text.
##
## A convincing gold cannot reach 4.5:1 on parchment -- the maths does not allow
## it, and darkening one until it does turns it to mud. So gold does here what it
## does on the reference: it draws frames, rules, laurels and the crest, where
## contrast is judged as a graphic. Anything that has to be READ as a number uses
## GOLD_INK instead.
const GOLD        := Color("#B8860B")
const GOLD_INK    := Color("#6E4E06")  ## a gold FIGURE: 6.26:1 on PANEL
const GOLD_DEEP   := Color("#5C3F05")  ## edges and pressed states

const ENERGY      := Color("#8F4304")
const DIAMOND     := Color("#175C77")
const DANGER      := Color("#8B2222")
const SUCCESS     := Color("#2F6B3A")

## The imperial band: the top bar, screen-title plates and the primary button.
const BANNER      := Color("#7E1C1C")
const BANNER_INK  := Color("#F5E7C8")  ## 8.28:1 on BANNER
const STONE_EDGE  := Color("#A08E6A")  ## the lip of a carved plate

## Tier colours.
##
## These deliberately NO LONGER match balance/tiers.json, and that file is not
## changing. Tier hue is a presentation choice made against a GROUND: the admin
## panel is dark and the bright ladder is correct there, the game is now light
## and every one of those seven measured below 3.3:1 on parchment -- unreadable,
## and this is the text that names the rarity. Same ladder, same hue order, same
## separation, retuned for the ground it is printed on.
##
## The rule that makes the ladder robust is unchanged: tier is never carried by
## colour alone. Every card spells the tier out in words as well.
const TIERS := {
	"common":    Color("#5F666B"),
	"uncommon":  Color("#1B6E36"),
	"rare":      Color("#12608F"),
	"epic":      Color("#6B21A8"),
	"legendary": Color("#8A6100"),
	"mystic":    Color("#9A1E9E"),
	"special":   Color("#A81F1F"),
}

static func tier(id: String) -> Color:
	return TIERS.get(id, TEXT_DIM)
