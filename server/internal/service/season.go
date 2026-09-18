package service

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/yigitkarabulut0/emperors/server/internal/db"
	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
	"github.com/yigitkarabulut0/emperors/server/internal/game/liveops"
	"github.com/yigitkarabulut0/emperors/server/internal/game/rewards"
	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
	"github.com/yigitkarabulut0/emperors/server/internal/ledger"
)

// The season (liveops.season): 28 days from its Monday, and the Royal Charter
// on its points -- fifty tiers, a free lane for every lord and a royal lane for
// one who opens it (900 diamonds, or the season_pass product). Points come
// from what a lord does (recordDeeds), capped a season day. Anything reached
// and not claimed when the season ends is sent on (closeSeason).

var (
	ErrNoSeason = errors.New("no season is running")
	// ErrCharterEmpty is a claim with nothing reached and unclaimed.
	ErrCharterEmpty = errors.New("there is nothing on the Charter to claim")
	// ErrCharterLocked is a royal tier claimed before the lane is open.
	ErrCharterLocked = errors.New("the royal lane is not open")
	// ErrRoyalOpen is opening a royal lane already open.
	ErrRoyalOpen = errors.New("the royal lane is already open this season")
)

// Lanes of the Charter.
const (
	LaneFree  = "free"
	LaneRoyal = "royal"
)

// CharterTier is one tier of the Charter as this lord stands to it.
type CharterTier struct {
	Tier    int  `json:"tier"`
	Reached bool `json:"reached"`
	// A tier the page crowns: every tenth, and any whose royal lane holds a
	// look (the Charter's colour, title and frame).
	Crown        bool           `json:"crown"`
	Free         []rewards.Line `json:"free"`
	Royal        []rewards.Line `json:"royal"`
	FreeClaimed  bool           `json:"free_claimed"`
	RoyalClaimed bool           `json:"royal_claimed"`
}

// PointsLine is one way to earn points, written out: "Each Golden Hour lit",
// 40.
type PointsLine struct {
	Deed   string `json:"deed"`
	Text   string `json:"text"`
	Points int64  `json:"points"`
	Icon   string `json:"icon"`
}

// CharterUnlock is how the royal lane opens: diamonds, or the product.
type CharterUnlock struct {
	Diamonds int64 `json:"diamonds"`
	// The App Store product, and its price in cents as a fallback label while
	// the phone's store has not said its local price.
	Product  string `json:"product"`
	StoreID  string `json:"store_id"`
	USDCents int64  `json:"usd_cents"`
	Title    string `json:"title"`
}

// SeasonView is the Season Pass page.
type SeasonView struct {
	Number int    `json:"number"`
	Name   string `json:"name"`
	// Seconds until it ends; its day of Days.
	EndsIn int64 `json:"ends_in"`
	Day    int   `json:"day"`
	Days   int   `json:"days"`
	// Charter points (whole), the tier they reach, and the way to the next.
	Points        int64 `json:"points"`
	PointsPerTier int64 `json:"points_per_tier"`
	Tier          int   `json:"tier"`
	Tiers         int   `json:"tiers"`
	// Points into the tier being worked on (0..PointsPerTier).
	TierPoints int64 `json:"tier_points"`
	// Today's points against the day's cap.
	DayPoints int64 `json:"day_points"`
	DayCap    int64 `json:"day_cap"`
	Royal     bool  `json:"royal"`
	// The tier whose lords are the next season's Knights.
	KnightTier int           `json:"knight_tier"`
	Unlock     CharterUnlock `json:"unlock"`
	// Tiers reached and not yet claimed, in the lanes this lord holds.
	Claimable int `json:"claimable"`
	// What the lanes hold in all, in diamonds.
	FreeDiamonds  int64         `json:"free_diamonds"`
	RoyalDiamonds int64         `json:"royal_diamonds"`
	Sources       []PointsLine  `json:"sources"`
	Charter       []CharterTier `json:"charter"`
}

