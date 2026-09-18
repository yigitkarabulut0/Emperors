package service

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/yigitkarabulut0/emperors/server/internal/db"
	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
	"github.com/yigitkarabulut0/emperors/server/internal/game/deeds"
	"github.com/yigitkarabulut0/emperors/server/internal/game/economy"
	"github.com/yigitkarabulut0/emperors/server/internal/game/estates"
	"github.com/yigitkarabulut0/emperors/server/internal/game/items"
	"github.com/yigitkarabulut0/emperors/server/internal/game/talents"
	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
)

var (
	ErrUpgradeMaxed = errors.New("already at maximum level")
)

// loadEffects reads a player's Family upgrades and Territory holdings and folds
// them into their effects.
//
// One extra query on the hot path, deliberately: caching the derived numbers on
// the player row would mean a balance republish silently leaving every player on
// the old bonuses until something happened to touch them.
func (d Deps) loadEffects(ctx context.Context, q *sqlcdb.Queries, p sqlcdb.AppPlayer) (estates.Effects, error) {
	ups, err := q.ListUpgrades(ctx, p.ID)
	if err != nil {
		return estates.Effects{}, fmt.Errorf("list upgrades: %w", err)
	}
	holds, err := q.ListHoldings(ctx, p.ID)
	if err != nil {
		return estates.Effects{}, fmt.Errorf("list holdings: %w", err)
	}

	upLevels := make(map[string]int, len(ups))
	for _, u := range ups {
		upLevels[u.UpgradeID] = int(u.Level)
	}
	holdLevels := make(map[string]int, len(holds))
	for _, h := range holds {
		holdLevels[h.HoldingID] = int(h.Level)
	}
	eff := estates.Derive(d.Config, int64(p.Level), upLevels, holdLevels)

	// A kingdom's upgrades apply to every member, so they belong in the same
	// effects the rest of the game reads.
	if p.KingdomID != nil {
		kups, err := q.ListKingdomUpgrades(ctx, *p.KingdomID)
		if err != nil {
			return estates.Effects{}, fmt.Errorf("kingdom upgrades: %w", err)
		}
		kLevels := make(map[string]int, len(kups))
		for _, k := range kups {
			kLevels[k.UpgradeID] = int(k.Level)
		}
		estates.ApplyKingdom(d.Config, &eff, int64(p.Level), kLevels, holdLevels)
	}

	// The talent tree feeds the SAME buckets the Family's upgrades do, folded in
	// exactly here, in the permanent lane, under the same caps (talents.Apply).
	// A talent that applied its percentage anywhere else would be the second
	// multiplication site the bucket rule exists to forbid.
	if int(p.Level) >= d.Config.SectionLevel(d.Config.Talents.Section) || p.Legacy > 0 {
		spend, err := d.loadTalents(ctx, q, p.ID)
		if err != nil {
			return estates.Effects{}, err
		}
		if len(spend) > 0 {
			talents.Apply(d.Config, &eff, int64(p.Level), holdLevels, spend)
		}
	}

	// Server-wide events are timed, so they feed each bucket's TEMPORARY lane.
	// It has its own ceiling, which is what makes them safe and what makes them
	// work: an event can never push a payout past a number the engine can write
	// down, and it still reaches a lord whose permanent bonuses already sit at
	// the cap -- in the permanent lane it gave that lord nothing. ApplyBucket
	// stays the single place a percentage is applied.
	for bucket, bp := range d.Boosts.Get() {
		if IsBoostable(bucket) {
			addLiveBonus(&eff, bucket, bp)
		}
	}

	// The hour's event and the festival running are server-wide and timed too,
	// and ride the same lanes (liveops.go).
	now := d.Now()
	if h := d.runningHourly(now, gameconfig.HourlyBoost); h != nil {
		addLiveBonus(&eff, h.Event.Effect.Bucket, h.Event.Effect.BP)
	}
	if f := d.festivalAt(now); f != nil {
		addLiveBonus(&eff, f.Tpl.Effect.Bucket, f.Tpl.Effect.BP)
	}
	// The Throne's edict (throne.go), read off the same poll and filed on the
	// same lanes. It reaches the whole realm, so the check is who the balance
	// says it reaches and not which kingdom this lord belongs to.
	if dec := d.Boosts.Decree(); dec != nil && dec.EndsAt.After(now) && d.decreeReaches(dec, p) {
		if dc := d.Config.PvP.Throne.Decree(dec.ID); dc != nil {
			addLiveBonus(&eff, dc.Bucket, dc.BP)
		}
	}

	// The admin override ADDS to whatever the config granted, and the sum is
	// clamped exactly once, here. Keeping it out of estates.Derive is what lets
	// internal/game stay pure and unaware of the database, while still giving
	// live-ops a per-player knob.
	//
	// An expiry in the past is simply not applied -- no sweeper, no job, and no
	// window where a lapsed override is still live because nothing ran.
	if p.LuckBp != 0 && (p.LuckExpiresAt == nil || p.LuckExpiresAt.After(d.Now())) {
		eff.LuckBP += int64(p.LuckBp)
	}

	// A Kingdom Shop draught expires, so it rides the xp bucket's temporary lane
	// alongside any live event, and that lane's cap is applied once by
	// ApplyBucket. Buying one can lift a player toward the timed ceiling, never
	// past it -- and it still works for a scholar whose Scriptorium and Archives
	// already fill the permanent lane.
	if p.XpBoostBp != 0 && (p.XpBoostExpiresAt == nil || p.XpBoostExpiresAt.After(d.Now())) {
		eff.Bonuses.AddTemp(economy.BucketXPGain, int64(p.XpBoostBp))
	}
	// A timed bonus this lord was GIVEN -- a welcome back, a reward -- rides the
	// timed lane like a server event. The player row's boost_until says whether
	// one can still be live, so the table is read only then: this is the hot
	// path, run before every action.
	if p.BoostUntil != nil && p.BoostUntil.After(d.Now()) {
		boosts, err := q.ListLiveBoosts(ctx, sqlcdb.ListLiveBoostsParams{PlayerID: p.ID, Now: d.Now()})
		if err != nil {
			return estates.Effects{}, fmt.Errorf("player boosts: %w", err)
		}
		for _, b := range boosts {
			switch b.Bucket {
			case gameconfig.BucketCollectIncome:
				eff.Bonuses.AddTemp(economy.BucketCollectIncome, int64(b.AmountBp))
			case gameconfig.BucketXP:
				eff.Bonuses.AddTemp(economy.BucketXPGain, int64(b.AmountBp))
			case gameconfig.BucketLuck:
				// A Tax Cart's Lucky Charm: into the luck total, clamped with
				// the rest of it below.
				eff.LuckBP += int64(b.AmountBp)
			}
		}
	}

	// Legacy stacks lift income, and they lift it through the SAME capped
	// buckets as everything else — so ten runs move a player toward a ceiling
	// the family tree could already reach rather than past it. A terminal sink
	// that inflated the economy would not be a sink.
	if p.Legacy > 0 {
		bp := int64(p.Legacy) * d.Config.Progression.Legacy.IncomeBPPerStack
		eff.Bonuses.Add(economy.BucketCollectIncome, bp)
		eff.TaxIncomeBP += bp
		eff.TaxMilliPerHour = estates.TaxRate(d.Config, int64(p.Level), holdLevels, eff.TaxIncomeBP)
	}

	// The Collection tilts rolls, which is what loops the reward back into the
	// thing being rewarded: a broader wall makes better drops, which makes more
	// to collect. It ADDS into the same luck total as everything else and is
	// clamped once, below, so the whole board cannot push past a ceiling the
	// game's own upgrades could already reach.
	if ids, err := q.ListCollection(ctx, p.ID); err == nil && len(ids) > 0 {
		held := make(map[string]bool, len(ids))
		for _, id := range ids {
			held[id] = true
		}
		eff.LuckBP += collectionLuck(d.Config, held)
	}
	eff.LuckBP = items.ClampLuckBP(eff.LuckBP)
	return eff, nil
}

