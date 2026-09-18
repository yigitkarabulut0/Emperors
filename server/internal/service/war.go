package service

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/yigitkarabulut0/emperors/server/internal/db"
	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
	"github.com/yigitkarabulut0/emperors/server/internal/game"
	"github.com/yigitkarabulut0/emperors/server/internal/game/combat"
	"github.com/yigitkarabulut0/emperors/server/internal/game/deeds"
	"github.com/yigitkarabulut0/emperors/server/internal/game/war"
	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
)

// KRALLIK SAVASLARI -- the Kingdom tab's WAR section (war.json, Wave 8).
//
// Kingdoms are drawn against each other on Friday evening by the Might of their
// best fifteen, never against more than one and a half times their own and never
// the same pair twice running; the war itself runs Saturday to Monday.
//
// NOTHING OF A LORD'S IS AT STAKE. No gold is stolen, no energy is spent, a
// shield neither stops a war attack nor breaks on one, no cooldown is touched,
// no revenge token is granted and no reputation is earned per attack. What moves
// is POINTS, and what bounds it is three attacks a day. That is what lets a lord
// throw themselves at the biggest name on the other side without counting the
// cost -- and what stops a war from being a raid with a banner on it.
//
// That list is the feature, and it is exactly the sort of list that erodes one
// well-meaning line at a time, so war_rules_test.go reads this file and fails
// the build if it ever names any of them.
//
// LOCKING ORDER: app.players (LockTwoPlayers, ascending uuid), then app.wars
// (AddWarPoints' own row lock). A kingdom's row is never held here.

var (
	ErrWarSelf     = errors.New("you cannot ride out against yourself")
	ErrWarLocked   = errors.New("the kingdom wars open later")
	ErrNoWar       = errors.New("your kingdom is in no war this week")
	ErrWarBye      = errors.New("your kingdom drew nobody this week")
	ErrWarNotLive  = errors.New("the fighting has not begun")
	ErrWarOver     = errors.New("the war is over")
	ErrWarNotFoe   = errors.New("that lord is not in the kingdom you are at war with")
	ErrNoWarAttack = errors.New("you have made today's attacks")
)

// warRosterShown, warLogShown and warScorersShown are how much of each list the
// screen is sent. The scorers' is high because it is also what the settle pays
// from -- everybody who swung is on it.
const (
	warRosterShown  = 30
	warLogShown     = 25
	warScorersShown = 10
	warPaidShown    = 300
)

// closeWarDraw is the period_closes key a drawn week is written under.
const closeWarDraw = "war_draw"

// WarView is the WAR section.
type WarView struct {
	Unlocked    bool `json:"unlocked"`
	UnlockLevel int  `json:"unlock_level"`
	HasKingdom  bool `json:"has_kingdom"`

	// The war this week, when there is one. Nil between wars, and nil for a
	// kingdom nobody could be matched with.
	War *WarWeekView `json:"war"`
	// Seconds to the next drawing of the pairs.
	DrawsIn int64 `json:"draws_in"`
	// The kingdom drew nobody near enough in strength this week.
	Bye bool `json:"bye"`

	// The enemy's lords, and this lord's own side.
	Enemies []WarLordView `json:"enemies"`
	Allies  []WarLordView `json:"allies"`
	// The week's best lords, both sides together: the Warlord race.
	Scorers []WarScorerView `json:"scorers"`
	Log     []WarLogView    `json:"log"`

	Mine  WarMine   `json:"mine"`
	Rules WarRules  `json:"rules"`
	Purse WarPurses `json:"purse"`
}

// WarWeekView is the week's war as the banner reads it.
type WarWeekView struct {
	ID string `json:"id"`
	// Which side the asker's kingdom is, so nothing else has to be worked out
	// twice: every figure below is already told from their side.
	Side string `json:"side"`
	// Seconds until the fighting starts, and until it ends. One of the two is
	// always zero.
	StartsIn int64 `json:"starts_in"`
	EndsIn   int64 `json:"ends_in"`
	Live     bool  `json:"live"`

	Mine   WarSideView `json:"mine"`
	Theirs WarSideView `json:"theirs"`
	// Set once the week has been paid out.
	Settled bool `json:"settled"`
	Won     bool `json:"won"`
	Drawn   bool `json:"drawn"`
}

// WarSideView is one kingdom in the war.
type WarSideView struct {
	KingdomID string `json:"kingdom_id"`
	Name      string `json:"name"`
	Tag       string `json:"tag"`
	Points    int64  `json:"points"`
	// What the side was worth when the pair was drawn.
	Might   int64 `json:"might"`
	Members int   `json:"members"`
}

