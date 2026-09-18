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
	"github.com/yigitkarabulut0/emperors/server/internal/game/deeds"
	"github.com/yigitkarabulut0/emperors/server/internal/game/rewards"
	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
	"github.com/yigitkarabulut0/emperors/server/internal/ledger"
)

// The week's quests (retention.weekly): six a week from the lord's own Monday
// midnight -- the two diamond ones on every board, four drawn for the lord and
// the week -- each worth points toward three chests. Progress is the week's
// deeds (app.player_deeds, scope week), counted by recordDeeds as the lord
// plays; nothing here counts anything.

// WeeklyTaskView is one of the week's quests.
type WeeklyTaskView struct {
	Slot     int            `json:"slot"`
	ID       string         `json:"id"`
	Name     string         `json:"name"`
	Short    string         `json:"short"`
	Blurb    string         `json:"blurb"`
	Icon     string         `json:"icon"`
	Target   int64          `json:"target"`
	Progress int64          `json:"progress"`
	Done     bool           `json:"done"`
	Claimed  bool           `json:"claimed"`
	Points   int64          `json:"points"`
	Lines    []rewards.Line `json:"lines"`
}

// WeeklyChestView is one of the week's chests.
type WeeklyChestView struct {
	Tier    int            `json:"tier"`
	At      int64          `json:"at"`
	Ready   bool           `json:"ready"`
	Claimed bool           `json:"claimed"`
	Lines   []rewards.Line `json:"lines"`
}

// WeeklyView is the week.
type WeeklyView struct {
	Week      string            `json:"week"`
	EndsIn    int64             `json:"ends_in"`
	Points    int64             `json:"points"`
	PointsMax int64             `json:"points_max"`
	Tasks     []WeeklyTaskView  `json:"tasks"`
	Chests    []WeeklyChestView `json:"chests"`
}

// WeeklyClaim is what a task or a chest paid.
type WeeklyClaim struct {
	Lines    []rewards.Line `json:"lines"`
	Weekly   *WeeklyView    `json:"weekly"`
	Snapshot *Snapshot      `json:"snapshot"`
}

// weekOf is the Monday of the lord's own week.
func weekOf(now time.Time, offsetMinutes int32) time.Time {
	return deeds.WeekStart(localDay(now, offsetMinutes))
}

// weeklyDraw is the board a lord's week would draw: the fixed tasks, then Draw
// from the pool by a pure function of (secret, lord, week), as the day's quests
// are drawn -- two devices agree, and nothing is stored until the first look
// freezes it.
func (d Deps) weeklyDraw(playerID uuid.UUID, level int, week time.Time) []gameconfig.WeeklyTask {
	w := d.Config.Retention.Weekly
	out := append([]gameconfig.WeeklyTask(nil), w.Fixed...)
	floor := max(level, w.EligibleLevelFloor)
	eligible := make([]gameconfig.WeeklyTask, 0, len(w.Pool))
	for _, t := range w.Pool {
		if t.MinLevel <= floor {
			eligible = append(eligible, t)
		}
	}
	rng := game.SeedForString(d.ShopSecret, playerID.String(), uint64(week.Unix()), 0x3EE7)
	n := min(w.Draw, len(eligible))
	for i := 0; i < n; i++ {
		j := i + int(rng.Uint64N(uint64(len(eligible)-i)))
		eligible[i], eligible[j] = eligible[j], eligible[i]
	}
	return append(out, eligible[:n]...)
}

// weeklyTask finds a task by id, fixed or drawn; nil for one the balance no
// longer has (a board keeps the rest).
func (d Deps) weeklyTask(id string) *gameconfig.WeeklyTask {
	w := d.Config.Retention.Weekly
	for _, list := range [][]gameconfig.WeeklyTask{w.Fixed, w.Pool} {
		for i := range list {
			if list[i].ID == id {
				return &list[i]
			}
		}
	}
	return nil
}

// weeklyBoard is the week's row, frozen at its first look, and its tasks by
// slot (a slot whose task the balance dropped is nil).
func (d Deps) weeklyBoard(ctx context.Context, q *sqlcdb.Queries, p sqlcdb.AppPlayer,
	week time.Time) (sqlcdb.AppPlayerWeekly, []*gameconfig.WeeklyTask, error) {
	day := pgtype.Date{Time: week, Valid: true}
	row, err := q.GetWeekly(ctx, sqlcdb.GetWeeklyParams{PlayerID: p.ID, Week: day})
	if errors.Is(err, pgx.ErrNoRows) {
		drawn := d.weeklyDraw(p.ID, int(p.Level), week)
		ids := make([]string, len(drawn))
		for i, t := range drawn {
			ids[i] = t.ID
		}
		row, err = q.EnsureWeekly(ctx, sqlcdb.EnsureWeeklyParams{PlayerID: p.ID, Week: day, TaskIds: ids})
	}
	if err != nil {
		return row, nil, fmt.Errorf("week's board: %w", err)
	}
	tasks := make([]*gameconfig.WeeklyTask, len(row.TaskIds))
	for i, id := range row.TaskIds {
		tasks[i] = d.weeklyTask(id)
	}
	return row, tasks, nil
}

