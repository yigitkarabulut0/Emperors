package service

import (
	"context"
	"errors"
	"fmt"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/yigitkarabulut0/emperors/server/internal/db"
	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
	"github.com/yigitkarabulut0/emperors/server/internal/game"
	"github.com/yigitkarabulut0/emperors/server/internal/game/campaign"
	"github.com/yigitkarabulut0/emperors/server/internal/game/combat"
	"github.com/yigitkarabulut0/emperors/server/internal/game/deeds"
	"github.com/yigitkarabulut0/emperors/server/internal/game/economy"
	"github.com/yigitkarabulut0/emperors/server/internal/ledger"
)

// THE CONQUEST CAMPAIGN -- the Attack tab's CAMPAIGN sub-tab (campaign.json).
//
// Ten chapters of twelve stages against the realm's own garrisons, from level
// six: four levels before another lord may raid back, so a lord learns what a
// battle is before one can happen to them.
//
// A stage costs energy and pays WAGES -- what that energy would have earned at
// the lord's best job -- three times over the first time it falls and a fifth of
// that after, which is 0.6 of simply working. So a stage is never worth farming,
// and what brings a lord back is the stars.
//
// No battle row is kept. app.battles is lords against lords (its defender_id
// points at a player), and a garrison is not a lord; the replay goes back in the
// answer and the stars are what is written down.

var (
	ErrCampaignLocked = errors.New("the campaign opens later")
	ErrStageUnknown   = errors.New("no such stage")
	ErrStageShut      = errors.New("the road to that stage has not been opened")
	ErrChestShut      = errors.New("that chest is not open yet")
	ErrChestTaken     = errors.New("you have taken that chest")
)

// CampaignView is the map: every chapter, and where this lord stands on it.
type CampaignView struct {
	Unlocked    bool `json:"unlocked"`
	UnlockLevel int  `json:"unlock_level"`
	// Where the road has got to: the first stage not yet cleared.
	ChapterID string `json:"chapter_id"`
	Stage     int    `json:"stage"`
	Stars     int    `json:"stars"`
	MaxStars  int    `json:"max_stars"`

	Chapters []ChapterView `json:"chapters"`
}

// ChapterView is one map of the ten.
type ChapterView struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	Blurb    string `json:"blurb"`
	Art      string `json:"art"`
	Level    int64  `json:"level"`
	Stars    int    `json:"stars"`
	MaxStars int    `json:"max_stars"`
	// Whether its first stage may be walked at all, and how far the lord has
	// got inside it.
	Open    bool `json:"open"`
	Cleared int  `json:"cleared"`
	Stages  int  `json:"stages"`

	Chests []ChapterChestView `json:"chests"`
}

// ChapterChestView is one of a chapter's three.
type ChapterChestView struct {
	Index   int      `json:"index"`
	Stars   int      `json:"stars"`
	Lines   []string `json:"lines"`
	Open    bool     `json:"open"`
	Claimed bool     `json:"claimed"`
}

// StageView is one mile of the road, as its node on the map says it.
type StageView struct {
	Stage  int    `json:"stage"`
	Kind   string `json:"kind"`
	Level  int64  `json:"level"`
	Energy int64  `json:"energy"`
	Might  int64  `json:"might"`
	// The garrison, in the words the card uses: who stands there and how many.
	Enemy    string `json:"enemy"`
	Soldiers int    `json:"soldiers"`
	// What the first clear pays in gear, when it pays any.
	FirstItemTier string `json:"first_item_tier,omitempty"`
	// This lord's own standing: the stars held, whether it may be walked, and
	// whether it has ever fallen.
	Stars   int  `json:"stars"`
	Open    bool `json:"open"`
	Cleared bool `json:"cleared"`
	// What walking it pays THIS time, already in the words the reward uses.
	Lines []string `json:"lines"`
}

// ChapterStagesView is one chapter opened: its twelve miles.
type ChapterStagesView struct {
	ID     string             `json:"id"`
	Name   string             `json:"name"`
	Art    string             `json:"art"`
	Stars  int                `json:"stars"`
	Stages []StageView        `json:"stages"`
	Chests []ChapterChestView `json:"chests"`
}