// WarLordView is one lord in a war, on either side.
type WarLordView struct {
	PlayerID string `json:"player_id"`
	Name     string `json:"name"`
	Avatar   string `json:"avatar"`
	Level    int64  `json:"level"`
	Might    int64  `json:"might"`
	// What they have taken for their side, and how many of their banners are
	// down.
	Points      int64 `json:"points"`
	BannersLost int   `json:"banners_lost"`
	Banners     int   `json:"banners"`
	Routed      bool  `json:"routed"`
	// How many times the asker has already met this lord in this war.
	Met int `json:"met"`
	// What beating them would be worth to the asker's side, right now -- the
	// ratio, the clamp and the routed quarter already in it. The client prints
	// this number; it never works one out.
	Worth int64 `json:"worth,omitempty"`
	Mine  bool  `json:"mine"`
	Look
}

// WarScorerView is one lord on the week's board.
type WarScorerView struct {
	Place    int    `json:"place"`
	PlayerID string `json:"player_id"`
	Name     string `json:"name"`
	Side     string `json:"side"`
	Points   int64  `json:"points"`
	Attacks  int    `json:"attacks"`
	// Whether they are on the asker's side, and whether they are the asker.
	Ours bool `json:"ours"`
	Mine bool `json:"mine"`
}

// WarLogView is one attack, as the log tells it.
type WarLogView struct {
	At       string `json:"at"`
	Attacker string `json:"attacker"`
	Defender string `json:"defender"`
	Won      bool   `json:"won"`
	Points   int64  `json:"points"`
	Routed   bool   `json:"routed"`
	// Whether the attacker was on the asker's side.
	Ours     bool   `json:"ours"`
	BattleID string `json:"battle_id,omitempty"`
}

// WarMine is what this lord may still do today.
type WarMine struct {
	Attacks     int `json:"attacks"`
	AttacksLeft int `json:"attacks_left"`
	PerDay      int `json:"per_day"`
	// Seconds until the day's three come back.
	ResetsIn int64 `json:"resets_in"`
	// This lord's own banners, and their points for the side.
	BannersLost int   `json:"banners_lost"`
	Banners     int   `json:"banners"`
	Routed      bool  `json:"routed"`
	Points      int64 `json:"points"`
	Might       int64 `json:"might"`
}

// WarRules are the war's terms, for the sheet behind the (i).
type WarRules struct {
	AttacksPerDay int   `json:"attacks_per_day"`
	Banners       int   `json:"banners"`
	RoutBP        int64 `json:"rout_bp"`
	WinBase       int64 `json:"win_base"`
	RatioMinBP    int64 `json:"ratio_min_bp"`
	RatioMaxBP    int64 `json:"ratio_max_bp"`
	Loss          int64 `json:"loss"`
	Held          int64 `json:"held"`
	TopMembers    int   `json:"top_members"`
	MaxRatioBP    int64 `json:"max_ratio_bp"`
	MinMembers    int   `json:"min_members"`
	Days          int   `json:"days"`
	// The one line every lord asks about, in the server's own words so the two
	// screens that say it cannot disagree.
	ShieldNote string `json:"shield_note"`
}

// WarPurses is what each side takes home.
type WarPurses struct {
	Won  WarPurseView `json:"won"`
	Lost WarPurseView `json:"lost"`
}

// WarPurseView is one purse as the card draws it.
type WarPurseView struct {
	Lines      []string `json:"lines"`
	Reputation int64    `json:"reputation"`
	KingdomXP  int64    `json:"kingdom_xp"`
}

// WarAttackResult is one attack, for the client to animate.
type WarAttackResult struct {
	BattleID string `json:"battle_id"`
	Won      bool   `json:"won"`
	// What the side took for it, and what the other side took for holding.
	Points     int64 `json:"points"`
	HeldPoints int64 `json:"held_points"`
	Routed     bool  `json:"routed"`
	// The defender's banners after this attack.
	BannersLost int `json:"banners_lost"`
	// The war's score after it, told from the asker's side.
	MyPoints    int64          `json:"my_points"`
	TheirPoints int64          `json:"their_points"`
	AttacksLeft int            `json:"attacks_left"`
	Replay      *combat.Replay `json:"replay"`
	Snapshot    *Snapshot      `json:"snapshot"`
}

// warShieldNote is the sentence the notice and the card both print.
const warShieldNote = "A shield guards against raids, not against the Kingdom War."

