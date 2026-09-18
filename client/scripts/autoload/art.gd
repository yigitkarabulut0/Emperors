extends Node
## Every texture lookup. No scene may hardcode a res://assets path.
##
## Every asset is a crop of the reference paintings (see art/SLICING_GUIDE.md).
## A missing asset does not crash: it warns once and returns a magenta square, so
## the lint (which checks the manifest against disk) is what catches it.

var _cache: Dictionary = {}
var _missing: Dictionary = {}
var _placeholder: Texture2D
var _clear: Texture2D


func tex(name: String) -> Texture2D:
	if _cache.has(name):
		return _cache[name]
	if name.contains("{") or name.contains("<") or name == "":
		# A layout placeholder ("items/{item}"): the screen sets the real texture
		# once its data arrives. Until then nothing is drawn -- the magenta square
		# is for assets that are MISSING, and a slot waiting for the server is not
		# one of those, so it must not flash magenta on the way in.
		return _clear_tex()
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


func _clear_tex() -> Texture2D:
	if _clear == null:
		var img := Image.create(2, 2, false, Image.FORMAT_RGBA8)
		img.fill(Color(0, 0, 0, 0))
		_clear = ImageTexture.create_from_image(img)
	return _clear


func _placeholder_tex() -> Texture2D:
	if _placeholder == null:
		var img := Image.create(32, 32, false, Image.FORMAT_RGBA8)
		img.fill(Color(1, 0, 1, 0.6))
		_placeholder = ImageTexture.create_from_image(img)
	return _placeholder


## Server art keys ("weapon_03") name one painted item design each. The seven
## reference paintings hold a handful of item pictures, all of them framed and
## sized for one screen, so a slot showed the same picture whatever was worn in
## it. The designs now ship as their own matted paintings under items/painted/
## (art/painted holds the renders; see FRONTEND.md section 6) and every screen
## draws one inset into its own empty tile, so a change of gear is a change of
## picture. A design without a painting warns once and draws the placeholder,
## like any missing asset.
## The stone on a gear tile's frame, in a tier's colour; unlit for no tier.
## The tints are made from the painted red stone by scripts/gen-gem-tints.py,
## on the palette in balance/tiers.json.
func gem(tier: String) -> Texture2D:
	return tex("family/gem_" + (tier if tier != "" and has("family/gem_" + tier) else "empty"))


## The painted crop for a reward line's art key (server rewards.Line.Icon).
## One mapping, so a reward looks the same in a letter, a chest and a
## ceremony. A key with a slash is already a crop -- a cosmetic's own art, sent
## by the server -- and the rest are the semantic keys the server names.
const REWARD_ICON := {
	"diamond": "icons/diamond", "gold": "icons/coin", "xp": "icons/xp",
	"favour": "icons/crown_small", "energy_potion": "rewards/energy_potion",
	"city_shield": "rewards/charter", "boost:collect": "icons/gold_stack",
	"boost:xp": "icons/xp",
	# The Royal Store's lasting goods, as their lines name them (art/slices/store_2.json).
	"steward": "rewards/steward", "quartermaster": "rewards/quartermaster",
	"largesse": "rewards/largesse", "patronage": "rewards/patronage", "stipend": "rewards/stipend",
	# Wave 3's tokens and the Lucky Charm, from reward_icons.png (art/slices/rewards.json),
	# painted big and drawn down to 120 on the long side: one picture for a letter's
	# row, a calendar square, the Tax Cart's prize and a ceremony's tile.
	"flask_small": "rewards/flask_small", "flask_large": "rewards/flask_large",
	"pardon": "rewards/pardon", "cart": "rewards/cart_token", "boost:luck": "rewards/fortune_charm",
	# Rekabet (Wave 5): an arena ticket wears the hour that gives it -- Honor
	# Hour's own disc, the crossed swords over a laurel. One object, one look.
	"arena_ticket": "hourly/honor_hour",
}


