extends Node
## Every texture lookup. No scene may hardcode a res://assets path.
##
## Every asset is a crop of the reference paintings (see art/SLICING_GUIDE.md).
## A missing asset does not crash: it warns once and returns a magenta square, so
## the lint (which checks the manifest against disk) is what catches it.

var _cache: Dictionary = {}
var _missing: Dictionary = {}
var _placeholder: Texture2D


func tex(name: String) -> Texture2D:
	if _cache.has(name):
		return _cache[name]
	if name.contains("{") or name.contains("<") or name == "":
		# A layout placeholder ("items/{item}"): the screen sets the real texture.
		return _placeholder_tex()
	var path := "res://assets/%s.png" % name
	if ResourceLoader.exists(path):
		var t: Texture2D = load(path)
		_cache[name] = t
		return t
	if not _missing.has(name):
		_missing[name] = true
		push_warning("[art] missing asset: " + name)
	return _placeholder_tex()


func has(name: String) -> bool:
	return ResourceLoader.exists("res://assets/%s.png" % name)


func _placeholder_tex() -> Texture2D:
	if _placeholder == null:
		var img := Image.create(32, 32, false, Image.FORMAT_RGBA8)
		img.fill(Color(1, 0, 1, 0.6))
		_placeholder = ImageTexture.create_from_image(img)
	return _placeholder


## Server art keys ("weapon_03") map onto the paintings cut from the references.
## Every screen has its own painting size, so it asks for its own set; within a
## set the key picks a painting deterministically. Unknown slots fall back to weapon.
const SETS := {
	"shop": {  # 192x216, badge area inpainted
		"weapon": ["items/dragonblade", "items/knights_oath"],
		"armor": ["items/lionheart_armor_shop", "items/valiant_armor"],
		"horse": ["items/royal_charger", "items/warhorse"],
	},
	"inventory": {  # 140x140 with tier frame baked (frame overlay corrects the tier)
		"weapon": ["items/shadowfang", "items/knights_blade", "items/bloodcrown"],
		"armor": ["items/dragonplate", "items/recruit_armor", "items/ranger_mail"],
		"horse": ["items/forest_charger", "items/nightmare"],
	},
	"equipped": {  # 221x194 landscape with gold frame
		"weapon": ["items/royal_longsword"],
		"armor": ["items/lionheart_armor"],
		"horse": ["items/war_steed"],
	},
	"family": {  # 220x192 with gold frame and gem
		"weapon": ["items/family_sword"],
		"armor": ["items/family_armor"],
		"horse": ["items/family_horse"],
	},
	"soldier": {  # ~100x100 gear tiles
		"weapon": ["items/army_spear"],
		"armor": ["items/army_leather_armor"],
		"horse": ["items/army_horse"],
	},
}


func item(art_key: String, set_name: String = "inventory") -> Texture2D:
	var parts := art_key.split("_")
	var slot := parts[0] if parts.size() > 0 else "weapon"
	var idx := int(parts[1]) if parts.size() > 1 else 0
	var set: Dictionary = SETS.get(set_name, SETS["inventory"])
	var list: Array = set.get(slot, set["weapon"])
	for i in list.size():
		var n: String = list[(idx + i) % list.size()]
		if has(n):
			return tex(n)
	return _placeholder_tex()