// GetWar paints the WAR section.
func (d Deps) GetWar(ctx context.Context, playerID uuid.UUID) (*WarView, error) {
	q := sqlcdb.New(d.Pool)
	p, err := q.GetPlayerByID(ctx, playerID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, fmt.Errorf("war: %w", err)
	}
	cfg := d.Config.War
	at := d.Config.SectionLevel(cfg.Section)
	now := d.Now()

	v := &WarView{
		Unlocked: d.Config.HasSection(cfg.Section) && int(p.Level) >= at, UnlockLevel: at,
		HasKingdom: p.KingdomID != nil,
		DrawsIn:    secondsUntil(war.NextDraw(d.Config, now), now),
		Enemies:    []WarLordView{}, Allies: []WarLordView{},
		Scorers: []WarScorerView{}, Log: []WarLogView{},
		Mine: WarMine{PerDay: cfg.AttacksPerDay, AttacksLeft: cfg.AttacksPerDay,
			Might: p.Might, Banners: cfg.Banners},
		Rules: WarRules{
			AttacksPerDay: cfg.AttacksPerDay, Banners: cfg.Banners, RoutBP: cfg.RoutBP,
			WinBase: cfg.Points.WinBase, RatioMinBP: cfg.Points.RatioMin,
			RatioMaxBP: cfg.Points.RatioMax, Loss: cfg.Points.Loss, Held: cfg.Points.Held,
			TopMembers: cfg.TopMembers, MaxRatioBP: cfg.MaxRatioBP, MinMembers: cfg.MinMembers,
			Days: cfg.Days, ShieldNote: warShieldNote,
		},
		Purse: WarPurses{
			Won: WarPurseView{Lines: d.rewardLines(cfg.Won.Grant, int(p.Level)),
				Reputation: cfg.Won.Reputation, KingdomXP: cfg.Won.KingdomXP},
			Lost: WarPurseView{Lines: d.rewardLines(cfg.Lost.Grant, int(p.Level)),
				Reputation: cfg.Lost.Reputation, KingdomXP: cfg.Lost.KingdomXP},
		},
	}
	if !v.HasKingdom {
		return v, nil
	}

	row, err := q.GetWarFor(ctx, sqlcdb.GetWarForParams{
		Week: dateOf(warWeek(d.Config, now)), KingdomID: *p.KingdomID,
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return v, nil // between wars
		}
		return nil, fmt.Errorf("this week's war: %w", err)
	}
	if row.BID == nil {
		v.Bye = true
		return v, nil
	}
	side, mineID, theirsID := warSides(row, *p.KingdomID)

	week := &WarWeekView{
		ID: row.ID.String(), Side: side,
		StartsIn: secondsUntil(row.StartsAt, now), EndsIn: secondsUntil(row.EndsAt, now),
		Live:    !now.Before(row.StartsAt) && now.Before(row.EndsAt),
		Settled: row.SettledAt != nil,
	}
	week.Mine, week.Theirs = d.warSideView(ctx, q, row, mineID), d.warSideView(ctx, q, row, theirsID)
	if row.SettledAt != nil {
		week.Drawn = row.WinnerID == nil
		week.Won = row.WinnerID != nil && *row.WinnerID == mineID
	}
	v.War = week

	enemies, err := d.warRoster(ctx, q, row, theirsID, playerID, p.Might, true)
	if err != nil {
		return nil, err
	}
	v.Enemies = enemies
	allies, err := d.warRoster(ctx, q, row, mineID, playerID, p.Might, false)
	if err != nil {
		return nil, err
	}
	v.Allies = allies
	for _, a := range allies {
		if a.Mine {
			v.Mine.BannersLost, v.Mine.Routed, v.Mine.Points = a.BannersLost, a.Routed, a.Points
		}
	}

	// The day's three, counted from the rows themselves: a restart hands nobody
	// a fresh three, and a lord who attacked at 23:59 has three again a minute
	// later because the war's day is the REALM'S day, not theirs. A war is one
	// clock for two kingdoms; a local day would give the lord further east a
	// fourth attack the lord further west could not answer.
	since := warDayStart(row, now)
	used, err := q.CountWarAttacksSince(ctx, sqlcdb.CountWarAttacksSinceParams{
		WarID: row.ID, AttackerID: playerID, Since: since,
	})
	if err != nil {
		return nil, fmt.Errorf("today's attacks: %w", err)
	}
	v.Mine.Attacks = int(used)
	v.Mine.AttacksLeft = maxInt(0, cfg.AttacksPerDay-int(used))
	v.Mine.ResetsIn = secondsUntil(warDayEnd(row, now), now)

	scorers, err := q.ListWarScorers(ctx, sqlcdb.ListWarScorersParams{WarID: row.ID, Lim: warScorersShown})
	if err != nil {
		return nil, fmt.Errorf("war scorers: %w", err)
	}
	for i, s := range scorers {
		v.Scorers = append(v.Scorers, WarScorerView{
			Place: i + 1, PlayerID: s.AttackerID.String(), Name: s.DisplayName, Side: s.Side,
			Points: s.Points, Attacks: int(s.Attacks),
			Ours: s.Side == side, Mine: s.AttackerID == playerID,
		})
	}

	logRows, err := q.ListWarLog(ctx, sqlcdb.ListWarLogParams{WarID: row.ID, Lim: warLogShown})
	if err != nil {
		return nil, fmt.Errorf("war log: %w", err)
	}
	for _, l := range logRows {
		e := WarLogView{
			At: l.CreatedAt.UTC().Format(time.RFC3339), Attacker: l.AttackerName,
			Defender: l.DefenderName, Won: l.Won, Points: int64(l.Points),
			Routed: l.Routed, Ours: l.Side == side,
		}
		if l.BattleID != nil {
			e.BattleID = l.BattleID.String()
		}
		v.Log = append(v.Log, e)
	}
	return v, nil
}

