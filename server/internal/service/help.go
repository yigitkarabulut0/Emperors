package service

import (
	"context"
	"errors"
	"fmt"
	"hash/fnv"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/yigitkarabulut0/emperors/server/internal/db"
	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
	"github.com/yigitkarabulut0/emperors/server/internal/game/deeds"
	"github.com/yigitkarabulut0/emperors/server/internal/game/social"
	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
	"github.com/yigitkarabulut0/emperors/server/internal/ledger"
)

// HELP -- the Kingdom tab's HELP sub-tab: the day's shared goal and the
// kingdom's own aid (social.json, goal and aid).
//
// The AID is a stack of gold and experience for the lord who asked, and favour
// for the one who answered. The stack is an ordinary row in app.player_boosts
// with source 'aid', so it rides the timed lane every other boost rides and is
// capped where they are capped -- there is no second ceiling to remember.
//
// The GOAL is one bar a day for the whole kingdom, and nothing in the game
// reports to it directly: every counted deed already passes through
// recordDeeds, so the goal reads the counters that are being written anyway.
// A second reporting path would be a second set of numbers to disagree.
//
// Two guards keep the goal from being a kingdom-hopping machine: the target is
// frozen from the members the kingdom had when the day began, and a lord with
// no contribution row -- which is every lord who joined after it began -- can
// claim nothing.

var (
	ErrNoKingdomHelp = errors.New("you have no kingdom to call on")
	ErrAidSoon       = errors.New("you have just called for aid")
	ErrAidDayFull    = errors.New("you have answered as many calls as the day allows")
	ErrAidOwn        = errors.New("you cannot answer your own call")
	ErrAidGone       = errors.New("that call has been answered or has lapsed")
	ErrAidFull       = errors.New("that lord is already carrying all the help they can hold")
	ErrGoalNone      = errors.New("there is no goal to claim")
	ErrGoalShort     = errors.New("that chest is not open yet")
	ErrGoalShare     = errors.New("you did too little of the work to claim it")
	ErrGoalTaken     = errors.New("you have taken that chest")
)

// HelpView is the HELP sub-tab.
type HelpView struct {
	Goal *GoalView `json:"goal,omitempty"`

	Calls []AidCall `json:"calls"`
	// How many calls this lord may still answer today, and when they may ask
	// again themselves (0 is now).
	AidLeft int   `json:"aid_left"`
	AskIn   int64 `json:"ask_in"`
	// What one answered call is worth, both ways.
	AidStackBP int64 `json:"aid_stack_bp"`
	AidHours   int   `json:"aid_hours"`
	AidFavour  int64 `json:"aid_favour"`
	// How many stacks this lord is carrying, and how many they may.
	MyStacks  int `json:"my_stacks"`
	MaxStacks int `json:"max_stacks"`
}

// GoalView is the day's shared goal.
type GoalView struct {
	ID    string `json:"id"`
	Kind  string `json:"kind"`
	Name  string `json:"name"`
	Blurb string `json:"blurb"`
	Icon  string `json:"icon"`

	Progress int64 `json:"progress"`
	Target   int64 `json:"target"`
	Members  int   `json:"members"`
	// Seconds until the bar closes, and until the chests do.
	EndsIn  int64 `json:"ends_in"`
	ClaimIn int64 `json:"claim_in"`

	// This lord's own share, and what they must reach to claim.
	Mine     int64 `json:"mine"`
	MineNeed int64 `json:"mine_need"`

	Chests []GoalChest  `json:"chests"`
	Top    []GoalHelper `json:"top"`
}

// GoalChest is one chest on the bar.
type GoalChest struct {
	Index int   `json:"index"`
	AtBP  int64 `json:"at_bp"`
	// What the bar must reach for it, in the goal's own units, so the client
	// never divides anything.
	At      int64    `json:"at"`
	Lines   []string `json:"lines"`
	Reached bool     `json:"reached"`
	Claimed bool     `json:"claimed"`
}