// EstatesView is the Keep tab (upgrades) and the Map tab (holdings).
// The navigation sections that open the Family upgrades and the vault.
const (
	estatesSection = "estates"
	bankSection    = "bank"
)

type EstatesView struct {
	Upgrades []UpgradeView `json:"upgrades"`
	Holdings []HoldingView `json:"holdings"`
	Tax      TaxView       `json:"tax"`
	// The Family upgrades open with the estates section, and the vault with the
	// bank. The screen showed both from level 1 with working buttons.
	UpgradesUnlockLevel int          `json:"upgrades_unlock_level"`
	UpgradesUnlocked    bool         `json:"upgrades_unlocked"`
	Treasury            TreasuryView `json:"treasury"`
}

// TreasuryView is the vault's card: what is in it, what a deposit costs, and
// whether it is open yet. The fee was written into the client as "10%".
type TreasuryView struct {
	Vault        string `json:"vault"`
	DepositFeeBP int64  `json:"deposit_fee_bp"`
	UnlockLevel  int    `json:"unlock_level"`
	Unlocked     bool   `json:"unlocked"`
}

type UpgradeView struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	Blurb    string `json:"blurb"`
	Bucket   string `json:"bucket"`
	Level    int    `json:"level"`
	MaxLevel int    `json:"max_level"`
	PerLevel int64  `json:"per_level"`
	NextCost int64  `json:"next_cost"`
	Maxed    bool   `json:"maxed"`
	Effect   int64  `json:"effect_now"`
	// What the upgrade gives after the next level, so the card can say what the
	// price buys. Zero when maxed.
	EffectNext int64 `json:"effect_next"`
}