// warSideView is one kingdom's half of the banner.
func (d Deps) warSideView(ctx context.Context, q *sqlcdb.Queries, row sqlcdb.AppWar,
	kingdomID uuid.UUID) WarSideView {

	v := WarSideView{KingdomID: kingdomID.String()}
	if row.AID == kingdomID {
		v.Points, v.Might = int64(row.APoints), row.AMight
	} else {
		v.Points, v.Might = int64(row.BPoints), row.BMight
	}
	if k, err := q.GetKingdom(ctx, kingdomID); err == nil {
		v.Name, v.Tag = k.Name, k.Tag
	}
	if n, err := q.CountKingdomMembers(ctx, &kingdomID); err == nil {
		v.Members = int(n)
	}
	return v
}

// warRoster is one side's lords, with what each of them is worth to the asker.
func (d Deps) warRoster(ctx context.Context, q *sqlcdb.Queries, row sqlcdb.AppWar,
	kingdomID, me uuid.UUID, myMight int64, foes bool) ([]WarLordView, error) {

	cfg := d.Config.War
	rows, err := q.ListWarRoster(ctx, sqlcdb.ListWarRosterParams{
		WarID: row.ID, Me: me, KingdomID: &kingdomID, Lim: warRosterShown,
	})
	if err != nil {
		return nil, fmt.Errorf("war roster: %w", err)
	}
	out := make([]WarLordView, 0, len(rows))
	for _, r := range rows {
		routed := war.Routed(d.Config, int(r.BannersLost))
		l := WarLordView{
			PlayerID: r.ID.String(), Name: r.DisplayName, Avatar: r.Avatar,
			Level: int64(r.Level), Might: r.Might, Points: r.Points,
			BannersLost: int(r.BannersLost), Banners: cfg.Banners, Routed: routed,
			Met: int(r.Met), Mine: r.ID == me,
			Look: lookOf(d.Config, r.CosFrame, r.CosTitle, r.CosColor, r.CosCrest, r.VipPoints),
		}
		if foes {
			// What this lord is worth is the SERVER'S arithmetic, run for the
			// card exactly as the attack will run it. A client that worked out
			// "14 points" from a ratio of its own would be the second
			// implementation of the scoring, and the first one to be wrong.
			l.Worth = war.WinPoints(d.Config, myMight, r.Might, routed)
		}
		out = append(out, l)
	}
	return out, nil
}

// warWeek is the Monday the week's pairs were drawn in: the key a war is filed
// under.
func warWeek(cfg *gameconfig.Bundle, now time.Time) time.Time {
	return mondayOf(war.WindowFor(cfg, now).Drawn)
}

// mondayOf is the UTC Monday of a moment's week.
func mondayOf(t time.Time) time.Time {
	return time.Unix(deeds.UWeek(t)*86400, 0).UTC()
}

// warSides says which side of a pair a kingdom is, and who the other one is.
func warSides(row sqlcdb.AppWar, kingdomID uuid.UUID) (side string, mine, theirs uuid.UUID) {
	if row.AID == kingdomID {
		if row.BID != nil {
			theirs = *row.BID
		}
		return "a", row.AID, theirs
	}
	return "b", *row.BID, row.AID
}

// warDayStart is when this lord's three attacks were last handed out: UTC
// midnight, or the war's own start on its first day.
func warDayStart(row sqlcdb.AppWar, now time.Time) time.Time {
	day := now.UTC().Truncate(24 * time.Hour)
	if day.Before(row.StartsAt) {
		return row.StartsAt
	}
	return day
}

// warDayEnd is when they come back: the next UTC midnight, or the war's end if
// that falls first.
func warDayEnd(row sqlcdb.AppWar, now time.Time) time.Time {
	next := now.UTC().Truncate(24*time.Hour).AddDate(0, 0, 1)
	if row.EndsAt.Before(next) {
		return row.EndsAt
	}
	return next
}

