package service

import (
	"context"
	"fmt"
	"time"

	"github.com/google/uuid"

	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
	"github.com/yigitkarabulut0/emperors/server/internal/game/arena"
	"github.com/yigitkarabulut0/emperors/server/internal/game/deeds"
)

// Rekabet's desk (admin/pvp.go): the arena's ladder, the bounty board's escrow
// and the Throne. The rules live here, beside the game, so the panel and the
// game can never disagree about what a league is or what a bounty still holds.

// ArenaDeskView is the ladder and what it has been doing.
type ArenaDeskView struct {
	Season int `json:"season"`
	// Where the ladder stands, and how it is spread over the leagues.
	Ladder  []ArenaDeskRow  `json:"ladder"`
	Leagues []ArenaDeskBand `json:"leagues"`
	Lords   int             `json:"lords"`
	// Fights in the last day, and how many were against a hired champion --
	// the number that says whether the population can fill its own bands.
	Fights    int   `json:"fights_today"`
	BotFights int   `json:"champion_fights_today"`
	ResetsIn  int64 `json:"season_resets_in"`
}

type ArenaDeskRow struct {
	Place  int    `json:"place"`
	Name   string `json:"name"`
	Level  int    `json:"level"`
	Rating int    `json:"rating"`
	Peak   int    `json:"peak"`
	Wins   int    `json:"wins"`
	Losses int    `json:"losses"`
	League string `json:"league"`
}

type ArenaDeskBand struct {
	ID    string `json:"id"`
	Name  string `json:"name"`
	At    int    `json:"at_rating"`
	Lords int    `json:"lords"`
}

// ArenaDesk is the ladder as the panel reads it.
func (d Deps) ArenaDesk(ctx context.Context, limit int32) (*ArenaDeskView, error) {
	q := sqlcdb.New(d.Pool)
	now := d.Now()
	season := d.seasonNow(now)
	v := &ArenaDeskView{Season: season.Number, Ladder: []ArenaDeskRow{}, Leagues: []ArenaDeskBand{},
		ResetsIn: secondsUntil(season.End, now)}
	tiers := d.arenaTiers()
	counts := map[string]int{}
	rows, err := q.ArenaLadder(ctx, sqlcdb.ArenaLadderParams{Season: int32(season.Number), Lim: limit})
	if err != nil {
		return nil, fmt.Errorf("ladder: %w", err)
	}
	for _, r := range rows {
		league := arena.League(tiers, int(r.Rating), int(r.Place))
		counts[league.ID]++
		v.Ladder = append(v.Ladder, ArenaDeskRow{
			Place: int(r.Place), Name: r.DisplayName, Level: int(r.Level),
			Rating: int(r.Rating), Peak: int(r.Peak),
			Wins: int(r.Wins), Losses: int(r.Losses), League: league.ID,
		})
	}
	v.Lords = len(rows)
	for _, t := range tiers {
		v.Leagues = append(v.Leagues, ArenaDeskBand{ID: t.ID, Name: t.Name, At: t.AtRating, Lords: counts[t.ID]})
	}
	if n, err := q.CountArenaSince(ctx, now.Add(-24*time.Hour)); err == nil {
		v.Fights = int(n.Fights)
		v.BotFights = int(n.Champions)
	}
	return v, nil
}

// BountyDeskView is the board's escrow and what it has burned.
type BountyDeskView struct {
	// Gold held on heads now, and gold burned in the last week: the two
	// numbers that say whether the sink is working.
	Escrowed int64            `json:"escrowed"`
	Burned   int64            `json:"burned_this_week"`
	Open     int              `json:"open"`
	Claimed  int              `json:"claimed_this_week"`
	Rows     []BountyDeskRow  `json:"rows"`
	Pairs    []BountyDeskPair `json:"pairs"`
}

type BountyDeskRow struct {
	ID        string `json:"id"`
	Target    string `json:"target"`
	Placer    string `json:"placer"`
	Amount    int64  `json:"amount"`
	Remaining int64  `json:"remaining"`
	Fee       int64  `json:"fee_burned"`
	ExpiresIn int64  `json:"expires_in"`
}

// BountyDeskPair is a placer and a claimer who keep meeting: the shape
// collusion takes, and the reason pair_claims_per_week exists.
type BountyDeskPair struct {
	Placer  string `json:"placer"`
	Claimer string `json:"claimer"`
	Claims  int    `json:"claims"`
	Paid    int64  `json:"paid"`
}

