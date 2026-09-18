package service

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
	"github.com/yigitkarabulut0/emperors/server/internal/game/economy"
	"github.com/yigitkarabulut0/emperors/server/internal/game/estates"
	"github.com/yigitkarabulut0/emperors/server/internal/game/items"
	"github.com/yigitkarabulut0/emperors/server/internal/game/rewards"
	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
	"github.com/yigitkarabulut0/emperors/server/internal/ledger"
)

// ErrRewardInvalid is a reward that breaks the rules: an unknown token, a
// number over its limit, gold in something money buys.
var ErrRewardInvalid = errors.New("that reward cannot be delivered")

// GrantSource is why a reward is being paid.
type GrantSource struct {
	// Why diamonds moved, for the diamond ledger.
	Diamonds ledger.Reason
	// Why gold moved, for the gold ledger.
	Gold string
	// What the grant answers to -- a letter, a transaction, a day -- written on
	// every ledger row it makes and used to seed the gear it rolls.
	Ref string
	// player_items.acquired_from for any gear it grants.
	ItemFrom string
	// Bought with real money: the FAIR rules are checked again here, whatever
	// the product definition claimed.
	Paid bool
	// For cosmetics held for a season or a reign; nil is forever.
	CosmeticExpires *time.Time
	// What a cosmetic already owned pays instead, when set: a purchase's
	// fallback_diamonds, ledgered against the purchase (so a refund finds it)
	// rather than as the cosmetic's own duplicate value.
	DupeDiamonds int64
}

// Granted is what a reward actually gave.
type Granted struct {
	Diamonds int64 `json:"diamonds,omitempty"`
	// The part of Diamonds that went to repay a refund debt.
	DebtRepaid   int64 `json:"debt_repaid,omitempty"`
	Gold         int64 `json:"gold,omitempty"`
	XP           int64 `json:"xp,omitempty"`
	LevelsGained int   `json:"levels_gained,omitempty"`
	// Diamonds a level reached by this reward paid.
	LevelDiamonds int64            `json:"level_diamonds,omitempty"`
	Tokens        map[string]int64 `json:"tokens,omitempty"`
	Items         []items.Instance `json:"items,omitempty"`
	Cosmetics     []string         `json:"cosmetics,omitempty"`
	// Diamonds paid for cosmetics the player already owned.
	DuplicateDiamonds int64          `json:"duplicate_diamonds,omitempty"`
	Lines             []rewards.Line `json:"lines"`
}