// WarAttack is one lord thrown at one lord of the kingdom at war.
//
// NOT sequenced. Nothing of the attacker's moves -- no gold, no energy, no
// shield, no cooldown -- so the action_seq the client's queued collects are
// counting on must not move either. The client adopts the answer the way it
// adopts a claimed letter.
func (d Deps) WarAttack(ctx context.Context, playerID, defenderID uuid.UUID) (*WarAttackResult, error) {
	if playerID == defenderID {
		return nil, ErrWarSelf
	}
	cfg := d.Config.War

	// Both armies are read BEFORE the transaction, for the reason Attack states:
	// they are large reads, and holding two row locks across them would
	// serialise every fight in the game.
	mine, err := d.GetArmy(ctx, playerID)
	if err != nil {
		return nil, err
	}
	theirs, err := d.GetArmy(ctx, defenderID)
	if err != nil {
		return nil, err
	}

	res := &WarAttackResult{}
	err = db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
		q := sqlcdb.New(tx)
		locked, err := q.LockTwoPlayers(ctx, []uuid.UUID{playerID, defenderID})
		if err != nil {
			return fmt.Errorf("lock players: %w", err)
		}
		var me, foe sqlcdb.AppPlayer
		for _, p := range locked {
			if p.ID == playerID {
				me = p
			} else {
				foe = p
			}
		}
		if me.ID == uuid.Nil || foe.ID == uuid.Nil {
			return ErrNotFound
		}
		if !d.Config.HasSection(cfg.Section) || int(me.Level) < d.Config.SectionLevel(cfg.Section) {
			return ErrWarLocked
		}
		if me.KingdomID == nil {
			return ErrNotInKingdom
		}
		now := d.Now()
		row, err := q.GetWarFor(ctx, sqlcdb.GetWarForParams{
			Week: dateOf(warWeek(d.Config, now)), KingdomID: *me.KingdomID,
		})
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrNoWar
			}
			return fmt.Errorf("this week's war: %w", err)
		}
		if row.BID == nil {
			return ErrWarBye
		}
		side, _, theirsID := warSides(row, *me.KingdomID)
		if foe.KingdomID == nil || *foe.KingdomID != theirsID {
			return ErrWarNotFoe
		}
		if now.Before(row.StartsAt) {
			return ErrWarNotLive
		}
		if !now.Before(row.EndsAt) || row.SettledAt != nil {
			return ErrWarOver
		}

		used, err := q.CountWarAttacksSince(ctx, sqlcdb.CountWarAttacksSinceParams{
			WarID: row.ID, AttackerID: playerID, Since: warDayStart(row, now),
		})
		if err != nil {
			return fmt.Errorf("today's attacks: %w", err)
		}
		if int(used) >= cfg.AttacksPerDay {
			return ErrNoWarAttack
		}
		lost, err := q.CountBannersLost(ctx, sqlcdb.CountBannersLostParams{
			WarID: row.ID, DefenderID: defenderID,
		})
		if err != nil {
			return fmt.Errorf("banners: %w", err)
		}
		routed := war.Routed(d.Config, int(lost))

		// The fight. An ordinary battle: the defender keeps the soldiers they
		// have sent away, as they do against a raid, because a lord's walls are
		// manned whether or not they are at home.
		battleID := uuid.New()
		rng := game.SeedForString(d.ShopSecret, battleID.String(),
			uint64(mine.Totals.Might), uint64(theirs.Totals.Might))
		replay := combat.Simulate(d.Config, rng, rng.Uint64(), myArmy(me, mine), theirArmy(foe, theirs))
		replay.AttackerMight, replay.DefenderMight = mine.Totals.Might, theirs.Totals.Might
		won := replay.Winner == combat.SideAttacker

		// What it was worth. The Might in the ratio is the CACHED figure on each
		// lord's row -- the same one the roster card quoted before the tap -- so
		// what the card promised is what the war pays. A figure recomputed from
		// the armies here would drift from the card the moment a sword changed
		// hands.
		var points, held int64
		if won {
			points = war.WinPoints(d.Config, me.Might, foe.Might, routed)
		} else {
			points, held = war.LossPoints(d.Config), war.HeldPoints(d.Config)
		}

		aPts, bPts := points, held
		if side == "b" {
			aPts, bPts = held, points
		}
		after, err := q.AddWarPoints(ctx, sqlcdb.AddWarPointsParams{
			APoints: int32(aPts), BPoints: int32(bPts), ID: row.ID,
		})
		if err != nil {
			return fmt.Errorf("war points: %w", err)
		}
		if _, err := q.RecordWarAttack(ctx, sqlcdb.RecordWarAttackParams{
			WarID: row.ID, AttackerID: playerID, DefenderID: defenderID, Side: side,
			Won: won, Points: int32(points), HeldPoints: int32(held), Routed: routed,
			BattleID: &battleID, Now: now,
		}); err != nil {
			return fmt.Errorf("record attack: %w", err)
		}

		raw, err := json.Marshal(replay)
		if err != nil {
			return fmt.Errorf("encode replay: %w", err)
		}
		if _, err := q.InsertBattle(ctx, sqlcdb.InsertBattleParams{
			ID: battleID, AttackerID: playerID, DefenderID: defenderID,
			Seed: int64(replay.Seed), ConfigVersion: int32(d.Config.Version),
			AttackerWon: won, Rounds: int32(replay.Rounds),
			AttackerMight: mine.Totals.Might, DefenderMight: theirs.Totals.Might,
			GoldStolen: 0, RansomPaid: 0, XpAwarded: 0, EnergySpent: 0,
			Replay: raw, Kind: "war",
		}); err != nil {
			return fmt.Errorf("insert battle: %w", err)
		}

		res.BattleID, res.Won, res.Replay = battleID.String(), won, replay
		res.Points, res.HeldPoints, res.Routed = points, held, routed
		res.BannersLost = int(lost)
		if won {
			res.BannersLost++
		}
		res.AttacksLeft = maxInt(0, cfg.AttacksPerDay-int(used)-1)
		res.MyPoints, res.TheirPoints = int64(after.APoints), int64(after.BPoints)
		if side == "b" {
			res.MyPoints, res.TheirPoints = int64(after.BPoints), int64(after.APoints)
		}

		dd := deeds.Deeds{deeds.WarAttacks: 1}
		if won {
			dd[deeds.WarWins] = 1
		}
		d.recordDeeds(ctx, tx, me, dd)
		return nil
	})
	if err != nil {
		return nil, err
	}
	// The snapshot is taken because the client adopts one after every action;
	// nothing in it moved.
	snap, err := d.GetState(ctx, playerID)
	res.Snapshot = snap
	return res, err
}