type HoldingView struct {
	ID           string `json:"id"`
	Name         string `json:"name"`
	Level        int    `json:"level"`
	MaxLevel     int    `json:"max_level"`
	UnlockLevel  int    `json:"unlock_level"`
	Unlocked     bool   `json:"unlocked"`
	NextCost     int64  `json:"next_cost"`
	Maxed        bool   `json:"maxed"`
	YieldPerHour int64  `json:"yield_per_hour_milli"`
	// What ONE more level is worth, which is the number the player is actually
	// deciding on. YieldPerHour is the holding's current total, so at level 0 --
	// the state every holding starts in and most stayed in -- it is zero, and the
	// row could only offer a price with nothing to weigh it against.
	YieldPerLevel int64 `json:"yield_per_level_milli"`
}

// TaxView is what the Family tab shows about idle income.
//
// Presented per HOUR, never per second: 0.23 gold a second reads as nothing.
// TaxView is the estates' income, which now arrives continuously.
//
// There is no Pending any more, and no cap: the middleware credits the purse on
// every request, so what used to be "waiting to be collected" is at most the
// sub-gold remainder. PerHourMilli is what the client needs to tick the number
// up between requests.
type TaxView struct {
	PerHourMilli int64 `json:"per_hour_milli"`
}

func (d Deps) GetEstates(ctx context.Context, playerID uuid.UUID) (*EstatesView, error) {
	q := sqlcdb.New(d.Pool)
	p, err := q.GetPlayerByID(ctx, playerID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, fmt.Errorf("load player: %w", err)
	}

	ups, err := q.ListUpgrades(ctx, playerID)
	if err != nil {
		return nil, fmt.Errorf("list upgrades: %w", err)
	}
	holds, err := q.ListHoldings(ctx, playerID)
	if err != nil {
		return nil, fmt.Errorf("list holdings: %w", err)
	}
	upLevels := map[string]int{}
	for _, u := range ups {
		upLevels[u.UpgradeID] = int(u.Level)
	}
	holdLevels := map[string]int{}
	for _, h := range holds {
		holdLevels[h.HoldingID] = int(h.Level)
	}
	// loadEffects, not a bare Derive.
	//
	// Derive knows about this player's own upgrades and holdings and nothing
	// else, so the rate this screen printed silently dropped a kingdom's Royal
	// Treasury, any live server event, and — once it existed — the Legacy bonus.
	// The rate a player is actually PAID has always come from loadEffects (see
	// state.go), so this was the screen disagreeing with the purse rather than
	// the purse being wrong, which is arguably worse: the number was there to be
	// trusted.
	eff, err := d.loadEffects(ctx, q, p)
	if err != nil {
		return nil, err
	}

	upAt := d.Config.SectionLevel(estatesSection)
	bankAt := d.Config.SectionLevel(bankSection)
	view := &EstatesView{
		Upgrades:            make([]UpgradeView, 0, len(d.Config.Estates.Upgrades)),
		Holdings:            make([]HoldingView, 0, len(d.Config.Estates.Holdings)),
		UpgradesUnlockLevel: upAt,
		UpgradesUnlocked:    int(p.Level) >= upAt,
		Treasury: TreasuryView{
			Vault:        itoa(p.TreasuryGold),
			DepositFeeBP: d.Config.Progression.Treasury.DepositFeeBP,
			UnlockLevel:  bankAt,
			Unlocked:     int(p.Level) >= bankAt,
		},
	}
	for _, u := range d.Config.Estates.Upgrades {
		lv := upLevels[u.ID]
		cost, ok := u.Cost(lv)
		var next int64
		if ok {
			next = u.PerLevel * int64(lv+1)
		}
		view.Upgrades = append(view.Upgrades, UpgradeView{
			ID: u.ID, Name: u.Name, Blurb: u.Blurb, Bucket: u.Bucket,
			Level: lv, MaxLevel: u.MaxLevel, PerLevel: u.PerLevel,
			NextCost: cost, Maxed: !ok, Effect: u.PerLevel * int64(lv),
			EffectNext: next,
		})
	}
	for _, h := range d.Config.Estates.Holdings {
		lv := holdLevels[h.ID]
		cost, ok := h.Cost(lv)
		view.Holdings = append(view.Holdings, HoldingView{
			ID: h.ID, Name: h.Name, Level: lv, MaxLevel: h.MaxLevel,
			UnlockLevel: h.UnlockLevel, Unlocked: int(p.Level) >= h.UnlockLevel,
			NextCost: cost, Maxed: !ok,
			YieldPerHour:  h.TaxMilliPerHourPerLevel * int64(lv),
			YieldPerLevel: h.TaxMilliPerHourPerLevel,
		})
	}

	view.Tax = TaxView{PerHourMilli: eff.TaxMilliPerHour}
	return view, nil
}