// StageResult is one stage fought.
type StageResult struct {
	ChapterID string `json:"chapter_id"`
	Stage     int    `json:"stage"`
	Won       bool   `json:"won"`
	// The stars this walk was worth, and the best this lord has ever done.
	Stars      int  `json:"stars"`
	BestStars  int  `json:"best_stars"`
	FirstClear bool `json:"first_clear"`
	// What was paid. Nothing at all on a loss: the energy is spent and the road
	// stays shut, which is what makes it a road rather than a queue.
	Granted  Granted        `json:"granted"`
	Replay   *combat.Replay `json:"replay"`
	Snapshot *Snapshot      `json:"snapshot"`
}

// GetCampaign paints the map.
func (d Deps) GetCampaign(ctx context.Context, playerID uuid.UUID) (*CampaignView, error) {
	q := sqlcdb.New(d.Pool)
	p, err := q.GetPlayerByID(ctx, playerID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, fmt.Errorf("campaign: %w", err)
	}
	stars, err := d.loadStars(ctx, q, playerID)
	if err != nil {
		return nil, err
	}
	at := d.Config.SectionLevel(d.Config.Campaign.Section)

	v := &CampaignView{
		Unlocked: int(p.Level) >= at, UnlockLevel: at,
		Stars: stars.Total(), Chapters: []ChapterView{},
	}
	v.ChapterID, v.Stage = campaign.Where(d.Config, stars)

	for ci := range d.Config.Campaign.Chapters {
		ch := &d.Config.Campaign.Chapters[ci]
		claimed, err := d.claimedChests(ctx, q, playerID, ch.ID)
		if err != nil {
			return nil, err
		}
		held := stars.InChapter(ch.ID)
		cv := ChapterView{
			ID: ch.ID, Name: ch.Name, Blurb: ch.Blurb, Art: ch.Art, Level: ch.Level,
			Stars: held, MaxStars: ch.StarsForChapter(),
			Open:   campaign.Open(d.Config, stars, ch.ID, 1),
			Stages: len(ch.Stages), Chests: []ChapterChestView{},
		}
		for _, st := range ch.Stages {
			if stars.Cleared(ch.ID, st.Stage) {
				cv.Cleared++
			}
		}
		for i, chest := range ch.Chests {
			cv.Chests = append(cv.Chests, ChapterChestView{
				Index: i, Stars: chest.Stars, Lines: d.rewardLines(chest.Grant, int(p.Level)),
				Open: held >= chest.Stars, Claimed: claimed[i],
			})
		}
		v.MaxStars += cv.MaxStars
		v.Chapters = append(v.Chapters, cv)
	}
	return v, nil
}

// GetChapter opens one map: its twelve miles, with what each pays this lord.
func (d Deps) GetChapter(ctx context.Context, playerID uuid.UUID, chapterID string) (*ChapterStagesView, error) {
	ch := d.Config.Chapter(chapterID)
	if ch == nil {
		return nil, ErrStageUnknown
	}
	q := sqlcdb.New(d.Pool)
	p, err := q.GetPlayerByID(ctx, playerID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, fmt.Errorf("chapter: %w", err)
	}
	stars, err := d.loadStars(ctx, q, playerID)
	if err != nil {
		return nil, err
	}
	claimed, err := d.claimedChests(ctx, q, playerID, ch.ID)
	if err != nil {
		return nil, err
	}

	v := &ChapterStagesView{
		ID: ch.ID, Name: ch.Name, Art: ch.Art, Stars: stars.InChapter(ch.ID),
		Stages: []StageView{}, Chests: []ChapterChestView{},
	}
	for si := range ch.Stages {
		st := &ch.Stages[si]
		cleared := stars.Cleared(ch.ID, st.Stage)
		sv := StageView{
			Stage: st.Stage, Kind: st.Kind, Level: st.Level, Energy: st.Energy,
			Might: st.Might, Enemy: st.Enemy.Name, FirstItemTier: st.FirstClearItemTier,
			Stars: stars.At(ch.ID, st.Stage), Cleared: cleared,
			Open: campaign.Open(d.Config, stars, ch.ID, st.Stage),
		}
		for _, g := range st.Enemy.Soldiers {
			sv.Soldiers += g.Count
		}
		sv.Lines = d.rewardLines(campaign.Reward(d.Config, st, !cleared), int(p.Level))
		v.Stages = append(v.Stages, sv)
	}
	for i, chest := range ch.Chests {
		v.Chests = append(v.Chests, ChapterChestView{
			Index: i, Stars: chest.Stars, Lines: d.rewardLines(chest.Grant, int(p.Level)),
			Open: v.Stars >= chest.Stars, Claimed: claimed[i],
		})
	}
	return v, nil
}