// --- the two jobs -----------------------------------------------------------

const warSettleLimit = 50

// drawWars matches the kingdoms for the week whose draw has come round.
//
// Claimed in admin.period_closes, as the Throne's crowning is, so a week is
// drawn once however often the job runs -- and every insert is ON CONFLICT DO
// NOTHING besides, so a run that fell over halfway finishes the job rather than
// doubling it.
func drawWars(ctx context.Context, d Deps, now time.Time) error {
	cfg := d.Config.War
	if !d.Config.HasSection(cfg.Section) || cfg.Days <= 0 {
		return nil
	}
	window := war.WindowFor(d.Config, now)
	if now.Before(window.Drawn) {
		return nil
	}
	week := mondayOf(window.Drawn)
	uweek := deeds.UWeek(window.Drawn)

	q := sqlcdb.New(d.Pool)
	done, err := q.PeriodClosed(ctx, sqlcdb.PeriodClosedParams{What: closeWarDraw, Period: uweek})
	if err != nil {
		return fmt.Errorf("drawn: %w", err)
	}
	if done {
		return nil
	}

	musters, err := q.ListKingdomMusters(ctx, int32(cfg.TopMembers))
	if err != nil {
		return fmt.Errorf("musters: %w", err)
	}
	sides := make([]war.Side, 0, len(musters))
	names := make(map[string]string, len(musters))
	for _, m := range musters {
		sides = append(sides, war.Side{ID: m.ID.String(), Might: m.Might, Member: int(m.Members)})
		names[m.ID.String()] = m.Name
	}
	// Who fought whom last week: nobody meets the same kingdom twice running
	// while there is anybody else to meet.
	last := map[string]string{}
	if prev, err := q.ListWarsInWeek(ctx, dateOf(week.AddDate(0, 0, -7))); err == nil {
		for _, w := range prev {
			if w.BID == nil {
				continue
			}
			last[w.AID.String()], last[w.BID.String()] = w.BID.String(), w.AID.String()
		}
	}

	pairs := war.Draw(d.Config, sides, last)
	might := make(map[string]int64, len(sides))
	for _, s := range sides {
		might[s.ID] = s.Might
	}
	drawn := 0
	for _, pair := range pairs {
		aID, err := uuid.Parse(pair.A)
		if err != nil {
			continue
		}
		var bID *uuid.UUID
		var bMight int64
		if !pair.Bye {
			id, err := uuid.Parse(pair.B)
			if err != nil {
				continue
			}
			bID, bMight = &id, might[pair.B]
		}
		if _, err := q.DrawWar(ctx, sqlcdb.DrawWarParams{
			Week: dateOf(week), AID: aID, BID: bID,
			AMight: might[pair.A], BMight: bMight,
			StartsAt: window.From, EndsAt: window.To,
		}); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				continue // this kingdom was already drawn into the week
			}
			return fmt.Errorf("draw %s: %w", pair.A, err)
		}
		drawn++
		d.tellWarDrawn(ctx, q, aID, names[pair.B], pair.Bye, window)
		if bID != nil {
			d.tellWarDrawn(ctx, q, *bID, names[pair.A], false, window)
		}
	}
	if d.Log != nil {
		d.Log.Info("the war pairs are drawn", "week", week.Format("2006-01-02"), "wars", drawn)
	}
	return q.ClosePeriod(ctx, sqlcdb.ClosePeriodParams{
		What: closeWarDraw, Period: uweek, Lords: int32(drawn),
	})
}