## A title's picture on a reward line, and the enamel chip a name colour is
## sold on (the Wardrobe's and the Store's: its face is laid on at 11, 11).
const TITLE_SCROLL := "rewards/title_scroll"
const CHIP := "icons/colour_chip"
const CHIP_FACE := "icons/colour_chip_face"
const CHIP_FACE_AT := Vector2i(11, 11)
var _chips: Dictionary = {}


func reward_icon(key: String) -> Texture2D:
	if REWARD_ICON.has(key):
		return tex(REWARD_ICON[key])
	if key.contains("/") and has(key):
		return tex(key)
	# A frame cosmetic's art key names a set (frames/<id>_square, _ring, _tile);
	# on a reward it is the square one, as the wardrobe shows it.
	if key.begins_with("frames/") and has(key + "_square"):
		return tex(key + "_square")
	if key.begins_with("item:"):
		# Gear not yet rolled (a sealed letter's contents, a preview, the store):
		# its tier's stone, the one every gear tile wears, cut clean round its
		# setting (art/slices/rewards.json, tinted by scripts/gen-gem-tints.py).
		# The gear tiles' own crop (gem()) carries its slot's steel plate, and
		# showed as a grey square in a reward tile. Gear that was rolled names its
		# own painting (items/painted/<art>) and is drawn above.
		var tier := key.substr(5)
		return tex("rewards/gem_" + (tier if tier != "" and has("rewards/gem_" + tier) else "empty"))
	# A title (title:<id>): the crowned ribbon's middle, cut to read at a
	# reward's 46 units (art/slices/titles_sheet.json).
	if key.begins_with("title:"):
		return tex(TITLE_SCROLL)
	# A name colour (name_color:<id>): the enamel chip the Wardrobe and the
	# Store sell it on. The line carries the colour; reward_line_icon puts it on
	# the chip's face. Without it, the chip as painted.
	if key.begins_with("name_color:"):
		return tex(CHIP)
	# A reward this build has no picture for yet (a cosmetic without art, a
	# token added after it shipped): the crown the rewards already wear.
	# tests/reward_icons_complete.gd keeps every key the server sends off it.
	return tex("icons/reward_crown")


## A reward line's picture ({icon, color}): its key's (reward_icon), and for a
## name colour the enamel chip with its face in the line's own colour. Every
## screen that has the whole line draws it with this.
func reward_line_icon(line: Dictionary) -> Texture2D:
	var key := str(line.get("icon", ""))
	var color := str(line.get("color", ""))
	if key.begins_with("name_color:") and color != "":
		return colour_chip(color)
	return reward_icon(key)


## The enamel chip with its face in `color`, as one picture: the chip's gold
## rim (icons/colour_chip) and its face (icons/colour_chip_face) modulated by
## the colour and laid on at CHIP_FACE_AT -- how the Wardrobe and the Store
## draw it as two nodes, made into one texture for the reward rows, which
## hold one. Kept per colour.
func colour_chip(color: String) -> Texture2D:
	if _chips.has(color):
		return _chips[color]
	var rim := tex(CHIP)
	var face_tex := tex(CHIP_FACE)
	var img := rim.get_image() if rim != null else null
	var face := face_tex.get_image() if face_tex != null else null
	if img == null or face == null:
		return rim
	img = img.duplicate()
	img.decompress()
	img.convert(Image.FORMAT_RGBA8)
	face = face.duplicate()
	face.decompress()
	face.convert(Image.FORMAT_RGBA8)
	var c := Color(color)
	for y in face.get_height():
		for x in face.get_width():
			var p := face.get_pixel(x, y)
			face.set_pixel(x, y, Color(p.r * c.r, p.g * c.g, p.b * c.b, p.a))
	img.blend_rect(face, Rect2i(Vector2i.ZERO, face.get_size()), CHIP_FACE_AT)
	var t := ImageTexture.create_from_image(img)
	_chips[color] = t
	return t


