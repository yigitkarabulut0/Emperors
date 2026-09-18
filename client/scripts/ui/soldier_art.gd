class_name SoldierArt
extends RefCounted
## Which painting a soldier wears, and which numeral its tier shows.
##
## The soldier sheet (art/reference/soldiers_sheet.png) paints each of the three
## types three times: rough, fine and gilded. A tier wears the look its rarity
## already reads as on every frame and chip in the game -- common and uncommon
## (steel, green) rough, rare and epic (blue, purple) fine, legendary, mystic
## and special (gold, magenta, crimson) gilded. By the published odds most
## villagers are therefore rough and most gladiators fine, and a gilded soldier
## is what a roll that lands high looks like. There was one painting per type;
## a tier VII gladiator was drawn as the tier I one.
##
## The numerals are the sheet's own for every tier, I to VII
## (art/reference/numerals_sheet.png): the plain diamond wherever a list or a
## card shows a tier, the fleur diamond for the one large badge a screen holds.
## Tiers IV and up used to be a blank plate with the numeral set in type.
##
## Pure lookups: every screen that draws a soldier or a tier asks here, so a
## soldier looks the same on the Army row, the selected panel and the reroll
## panel.

const TIER_INDEX := {"common": 1, "uncommon": 2, "rare": 3, "epic": 4, "legendary": 5, "mystic": 6, "special": 7}
const TYPES := ["peasant", "mercenary", "gladiator"]
## By tier index; index 0 is never a tier.
const LOOKS := ["rough", "rough", "rough", "fine", "fine", "gilded", "gilded", "gilded"]


## 1..7 from a tier id ("rare") or a tier index; anything else reads as 1.
static func tier_of(tier: Variant) -> int:
	if tier is int or tier is float:
		return clampi(int(tier), 1, 7)
	return int(TIER_INDEX.get(str(tier), 1))


static func look(tier: Variant) -> String:
	return LOOKS[tier_of(tier)]


## The strip card's portrait (133x164): the type in the look of its tier.
static func portrait(type: String, tier: Variant) -> String:
	return "portraits/soldier_%s_%s" % [_type(type), look(tier)]


## The selected soldier's portrait (202x286), for the window under the ring.
static func large(type: String, tier: Variant) -> String:
	return "portraits/soldier_%s_%s_large" % [_type(type), look(tier)]


## The plain tier diamond (50x50), centred on its painted rim.
static func numeral(tier: Variant) -> String:
	return "army/tier_%d" % tier_of(tier)


## The fleur tier diamond (80x124) for the one large badge on a screen.
static func numeral_large(tier: Variant) -> String:
	return "army/tier_large_%d" % tier_of(tier)


static func _type(type: String) -> String:
	return type if type in TYPES else "peasant"