// weekDeeds is the lord's counts for the week.
func weekDeeds(ctx context.Context, q *sqlcdb.Queries, playerID uuid.UUID, week time.Time) (map[string]int64, error) {
	rows, err := q.ListDeeds(ctx, sqlcdb.ListDeedsParams{
		PlayerID: playerID, Scope: deeds.ScopeWeek, Period: deeds.EpochDay(week),
	})
	if err != nil {
		return nil, fmt.Errorf("week's deeds: %w", err)
	}
	out := make(map[string]int64, len(rows))
	for _, r := range rows {
		out[r.Deed] = r.Value
	}
	return out, nil
}

// GetWeekly reports the week.
func (d Deps) GetWeekly(ctx context.Context, playerID uuid.UUID) (*WeeklyView, error) {
	q := sqlcdb.New(d.Pool)
	p, err := q.GetPlayerByID(ctx, playerID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, fmt.Errorf("weekly: %w", err)
	}
	return d.weeklyView(ctx, q, p)
}

func (d Deps) weeklyView(ctx context.Context, q *sqlcdb.Queries, p sqlcdb.AppPlayer) (*WeeklyView, error) {
	now := d.Now()
	week := weekOf(now, p.ResetOffsetMinutes)
	row, tasks, err := d.weeklyBoard(ctx, q, p, week)
	if err != nil {
		return nil, err
	}
	counts, err := weekDeeds(ctx, q, p.ID, week)
	if err != nil {
		return nil, err
	}
	eff, err := d.loadEffects(ctx, q, p)
	if err != nil {
		return nil, err
	}
	bonuses := rewards.PermanentOnly(eff.Bonuses)
	lines := func(g gameconfig.RewardBundle) []rewards.Line {
		return rewards.Lines(d.Config, g, rewards.Resolve(d.Config, g, int(p.Level), bonuses))
	}

	// The week ends at the lord's next Monday midnight, in their own time.
	end := week.AddDate(0, 0, 7).Add(-time.Duration(p.ResetOffsetMinutes) * time.Minute)
	v := &WeeklyView{Week: week.Format("2006-01-02"), EndsIn: ceilSeconds(end.Sub(now)),
		Points: int64(row.Points), Tasks: []WeeklyTaskView{}, Chests: []WeeklyChestView{}}
	for i, t := range tasks {
		if t == nil {
			continue
		}
		got := counts[t.Deed]
		v.PointsMax += t.Points
		v.Tasks = append(v.Tasks, WeeklyTaskView{
			Slot: i, ID: t.ID, Name: t.Name, Short: t.Short, Blurb: t.Blurb, Icon: t.Icon,
			Target: t.Target, Progress: min(got, t.Target), Done: got >= t.Target,
			Claimed: row.Claimed&(1<<i) != 0, Points: t.Points, Lines: lines(t.Grant),
		})
	}
	for i, c := range d.Config.Retention.Weekly.Chests {
		v.Chests = append(v.Chests, WeeklyChestView{
			Tier: i, At: c.At, Ready: int64(row.Points) >= c.At,
			Claimed: row.Chests&(1<<i) != 0, Lines: lines(c.Grant),
		})
	}
	return v, nil
}

// ClaimWeeklyTask pays one finished task and adds its points.
func (d Deps) ClaimWeeklyTask(ctx context.Context, playerID uuid.UUID, slot int) (*WeeklyClaim, error) {
	return d.weeklyClaim(ctx, playerID, func(ctx context.Context, q *sqlcdb.Queries, p *sqlcdb.AppPlayer,
		week time.Time) ([]rewards.Line, error) {
		_, tasks, err := d.weeklyBoard(ctx, q, *p, week)
		if err != nil {
			return nil, err
		}
		if slot < 0 || slot >= len(tasks) || tasks[slot] == nil {
			return nil, ErrNotFound
		}
		t := tasks[slot]
		counts, err := weekDeeds(ctx, q, p.ID, week)
		if err != nil {
			return nil, err
		}
		if counts[t.Deed] < t.Target {
			return nil, ErrQuestUnfinished
		}
		if _, err := q.ClaimWeeklyTask(ctx, sqlcdb.ClaimWeeklyTaskParams{
			PlayerID: p.ID, Week: pgtype.Date{Time: week, Valid: true},
			Bit: int32(1) << slot, Points: int32(t.Points),
		}); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return nil, ErrAlreadyClaimed
			}
			return nil, fmt.Errorf("claim a task: %w", err)
		}
		g, err := d.grantBundle(ctx, q, p, t.Grant, GrantSource{
			Diamonds: ledger.Weekly, Gold: "weekly",
			Ref: fmt.Sprintf("weekly:%s:%s", week.Format("2006-01-02"), t.ID), ItemFrom: "reward",
		})
		if err != nil {
			return nil, err
		}
		return g.Lines, nil
	}, true)
}