// loadStars reads every mile this lord has walked.
func (d Deps) loadStars(ctx context.Context, q *sqlcdb.Queries, playerID uuid.UUID) (campaign.Stars, error) {
	rows, err := q.ListCampaign(ctx, playerID)
	if err != nil {
		return nil, fmt.Errorf("campaign rows: %w", err)
	}
	stars := campaign.Stars{}
	for _, r := range rows {
		if stars[r.ChapterID] == nil {
			stars[r.ChapterID] = map[int]int{}
		}
		stars[r.ChapterID][int(r.Stage)] = int(r.Stars)
	}
	return stars, nil
}

// claimedChests is which of a chapter's chests this lord has taken.
func (d Deps) claimedChests(ctx context.Context, q *sqlcdb.Queries, playerID uuid.UUID,
	chapterID string) (map[int]bool, error) {

	rows, err := q.ListCampaignChests(ctx, sqlcdb.ListCampaignChestsParams{
		PlayerID: playerID, ChapterID: chapterID,
	})
	if err != nil {
		return nil, fmt.Errorf("chapter chests: %w", err)
	}
	out := make(map[int]bool, len(rows))
	for _, ix := range rows {
		out[int(ix)] = true
	}
	return out, nil
}

// FightStage walks one mile of the road.
//
// Sequenced: it spends energy and pays wages, and the client's queued collects
// are counting on the order.
func (d Deps) FightStage(ctx context.Context, playerID uuid.UUID, chapterID string, stage int,
	wantSeq int64) (*StageResult, error) {

	ch := d.Config.Chapter(chapterID)
	if ch == nil {
		return nil, ErrStageUnknown
	}
	st := d.Config.Stage(chapterID, stage)
	if st == nil {
		return nil, ErrStageUnknown
	}
	// The army is read outside the transaction, as a raid reads it: assembling
	// it is a handful of queries and none of them need the lock.
	mine, err := d.GetArmy(ctx, playerID)
	if err != nil {
		return nil, err
	}

	res := &StageResult{ChapterID: chapterID, Stage: stage}
	err = db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
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
		if int(p.Level) < d.Config.SectionLevel(d.Config.Campaign.Section) {
			return ErrCampaignLocked
		}
		stars, err := d.loadStars(ctx, q, playerID)
		if err != nil {
			return err
		}
		if !campaign.Open(d.Config, stars, chapterID, stage) {
			return ErrStageShut
		}

		eff, err := d.loadEffects(ctx, q, p)
		if err != nil {
			return err
		}
		now := d.Now()
		settled, _, _ := settleEnergy(d.Config, p, eff, now)
		spent, ok := economy.Spend(settled, st.Energy)
		if !ok {
			return ErrNotEnoughEnergy
		}

		// The fight. The seed comes from a fresh id, as a raid's does, so the
		// same stage fought twice is two different battles and a retry of a
		// dropped request is a new one rather than a re-roll of the old.
		battleID := uuid.New()
		rng := game.SeedForString(d.ShopSecret, battleID.String(),
			uint64(mine.Field.Might), uint64(st.Might))
		replay := campaign.Battle(d.Config, rng, rng.Uint64(), myArmy(p, mine),
			mine.Field.Might, st.Enemy)
		won := replay.Winner == combat.SideAttacker
		res.Replay, res.Won = replay, won

		after, err := q.SpendEnergySeq(ctx, sqlcdb.SpendEnergySeqParams{
			ID: playerID, EnergyMilli: spent.Milli, EnergyUpdatedAt: spent.UpdatedAt,
			ActionSeq: wantSeq,
		})
		if err != nil {
			return fmt.Errorf("spend energy: %w", err)
		}
		p = after

		dd := deeds.Deeds{deeds.CampaignStages: 1, deeds.Energy: st.Energy}
		if won {
			held := stars.At(chapterID, stage)
			first := held == 0
			res.FirstClear = first
			res.Stars = campaign.StarsFor(d.Config, true, replay.AttackerHPLeftBP)

			// The row keeps the BEST a lord has ever done, so walking a mile
			// again with a chipped sword cannot cost them a chapter's chest.
			row, err := q.ClearCampaignStage(ctx, sqlcdb.ClearCampaignStageParams{
				PlayerID: playerID, ChapterID: chapterID, Stage: int32(stage),
				Stars: int32(res.Stars), Now: now,
			})
			if err != nil {
				return fmt.Errorf("clear stage: %w", err)
			}
			res.BestStars = int(row.Stars)

			g, err := d.grantBundle(ctx, q, &p, campaign.Reward(d.Config, st, first), GrantSource{
				Diamonds: ledger.Reward, Gold: "campaign", ItemFrom: "campaign",
				Ref: fmt.Sprintf("campaign:%s:%d", chapterID, stage),
			})
			if err != nil {
				return err
			}
			res.Granted = g

			// The counter is stars EARNED: what this walk added to the chapter,
			// which is nothing at all when the lord had already done better.
			if gain := res.BestStars - held; gain > 0 {
				dd[deeds.CampaignStars] = int64(gain)
			}
			if first {
				dd[deeds.CampaignFirsts] = 1
			}
		}
		d.recordDeeds(ctx, tx, p, dd)
		return nil
	})
	if err != nil {
		return nil, err
	}
	snap, err := d.GetState(ctx, playerID)
	res.Snapshot = snap
	return res, err
}