// CharterClaim is what a claim paid, and what it had to leave.
type CharterClaim struct {
	Lines []rewards.Line `json:"lines"`
	// Tiers whose gear the armory had no room for, left to claim later.
	Skipped  []int       `json:"skipped"`
	Season   *SeasonView `json:"season"`
	Snapshot *Snapshot   `json:"snapshot"`
}

// CharterOpened is the royal lane, opened with diamonds.
type CharterOpened struct {
	Season   *SeasonView `json:"season"`
	Snapshot *Snapshot   `json:"snapshot"`
}

// seasonNow is the season an instant falls in.
func (d Deps) seasonNow(now time.Time) liveops.Season {
	return liveops.SeasonAt(d.Config.LiveOps.Season, now)
}

// liveSeason is the season for the snapshot: its number, end, and this lord's
// tier and lane.
func (d Deps) liveSeason(ctx context.Context, q *sqlcdb.Queries, p sqlcdb.AppPlayer, now time.Time) LiveSeason {
	sc := d.Config.LiveOps.Season
	s := d.seasonNow(now)
	out := LiveSeason{Number: s.Number, EndsIn: secondsUntil(s.End, now), Tiers: sc.Tiers}
	if s.Number < 1 {
		return out
	}
	if row, err := q.GetPlayerSeason(ctx, sqlcdb.GetPlayerSeasonParams{PlayerID: p.ID, Season: int32(s.Number)}); err == nil {
		out.Tier = liveops.Tier(row.PointsMilli/1000, sc.PointsPerTier, sc.Tiers)
		out.Royal = row.RoyalAt != nil
	}
	return out
}

// charterOpen is what a season row has reached and not claimed, per lane.
func (d Deps) charterOpen(row sqlcdb.AppPlayerSeason) (free, royal []int) {
	sc := d.Config.LiveOps.Season
	reached := liveops.Tier(row.PointsMilli/1000, sc.PointsPerTier, sc.Tiers)
	free = liveops.Open(reached, uint64(row.FreeClaimed))
	if row.RoyalAt != nil {
		royal = liveops.Open(reached, uint64(row.RoyalClaimed))
	}
	return free, royal
}

// seasonClaimable is how many Charter rewards wait for a lord: the badge.
func (d Deps) seasonClaimable(ctx context.Context, q *sqlcdb.Queries, p sqlcdb.AppPlayer, now time.Time) int {
	s := d.seasonNow(now)
	if s.Number < 1 {
		return 0
	}
	row, err := q.GetPlayerSeason(ctx, sqlcdb.GetPlayerSeasonParams{PlayerID: p.ID, Season: int32(s.Number)})
	if err != nil {
		return 0
	}
	free, royal := d.charterOpen(row)
	return len(free) + len(royal)
}