// ClaimWeeklyChest opens one of the week's chests, once its points are earned.
func (d Deps) ClaimWeeklyChest(ctx context.Context, playerID uuid.UUID, tier int) (*WeeklyClaim, error) {
	chests := d.Config.Retention.Weekly.Chests
	if tier < 0 || tier >= len(chests) {
		return nil, ErrNotFound
	}
	c := chests[tier]
	return d.weeklyClaim(ctx, playerID, func(ctx context.Context, q *sqlcdb.Queries, p *sqlcdb.AppPlayer,
		week time.Time) ([]rewards.Line, error) {
		row, _, err := d.weeklyBoard(ctx, q, *p, week)
		if err != nil {
			return nil, err
		}
		if row.Chests&(1<<tier) != 0 {
			return nil, ErrAlreadyClaimed
		}
		if int64(row.Points) < c.At {
			return nil, ErrQuestUnfinished
		}
		if _, err := q.ClaimWeeklyChest(ctx, sqlcdb.ClaimWeeklyChestParams{
			PlayerID: p.ID, Week: pgtype.Date{Time: week, Valid: true},
			Bit: int32(1) << tier, At: int32(c.At),
		}); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return nil, ErrAlreadyClaimed
			}
			return nil, fmt.Errorf("open a chest: %w", err)
		}
		g, err := d.grantBundle(ctx, q, p, c.Grant, GrantSource{
			Diamonds: ledger.Weekly, Gold: "weekly",
			Ref: fmt.Sprintf("weekly:%s:chest%d", week.Format("2006-01-02"), tier+1), ItemFrom: "chest",
		})
		if err != nil {
			return nil, err
		}
		return g.Lines, nil
	}, false)
}

// weeklyClaim runs one claim in its own transaction and answers with the week
// and the lord after it. A task claimed is a deed (the achievements to come
// count them); a chest is not.
func (d Deps) weeklyClaim(ctx context.Context, playerID uuid.UUID,
	claim func(context.Context, *sqlcdb.Queries, *sqlcdb.AppPlayer, time.Time) ([]rewards.Line, error),
	isTask bool) (*WeeklyClaim, error) {
	var lines []rewards.Line
	err := db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
		q := sqlcdb.New(tx)
		p, err := q.LockPlayer(ctx, playerID)
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrNotFound
			}
			return fmt.Errorf("lock player: %w", err)
		}
		before := p
		week := weekOf(d.Now(), p.ResetOffsetMinutes)
		if lines, err = claim(ctx, q, &p, week); err != nil {
			return err
		}
		if isTask {
			d.recordDeeds(ctx, tx, before, deeds.Deeds{deeds.WeeklyQuests: 1})
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	view, err := d.GetWeekly(ctx, playerID)
	if err != nil {
		return nil, err
	}
	snap, err := d.GetState(ctx, playerID)
	if err != nil {
		return nil, err
	}
	return &WeeklyClaim{Lines: lines, Weekly: view, Snapshot: snap}, nil
}

// weeklyWaiting is how many of the week's tasks are done and not claimed, and
// chests earned and not opened: the badge, without pricing a single reward.
func (d Deps) weeklyWaiting(ctx context.Context, q *sqlcdb.Queries, p sqlcdb.AppPlayer) (int, error) {
	week := weekOf(d.Now(), p.ResetOffsetMinutes)
	row, tasks, err := d.weeklyBoard(ctx, q, p, week)
	if err != nil {
		return 0, err
	}
	counts, err := weekDeeds(ctx, q, p.ID, week)
	if err != nil {
		return 0, err
	}
	n := 0
	for i, t := range tasks {
		if t != nil && counts[t.Deed] >= t.Target && row.Claimed&(1<<i) == 0 {
			n++
		}
	}
	for i, c := range d.Config.Retention.Weekly.Chests {
		if int64(row.Points) >= c.At && row.Chests&(1<<i) == 0 {
			n++
		}
	}
	return n, nil
}