// tellWarDrawn is the line a hall gets when the pairs are made.
func (d Deps) tellWarDrawn(ctx context.Context, q *sqlcdb.Queries, kingdomID uuid.UUID,
	foe string, bye bool, window war.Window) {

	line := fmt.Sprintf("The war is drawn: %s. The fighting begins %s.", foe,
		window.From.Format("Monday"))
	payload := map[string]any{"foe": foe, "starts": window.From.UTC().Format(time.RFC3339)}
	if bye {
		line = "No kingdom was near enough in strength this week. The banners rest."
		payload = map[string]any{"bye": true}
	}
	if _, err := d.systemLine(ctx, q, kingdomID, SysWar, line, payload); err != nil && d.Log != nil {
		d.Log.Warn("the hall was not told of the draw", "kingdom", kingdomID, "err", err)
	}
}

// settleWars pays out every war whose days are over.
//
// Idempotent three times over: the war's settled_at, an idempotency key on every
// letter, and a kingdom's reputation and experience written once inside the same
// claim. Each lord is paid in their own transaction, as the Throne's court is.
func settleWars(ctx context.Context, d Deps, now time.Time) error {
	q := sqlcdb.New(d.Pool)
	due, err := q.ListDueWars(ctx, sqlcdb.ListDueWarsParams{Now: now, Lim: warSettleLimit})
	if err != nil {
		return fmt.Errorf("wars due: %w", err)
	}
	for _, row := range due {
		if err := d.settleWar(ctx, row, now); err != nil {
			return fmt.Errorf("settle %s: %w", row.ID, err)
		}
	}
	return nil
}

// settleWar closes one week's war.
func (d Deps) settleWar(ctx context.Context, row sqlcdb.AppWar, now time.Time) error {
	cfg := d.Config.War
	q := sqlcdb.New(d.Pool)

	// A bye: nobody to fight, nothing to pay. The week is closed all the same,
	// so it stops being looked at.
	if row.BID == nil {
		if err := q.SettleWar(ctx, sqlcdb.SettleWarParams{Now: &now, ID: row.ID}); err != nil {
			return fmt.Errorf("close the bye: %w", err)
		}
		return nil
	}

	winner := war.Winner(int64(row.APoints), int64(row.BPoints), row.AID.String(), row.BID.String())
	var winnerID *uuid.UUID
	if winner != "" {
		if id, err := uuid.Parse(winner); err == nil {
			winnerID = &id
		}
	}
	names := map[uuid.UUID]string{}
	for _, id := range []uuid.UUID{row.AID, *row.BID} {
		if k, err := q.GetKingdom(ctx, id); err == nil {
			names[id] = k.Name
		}
	}
	ref := "war:" + row.ID.String()

	// Everybody who swung, and what they did. A lord who took part is paid; a
	// lord who watched the week go by is not, which is the whole reason the
	// purse is a purse and not a dividend.
	scorers, err := q.ListWarScorers(ctx, sqlcdb.ListWarScorersParams{WarID: row.ID, Lim: warPaidShown})
	if err != nil {
		return fmt.Errorf("war scorers: %w", err)
	}
	// The Warlord of the Week is the best lord in the war, on either side: the
	// list comes back biggest first.
	var warlord uuid.UUID
	if len(scorers) > 0 && scorers[0].Points > 0 {
		warlord = scorers[0].AttackerID
	}
	// Worn until the next war ends, which is when the next Warlord is named.
	until := row.EndsAt.AddDate(0, 0, 7)

	for _, s := range scorers {
		scorer := s
		kingdomID := row.AID
		if scorer.Side == "b" {
			kingdomID = *row.BID
		}
		won := winnerID != nil && *winnerID == kingdomID
		purse := cfg.Lost
		if won {
			purse = cfg.Won
		}
		foe := names[row.AID]
		if scorer.Side == "a" {
			foe = names[*row.BID]
		}
		err := db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
			tq := sqlcdb.New(tx)
			if _, err := d.SendMail(ctx, tq, scorer.AttackerID, MailDraft{
				Kind: MailWar, Title: warLetterTitle(won, winner == ""),
				Body: warLetterBody(foe, won, winner == "", scorer.Points, int(scorer.Attacks),
					scorer.AttackerID == warlord),
				Attachments: purse.Grant, IdemKey: ref,
			}); err != nil {
				return err
			}
			if scorer.AttackerID == warlord && cfg.WarlordTitle != "" &&
				d.Config.Cosmetic(cfg.WarlordTitle) != nil {
				if err := tq.HoldCosmeticUntil(ctx, sqlcdb.HoldCosmeticUntilParams{
					PlayerID: scorer.AttackerID, CosmeticID: cfg.WarlordTitle, Source: "war",
					SourceRef: &ref, Until: &until,
				}); err != nil {
					return fmt.Errorf("hold %s: %w", cfg.WarlordTitle, err)
				}
			}
			return nil
		})
		if err != nil {
			return err
		}
	}

	// What the kingdoms themselves take. Written inside the same statement that
	// closes the war, so a job that runs twice cannot pay a kingdom twice.
	err = db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
		tq := sqlcdb.New(tx)
		fresh, err := tq.LockWar(ctx, row.ID)
		if err != nil {
			return fmt.Errorf("lock war: %w", err)
		}
		if fresh.SettledAt != nil {
			return nil // another run got here first
		}
		for _, id := range []uuid.UUID{row.AID, *row.BID} {
			// A side that never got on the board takes nothing -- not the
			// purse, and above all not the renown, which feeds the Throne. A
			// kingdom that ignored its war for three days must not be paid the
			// same as one that lost it fighting. Holding a defence scores, so a
			// kingdom that only defended is on the board and is paid.
			points := int64(row.APoints)
			if id != row.AID {
				points = int64(row.BPoints)
			}
			if points <= 0 {
				continue
			}
			purse := cfg.Lost
			if winnerID != nil && *winnerID == id {
				purse = cfg.Won
			}
			if err := d.payKingdomPurse(ctx, tq, id, purse, now); err != nil {
				return err
			}
		}
		return tq.SettleWar(ctx, sqlcdb.SettleWarParams{Now: &now, WinnerID: winnerID, ID: row.ID})
	})
	if err != nil {
		return err
	}

	for _, id := range []uuid.UUID{row.AID, *row.BID} {
		foe := names[row.AID]
		if id == row.AID {
			foe = names[*row.BID]
		}
		mine, theirs := int64(row.APoints), int64(row.BPoints)
		if id != row.AID {
			mine, theirs = theirs, mine
		}
		line := fmt.Sprintf("The war with %s ends %d-%d.", foe, mine, theirs)
		switch {
		case winnerID == nil:
			line += " Neither kingdom could be separated."
		case *winnerID == id:
			line += " The kingdom holds the field, and the purse is in the post."
		default:
			line += " The field is theirs this week."
		}
		if _, err := d.systemLine(ctx, q, id, SysWar, line,
			map[string]any{"points": mine, "theirs": theirs}); err != nil && d.Log != nil {
			d.Log.Warn("the hall was not told the war ended", "kingdom", id, "err", err)
		}
	}
	if d.Log != nil {
		d.Log.Info("a war is settled", "war", row.ID, "winner", winner, "lords", len(scorers))
	}
	return nil
}