// BuyUpgrade advances one Family upgrade by a level.
func (d Deps) BuyUpgrade(ctx context.Context, playerID uuid.UUID, upgradeID string, wantSeq int64) (*EstatesView, error) {
	u := d.Config.Upgrade(upgradeID)
	if u == nil {
		return nil, ErrNotFound
	}
	// Read outside the purchase's transaction: a level only falls through a
	// Legacy, which is its own transaction, so the worst race is a refusal a
	// moment early.
	if p, err := sqlcdb.New(d.Pool).GetPlayerByID(ctx, playerID); err == nil {
		if at := d.Config.SectionLevel(estatesSection); int(p.Level) < at {
			return nil, fmt.Errorf("%w: the estates open at level %d", ErrLevelTooLow, at)
		}
	}
	if err := d.buyLevel(ctx, playerID, wantSeq, func(q *sqlcdb.Queries, level int) (int64, error) {
		cost, ok := u.Cost(level)
		if !ok {
			return 0, ErrUpgradeMaxed
		}
		return cost, nil
	}, func(ctx context.Context, q *sqlcdb.Queries, level int) error {
		_, err := q.BuyUpgradeLevel(ctx, sqlcdb.BuyUpgradeLevelParams{
			PlayerID: playerID, UpgradeID: upgradeID, Level: int32(level),
		})
		return err
	}, func(ctx context.Context, q *sqlcdb.Queries) (int, error) {
		rows, err := q.ListUpgrades(ctx, playerID)
		if err != nil {
			return 0, err
		}
		for _, r := range rows {
			if r.UpgradeID == upgradeID {
				return int(r.Level), nil
			}
		}
		return 0, nil
	}, "family_upgrade:"+upgradeID); err != nil {
		return nil, err
	}
	return d.GetEstates(ctx, playerID)
}