// grantBundle pays a reward. Every system that pays a player pays through here.
//
// The caller holds the player's row lock (LockPlayer) and passes the Queries of
// its transaction; the grant is all-or-nothing inside it. It never touches
// action_seq: a sequenced caller advances it in its own statement, and an
// asynchronous one (a letter, a purchase) must not, or it would silently drop
// the collects the client has queued.
//
// *p is kept current, so the caller sees the row as the grant left it.
func (d Deps) grantBundle(ctx context.Context, q *sqlcdb.Queries, p *sqlcdb.AppPlayer,
	b gameconfig.RewardBundle, src GrantSource) (Granted, error) {
	g := Granted{Lines: []rewards.Line{}}
	if problems := d.Config.CheckReward(b, src.Paid); len(problems) > 0 {
		return g, fmt.Errorf("%w: %s", ErrRewardInvalid, strings.Join(problems, "; "))
	}
	now := d.Now()
	eff, err := d.loadEffects(ctx, q, *p)
	if err != nil {
		return g, err
	}
	res := rewards.Resolve(d.Config, b, int(p.Level), eff.Bonuses)

	// The armory is checked before anything is written: a reward whose gear has
	// nowhere to go is refused whole, never half-paid.
	if n := rewards.ItemCount(b); n > 0 {
		used, err := q.CountPlayerItems(ctx, p.ID)
		if err != nil {
			return g, fmt.Errorf("count items: %w", err)
		}
		if used+n > d.bagCap(*p) {
			return g, ErrInventoryFull
		}
	}

	if b.Diamonds > 0 {
		after, err := q.CreditDiamonds(ctx, sqlcdb.CreditDiamondsParams{ID: p.ID, Amount: b.Diamonds})
		if err != nil {
			return g, fmt.Errorf("credit diamonds: %w", err)
		}
		if err := ledger.Diamonds(ctx, q, *p, after, b.Diamonds, src.Diamonds, src.Ref); err != nil {
			return g, err
		}
		g.Diamonds = b.Diamonds
		g.DebtRepaid = b.Diamonds - (after.Diamonds - p.Diamonds)
		*p = after
	}

	if res.Gold > 0 || res.XP > 0 {
		// A reward is worth what it is worth at any hour: its experience goes
		// through the XP bucket's permanent lane, as its gold did in Resolve.
		up, err := d.creditGoldXP(ctx, q, p, rewards.PermanentOnly(eff.Bonuses), eff,
			res.Gold, res.XP, p.ActionSeq, src.Gold, src.Ref, now)
		if err != nil {
			return g, err
		}
		g.Gold = res.Gold
		g.XP = economy.ApplyBucket(res.XP, rewards.PermanentOnly(eff.Bonuses), economy.BucketXPGain)
		g.LevelsGained = up.LevelsGained
		g.LevelDiamonds = up.Diamonds
	}

	if b.Favour > 0 {
		after, err := q.CreditFavour(ctx, sqlcdb.CreditFavourParams{ID: p.ID, Favour: b.Favour})
		if err != nil {
			return g, fmt.Errorf("credit favour: %w", err)
		}
		*p = after
	}

	for id, n := range b.Tokens {
		if _, err := q.UpsertToken(ctx, sqlcdb.UpsertTokenParams{PlayerID: p.ID, Token: id, Qty: n}); err != nil {
			return g, fmt.Errorf("token %s: %w", id, err)
		}
		if g.Tokens == nil {
			g.Tokens = map[string]int64{}
		}
		g.Tokens[id] += n
	}

	for _, id := range b.Cosmetics {
		c := d.Config.Cosmetic(id)
		_, err := q.InsertCosmetic(ctx, sqlcdb.InsertCosmeticParams{
			PlayerID: p.ID, CosmeticID: id, Source: src.Diamonds.Name,
			SourceRef: nilIfEmpty(src.Ref), ExpiresAt: src.CosmeticExpires,
		})
		if err == nil {
			g.Cosmetics = append(g.Cosmetics, id)
			continue
		}
		if !errors.Is(err, pgx.ErrNoRows) {
			return g, fmt.Errorf("cosmetic %s: %w", id, err)
		}
		// Already owned. A duplicate is paid in diamonds, never nothing.
		dupe, reason, ref := int64(0), ledger.CosmeticDupe, id
		if c != nil {
			dupe = c.DupeDiamonds
		}
		if src.DupeDiamonds > 0 {
			dupe, reason, ref = src.DupeDiamonds, src.Diamonds, src.Ref
		}
		if dupe > 0 {
			after, err := q.CreditDiamonds(ctx, sqlcdb.CreditDiamondsParams{ID: p.ID, Amount: dupe})
			if err != nil {
				return g, fmt.Errorf("duplicate cosmetic: %w", err)
			}
			if err := ledger.Diamonds(ctx, q, *p, after, dupe, reason, ref); err != nil {
				return g, err
			}
			g.DuplicateDiamonds += dupe
			*p = after
		}
	}

	for _, bg := range b.Boosts {
		until := now.Add(time.Duration(bg.Hours) * time.Hour)
		if _, err := q.InsertPlayerBoost(ctx, sqlcdb.InsertPlayerBoostParams{
			PlayerID: p.ID, Bucket: bg.Bucket, AmountBp: int32(bg.BP),
			StartsAt: now, ExpiresAt: until, Source: src.Diamonds.Name, SourceRef: nilIfEmpty(src.Ref),
		}); err != nil {
			return g, fmt.Errorf("boost: %w", err)
		}
		if err := q.ExtendBoostUntil(ctx, sqlcdb.ExtendBoostUntilParams{ID: p.ID, Until: until}); err != nil {
			return g, fmt.Errorf("boost marker: %w", err)
		}
	}

	if len(b.Items) > 0 {
		// Seeded by the lord as well as the ref: a ref names a reward (the fifth
		// cart, a day's square) that many lords are paid, and each must roll
		// their own gear.
		rolled := rewards.Items(d.Config, d.ShopSecret, p.ID.String()+"|"+src.Ref, int64(p.Level), eff.LuckBP, b.Items)
		for _, it := range rolled {
			if _, err := q.InsertPlayerItem(ctx, sqlcdb.InsertPlayerItemParams{
				PlayerID: p.ID, DefID: it.DefID, Slot: it.Slot, Tier: it.Tier,
				Ilvl: int32(it.Ilvl), QualityPct: int32(it.QualityPct), Masterwork: it.Masterwork,
				Attack: it.Attack, Defense: it.Defense, Speed: it.Speed,
				AcquiredFrom: src.ItemFrom, RolledConfigVersion: int32(d.Config.Version),
			}); err != nil {
				return g, fmt.Errorf("grant item: %w", err)
			}
			g.Items = append(g.Items, it)
		}
	}

	g.Lines = rewards.RolledLines(d.Config, rewards.Lines(d.Config, b, res), g.Items)
	return g, nil
}

