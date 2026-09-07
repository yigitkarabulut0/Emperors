extends Node
## Scene switching. Normally change_scene_to_file; in a capture run (see
## Proof) scenes are mounted inside a fixed 941x1672 SubViewport instead, so a
## screenshot is the design grid pixel for pixel regardless of the window.

var host: SubViewport = null


## Where overlays (dialogs, the battle) mount: the capture viewport when there
## is one, so screenshots include them; else the window root.
func overlay_parent() -> Node:
	return host if host != null else get_tree().root


func go(path: String) -> void:
	if host == null:
		get_tree().change_scene_to_file(path)
		return
	for c in host.get_children():
		c.queue_free()
	var cur := get_tree().current_scene
	if cur != null and not host.is_ancestor_of(cur):
		cur.queue_free()
		get_tree().current_scene = null
	var scene: PackedScene = load(path)
	host.add_child(scene.instantiate())
