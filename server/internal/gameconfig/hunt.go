package gameconfig

// The expeditions (balance/hunt.json, Wave 7).
//
// A soldier is sent out for an hour, two, four or eight, and comes back with
// what they found. It is the only income in the game that costs no energy at
// all, so what it costs instead is the SOLDIER: away, they do not fight and
// cannot be rerolled, dismissed or re-geared.
//
// What comes back is wages -- the energy yardstick -- scaled by the soldier's
// rank and rolled AT DISPATCH, then frozen. The field's range is on the card
// before the tap; a recall pays nothing at all, because a reward that survives
// a recall is a reward taken by cancelling.

// HuntConfig is the whole of it.
type HuntConfig struct {
	Section string      `json:"section"`
	Slots   []HuntSlots `json:"slots"`
	Fields  []HuntField `json:"fields"`
	// What a soldier's rank is worth on the road: this share of the tier
	// ladder's own multiplier, so the best soldier is worth about twice the
	// plainest rather than five times.
	TierShareBP int64 `json:"tier_share_bp"`
	// How far either side of the field's own figure the roll may land.
	SpreadBP int64 `json:"spread_bp"`
	// Always false: it is here so the rule is a number in the document rather
	// than a sentence in a comment.
	RecallPays bool `json:"recall_pays"`
}

// HuntSlots is how many expeditions may run at once, from a level.
type HuntSlots struct {
	Level int64 `json:"level"`
	Slots int   `json:"slots"`
}

// HuntField is one place to send a soldier.
type HuntField struct {
	ID    string `json:"id"`
	Name  string `json:"name"`
	Hours int64  `json:"hours"`
	Blurb string `json:"blurb"`

	GoldWages int64 `json:"gold_wages"`
	XPWages   int64 `json:"xp_wages"`

	// The chance of a piece of gear, and the rank it would be.
	ItemChanceBP int64  `json:"item_chance_bp"`
	ItemTier     string `json:"item_tier"`
}

// Field returns one field by id.
func (h HuntConfig) Field(id string) *HuntField {
	for i := range h.Fields {
		if h.Fields[i].ID == id {
			return &h.Fields[i]
		}
	}
	return nil
}

// SlotsAt is how many expeditions a lord of this level may have out.
func (h HuntConfig) SlotsAt(level int64) int {
	n := 0
	for _, s := range h.Slots {
		if level >= s.Level && s.Slots > n {
			n = s.Slots
		}
	}
	return n
}
