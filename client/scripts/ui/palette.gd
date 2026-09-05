class_name Palette
extends RefCounted
## The one place colours are defined.
##
## Tier colours mirror balance/tiers.json. They will move to the server config
## bundle so they can be retuned without a client update; until the config
## endpoint exists they live here, in sync with that file.

const BG          := Color("#1B1712")  ## app background
const PANEL       := Color("#241E1A")  ## cards and surfaces
const PANEL_HIGH  := Color("#2E2721")  ## hover / raised
const RAIL        := Color("#151210")  ## navigation rail
const LINE        := Color("#3A322B")  ## dividers and borders

const TEXT        := Color("#EDE6DA")
const TEXT_DIM    := Color("#9C9284")
const TEXT_FAINT  := Color("#6B6258")
const EMPTY_SLOT  := Color("#4A443C")  ## an unfilled equipment slot

const GOLD        := Color("#E5C97B")  ## primary accent, currency
const GOLD_DEEP   := Color("#B99A45")
const ENERGY      := Color("#F0A030")
const DIAMOND     := Color("#6FD3E8")
const DANGER      := Color("#D95A4E")
const SUCCESS     := Color("#6FBF73")

const TIERS := {
	"common":    Color("#9BA1A6"),
	"uncommon":  Color("#4ADE80"),
	"rare":      Color("#38BDF8"),
	"epic":      Color("#A855F7"),
	"legendary": Color("#F5C518"),
	"mystic":    Color("#E040FB"),
	"special":   Color("#EF4444"),
}

static func tier(id: String) -> Color:
	return TIERS.get(id, TEXT_DIM)
