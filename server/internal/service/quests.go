package service

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/yigitkarabulut0/emperors/server/internal/db"
	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
	"github.com/yigitkarabulut0/emperors/server/internal/game"
	"github.com/yigitkarabulut0/emperors/server/internal/game/economy"
	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
)

// ErrQuestUnfinished is a claim on a quest that is not done.
var ErrQuestUnfinished = errors.New("that task is not finished")

// QuestView is one of today's tasks.
type QuestView struct {
	Slot     int    `json:"slot"`
	ID       string `json:"id"`
	Name     string `json:"name"`
	Blurb    string `json:"blurb"`
	Target   int64  `json:"target"`
	Progress int64  `json:"progress"`
	Done     bool   `json:"done"`
	Claimed  bool   `json:"claimed"`
	XP       int64  `json:"xp"`
	Gold     int64  `json:"gold"`
}

// QuestsView is the day's board.
type QuestsView struct {
	Quests []QuestView `json:"quests"`
}

// questsFor picks today's tasks.
//
// A pure function of (secret, player, local day), exactly like the shop's
// offers: nothing is written when the day turns over, two devices cannot
// disagree about what today's quests are, and changing the pool cannot orphan
// stored rows. The seed is per-day, so the set is stable for the whole day and
// different tomorrow.
func (d Deps) questsFor(playerID uuid.UUID, level int, day time.Time) []gameconfig.Quest {
	cfg := d.Config.Progression.Quests
	if cfg.PerDay <= 0 || len(cfg.Pool) == 0 {
		return nil
	}

	// Only tasks the player can actually attempt. Offering "win a raid" to
	// somebody who cannot open the Fight tab is a daily they are guaranteed to
	// fail, which is worse than one fewer daily.
	eligible := make([]gameconfig.Quest, 0, len(cfg.Pool))
	for _, q := range cfg.Pool {
		if q.MinLevel <= level {
			eligible = append(eligible, q)
		}
	}
	if len(eligible) == 0 {
		return nil
	}

	rng := game.SeedForString(d.ShopSecret, playerID.String(),
		uint64(day.Unix()), 0x0DA11)

	// Partial Fisher-Yates: draw without replacement so a player never gets the
	// same task twice in one day.
	n := cfg.PerDay
	if n > len(eligible) {
		n = len(eligible)
	}
	for i := 0; i < n; i++ {
		j := i + int(rng.Uint64N(uint64(len(eligible)-i)))
		eligible[i], eligible[j] = eligible[j], eligible[i]
	}
	return eligible[:n]
}

func questProgress(p sqlcdb.AppPlayerQuest, kind string) int64 {
	switch kind {
	case "collects":
		return int64(p.Collects)
	case "wins":
		return int64(p.Wins)
	case "buys":
		return int64(p.Buys)
	case "energy":
		return int64(p.Energy)
	}
	return 0
}

// questReward is the design's formula: bigger tasks pay proportionally more,
// and both scale with level so a daily is worth doing at 50 as well as at 5.
func (d Deps) questReward(level int64, tier int64) (xp, gold int64) {
	c := d.Config.Progression.Quests
	return c.XPPerLevelPerTier * level * tier, c.GoldPerLevelPerTier * level * tier
}

// questDay returns the day's row, creating it with a frozen set of quests the
// first time anybody looks.
//
// Freezing matters: the draw filters the pool by level, so without this a
// player who levels mid-day gets a different board — and `claimed` is a bit per
// SLOT, so a reshuffled order would let a bit set for one quest be read as
// another's.
func (d Deps) questDay(ctx context.Context, q *sqlcdb.Queries, p sqlcdb.AppPlayer,
	day time.Time) (sqlcdb.AppPlayerQuest, []gameconfig.Quest, error) {
	drawn := d.questsFor(p.ID, int(p.Level), day)
	ids := make([]string, 0, len(drawn))
	for _, t := range drawn {
		ids = append(ids, t.ID)
	}

	row, err := q.EnsureQuestDay(ctx, sqlcdb.EnsureQuestDayParams{
		PlayerID: p.ID, Day: pgtype.Date{Time: day, Valid: true}, QuestIds: ids,
	})
	if err != nil {
		return row, nil, fmt.Errorf("quest day: %w", err)
	}
	return row, d.resolveQuests(row.QuestIds), nil
}

// resolveQuests turns stored ids back into templates, dropping any the pool no
// longer defines so a rebalance cannot break a day already in progress.
func (d Deps) resolveQuests(ids []string) []gameconfig.Quest {
	out := make([]gameconfig.Quest, 0, len(ids))
	for _, id := range ids {
		for i := range d.Config.Progression.Quests.Pool {
			if d.Config.Progression.Quests.Pool[i].ID == id {
				out = append(out, d.Config.Progression.Quests.Pool[i])
				break
			}
		}
	}
	return out
}

