package service

import (
	"context"
	"fmt"
	"time"

	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
	"github.com/yigitkarabulut0/emperors/server/internal/game/war"
)

// THE DESK's read of Wave 8: the beasts standing against the realm's kingdoms,
// and the week's wars.
//
// A read and nothing else. There is no lever here on purpose -- a beast's
// health, a blow's cost, what a win is worth and what a week pays are all
// written in the balance, where Validate holds them and the Balance page is
// where a designer moves one.
//
// The one figure this desk exists for is the KILL RATE. boss.json's
// hp_per_might_bp is calibrated against a reference kingdom
// (internal/game/boss/calibration_test.go) so that a level-one beast falls in
// 65 to 80 per cent of cycles; this is the same number measured in the wild,
// and it is the first thing to look at when the raid feels wrong.

// WarDeskView is the whole desk.
type WarDeskView struct {
	// The beasts standing right now.
	Standing []DeskBeast `json:"standing"`
	// What closed in the window, and how much of it the realm put down.
	Cycles     int64 `json:"cycles"`
	Killed     int64 `json:"killed"`
	KillRateBP int64 `json:"kill_rate_bp"`
	// The average muster a closed cycle was cut from, for reading the rate with.
	AvgMembers int64 `json:"avg_members"`
	Damage     int64 `json:"damage"`
	Blows      int64 `json:"blows"`
	BlowLords  int64 `json:"blow_lords"`
	ChestsPaid int64 `json:"chests_paid"`

	// The week's wars, the busiest first.
	Wars []DeskWar `json:"wars"`
	// The week they are filed under, and when the next pairs are drawn.
	Week      string `json:"week"`
	NextDrawn string `json:"next_drawn"`
	Byes      int    `json:"byes"`

	Attacks    int64 `json:"attacks"`
	AttackWins int64 `json:"attack_wins"`
	Routs      int64 `json:"routs"`
	WarLords   int64 `json:"war_lords"`
	Points     int64 `json:"points"`

	WindowHours int `json:"window_hours"`
}

// DeskBeast is one cycle running.
type DeskBeast struct {
	KingdomID   string `json:"kingdom_id"`
	KingdomName string `json:"kingdom_name"`
	Tag         string `json:"tag"`
	BossID      string `json:"boss_id"`
	Name        string `json:"name"`
	Level       int    `json:"level"`
	HPMax       int64  `json:"hp_max"`
	HPLeft      int64  `json:"hp_left"`
	HPLeftBP    int64  `json:"hp_left_bp"`
	Members     int    `json:"members"`
	Fighters    int64  `json:"fighters"`
	Might       int64  `json:"kingdom_might"`
	EndsIn      int64  `json:"ends_in"`
	Killed      bool   `json:"killed"`
}

// DeskWar is one week's pair.
type DeskWar struct {
	ID      string `json:"id"`
	AName   string `json:"a_name"`
	BName   string `json:"b_name"`
	APoints int    `json:"a_points"`
	BPoints int    `json:"b_points"`
	AMight  int64  `json:"a_might"`
	BMight  int64  `json:"b_might"`
	Attacks int64  `json:"attacks"`
	Bye     bool   `json:"bye"`
	Settled bool   `json:"settled"`
	Winner  string `json:"winner"`
	EndsIn  int64  `json:"ends_in"`
}

// deskRows is how many of each list the desk is sent.
const deskRows = 40

// KingdomWarDesk reads the desk over a window in hours.
func (d Deps) KingdomWarDesk(ctx context.Context, hours int) (*WarDeskView, error) {
	if hours <= 0 {
		hours = 24
	}
	now := d.Now()
	since := now.Add(-time.Duration(hours) * time.Hour)
	q := sqlcdb.New(d.Pool)
	v := &WarDeskView{
		Standing: []DeskBeast{}, Wars: []DeskWar{}, WindowHours: hours,
		Week:      warWeek(d.Config, now).Format("2006-01-02"),
		NextDrawn: war.NextDraw(d.Config, now).Format(time.RFC3339),
	}

	standing, err := q.DeskBossStanding(ctx, deskRows)
	if err != nil {
		return nil, fmt.Errorf("beasts standing: %w", err)
	}
	for _, r := range standing {
		b := DeskBeast{
			KingdomID: r.KingdomID.String(), KingdomName: r.KingdomName, Tag: r.KingdomTag,
			BossID: r.BossID, Name: r.BossID, Level: int(r.Level),
			HPMax: r.HpMax, HPLeft: r.HpLeft,
			HPLeftBP: r.HpLeft * 10000 / maxI64(r.HpMax, 1),
			Members:  int(r.Members), Fighters: r.Fighters, Might: r.KingdomMight,
			EndsIn: secondsUntil(r.EndsAt, now), Killed: r.KilledAt != nil,
		}
		if def := d.Config.Boss.Boss(r.BossID); def != nil {
			b.Name = def.Name
		}
		v.Standing = append(v.Standing, b)
	}

	closed, err := q.DeskBossSettled(ctx, &since)
	if err != nil {
		return nil, fmt.Errorf("cycles closed: %w", err)
	}
	v.Cycles, v.Killed, v.Damage, v.AvgMembers = closed.Cycles, closed.Killed, closed.Damage, closed.Members
	if closed.Cycles > 0 {
		v.KillRateBP = closed.Killed * 10000 / closed.Cycles
	}
	blows, err := q.DeskBossBlows(ctx, since)
	if err != nil {
		return nil, fmt.Errorf("blows: %w", err)
	}
	v.Blows, v.BlowLords, v.ChestsPaid = blows.Blows, blows.Lords, blows.Paid

	wars, err := q.DeskWars(ctx, sqlcdb.DeskWarsParams{
		Week: d.WarWeekOf(now), Lim: deskRows,
	})
	if err != nil {
		return nil, fmt.Errorf("the week's wars: %w", err)
	}
	for _, r := range wars {
		w := DeskWar{
			ID: r.ID.String(), AName: r.AName, APoints: int(r.APoints), BPoints: int(r.BPoints),
			AMight: r.AMight, BMight: r.BMight, Attacks: r.Attacks,
			Bye: r.BID == nil, Settled: r.SettledAt != nil, EndsIn: secondsUntil(r.EndsAt, now),
		}
		if r.BName != nil {
			w.BName = *r.BName
		}
		if r.WinnerID != nil {
			w.Winner = r.WinnerID.String()
		}
		if w.Bye {
			v.Byes++
		}
		v.Wars = append(v.Wars, w)
	}

	att, err := q.DeskWarAttacks(ctx, since)
	if err != nil {
		return nil, fmt.Errorf("war attacks: %w", err)
	}
	v.Attacks, v.AttackWins, v.Routs = att.Attacks, att.Wins, att.Routs
	v.WarLords, v.Points = att.Lords, att.Points
	return v, nil
}