// GetSeason is the Season Pass page.
func (d Deps) GetSeason(ctx context.Context, playerID uuid.UUID) (*SeasonView, error) {
	q := sqlcdb.New(d.Pool)
	p, err := q.GetPlayerByID(ctx, playerID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, fmt.Errorf("load player: %w", err)
	}
	now := d.Now()
	s := d.seasonNow(now)
	if s.Number < 1 {
		return nil, ErrNoSeason
	}
	row, err := q.GetPlayerSeason(ctx, sqlcdb.GetPlayerSeasonParams{PlayerID: p.ID, Season: int32(s.Number)})
	if err != nil {
		if !errors.Is(err, pgx.ErrNoRows) {
			return nil, fmt.Errorf("season row: %w", err)
		}
		row = sqlcdb.AppPlayerSeason{PlayerID: p.ID, Season: int32(s.Number)}
	}
	eff, err := d.loadEffects(ctx, q, p)
	if err != nil {
		return nil, err
	}
	sc := d.Config.LiveOps.Season
	points := row.PointsMilli / 1000
	tier := liveops.Tier(points, sc.PointsPerTier, sc.Tiers)
	day := liveops.DayOf(s.Start, now)
	v := &SeasonView{
		Number: s.Number, Name: fmt.Sprintf("Season %d", s.Number),
		EndsIn: secondsUntil(s.End, now), Day: day, Days: sc.Days,
		Points: points, PointsPerTier: sc.PointsPerTier, Tier: tier, Tiers: sc.Tiers,
		DayCap: sc.DailyCap, Royal: row.RoyalAt != nil, KnightTier: sc.KnightTier,
		Sources: pointsLines(sc.Sources),
		Charter: make([]CharterTier, 0, sc.Tiers),
	}
	if tier < sc.Tiers {
		v.TierPoints = points - int64(tier)*sc.PointsPerTier
	} else {
		v.TierPoints = sc.PointsPerTier
	}
	if int(row.Day) == day {
		v.DayPoints = row.DayMilli / 1000
	}
	if pr := d.Config.Product(sc.RoyalProduct); pr != nil {
		v.Unlock = CharterUnlock{Diamonds: sc.RoyalDiamonds, Product: pr.ID, StoreID: pr.StoreID,
			USDCents: pr.USDCents, Title: pr.Title}
	} else {
		v.Unlock = CharterUnlock{Diamonds: sc.RoyalDiamonds}
	}
	free, royal := d.charterOpen(row)
	v.Claimable = len(free) + len(royal)
	for i := 0; i < sc.Tiers; i++ {
		v.FreeDiamonds += sc.Free[i].Diamonds
		v.RoyalDiamonds += sc.Royal[i].Diamonds
		v.Charter = append(v.Charter, CharterTier{
			Tier: i + 1, Reached: i < tier,
			Crown:        (i+1)%10 == 0 || len(sc.Royal[i].Cosmetics) > 0,
			Free:         d.linesOf(p, eff, sc.Free[i]),
			Royal:        d.linesOf(p, eff, sc.Royal[i]),
			FreeClaimed:  row.FreeClaimed&(1<<uint(i)) != 0,
			RoyalClaimed: row.RoyalClaimed&(1<<uint(i)) != 0,
		})
	}
	return v, nil
}

// royalSource is how a royal tier pays: as the purchase that opened the lane
// (so a refund finds it), or as the season's own when diamonds opened it.
func royalSource(row sqlcdb.AppPlayerSeason, tier int) GrantSource {
	if row.RoyalRef != nil {
		return GrantSource{Diamonds: ledger.SeasonRoyalPaid, Gold: "season", Ref: *row.RoyalRef,
			ItemFrom: "season", Paid: true}
	}
	return GrantSource{Diamonds: ledger.Season, Gold: "season",
		Ref: fmt.Sprintf("season:%d:royal:%d", row.Season, tier), ItemFrom: "season"}
}

func freeSource(season int32, tier int) GrantSource {
	return GrantSource{Diamonds: ledger.Season, Gold: "season",
		Ref: fmt.Sprintf("season:%d:free:%d", season, tier), ItemFrom: "season"}
}