// GetQuests returns today's board.
func (d Deps) GetQuests(ctx context.Context, playerID uuid.UUID) (*QuestsView, error) {
	q := sqlcdb.New(d.Pool)
	p, err := q.GetPlayerByID(ctx, playerID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, fmt.Errorf("quests: %w", err)
	}

	day := localDay(d.Now(), p.ResetOffsetMinutes)
	prog, tasks, err := d.questDay(ctx, q, p, day)
	if err != nil {
		return nil, err
	}

	out := &QuestsView{Quests: []QuestView{}}
	for i, t := range tasks {
		done := questProgress(prog, t.Kind)
		xp, gold := d.questReward(int64(p.Level), t.Tier)
		out.Quests = append(out.Quests, QuestView{
			Slot: i, ID: t.ID, Name: t.Name, Blurb: t.Blurb,
			Target: t.Target, Progress: min64(done, t.Target),
			Done:    done >= t.Target,
			Claimed: prog.Claimed&(1<<i) != 0,
			XP:      xp, Gold: gold,
		})
	}
	return out, nil
}

// ClaimQuest pays out one finished task.
func (d Deps) ClaimQuest(ctx context.Context, playerID uuid.UUID, slot int, wantSeq int64) (*QuestsView, error) {
	err := db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
		q := sqlcdb.New(tx)
		p, err := q.LockPlayer(ctx, playerID)
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrNotFound
			}
			return fmt.Errorf("lock player: %w", err)
		}
		if err := checkSeq(p, wantSeq); err != nil {
			return err
		}

		day := localDay(d.Now(), p.ResetOffsetMinutes)
		today := pgtype.Date{Time: day, Valid: true}
		prog, tasks, err := d.questDay(ctx, q, p, day)
		if err != nil {
			return err
		}
		if slot < 0 || slot >= len(tasks) {
			return ErrNotFound
		}
		t := tasks[slot]
		if questProgress(prog, t.Kind) < t.Target {
			return ErrQuestUnfinished
		}

		// Setting the bit is the claim. Zero rows means it was already set, so
		// two taps cannot both be paid.
		if _, err := q.ClaimQuest(ctx, sqlcdb.ClaimQuestParams{
			PlayerID: playerID, Day: today, Bit: int32(1 << slot),
		}); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrAlreadyClaimed
			}
			return fmt.Errorf("claim quest: %w", err)
		}

		xp, gold := d.questReward(int64(p.Level), t.Tier)
		eff, err := d.loadEffects(ctx, q, p)
		if err != nil {
			return err
		}
		up := economy.AwardXP(d.Config, int(p.Level), p.Xp, xp, eff.Bonuses)

		after, err := q.ApplyCollect(ctx, sqlcdb.ApplyCollectParams{
			ID: playerID, EnergyMilli: p.EnergyMilli, EnergyUpdatedAt: p.EnergyUpdatedAt,
			Gold: gold, Xp: up.XP, Level: int32(up.Level),
			StatPointsUnspent: int32(up.StatPoints), Diamonds: up.Diamonds,
			ActionSeq: wantSeq,
		})
		if err != nil {
			return fmt.Errorf("pay quest: %w", err)
		}
		return q.RecordGold(ctx, sqlcdb.RecordGoldParams{
			PlayerID: playerID, Delta: gold, BalanceAfter: after.Gold,
			Reason: "quest", RefID: strPtr(t.ID),
		})
	})
	if err != nil {
		return nil, err
	}
	return d.GetQuests(ctx, playerID)
}

func min64(a, b int64) int64 {
	if a < b {
		return a
	}
	return b
}

// bumpQuests records progress toward today's tasks.
//
// Called from inside the action's own transaction, so a quest can never count
// something that was rolled back. Failures are swallowed by the caller on
// purpose: a quest counter is not worth failing a collect over, and the next
// action will catch the row up.
func (d Deps) bumpQuests(ctx context.Context, q *sqlcdb.Queries, p sqlcdb.AppPlayer,
	collects, wins, buys, energy int64) error {
	if len(d.Config.Progression.Quests.Pool) == 0 {
		return nil
	}
	day := localDay(d.Now(), p.ResetOffsetMinutes)
	// The ids are only used when this is the row's first write of the day; an
	// existing row keeps whatever it was frozen with.
	ids := make([]string, 0, d.Config.Progression.Quests.PerDay)
	for _, t := range d.questsFor(p.ID, int(p.Level), day) {
		ids = append(ids, t.ID)
	}
	_, err := q.BumpQuestProgress(ctx, sqlcdb.BumpQuestProgressParams{
		PlayerID: p.ID, Day: pgtype.Date{Time: day, Valid: true},
		Collects: int32(collects), Wins: int32(wins),
		Buys: int32(buys), Energy: int32(energy), QuestIds: ids,
	})
	return err
}

// logQuestBump records a dropped quest tick.
//
// Swallowed, but not silently: if these ever appear in volume the counters are
// drifting and the dailies will quietly stop completing.
func (d Deps) logQuestBump(err error) {
	if d.Log != nil {
		d.Log.Warn("quest progress not recorded", "err", err)
	}
}