// GoalHelper is one lord's share, for the hall's list.
type GoalHelper struct {
	PlayerID string `json:"player_id"`
	Name     string `json:"name"`
	Avatar   string `json:"avatar"`
	Level    int64  `json:"level"`
	Look     Look   `json:"look,omitzero"`
	Amount   int64  `json:"amount"`
	Mine     bool   `json:"mine"`
}

// AidCall is one lord asking their kingdom for help.
type AidCall struct {
	ID       string `json:"id"`
	PlayerID string `json:"player_id"`
	Name     string `json:"name"`
	Avatar   string `json:"avatar"`
	Level    int64  `json:"level"`
	Look     Look   `json:"look,omitzero"`
	At       int64  `json:"at"`
	EndsIn   int64  `json:"ends_in"`
	Answers  int    `json:"answers"`
	// Whether this lord has already answered it.
	Answered bool `json:"answered"`
}

// GetHelp reads the sub-tab, making the day's goal if the kingdom has none.
func (d Deps) GetHelp(ctx context.Context, playerID uuid.UUID) (*HelpView, error) {
	cfg := d.Config.Social
	var out HelpView
	err := db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
		q := sqlcdb.New(tx)
		p, err := q.GetPlayerByID(ctx, playerID)
		if err != nil {
			return ErrNotFound
		}
		if p.KingdomID == nil {
			return ErrNoKingdomHelp
		}
		room := *p.KingdomID
		now := d.Now()
		out = HelpView{
			Calls: []AidCall{}, MaxStacks: cfg.Aid.MaxStacks,
			AidStackBP: cfg.Aid.StackBP, AidHours: cfg.Aid.Hours, AidFavour: cfg.Aid.FavourPerAid,
		}
		out.AidLeft = max(0, cfg.Aid.PerDay-aidGivenToday(p, localDay(now, p.ResetOffsetMinutes)))
		if p.AidAskedAt != nil {
			if next := p.AidAskedAt.Add(time.Duration(cfg.Aid.AskCooldownMinutes) * time.Minute); next.After(now) {
				out.AskIn = int64(next.Sub(now).Seconds()) + 1
			}
		}
		if n, err := q.CountAidStacks(ctx, playerID); err == nil {
			out.MyStacks = int(n)
		}

		calls, err := q.ListAidCalls(ctx, sqlcdb.ListAidCallsParams{
			Me: playerID, KingdomID: room, Lim: 20,
		})
		if err != nil {
			return fmt.Errorf("calls: %w", err)
		}
		for _, c := range calls {
			out.Calls = append(out.Calls, AidCall{
				ID: c.ID.String(), PlayerID: c.AskerID.String(), Name: c.DisplayName,
				Avatar: c.Avatar, Level: int64(c.Level),
				Look: lookOf(d.Config, c.CosFrame, c.CosTitle, c.CosColor, c.CosCrest, c.VipPoints),
				At:   c.CreatedAt.Unix(), EndsIn: int64(c.ExpiresAt.Sub(now).Seconds()) + 1,
				Answers: int(c.Answers), Answered: c.Answered,
			})
		}

		goal, err := d.ensureGoal(ctx, q, room, now)
		if err != nil {
			return err
		}
		if goal != nil {
			v, err := d.goalView(ctx, q, *goal, playerID, now)
			if err != nil {
				return err
			}
			out.Goal = v
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return &out, nil
}

// aidGivenToday is the day's count, or zero on a new day.
func aidGivenToday(p sqlcdb.AppPlayer, today time.Time) int {
	if !p.AidDay.Valid || !p.AidDay.Time.Equal(today) {
		return 0
	}
	return int(p.AidGiven)
}

// ensureGoal reads the kingdom's live goal, making the day's if there is none.
//
// The KIND is chosen from the kingdom and the day together, so every member
// asks the same question and gets the same answer without a job running
// anywhere. The TARGET is frozen from the members the kingdom has at that
// moment: a kingdom that doubles overnight does not double its bar.
func (d Deps) ensureGoal(ctx context.Context, q *sqlcdb.Queries, room uuid.UUID, now time.Time) (*sqlcdb.AppKingdomGoal, error) {
	cfg := d.Config.Social.Goal
	if len(cfg.Kinds) == 0 {
		return nil, nil
	}
	day := now.UTC().Truncate(24 * time.Hour)
	if g, err := q.GetKingdomGoal(ctx, sqlcdb.GetKingdomGoalParams{
		KingdomID: room, Day: dateOf(day),
	}); err == nil {
		return &g, nil
	} else if !errors.Is(err, pgx.ErrNoRows) {
		return nil, fmt.Errorf("goal: %w", err)
	}

	members, err := q.CountKingdomMembers(ctx, &room)
	if err != nil {
		return nil, fmt.Errorf("members: %w", err)
	}
	if int(members) < cfg.MinMembers {
		// A kingdom of one or two has no shared goal: a bar nobody can reach
		// reads as a punishment for being small.
		return nil, nil
	}
	kind := d.goalKindFor(ctx, q, room, day)
	g, err := q.UpsertKingdomGoal(ctx, sqlcdb.UpsertKingdomGoalParams{
		KingdomID: room, Day: dateOf(day), Kind: kind.ID,
		Target:     social.GoalTarget(kind.PerMember, int(members)),
		Members:    int16(members),
		EndsAt:     day.Add(time.Duration(cfg.Hours) * time.Hour),
		ClaimUntil: day.Add(time.Duration(cfg.ClaimHours) * time.Hour),
	})
	if err != nil {
		return nil, fmt.Errorf("set the goal: %w", err)
	}
	return &g, nil
}

// goalKindFor is the day's question: the drawn one, unless the kingdom could
// not answer it today, and then the next one along.
//
// Only the beast can be unanswerable. A cycle is forty-eight hours and a
// kingdom that put its beast down early waits the rest of the window out, so a
// hall can wake to a day with nothing to strike -- and "strike the beast three
// times" on a day with no beast is not a goal, it is a locked door. Every other
// question can be answered any morning.
func (d Deps) goalKindFor(ctx context.Context, q *sqlcdb.Queries, room uuid.UUID,
	day time.Time) gameconfig.GoalKind {

	kinds := d.Config.Social.Goal.Kinds
	start := goalPick(room, day, len(kinds))
	for i := range kinds {
		k := kinds[(start+i)%len(kinds)]
		if k.ID != "boss" {
			return k
		}
		if _, err := q.GetKingdomBoss(ctx, room); err == nil {
			return k
		}
	}
	return kinds[start]
}

// goalPick chooses the day's question from the kingdom and the day, so every
// member of one hall asks the same one and two halls rarely ask the same.
func goalPick(room uuid.UUID, day time.Time, n int) int {
	h := fnv.New32a()
	_, _ = h.Write(room[:])
	_, _ = h.Write([]byte(day.Format("2006-01-02")))
	return int(h.Sum32()) % n
}

// goalView dresses a goal for the page.
func (d Deps) goalView(ctx context.Context, q *sqlcdb.Queries, g sqlcdb.AppKingdomGoal, playerID uuid.UUID, now time.Time) (*GoalView, error) {
	cfg := d.Config.Social.Goal
	kind := cfg.Kind(g.Kind)
	v := &GoalView{
		ID: g.ID.String(), Kind: g.Kind, Progress: g.Progress, Target: g.Target,
		Members: int(g.Members), Chests: []GoalChest{}, Top: []GoalHelper{},
	}
	if kind != nil {
		v.Name, v.Blurb, v.Icon = kind.Name, kind.Blurb, kind.Icon
	}
	if g.EndsAt.After(now) {
		v.EndsIn = int64(g.EndsAt.Sub(now).Seconds()) + 1
	}
	if g.ClaimUntil.After(now) {
		v.ClaimIn = int64(g.ClaimUntil.Sub(now).Seconds()) + 1
	}
	v.MineNeed = social.GoalShare(g.Target, int(g.Members), cfg.MinShareOfEqualBP)

	var claimed int
	part, err := q.GetGoalPart(ctx, sqlcdb.GetGoalPartParams{GoalID: g.ID, PlayerID: playerID})
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return nil, fmt.Errorf("my share: %w", err)
	}
	if err == nil {
		v.Mine, claimed = part.Amount, int(part.Claimed)
	}

	at := make([]int64, 0, len(cfg.Tiers))
	for _, t := range cfg.Tiers {
		at = append(at, t.AtBP)
	}
	reached := social.GoalTiersReached(g.Progress, g.Target, at)
	for i, t := range cfg.Tiers {
		v.Chests = append(v.Chests, GoalChest{
			Index: i, AtBP: t.AtBP, At: g.Target * t.AtBP / 10000,
			Lines:   d.rewardLines(t.Grant, 1),
			Reached: reached&(1<<i) != 0, Claimed: claimed&(1<<i) != 0,
		})
	}

	rows, err := q.ListGoalParts(ctx, sqlcdb.ListGoalPartsParams{GoalID: g.ID, Lim: 10})
	if err != nil {
		return nil, fmt.Errorf("shares: %w", err)
	}
	for _, r := range rows {
		v.Top = append(v.Top, GoalHelper{
			PlayerID: r.PlayerID.String(), Name: r.DisplayName, Avatar: r.Avatar,
			Level: int64(r.Level), Amount: r.Amount, Mine: r.PlayerID == playerID,
			Look: lookOf(d.Config, r.CosFrame, r.CosTitle, r.CosColor, r.CosCrest, r.VipPoints),
		})
	}
	return v, nil
}

