package service

import (
	"context"
	"fmt"
	"time"

	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
)

// THE DESK's read of the wave's four features (Wave 7): how far the realm has
// walked, who is out on the roads, what the anvil has made and burnt, and which
// ranks of the tree the realm is buying.
//
// A read and nothing else: there is no lever here. The campaign is written down
// in the balance, an expedition is a lord's own tap, and a talent is a lord's
// own choice -- what an operator needs is to SEE them, and every number that
// could be moved is moved in the balance where it is validated.

// DepthView is the whole desk.
type DepthView struct {
	Chapters []ChapterProgress `json:"chapters"`
	// The miles walked in the window, and how many were first clears.
	Walks       int64 `json:"walks"`
	FirstClears int64 `json:"first_clears"`

	Fields []FieldOut `json:"fields"`
	// What the roads settled in the window.
	Home     int64 `json:"home"`
	Recalled int64 `json:"recalled"`
	// The wages they paid, in the balance's own units.
	GoldWages int64 `json:"gold_wages"`
	XPWages   int64 `json:"xp_wages"`

	Forged    []ForgedTier `json:"forged"`
	ForgeGold int64        `json:"forge_gold"`

	Talents  []TalentPick `json:"talents"`
	Respecs  int64        `json:"respecs"`
	Rethinks int64        `json:"rethinks"` // lords who have respecced at least once

	// The window these figures cover, in hours.
	WindowHours int `json:"window_hours"`
}

// ChapterProgress is one chapter of the road, across the realm.
type ChapterProgress struct {
	ID    string `json:"id"`
	Name  string `json:"name"`
	Lords int64  `json:"lords"`
	// Miles cleared at least once, the stars held on them, and every walk.
	Stages int64 `json:"stages"`
	Stars  int64 `json:"stars"`
	Walks  int64 `json:"walks"`
}

// FieldOut is one road, as it stands.
type FieldOut struct {
	ID     string `json:"id"`
	Name   string `json:"name"`
	Away   int64  `json:"away"`
	AtGate int64  `json:"at_gate"`
}

// ForgedTier is what the anvil made, by the rank that came out.
type ForgedTier struct {
	Tier string `json:"tier"`
	Made int64  `json:"made"`
}

// TalentPick is one rank of the tree, across the realm.
type TalentPick struct {
	ID     string `json:"id"`
	Name   string `json:"name"`
	Branch string `json:"branch"`
	Lords  int64  `json:"lords"`
	Ranks  int64  `json:"ranks"`
}

// Depth reads the desk. `hours` is the window the moving figures cover.
func (d Deps) Depth(ctx context.Context, hours int) (*DepthView, error) {
	if hours <= 0 || hours > 24*30 {
		hours = 24
	}
	q := sqlcdb.New(d.Pool)
	since := d.Now().Add(-time.Duration(hours) * time.Hour)
	v := &DepthView{
		WindowHours: hours,
		Chapters:    []ChapterProgress{}, Fields: []FieldOut{},
		Forged: []ForgedTier{}, Talents: []TalentPick{},
	}

	rows, err := q.CampaignByChapter(ctx)
	if err != nil {
		return nil, fmt.Errorf("campaign: %w", err)
	}
	seen := map[string]ChapterProgress{}
	for _, r := range rows {
		seen[r.ChapterID] = ChapterProgress{
			ID: r.ChapterID, Lords: r.Lords, Stages: r.Stages, Stars: r.Stars, Walks: r.Walks,
		}
	}
	// In the road's own order, and named as the balance names them: a chapter
	// nobody has reached is a row of zeros rather than a gap in the list.
	for i := range d.Config.Campaign.Chapters {
		ch := &d.Config.Campaign.Chapters[i]
		row := seen[ch.ID]
		row.ID, row.Name = ch.ID, ch.Name
		v.Chapters = append(v.Chapters, row)
	}
	if c, err := q.CampaignSince(ctx, since); err == nil {
		v.FirstClears, v.Walks = c.FirstClears, c.Walks
	}

	fields, err := q.ExpeditionsByField(ctx)
	if err != nil {
		return nil, fmt.Errorf("expeditions: %w", err)
	}
	out := map[string]FieldOut{}
	for _, r := range fields {
		out[r.FieldID] = FieldOut{ID: r.FieldID, Away: r.Away, AtGate: r.AtGate}
	}
	for i := range d.Config.Hunt.Fields {
		f := &d.Config.Hunt.Fields[i]
		row := out[f.ID]
		row.ID, row.Name = f.ID, f.Name
		v.Fields = append(v.Fields, row)
	}
	if e, err := q.ExpeditionsSince(ctx, &since); err == nil {
		v.Home, v.Recalled = e.Home, e.Recalled
		v.GoldWages, v.XPWages = e.GoldWages, e.XpWages
	}

	if made, err := q.ForgedSince(ctx, since); err == nil {
		for _, m := range made {
			v.Forged = append(v.Forged, ForgedTier{Tier: m.Tier, Made: m.Made})
		}
	}
	if g, err := q.ForgeGoldSince(ctx, since); err == nil {
		v.ForgeGold = g
	}

	if picks, err := q.TalentsPicked(ctx, 12); err == nil {
		for _, p := range picks {
			pick := TalentPick{ID: p.TalentID, Name: p.TalentID, Lords: p.Lords, Ranks: p.Ranks}
			if t, br := d.Config.Talents.Talent(p.TalentID); t != nil {
				pick.Name, pick.Branch = t.Name, br.Name
			}
			v.Talents = append(v.Talents, pick)
		}
	}
	if r, err := q.TalentRespecs(ctx); err == nil {
		v.Rethinks, v.Respecs = r.Lords, r.Respecs
	}
	return v, nil
}