func item(art_key: String) -> Texture2D:
	if art_key == "":
		return _clear_tex()
	return tex("items/painted/" + art_key)


## The painted face drawn for a player's portrait id (balance/progression.json
## "avatars").
##
## Every id has its own bust (art/reference/avatars_sheet.png, cut by
## art/slices/avatars_sheet.json): the knight in his helmet, the king in his
## crown, the monk, the witch. Until that painting there were four faces for the
## twelve ids, so a lord who chose the monk was drawn as a captain and three
## different choices showed the same queen.
##
## The faces are cut square inside their painted frames and carry no frame of
## their own: every screen puts its frame round them -- the Attack card's baked
## one, a rarity ring on the profile and in battle.
const AVATAR_FACE := {
	"knight": "portraits/avatar_knight", "king": "portraits/avatar_king",
	"queen": "portraits/avatar_queen", "archer": "portraits/avatar_archer",
	"monk": "portraits/avatar_monk", "berserk": "portraits/avatar_berserk",
	"knave": "portraits/avatar_knave", "herald": "portraits/avatar_herald",
	"templar": "portraits/avatar_templar", "witch": "portraits/avatar_witch",
	"captain": "portraits/avatar_captain", "princess": "portraits/avatar_princess",
	# Karel the Bandit, the guide's first fight (server: retention.guide.bandit
	# avatar "bandit"): the hooded, scarred knave of the avatars sheet, the
	# painted kit's one rogue. Not a choice (AVATAR_CHOICES leaves it out).
	"bandit": "portraits/avatar_knave",
}
## The faces a player may choose between, in the order the picker shows them
## (the balance's order): one face to an id, and the id is what a pick saves.
const AVATAR_CHOICES := [
	["portraits/avatar_knight", ["knight"]], ["portraits/avatar_king", ["king"]],
	["portraits/avatar_queen", ["queen"]], ["portraits/avatar_archer", ["archer"]],
	["portraits/avatar_monk", ["monk"]], ["portraits/avatar_berserk", ["berserk"]],
	["portraits/avatar_knave", ["knave"]], ["portraits/avatar_herald", ["herald"]],
	["portraits/avatar_templar", ["templar"]], ["portraits/avatar_witch", ["witch"]],
	["portraits/avatar_captain", ["captain"]], ["portraits/avatar_princess", ["princess"]],
]
## The face for an id nobody knows: the server's default avatar.
const AVATAR_DEFAULT := "portraits/avatar_knight"


## The face for a portrait id, cut at 236 -- the battle's portrait -- and fine
## down to about 120.
func avatar(id: String) -> String:
	return str(AVATAR_FACE.get(id, AVATAR_DEFAULT))


## The same face cut at 96, for rows that draw it near 70: the 236 cut shrunk
## that far, with no mipmaps, shimmers.
func avatar_small(id: String) -> String:
	return avatar(id) + "_small"


## The same face cut round, 160 across, for a round window (the rankings'
## podium and rows).
func avatar_ring(id: String) -> String:
	return avatar(id) + "_ring"


## The twelve painted crests (art/reference/crests_sheet.png, cut by
## art/slices/crests_sheet.json), each 91:120.
const CRESTS := ["icons/crest_lion", "icons/crest_wolf", "icons/crest_stag", "icons/crest_eagle",
	"icons/crest_bear", "icons/crest_dragon", "icons/crest_boar", "icons/crest_falcon",
	"icons/crest_tower", "icons/crest_rose", "icons/crest_sun", "icons/crest_raven"]


## The crest drawn for a lord or a kingdom that has not chosen one: one of the
## twelve, by its id, so the same lord or kingdom always wears the same crest --
## on a rival card, in the hall, wherever it is shown.
func crest(key: String) -> String:
	return str(CRESTS[absi(key.hash()) % CRESTS.size()])