// goalDeeds turns what an action just did into what the day's goal counts.
// Nothing in the game reports to the goal directly: this reads the counters
// recordDeeds is writing anyway.
func goalDeeds(kind string, dd deeds.Deeds) int64 {
	switch kind {
	case "energy":
		return dd[deeds.Energy]
	case "victories":
		return dd[deeds.RaidWins] + dd[deeds.ArenaWins]
	// PvE ve derinlik (Wave 7): a mile of the road, walked or walked again.
	case "campaign":
		return dd[deeds.CampaignStages]
	// Krallik Boss (Wave 8): a blow at the kingdom's beast. Struck, not landed:
	// a lord who threw themselves at it and fell did their part.
	case "boss":
		return dd[deeds.BossHits]
	}
	return 0
}

// addGoalProgress moves the kingdom's bar by what this action did, inside the
// action's own transaction and its savepoint: a bar that could not be moved
// costs a tick, never the action.
func (d Deps) addGoalProgress(ctx context.Context, q *sqlcdb.Queries, p sqlcdb.AppPlayer, dd deeds.Deeds, now time.Time) error {
	if p.KingdomID == nil {
		return nil
	}
	g, err := d.ensureGoal(ctx, q, *p.KingdomID, now)
	if err != nil || g == nil {
		return err
	}
	amount := goalDeeds(g.Kind, dd)
	if amount <= 0 || !g.EndsAt.After(now) {
		return nil
	}
	row, err := q.AddGoalProgress(ctx, sqlcdb.AddGoalProgressParams{
		GoalID: g.ID, PlayerID: p.ID, Amount: amount,
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil // the bar closed between the read and the write
		}
		return fmt.Errorf("goal progress: %w", err)
	}
	// The room watches its own bar move.
	d.tell(*p.KingdomID, "goal", map[string]any{
		"id": row.ID.String(), "progress": row.Progress, "target": row.Target,
	})
	return nil
}

