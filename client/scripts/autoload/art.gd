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


## Server art keys ("weapon_03") name one painted item design each. The seven
## reference paintings hold a handful of item pictures, all of them framed and
## sized for one screen, so a slot showed the same picture whatever was worn in
## it. The designs now ship as their own matted paintings under items/painted/
## (art/painted holds the renders; see FRONTEND.md section 6) and every screen
## draws one inset into its own empty tile, so a change of gear is a change of
## picture. A design without a painting warns once and draws the placeholder,
## like any missing asset.
func item(art_key: String) -> Texture2D:
	if art_key == "":
		return _placeholder_tex()
	return tex("items/painted/" + art_key)