// creditGoldXP credits gold and experience through the one statement every
// level-up goes through, so a level reached from a letter, a quest or a raid
// pays what a level reached anywhere pays: stat points, diamonds, and a pool
// refilled to the NEW level's maximum.
//
// seq is the action_seq to leave on the row: the caller's for a sequenced
// action, the row's own for an asynchronous grant.
func (d Deps) creditGoldXP(ctx context.Context, q *sqlcdb.Queries, p *sqlcdb.AppPlayer,
	bonuses economy.Bonuses, eff estates.Effects, gold, xp, seq int64,
	goldReason, ref string, now time.Time) (economy.LevelUp, error) {

	up := economy.AwardXP(d.Config, int(p.Level), p.Xp, xp, bonuses)
	energyMilli, energyAt := p.EnergyMilli, p.EnergyUpdatedAt
	if up.Refilled {
		full := economy.Refill(levelUpMax(d.Config, *p, up, eff), now)
		energyMilli, energyAt = full.Milli, full.UpdatedAt
	}
	after, err := q.ApplyCollect(ctx, sqlcdb.ApplyCollectParams{
		ID: p.ID, EnergyMilli: energyMilli, EnergyUpdatedAt: energyAt,
		Gold: gold, Xp: up.XP, Level: int32(up.Level),
		StatPointsUnspent: int32(up.StatPoints), Diamonds: up.Diamonds,
		ActionSeq: seq,
	})
	if err != nil {
		return up, fmt.Errorf("credit gold and experience: %w", err)
	}
	if gold > 0 {
		if err := q.RecordGold(ctx, sqlcdb.RecordGoldParams{
			PlayerID: p.ID, Delta: gold, BalanceAfter: after.Gold,
			Reason: goldReason, RefID: nilIfEmpty(ref),
		}); err != nil {
			return up, fmt.Errorf("record gold: %w", err)
		}
	}
	if err := ledger.Diamonds(ctx, q, *p, after, up.Diamonds, ledger.LevelUp,
		levelRef(p.Level, up.Level)); err != nil {
		return up, err
	}
	*p = after
	return up, nil
}

// levelUpMax is the pool a level-up refills to: the maximum at the level just
// reached, not the one just left.
//
// The single collect and the raid refilled to the old level's maximum while the
// batch refilled to the new one, so the same level-up left a player four energy
// short depending on which route their last tap took.
func levelUpMax(cfg *gameconfig.Bundle, p sqlcdb.AppPlayer, up economy.LevelUp, eff estates.Effects) int64 {
	return economy.MaxEnergy(cfg, int64(up.Level), int64(p.StatEnergy), eff.MaxEnergyFlat)
}

func nilIfEmpty(s string) *string {
	if s == "" {
		return nil
	}
	return &s
}
