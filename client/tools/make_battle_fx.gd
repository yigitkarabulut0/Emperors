extends SceneTree
## Bakes the two things a blow needs and the paintings do not contain.
##
## The references are screens, not a fight: there is no impact in them and no
## swing. Both are drawn here rather than found, in the game's own gold, and
## both are shapes rather than pictures -- a burst and a crescent -- so they
## read at any size and never look like a photograph of an explosion.
##
## Run: godot --headless --path client --script tools/make_battle_fx.gd

const SIZE := 256
const GOLD := Color(1.0, 0.86, 0.52)
const WHITE := Color(1.0, 0.98, 0.92)


func _initialize() -> void:
	_burst().save_png(ProjectSettings.globalize_path("res://assets/battle/impact.png"))
	print("wrote battle/impact.png %dx%d" % [SIZE, SIZE])
	_slash().save_png(ProjectSettings.globalize_path("res://assets/battle/slash.png"))
	print("wrote battle/slash.png %dx%d" % [SIZE, SIZE])
	quit()


## A four-point star with a hot core: what a blow landing looks like.
##
## The long axes are horizontal and vertical and the falloff is sharp, so it
## reads as a strike rather than a glow. Drawn in one pass from the centre out.
func _burst() -> Image:
	var img := Image.create(SIZE, SIZE, false, Image.FORMAT_RGBA8)
	var c := (SIZE - 1) / 2.0
	for y in SIZE:
		for x in SIZE:
			var dx := (x - c) / c
			var dy := (y - c) / c
			var r := sqrt(dx * dx + dy * dy)
			if r > 1.0:
				continue
			# The star: a spike along each axis, thin where the other is large.
			var spike := maxf(1.0 - absf(dy) * 7.0, 1.0 - absf(dx) * 7.0)
			spike = maxf(spike, 0.0) * pow(1.0 - r, 1.5)
			# The core: a small hot centre that carries the flash.
			var core := pow(clampf(1.0 - r * 3.2, 0.0, 1.0), 2.0)
			var a := clampf(spike * 1.15 + core, 0.0, 1.0)
			if a <= 0.004:
				continue
			img.set_pixel(x, y, Color(WHITE.lerp(GOLD, clampf(r * 2.2, 0.0, 1.0)), a))
	return img


## A crescent: the arc a blade leaves behind it.
##
## Bright along its leading edge and fading behind, so it has a direction --
## which is what makes a swing read as a swing and not as a smear.
func _slash() -> Image:
	var img := Image.create(SIZE, SIZE, false, Image.FORMAT_RGBA8)
	var c := (SIZE - 1) / 2.0
	var outer := 0.99
	var inner := 0.76
	for y in SIZE:
		for x in SIZE:
			var dx := (x - c) / c
			var dy := (y - c) / c
			var r := sqrt(dx * dx + dy * dy)
			if r > outer or r < inner:
				continue
			# Across the arc: brightest at its outer edge.
			var across := 1.0 - absf((r - (inner + outer) / 2.0) / ((outer - inner) / 2.0))
			# Along the arc: a 120-degree sweep that thins to nothing at the tips.
			var ang := atan2(dy, dx)
			var along := clampf(1.0 - absf(ang) / 1.05, 0.0, 1.0)
			# Hot and hard on the leading edge, soft behind: a blade, not a smear.
			var a := clampf(pow(across, 0.45) * pow(along, 1.1), 0.0, 1.0)
			if a <= 0.004:
				continue
			img.set_pixel(x, y, Color(WHITE.lerp(GOLD, 1.0 - across), a))
	return img