// BountyDesk is the board as the panel reads it.
func (d Deps) BountyDesk(ctx context.Context, limit int32) (*BountyDeskView, error) {
	q := sqlcdb.New(d.Pool)
	now := d.Now()
	v := &BountyDeskView{Rows: []BountyDeskRow{}, Pairs: []BountyDeskPair{}}
	if t, err := q.BountyTotals(ctx, now.Add(-7*24*time.Hour)); err == nil {
		v.Escrowed, v.Burned, v.Open, v.Claimed = t.Escrowed, t.Burned, int(t.Open), int(t.Claimed)
	}
	rows, err := q.ListBountiesDesk(ctx, limit)
	if err != nil {
		return nil, fmt.Errorf("bounties: %w", err)
	}
	for _, r := range rows {
		v.Rows = append(v.Rows, BountyDeskRow{
			ID: r.ID.String(), Target: r.TargetName, Placer: r.PlacerName,
			Amount: r.Amount, Remaining: r.Remaining, Fee: r.FeeBurned,
			ExpiresIn: secondsUntil(r.ExpiresAt, now),
		})
	}
	pairs, err := q.BountyPairs(ctx, sqlcdb.BountyPairsParams{Uweek: deeds.UWeek(now), Lim: 20})
	if err == nil {
		for _, p := range pairs {
			v.Pairs = append(v.Pairs, BountyDeskPair{
				Placer: p.PlacerName, Claimer: p.ClaimerName,
				Claims: int(p.Claims), Paid: p.Paid,
			})
		}
	}
	return v, nil
}

// RevokeBounty closes a price and gives the whole remainder back.
//
// The only way to undo one, and the refund does NOT move the placer's sequence
// -- the same reason the expiry job cannot use CreditGold.
func (d Deps) RevokeBounty(ctx context.Context, id uuid.UUID) (int64, error) {
	q := sqlcdb.New(d.Pool)
	b, err := q.GetBounty(ctx, id)
	if err != nil {
		return 0, err
	}
	if b.ClosedAt != nil {
		return 0, ErrBountyGone
	}
	closed, err := q.CloseBounty(ctx, sqlcdb.CloseBountyParams{ID: id, ClosedAs: strPtr("revoked")})
	if err != nil {
		return 0, err
	}
	_ = closed
	if b.Remaining <= 0 {
		return 0, nil
	}
	after, err := q.RefundBounty(ctx, sqlcdb.RefundBountyParams{ID: b.PlacedBy, Gold: b.Remaining})
	if err != nil {
		return 0, err
	}
	if err := q.RecordGold(ctx, sqlcdb.RecordGoldParams{
		PlayerID: b.PlacedBy, Delta: b.Remaining, BalanceAfter: after.Gold,
		Reason: "bounty_refund", RefID: strPtr(id.String()),
	}); err != nil {
		return 0, err
	}
	_, err = d.SendMail(ctx, q, b.PlacedBy, MailDraft{
		Kind: MailBounty, Title: "Your price was withdrawn",
		Body:    "The crown has withdrawn the price you set. What it still held is returned to your purse.",
		IdemKey: "bounty:" + id.String() + ":revoked",
	})
	return b.Remaining, err
}

// ThroneDeskView is the reign, the week's race and the reigns before it.
type ThroneDeskView struct {
	Reign   *ReignView    `json:"reign"`
	Race    []ThroneRacer `json:"race"`
	Past    []ReignView   `json:"past"`
	Measure string        `json:"measure"`
	Scope   string        `json:"scope"`
	// The Monday the next settlement falls on.
	SettlesIn int64 `json:"settles_in"`
}

// ThroneDesk is the Throne as the panel reads it.
func (d Deps) ThroneDesk(ctx context.Context) (*ThroneDeskView, error) {
	q := sqlcdb.New(d.Pool)
	now := d.Now()
	cfg := d.Config.PvP.Throne
	v := &ThroneDeskView{Race: []ThroneRacer{}, Past: []ReignView{},
		Measure: cfg.Measure, Scope: cfg.DecreeScope,
		SettlesIn: secondsUntil(nextCrowning(now), now)}
	race, err := d.throneRace(ctx, q, deeds.UWeek(now), 20)
	if err != nil {
		return nil, err
	}
	for i := range race {
		race[i].Place = i + 1
	}
	v.Race = race
	if row, err := q.CurrentThrone(ctx, now); err == nil {
		r := ReignView{
			Week: row.Uweek, KingdomID: row.KingdomID.String(), KingdomName: row.KingdomName,
			KingdomTag: row.KingdomTag, EmperorID: row.EmperorID.String(),
			EmperorName: row.EmperorName, Renown: row.Reputation / reputationScale,
			Members: int(row.Members), EndsIn: secondsUntil(row.ReignEnds, now),
		}
		v.Reign = &r
	}
	if past, err := q.ListThrones(ctx, 12); err == nil {
		for _, r := range past {
			v.Past = append(v.Past, ReignView{
				Week: r.Uweek, KingdomID: r.KingdomID.String(), KingdomName: r.KingdomName,
				KingdomTag: r.KingdomTag, EmperorID: r.EmperorID.String(),
				EmperorName: r.EmperorName, Renown: r.Reputation / reputationScale,
				Members: int(r.Members), EndsIn: secondsUntil(r.ReignEnds, now),
			})
		}
	}
	return v, nil
}

// SettleThroneNow crowns the closed week by hand, for an operator who has just
// fixed whatever stopped the job.
func (d Deps) SettleThroneNow(ctx context.Context) error {
	return settleThrone(ctx, d, d.Now())
}
