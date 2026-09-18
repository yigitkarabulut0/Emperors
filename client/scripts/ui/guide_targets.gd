class_name GuideTargets
extends RefCounted
## The controls the guide through the first ten minutes points at, by name.
##
## Each screen that owns one registers it where it builds it, in one line
## (`GuideTargets.register("collect.job0", button)`), and the guide
## (scripts/ui/guide.gd) finds it here by the name the server's step gives
## (`snapshot.guide.target`). Nothing else reads this. A control that has left
## the tree is forgotten; one that is hidden -- a tab not on screen, a page
## not open -- is not found, which is how the guide knows to point at the way
## there instead.
##
## The names (docs/FRONTEND.md, "The guide"): collect.job0, rail.<tab>,
## pill.diamonds, daily.claim, court.chests, chests.open, shop.offer.<i>,
## family.gear.<slot>, family.stats, family.estates, army.recruit,
## attack.bandit.

static var _map: Dictionary = {}


static func register(name: String, control: Control) -> void:
	if control != null:
		_map[name] = weakref(control)


## The control registered under `name`, while it is in the tree and shown.
static func find(name: String) -> Control:
	var w: WeakRef = _map.get(name)
	if w == null:
		return null
	var c: Variant = w.get_ref()
	if not (c is Control) or not is_instance_valid(c):
		return null
	var ctl: Control = c
	if not ctl.is_inside_tree() or not ctl.is_visible_in_tree():
		return null
	return ctl


## Whether anything was ever registered under `name` (shown or not).
static func known(name: String) -> bool:
	var w: WeakRef = _map.get(name)
	return w != null and w.get_ref() != null


static func clear() -> void:
	_map.clear()