// ChestResult is a chapter chest taken.
type ChestResult struct {
	Granted  Granted   `json:"granted"`
	Snapshot *Snapshot `json:"snapshot"`
}

// ClaimChapterChest takes one of a chapter's three.
//
// Sequenced: it pays a reward, and a reward is gold.
func (d Deps) ClaimChapterChest(ctx context.Context, playerID uuid.UUID, chapterID string,
	index int, wantSeq int64) (*ChestResult, error) {

	ch := d.Config.Chapter(chapterID)
	if ch == nil || index < 0 || index >= len(ch.Chests) {
		return nil, ErrStageUnknown
	}
	chest := ch.Chests[index]

	res := &ChestResult{}
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
		held, err := q.CountCampaignStars(ctx, sqlcdb.CountCampaignStarsParams{
			PlayerID: playerID, ChapterID: chapterID,
		})
		if err != nil {
			return fmt.Errorf("stars: %w", err)
		}
		if int(held) < chest.Stars {
			return ErrChestShut
		}
		// The insert is the claim: a second tap writes no row and is told so
		// rather than paying twice.
		if _, err := q.ClaimCampaignChest(ctx, sqlcdb.ClaimCampaignChestParams{
			PlayerID: playerID, ChapterID: chapterID, ChestIx: int32(index), Now: d.Now(),
		}); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrChestTaken
			}
			return fmt.Errorf("claim chest: %w", err)
		}
		g, err := d.grantBundle(ctx, q, &p, chest.Grant, GrantSource{
			Diamonds: ledger.Reward, Gold: "campaign_chest", ItemFrom: "campaign",
			Ref: fmt.Sprintf("campaign:%s:chest:%d", chapterID, index),
		})
		if err != nil {
			return err
		}
		if _, err := q.BumpActionSeq(ctx, sqlcdb.BumpActionSeqParams{
			ID: playerID, ActionSeq: wantSeq,
		}); err != nil {
			return fmt.Errorf("sequence: %w", err)
		}
		res.Granted = g
		return nil
	})
	if err != nil {
		return nil, err
	}
	snap, err := d.GetState(ctx, playerID)
	res.Snapshot = snap
	return res, err
}