// AskAid raises a call for help in the lord's own hall.
func (d Deps) AskAid(ctx context.Context, playerID uuid.UUID) (*AidCall, error) {
	cfg := d.Config.Social.Aid
	var out AidCall
	var room uuid.UUID
	err := db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
		q := sqlcdb.New(tx)
		p, err := q.GetPlayerByID(ctx, playerID)
		if err != nil {
			return ErrNotFound
		}
		if p.KingdomID == nil {
			return ErrNoKingdomHelp
		}
		room = *p.KingdomID
		now := d.Now()
		if _, err := q.MarkAidAsked(ctx, sqlcdb.MarkAidAskedParams{
			PlayerID: playerID,
			NotSince: now.Add(-time.Duration(cfg.AskCooldownMinutes) * time.Minute),
		}); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrAidSoon
			}
			return fmt.Errorf("ask: %w", err)
		}
		call, err := q.AskForAid(ctx, sqlcdb.AskForAidParams{
			KingdomID: room, AskerID: playerID,
			ExpiresAt: now.Add(time.Duration(cfg.AskCooldownMinutes) * time.Minute),
		})
		if err != nil {
			return fmt.Errorf("call: %w", err)
		}
		if _, err := d.systemLine(ctx, q, room, SysAid,
			fmt.Sprintf("%s has called for aid.", p.DisplayName),
			map[string]any{"aid_id": call.ID.String(), "player_id": playerID.String()}); err != nil {
			return err
		}
		out = AidCall{
			ID: call.ID.String(), PlayerID: playerID.String(), Name: p.DisplayName,
			Avatar: p.Avatar, Level: int64(p.Level), At: call.CreatedAt.Unix(),
			EndsIn: int64(call.ExpiresAt.Sub(now).Seconds()) + 1,
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	d.tell(room, "aid", out)
	return &out, nil
}

