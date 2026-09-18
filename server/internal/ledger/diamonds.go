// Package ledger records currency movements.
//
// It exists as its own package so the game service and the admin service write
// the same rows through the same function. The rows are the audit trail a refund
// reads, the economy dashboard sums and the reconciliation check proves against
// the players table, so there must be exactly one way to write one.
package ledger

import (
	"context"
	"fmt"

	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
)

// Classes group diamond reasons for the economy dashboard. They are the
// ledger table's CHECK constraint, in Go.
const (
	ClassEarned    = "earned"    // given by play: levels, the calendar, rewards
	ClassPurchased = "purchased" // bought with real money
	ClassSpent     = "spent"     // spent by the player
	ClassAdmin     = "admin"     // granted or removed from the panel
	ClassRefund    = "refund"    // taken back (or restored) by a refund
	ClassOpening   = "opening"   // the balance that existed before the ledger did
)

// Reason is why diamonds moved.
type Reason struct {
	Name  string
	Class string
}

// Every reason diamonds move for. New ones are added here, never inline, so the
// dashboard's list of flows is this list.
var (
	LevelUp      = Reason{"levelup", ClassEarned}
	DailyLogin   = Reason{"daily_login", ClassEarned}
	Mail         = Reason{"mail", ClassEarned}
	Reward       = Reason{"reward", ClassEarned}
	CosmeticDupe = Reason{"cosmetic_duplicate", ClassEarned}

	EnergyRefill = Reason{"energy_refill", ClassSpent}
	Shield       = Reason{"shield", ClassSpent}
	MarketReroll = Reason{"market_reroll", ClassSpent}
	Rename       = Reason{"rename", ClassSpent}

	AdminGrant  = Reason{"admin_grant", ClassAdmin}
	AdminRemove = Reason{"admin_remove", ClassAdmin}
	// A refund debt the billing desk forgave: credited whole to the debt,
	// nothing to the purse (delta 0, gross the debt).
	DebtForgiven = Reason{"debt_forgiven", ClassAdmin}

	// Bought with money. Every row answers to its App Store transaction (ref),
	// so a refund finds all a purchase gave: the pack, the stipend's daily
	// shares, a patronage period's diamonds, a fallback for a cosmetic owned.
	Purchase  = Reason{"purchase", ClassPurchased}
	Stipend   = Reason{"stipend", ClassPurchased}
	Patronage = Reason{"patronage", ClassPurchased}
	// A refund takes back what its purchase gave; a reversed refund returns it.
	Refund         = Reason{"refund", ClassRefund}
	RefundReversed = Reason{"refund_reversed", ClassRefund}

	VIPGift  = Reason{"vip_gift", ClassEarned}
	Cosmetic = Reason{"cosmetic", ClassSpent}
	// The Royal Store's daily deals: the free gift's diamonds, and what a deal costs.
	DailyGift = Reason{"daily_gift", ClassEarned}
	Deal      = Reason{"deal", ClassSpent}

	// The daily loop (retention.json): a Tax Cart's diamonds, the week's quests
	// and chests, the Victory Road, the guide's finish -- and what mending a
	// broken calendar run costs.
	Cart            = Reason{"cart", ClassEarned}
	Weekly          = Reason{"weekly", ClassEarned}
	Road            = Reason{"road", ClassEarned}
	Guide           = Reason{"guide", ClassEarned}
	CalendarRestore = Reason{"calendar_restore", ClassSpent}

	// Live ops (liveops.json): the Royal Courier's gift, a festival's tasks and
	// milestones, the Royal Charter's lanes, the deeds' tiers -- and what
	// opening the Charter's royal lane with diamonds costs. The royal lane of a
	// Charter bought with money pays as the purchase (SeasonRoyalPaid, against
	// its transaction), so a refund finds everything it gave.
	Hourly          = Reason{"hourly", ClassEarned}
	Festival        = Reason{"festival", ClassEarned}
	Season          = Reason{"season", ClassEarned}
	SeasonRoyalPaid = Reason{"season_royal", ClassPurchased}
	SeasonUnlock    = Reason{"season_unlock", ClassSpent}
	Achievement     = Reason{"achievement", ClassEarned}

	// Rekabet (Wave 5): the arena's rating milestones and the Throne's letters.
	// Both are earned; neither can be bought, and validate_pvp.go refuses a
	// paid bundle anywhere in pvp.json.
	Arena  = Reason{"arena", ClassEarned}
	Throne = Reason{"throne", ClassEarned}

	// Sosyal (Wave 6): the kingdom's aid and its shared goal. Both are earned;
	// neither can be bought, and validate_social.go refuses a paid bundle
	// anywhere in social.json. Aid is also the SOURCE written on the two boost
	// rows a stack is made of, which is how the stacks are counted.
	Aid  = Reason{"aid", ClassEarned}
	Goal = Reason{"goal", ClassEarned}

	// Herald's Tidings: a watched advert. EARNED, because nothing left the
	// lord's pocket -- what they paid with was their attention, and the house
	// was paid by the advertiser. It is its own flow on the dashboard so the
	// advert's diamonds can be told from the calendar's.
	Advert = Reason{"advert", ClassEarned}
)

// Diamonds writes one ledger row for a change the caller has already made.
//
// before and after are the player row either side of the statement that moved
// the balance, so the row records exactly what the balance did (delta) and the
// debt it left (debt_after). gross is what was earned or spent before any refund
// debt was repaid from it: for a spend it is the negative price; for a credit it
// is the whole grant, even the part that went to the debt, because a refund of
// that grant must be able to see all of it.
//
// A movement of nothing writes nothing.
func Diamonds(ctx context.Context, q *sqlcdb.Queries, before, after sqlcdb.AppPlayer,
	gross int64, r Reason, ref string) error {
	delta := after.Diamonds - before.Diamonds
	if delta == 0 && gross == 0 {
		return nil
	}
	var refID *string
	if ref != "" {
		refID = &ref
	}
	if err := q.RecordDiamonds(ctx, sqlcdb.RecordDiamondsParams{
		PlayerID: after.ID, Delta: delta, Gross: gross,
		BalanceAfter: after.Diamonds, DebtAfter: after.DiamondDebt,
		Reason: r.Name, Class: r.Class, RefID: refID,
	}); err != nil {
		return fmt.Errorf("diamond ledger (%s): %w", r.Name, err)
	}
	return nil
}