// ClaimCharter claims a tier's reward in one lane (tier and lane given), or
// every reward reached and unclaimed in both lanes (neither given).
//
// Claiming all leaves a tier whose gear the armory has no room for (the free
// lane's rare and epic pieces), and says so: the rest are paid. A tier asked
// for by name is paid whole or not at all.
func (d Deps) ClaimCharter(ctx context.Context, playerID uuid.UUID, tier *int, lane string) (*CharterClaim, error) {
	res := CharterClaim{Lines: []rewards.Line{}, Skipped: []int{}}
	err := db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
		q := sqlcdb.New(tx)
		p, err := q.LockPlayer(ctx, playerID)
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrNotFound
			}
			return fmt.Errorf("lock player: %w", err)
		}
		now := d.Now()
		s := d.seasonNow(now)
		if s.Number < 1 {
			return ErrNoSeason
		}
		row, err := q.EnsurePlayerSeason(ctx, sqlcdb.EnsurePlayerSeasonParams{PlayerID: p.ID, Season: int32(s.Number), Might: p.Might})
		if err != nil {
			return fmt.Errorf("season row: %w", err)
		}
		sc := d.Config.LiveOps.Season
		free, royal := d.charterOpen(row)

		if tier != nil {
			i := *tier - 1
			if i < 0 || i >= sc.Tiers || (lane != LaneFree && lane != LaneRoyal) {
				return ErrNotFound
			}
			reached := liveops.Tier(row.PointsMilli/1000, sc.PointsPerTier, sc.Tiers)
			claimed := row.FreeClaimed
			if lane == LaneRoyal {
				if row.RoyalAt == nil {
					return ErrCharterLocked
				}
				claimed = row.RoyalClaimed
			}
			switch {
			case claimed&(1<<uint(i)) != 0:
				return ErrAlreadyClaimed
			case i >= reached:
				return ErrCharterEmpty
			}
			free, royal = nil, nil
			if lane == LaneFree {
				free = []int{i}
				if n := rewards.ItemCount(sc.Free[i]); n > 0 {
					used, err := q.CountPlayerItems(ctx, p.ID)
					if err != nil {
						return fmt.Errorf("count items: %w", err)
					}
					if used+n > d.bagCap(p) {
						return ErrInventoryFull
					}
				}
			} else {
				royal = []int{i}
			}
		} else {
			// Room in the armory, tier by tier: gear that will not fit waits.
			used, err := q.CountPlayerItems(ctx, p.ID)
			if err != nil {
				return fmt.Errorf("count items: %w", err)
			}
			room := d.bagCap(p) - used
			kept := free[:0:0]
			for _, i := range free {
				n := rewards.ItemCount(sc.Free[i])
				if n > room {
					res.Skipped = append(res.Skipped, i+1)
					continue
				}
				room -= n
				kept = append(kept, i)
			}
			free = kept
		}
		if len(free)+len(royal) == 0 {
			if len(res.Skipped) > 0 {
				return ErrInventoryFull
			}
			return ErrCharterEmpty
		}

		after, err := q.ClaimSeasonTiers(ctx, sqlcdb.ClaimSeasonTiersParams{
			PlayerID: p.ID, Season: row.Season,
			Free: int64(liveops.Mask(free)), Royal: int64(liveops.Mask(royal)),
		})
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrAlreadyClaimed
			}
			return fmt.Errorf("claim the charter: %w", err)
		}
		for _, i := range free {
			g, err := d.grantBundle(ctx, q, &p, sc.Free[i], freeSource(after.Season, i+1))
			if err != nil {
				return err
			}
			res.Lines = append(res.Lines, g.Lines...)
		}
		for _, i := range royal {
			g, err := d.grantBundle(ctx, q, &p, sc.Royal[i], royalSource(after, i+1))
			if err != nil {
				return err
			}
			res.Lines = append(res.Lines, g.Lines...)
			res.Lines = append(res.Lines, dupeLine(g)...)
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	if res.Season, err = d.GetSeason(ctx, playerID); err != nil {
		return nil, err
	}
	if res.Snapshot, err = d.GetState(ctx, playerID); err != nil {
		return nil, err
	}
	return &res, nil
}

// dupeLine says what a cosmetic already owned paid instead.
func dupeLine(g Granted) []rewards.Line {
	if g.DuplicateDiamonds <= 0 {
		return nil
	}
	return []rewards.Line{{Kind: "diamonds", Amount: g.DuplicateDiamonds, Icon: "diamond",
		Text: rewards.Group(g.DuplicateDiamonds) + " diamonds for what you already owned"}}
}