// AidGiven is what the helper gets back.
type AidGiven struct {
	Favour  int64 `json:"favour"`
	AidLeft int   `json:"aid_left"`
}

// AnswerAid answers one call: a stack for the lord who asked, favour for the
// lord who answered.
func (d Deps) AnswerAid(ctx context.Context, playerID, aidID uuid.UUID) (*AidGiven, error) {
	cfg := d.Config.Social.Aid
	var out AidGiven
	var room uuid.UUID
	err := db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
		q := sqlcdb.New(tx)
		call, err := q.GetAidCall(ctx, aidID)
		if err != nil {
			return ErrAidGone
		}
		if call.AskerID == playerID {
			return ErrAidOwn
		}
		now := d.Now()
		if !call.ExpiresAt.After(now) {
			return ErrAidGone
		}
		locked, err := q.LockTwoPlayers(ctx, []uuid.UUID{playerID, call.AskerID})
		if err != nil {
			return fmt.Errorf("lock players: %w", err)
		}
		var me, asker sqlcdb.AppPlayer
		for _, p := range locked {
			if p.ID == playerID {
				me = p
			} else {
				asker = p
			}
		}
		if me.ID == uuid.Nil || asker.ID == uuid.Nil {
			return ErrNotFound
		}
		if me.KingdomID == nil || asker.KingdomID == nil || *me.KingdomID != *asker.KingdomID {
			return ErrAidGone
		}
		room = *me.KingdomID
		if blocked, err := q.BlockedBetween(ctx, sqlcdb.BlockedBetweenParams{
			A: playerID, B: asker.ID,
		}); err == nil && blocked {
			return ErrAidGone
		}
		held, err := q.CountAidStacks(ctx, asker.ID)
		if err != nil {
			return fmt.Errorf("their stacks: %w", err)
		}
		if social.AidStacks(int(held), cfg.MaxStacks) <= 0 {
			return ErrAidFull
		}
		if _, err := q.SpendAid(ctx, sqlcdb.SpendAidParams{
			Today: dateOf(localDay(now, me.ResetOffsetMinutes)), PlayerID: playerID,
			PerDay: int32(cfg.PerDay),
		}); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrAidDayFull
			}
			return fmt.Errorf("day's aid: %w", err)
		}
		if _, err := q.AnswerAid(ctx, sqlcdb.AnswerAidParams{AidID: aidID, HelperID: playerID}); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrAidGone // already answered by this lord
			}
			return fmt.Errorf("answer: %w", err)
		}
		if _, err := q.BumpAidAnswers(ctx, aidID); err != nil {
			return fmt.Errorf("count answers: %w", err)
		}

		// The stack, on the lord who asked: gold and experience together, both
		// in the timed lane, through the one reward path.
		stack := gameconfig.RewardBundle{Boosts: []gameconfig.BoostGrant{
			{Bucket: gameconfig.BucketCollectIncome, BP: cfg.StackBP, Hours: int64(cfg.Hours)},
			{Bucket: gameconfig.BucketXP, BP: cfg.StackBP, Hours: int64(cfg.Hours)},
		}}
		if _, err := d.grantBundle(ctx, q, &asker, stack, GrantSource{
			Diamonds: ledger.Aid, Ref: aidID.String(),
		}); err != nil {
			return err
		}
		// The favour, on the lord who answered.
		if _, err := d.grantBundle(ctx, q, &me, gameconfig.RewardBundle{Favour: cfg.FavourPerAid},
			GrantSource{Diamonds: ledger.Aid, Ref: aidID.String()}); err != nil {
			return err
		}
		d.recordDeeds(ctx, tx, me, deeds.Deeds{deeds.AidGiven: 1})
		out = AidGiven{
			Favour:  cfg.FavourPerAid,
			AidLeft: max(0, cfg.PerDay-aidGivenToday(me, localDay(now, me.ResetOffsetMinutes))-1),
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	d.tell(room, "aid", map[string]string{"id": aidID.String()})
	return &out, nil
}