// BuyHolding advances one Territory holding by a level.
func (d Deps) BuyHolding(ctx context.Context, playerID uuid.UUID, holdingID string, wantSeq int64) (*EstatesView, error) {
	h := d.Config.Holding(holdingID)
	if h == nil {
		return nil, ErrNotFound
	}

	// The unlock gate was missing entirely: a level-1 player could buy a holding
	// meant for level 55 simply by affording it, skipping the whole progression.
	q0 := sqlcdb.New(d.Pool)
	owner, err := q0.GetPlayerByID(ctx, playerID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, fmt.Errorf("load player: %w", err)
	}
	if int(owner.Level) < h.UnlockLevel {
		return nil, fmt.Errorf("%w: %s unlocks at level %d", ErrLevelTooLow, h.Name, h.UnlockLevel)
	}

	if err := d.buyLevel(ctx, playerID, wantSeq, func(q *sqlcdb.Queries, level int) (int64, error) {
		cost, ok := h.Cost(level)
		if !ok {
			return 0, ErrUpgradeMaxed
		}
		return cost, nil
	}, func(ctx context.Context, q *sqlcdb.Queries, level int) error {
		_, err := q.BuyHoldingLevel(ctx, sqlcdb.BuyHoldingLevelParams{
			PlayerID: playerID, HoldingID: holdingID, Level: int32(level),
		})
		return err
	}, func(ctx context.Context, q *sqlcdb.Queries) (int, error) {
		rows, err := q.ListHoldings(ctx, playerID)
		if err != nil {
			return 0, err
		}
		for _, r := range rows {
			if r.HoldingID == holdingID {
				return int(r.Level), nil
			}
		}
		return 0, nil
	}, "holding:"+holdingID); err != nil {
		return nil, err
	}
	return d.GetEstates(ctx, playerID)
}

// buyLevel is the shared transaction for both trees.
func (d Deps) buyLevel(
	ctx context.Context, playerID uuid.UUID, wantSeq int64,
	price func(*sqlcdb.Queries, int) (int64, error),
	apply func(context.Context, *sqlcdb.Queries, int) error,
	current func(context.Context, *sqlcdb.Queries) (int, error),
	reason string,
) error {
	return db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
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

		level, err := current(ctx, q)
		if err != nil {
			return err
		}
		cost, err := price(q, level)
		if err != nil {
			return err
		}

		after, err := q.SpendGold(ctx, sqlcdb.SpendGoldParams{
			ID: playerID, Gold: cost, ActionSeq: wantSeq,
		})
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrNotEnoughGold
			}
			return fmt.Errorf("spend gold: %w", err)
		}
		if err := apply(ctx, q, level); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				// The level moved under us, so the price we charged was for a
				// different level. Roll back rather than sell the wrong thing.
				return ErrStaleAction
			}
			return fmt.Errorf("apply level: %w", err)
		}
		if err := q.RecordGold(ctx, sqlcdb.RecordGoldParams{
			PlayerID: playerID, Delta: -cost, BalanceAfter: after.Gold,
			Reason: reason, RefID: nil,
		}); err != nil {
			return err
		}
		kind := deeds.Upgrades
		if strings.HasPrefix(reason, "holding") {
			kind = deeds.Holdings
		}
		d.recordDeeds(ctx, tx, p, deeds.Deeds{kind: 1})
		return nil
	})
}

// addLiveBonus files a server-wide timed bonus -- the hour's event, a
// festival -- where its bucket's timed bonuses go. Gold and experience ride the
// timed lanes (ApplyBucket applies them, once, under the timed cap); luck is
// summed and clamped with the rest of it; renown and the market's discount
// join their totals, each already bounded where it is spent (the kingdom's
// daily renown cap, MaxDiscountBP).
func addLiveBonus(eff *estates.Effects, bucket string, bp int64) {
	switch bucket {
	case gameconfig.BucketCollectIncome:
		eff.Bonuses.AddTemp(economy.BucketCollectIncome, bp)
	case gameconfig.BucketXP:
		eff.Bonuses.AddTemp(economy.BucketXPGain, bp)
	case gameconfig.BucketLuck:
		eff.LuckBP += bp
	case gameconfig.BucketReputation:
		eff.ReputationBP += bp
	case gameconfig.BucketShopDiscount:
		eff.ShopDiscount += bp
	}
}