// OpenCharterWithDiamonds opens the season's royal lane for its price in
// diamonds.
func (d Deps) OpenCharterWithDiamonds(ctx context.Context, playerID uuid.UUID) (*CharterOpened, error) {
	err := db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
		q := sqlcdb.New(tx)
		p, err := q.LockPlayer(ctx, playerID)
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrNotFound
			}
			return fmt.Errorf("lock player: %w", err)
		}
		if p.State == "banned" {
			return ErrPlayerBanned
		}
		now := d.Now()
		s := d.seasonNow(now)
		if s.Number < 1 {
			return ErrNoSeason
		}
		row, err := q.EnsurePlayerSeason(ctx, sqlcdb.EnsurePlayerSeasonParams{PlayerID: p.ID, Season: int32(s.Number), Might: p.Might})
		if err != nil {
			return fmt.Errorf("season row: %w", err)
		}
		if row.RoyalAt != nil {
			return ErrRoyalOpen
		}
		price := d.Config.LiveOps.Season.RoyalDiamonds
		after, err := q.SpendDiamonds(ctx, sqlcdb.SpendDiamondsParams{ID: p.ID, Amount: price})
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrNotEnoughDiamonds
			}
			return fmt.Errorf("pay for the charter: %w", err)
		}
		if err := ledger.Diamonds(ctx, q, p, after, -price, ledger.SeasonUnlock,
			fmt.Sprintf("season:%d", s.Number)); err != nil {
			return err
		}
		if _, err := q.UnlockRoyal(ctx, sqlcdb.UnlockRoyalParams{
			PlayerID: p.ID, Season: int32(s.Number), At: &now,
		}); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrRoyalOpen
			}
			return fmt.Errorf("open the royal lane: %w", err)
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	var out CharterOpened
	if out.Season, err = d.GetSeason(ctx, playerID); err != nil {
		return nil, err
	}
	if out.Snapshot, err = d.GetState(ctx, playerID); err != nil {
		return nil, err
	}
	return &out, nil
}

// deliverCharter is a Royal Charter bought with money: the running season's
// royal lane, opened against the transaction -- or, for a lord whose lane is
// already open, the product's fallback diamonds (money is never refused).
func (d Deps) deliverCharter(ctx context.Context, q *sqlcdb.Queries, p *sqlcdb.AppPlayer,
	pr *gameconfig.Product, transactionID string) ([]rewards.Line, error) {
	now := d.Now()
	s := d.seasonNow(now)
	var row sqlcdb.AppPlayerSeason
	var err error
	if s.Number >= 1 {
		row, err = q.EnsurePlayerSeason(ctx, sqlcdb.EnsurePlayerSeasonParams{PlayerID: p.ID, Season: int32(s.Number), Might: p.Might})
		if err != nil {
			return nil, fmt.Errorf("season row: %w", err)
		}
	}
	if s.Number >= 1 && row.RoyalAt == nil {
		ref := transactionID
		if _, err := q.UnlockRoyal(ctx, sqlcdb.UnlockRoyalParams{
			PlayerID: p.ID, Season: int32(s.Number), At: &now, Ref: &ref,
		}); err != nil {
			return nil, fmt.Errorf("open the royal lane: %w", err)
		}
		return []rewards.Line{{Kind: "charter", Amount: int64(s.Number), Icon: "pass/royal_seal",
			Text: fmt.Sprintf("The royal lane of Season %d's Charter is open", s.Number)}}, nil
	}
	g, err := d.grantBundle(ctx, q, p, gameconfig.RewardBundle{Diamonds: pr.FallbackDiamonds}, GrantSource{
		Diamonds: ledger.Purchase, Gold: "purchase", Ref: transactionID, ItemFrom: "purchase", Paid: true,
	})
	if err != nil {
		return nil, err
	}
	out := []rewards.Line{{Kind: "charter", Icon: "pass/royal_seal",
		Text: "Your royal lane was already open, so the Charter is paid in diamonds"}}
	return append(out, g.Lines...), nil
}

// undoCharter is a refunded Charter: the lane it opened closes, and what its
// royal tiers gave that is still held goes back with it. Diamonds and looks
// were paid against the transaction, so the refund's own sweep finds them;
// the tokens are counted off the lane here.
func (d Deps) undoCharter(ctx context.Context, q *sqlcdb.Queries, p sqlcdb.AppPlayer, transactionID string) error {
	row, err := q.RevokeRoyal(ctx, sqlcdb.RevokeRoyalParams{PlayerID: p.ID, Ref: transactionID})
	if errors.Is(err, pgx.ErrNoRows) {
		return nil // a fallback, or a lane since closed
	}
	if err != nil {
		return fmt.Errorf("close the royal lane: %w", err)
	}
	for token, n := range d.charterTokens(uint64(row.WasClaimed)) {
		if err := q.TakeTokens(ctx, sqlcdb.TakeTokensParams{PlayerID: p.ID, Token: token, Qty: n}); err != nil {
			return fmt.Errorf("take charter tokens: %w", err)
		}
	}
	return nil
}