// GoalClaimed is what a chest paid.
type GoalClaimed struct {
	Index    int       `json:"index"`
	Lines    []string  `json:"lines"`
	Goal     *GoalView `json:"goal,omitempty"`
	Snapshot *Snapshot `json:"snapshot,omitempty"`
}

// ClaimGoalChest takes one chest off the day's bar.
//
// It does NOT move action_seq: it pays a reward, like a letter, and the
// client's queued taps are not counting on it.
func (d Deps) ClaimGoalChest(ctx context.Context, playerID uuid.UUID, index int) (*GoalClaimed, error) {
	cfg := d.Config.Social.Goal
	if index < 0 || index >= len(cfg.Tiers) {
		return nil, ErrNotFound
	}
	tier := cfg.Tiers[index]
	var out GoalClaimed
	err := db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
		q := sqlcdb.New(tx)
		p, err := q.LockPlayer(ctx, playerID)
		if err != nil {
			return ErrNotFound
		}
		if p.KingdomID == nil {
			return ErrNoKingdomHelp
		}
		now := d.Now()
		g, err := q.LatestClaimableGoal(ctx, *p.KingdomID)
		if err != nil {
			return ErrGoalNone
		}
		at := make([]int64, 0, len(cfg.Tiers))
		for _, t := range cfg.Tiers {
			at = append(at, t.AtBP)
		}
		if social.GoalTiersReached(g.Progress, g.Target, at)&(1<<index) == 0 {
			return ErrGoalShort
		}
		part, err := q.GetGoalPart(ctx, sqlcdb.GetGoalPartParams{GoalID: g.ID, PlayerID: playerID})
		if err != nil {
			// No row is a lord who did none of the work -- which is every lord
			// who joined the kingdom after the day began.
			return ErrGoalShare
		}
		if part.Amount < social.GoalShare(g.Target, int(g.Members), cfg.MinShareOfEqualBP) {
			return ErrGoalShare
		}
		if _, err := q.ClaimGoalTier(ctx, sqlcdb.ClaimGoalTierParams{
			Bit: int32(1 << index), GoalID: g.ID, PlayerID: playerID,
		}); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrGoalTaken
			}
			return fmt.Errorf("claim: %w", err)
		}
		granted, err := d.grantBundle(ctx, q, &p, tier.Grant, GrantSource{
			Diamonds: ledger.Goal, Ref: g.ID.String(), ItemFrom: "reward",
		})
		if err != nil {
			return err
		}
		out.Index = index
		out.Lines = []string{}
		for _, l := range granted.Lines {
			out.Lines = append(out.Lines, l.Text)
		}
		v, err := d.goalView(ctx, q, g, playerID, now)
		if err != nil {
			return err
		}
		out.Goal = v
		return nil
	})
	if err != nil {
		return nil, err
	}
	out.Snapshot, err = d.GetState(ctx, playerID)
	return &out, err
}
