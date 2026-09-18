class_name CourtBack
extends RefCounted
## The way back out of a Court view, the same on every one: the painted quiet
## plate with its gold chevron (chrome/court_back), the word set in type where
## the painting set its own, and a tap target a thumb can use (layout
## client/layout/court_back.json).
##
## The views are hosted over whichever tab they were opened from, and the plate
## takes the player back there. The paintings say COURT, which is right when
## that tab is the COURT; opened over any other (the diamond pill, the
## profile's ROYAL MAIL, Armory's MORE ROOM), the plate says WORD.

const WORD := "BACK"
## Opened from the COURT tab, the plate names it, as the paintings do.
const COURT_WORD := "COURT"
const SCREEN := "court_back"


## Builds the plate, its word and its tap target into `view` (build it after
## the view's own layout, so it sits over the header), and returns the tap
## target to connect.
static func build(view: Control) -> BaseButton:
	var ui := Layout.build(SCREEN, view)
	var word: Label = ui["back_word"]
	word.text = word_for(view)
	UI.fit_line(word, word.label_settings.font_size, 18)
	return ui["back_hit"]


## The plate's word for a view: COURT when the tab it lies over, the one it
## goes back to, is the COURT; BACK otherwise.
static func word_for(view: Node) -> String:
	if view == null or not view.is_inside_tree():
		return WORD
	var shell := view.get_tree().get_first_node_in_group("shell")
	if shell != null and shell.has_method("current_tab") and str(shell.call("current_tab")) == "court":
		return COURT_WORD
	return WORD