// charterTokens is what a royal lane's claimed tiers gave in tokens.
func (d Deps) charterTokens(claimed uint64) map[string]int64 {
	out := map[string]int64{}
	for i, b := range d.Config.LiveOps.Season.Royal {
		if claimed&(1<<uint(i)) != 0 {
			for k, v := range b.Tokens {
				out[k] += v
			}
		}
	}
	return out
}

// pointsLines writes out the ways to earn points.
func pointsLines(sources []gameconfig.PointSource) []PointsLine {
	out := make([]PointsLine, 0, len(sources))
	for _, s := range sources {
		out = append(out, PointsLine{Deed: s.Deed, Text: deedPhrase(s.Deed, s.Per), Points: s.Points, Icon: deedIcon(s.Deed)})
	}
	return out
}

// deedWords is each deed as a sentence names it: one, and many.
var deedWords = map[string][2]string{
	"collects":      {"collect", "collects"},
	"energy":        {"energy spent", "energy spent"},
	"xp":            {"experience earned", "experience earned"},
	"raids":         {"raid", "raids"},
	"raid_wins":     {"raid won", "raids won"},
	"revenge_wins":  {"revenge strike won", "revenge strikes won"},
	"defenses_held": {"raid held off", "raids held off"},
	"gold_stolen":   {"gold carried off", "gold carried off"},
	"buys":          {"market buy", "market buys"},
	"shop_gold":     {"gold spent at the market", "gold spent at the market"},
	"sells":         {"piece sold", "pieces sold"},
	"recruits":      {"soldier raised", "soldiers raised"},
	"rerolls":       {"soldier rerolled", "soldiers rerolled"},
	"upgrades":      {"upgrade built", "upgrades built"},
	"holdings":      {"holding bought or raised", "holdings bought or raised"},
	"donated_gold":  {"gold given to your kingdom", "gold given to your kingdom"},
	"stat_spends":   {"stat point spent", "stat points spent"},
	"daily_quests":  {"daily quest finished", "daily quests finished"},
	"daily_claims":  {"day's reward claimed", "days' rewards claimed"},
	"mail_claims":   {"letter opened", "letters opened"},
	"carts_opened":  {"Tax Cart opened", "Tax Carts opened"},
	"weekly_quests": {"weekly quest finished", "weekly quests finished"},
	"golden_hours":  {"Golden Hour lit", "Golden Hours lit"},
	// Rekabet (Wave 5).
	"arena_fights":     {"arena fight", "arena fights"},
	"arena_wins":       {"arena win", "arena wins"},
	"bounties_placed":  {"price set on a head", "prices set on heads"},
	"bounties_claimed": {"price collected", "prices collected"},
	"bounty_gold":      {"gold in prices collected", "gold in prices collected"},
}

// deedPhrase is "Each raid won", or "Every 5 energy spent".
func deedPhrase(deed string, per int64) string {
	w, ok := deedWords[deed]
	if !ok {
		w = [2]string{strings.ReplaceAll(deed, "_", " "), strings.ReplaceAll(deed, "_", " ")}
	}
	if per <= 1 {
		return "Each " + w[0]
	}
	return fmt.Sprintf("Every %s %s", rewards.Group(per), w[1])
}

// deedIcon is the painted quest mark a deed is drawn with.
func deedIcon(deed string) string {
	switch deed {
	case "raids", "raid_wins", "revenge_wins", "defenses_held", "gold_stolen", "recruits", "rerolls",
		"arena_fights", "arena_wins", "bounties_placed", "bounties_claimed", "bounty_gold":
		return "quest_swords"
	case "collects", "energy", "xp", "golden_hours":
		return "quest_bolt"
	}
	return "quest_scroll"
}