// payKingdomPurse gives one kingdom its renown and its experience.
//
// The renown rides the same two writes a raid's does -- the standing figure the
// decay eats, and the week's gain the Throne is decided on -- because a second
// place to keep renown would be a second number to disagree with the first.
func (d Deps) payKingdomPurse(ctx context.Context, q *sqlcdb.Queries, kingdomID uuid.UUID,
	purse gameconfig.WarPurse, now time.Time) error {

	if purse.Reputation > 0 {
		if err := q.AddKingdomReputation(ctx, sqlcdb.AddKingdomReputationParams{
			ID: kingdomID, Reputation: purse.Reputation * reputationScale,
		}); err != nil {
			return fmt.Errorf("kingdom reputation: %w", err)
		}
		if err := q.BumpKingdomWeek(ctx, sqlcdb.BumpKingdomWeekParams{
			KingdomID: kingdomID, Uweek: deeds.UWeek(now),
			Reputation: purse.Reputation * reputationScale,
		}); err != nil {
			return fmt.Errorf("kingdom week: %w", err)
		}
	}
	if purse.KingdomXP > 0 {
		k, err := q.LockKingdom(ctx, kingdomID)
		if err != nil {
			return fmt.Errorf("lock kingdom: %w", err)
		}
		level, _ := d.Config.KingdomLevelFor(k.Xp + purse.KingdomXP)
		if _, err := q.AddKingdomTreasury(ctx, sqlcdb.AddKingdomTreasuryParams{
			ID: kingdomID, Treasury: 0, Xp: purse.KingdomXP, Level: int32(level),
		}); err != nil {
			return fmt.Errorf("kingdom experience: %w", err)
		}
	}
	return nil
}

// warLetterTitle and warLetterBody are what a week's purse arrives as.
func warLetterTitle(won, drawn bool) string {
	switch {
	case drawn:
		return "The war ends even"
	case won:
		return "The kingdom holds the field"
	}
	return "The war is lost"
}

func warLetterBody(foe string, won, drawn bool, points int64, attacks int, warlord bool) string {
	what := fmt.Sprintf("You rode out %s against %s and took %d points for the kingdom.",
		times(attacks), foe, points)
	switch {
	case drawn:
		what += " Neither kingdom could be separated, and both take a share."
	case won:
		what += " The kingdom holds the field. Here is your share of the purse."
	default:
		what += " The field went to them this week, but nobody who rode out goes unpaid."
	}
	if warlord {
		what += " No lord in either kingdom did more: you are the Warlord of the Week."
	}
	return what
}

// WarWeekOf is the Monday a moment's war is filed under: the one seam a test, a
// tool or the panel may ask the rule through rather than writing it out again.
func (d Deps) WarWeekOf(now time.Time) pgtype.Date { return dateOf(warWeek(d.Config, now)) }
