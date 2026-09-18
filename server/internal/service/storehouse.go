package service

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/yigitkarabulut0/emperors/server/internal/db"
	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
	"github.com/yigitkarabulut0/emperors/server/internal/game/estates"
)

// The storehouse (migration 00040). Estate income fills it at the hourly rate,
// up to 8 hours of it -- 12 minutes more for each Tithe Barn level -- and waits
// there, out of a raider's reach, until the lord carries it in: to the purse,
// or straight to the vault less the deposit fee. Time past the capacity is
// lost, which is the reason to come back.
//
// It replaced CreditTax, which paid the purse on every request, uncapped. Two
// things that made: a purse that grew while its lord was away, for raiders to
// take; and a database write on every request of every lord.

// Where a storehouse can be carried.
const (
	StorehouseToPurse    = "purse"
	StorehouseToTreasury = "treasury"
)

// ErrStorehouseEmpty is a carry with less than a whole gold waiting.
var ErrStorehouseEmpty = errors.New("the storehouse holds nothing yet")

// ErrBadDestination is a carry to somewhere that is not the purse or the vault.
var ErrBadDestination = errors.New("carry the storehouse to the purse or the treasury")

// StorehouseView is the storehouse as the lord's screen draws it, settled to
// the snapshot's moment. The client ticks it between snapshots from Milli, the
// rate and the capacity -- the same sum as game/estates.Fill -- and never writes
// what it shows.
type StorehouseView struct {
	// Whole gold waiting, and the same in milli-gold for the tick.
	Gold  int64 `json:"gold"`
	Milli int64 `json:"milli"`
	// What it holds when full.
	Cap      int64 `json:"cap"`
	CapMilli int64 `json:"cap_milli"`
	// The estates' income, per hour, in milli-gold.
	PerHourMilli int64 `json:"per_hour_milli"`
	// How many hours it holds (8, and more with the Tithe Barn).
	Hours float64 `json:"hours"`
	// Seconds until full; 0 when it is.
	FullIn int64 `json:"full_in"`
	Full   bool  `json:"full"`
	// What carrying it to the vault costs, as the vault's deposits do.
	TreasuryFeeBP int64 `json:"treasury_fee_bp"`
	// Whether the vault is open to this lord yet.
	TreasuryOpen bool `json:"treasury_open"`
}

// storehouseOf reads a lord's storehouse off their row.
func storehouseOf(p sqlcdb.AppPlayer) estates.Storehouse {
	return estates.Storehouse{Milli: p.StorehouseMilli, At: p.StorehouseAt}
}

// refreshStorehouse keeps the cached rate and capacity honest. They depend on
// holdings, upgrades, kingdom nodes and level, and GetState -- which every
// mutating endpoint ends with -- has all of that loaded. When either moved, the
// storehouse is settled at the OLD pair up to now in the same statement that
// stores the new one, so a holding bought today never pays for the hours before
// it at its new rate. The row in hand is brought up to date to match, so the
// snapshot built from it says the new rate at once.
func (d Deps) refreshStorehouse(ctx context.Context, q *sqlcdb.Queries, p *sqlcdb.AppPlayer, eff estates.Effects, now time.Time) error {
	capMilli := estates.StorehouseCap(eff.TaxMilliPerHour, eff.OfflineCapSeconds)
	if p.TaxMilliPerHour == eff.TaxMilliPerHour && p.StorehouseCapMilli == capMilli {
		return nil
	}
	if err := q.RefreshStorehouse(ctx, sqlcdb.RefreshStorehouseParams{
		ID: p.ID, Now: now, Rate: eff.TaxMilliPerHour, CapMilli: capMilli,
	}); err != nil {
		return fmt.Errorf("refresh storehouse: %w", err)
	}
	settled := estates.Fill(storehouseOf(*p), p.TaxMilliPerHour, p.StorehouseCapMilli, now)
	p.StorehouseMilli, p.StorehouseAt = settled.Milli, settled.At
	p.TaxMilliPerHour, p.StorehouseCapMilli = eff.TaxMilliPerHour, capMilli
	return nil
}

// storehouseView settles a lord's storehouse to now for the screen.
func (d Deps) storehouseView(p sqlcdb.AppPlayer, eff estates.Effects, now time.Time) StorehouseView {
	s := estates.Fill(storehouseOf(p), p.TaxMilliPerHour, p.StorehouseCapMilli, now)
	full := estates.FullIn(s.Milli, p.TaxMilliPerHour, p.StorehouseCapMilli)
	return StorehouseView{
		Gold: s.Milli / 1000, Milli: s.Milli,
		Cap: p.StorehouseCapMilli / 1000, CapMilli: p.StorehouseCapMilli,
		PerHourMilli:  p.TaxMilliPerHour,
		Hours:         float64(eff.OfflineCapSeconds) / 3600,
		FullIn:        int64(full / time.Second),
		Full:          p.StorehouseCapMilli > 0 && s.Milli >= p.StorehouseCapMilli,
		TreasuryFeeBP: d.Config.Progression.Treasury.DepositFeeBP,
		TreasuryOpen:  int(p.Level) >= d.Config.SectionLevel(bankSection),
	}
}

// CarryResult is what a carry moved.
type CarryResult struct {
	To string `json:"to"`
	// What left the storehouse.
	Carried int64 `json:"carried"`
	// For the vault: what the fee burned, and what landed.
	Fee      int64     `json:"fee"`
	Banked   int64     `json:"banked"`
	Snapshot *Snapshot `json:"snapshot"`
}

// CarryStorehouse carries the storehouse's whole gold to the purse or the vault.
// A sequenced action: it moves gold the client's queued collects are counting.
func (d Deps) CarryStorehouse(ctx context.Context, playerID uuid.UUID, to string, wantSeq int64) (*CarryResult, error) {
	if to != StorehouseToPurse && to != StorehouseToTreasury {
		return nil, ErrBadDestination
	}
	res := CarryResult{To: to}
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
		if to == StorehouseToTreasury {
			if at := d.Config.SectionLevel(bankSection); int(p.Level) < at {
				return fmt.Errorf("%w: the treasury opens at level %d", ErrLevelTooLow, at)
			}
		}
		// Settled at the rate it has been filling at: a rate that changed since
		// is stored by the next GetState, after this.
		now := d.Now()
		s := estates.Fill(storehouseOf(p), p.TaxMilliPerHour, p.StorehouseCapMilli, now)
		gold := s.Milli / 1000
		if gold <= 0 {
			return ErrStorehouseEmpty
		}
		left := s.Milli % 1000
		res.Carried = gold

		if to == StorehouseToPurse {
			after, err := q.CarryStorehouseToPurse(ctx, sqlcdb.CarryStorehouseToPurseParams{
				ID: playerID, Gold: gold, LeftMilli: left, Now: now, ActionSeq: wantSeq,
			})
			if err != nil {
				return fmt.Errorf("carry to purse: %w", err)
			}
			return q.RecordGold(ctx, sqlcdb.RecordGoldParams{
				PlayerID: playerID, Delta: gold, BalanceAfter: after.Gold, Reason: "storehouse", RefID: nil,
			})
		}

		fee := gold * d.Config.Progression.Treasury.DepositFeeBP / 10000
		banked := gold - fee
		after, err := q.CarryStorehouseToTreasury(ctx, sqlcdb.CarryStorehouseToTreasuryParams{
			ID: playerID, Banked: banked, LeftMilli: left, Now: now, ActionSeq: wantSeq,
		})
		if err != nil {
			return fmt.Errorf("carry to treasury: %w", err)
		}
		// The estates' income is a faucet wherever it lands, and the fee a sink,
		// as a deposit's is: the economy dashboard counts both.
		if err := q.RecordGold(ctx, sqlcdb.RecordGoldParams{
			PlayerID: playerID, Delta: gold, BalanceAfter: after.Gold, Reason: "storehouse", RefID: nil,
		}); err != nil {
			return err
		}
		if fee > 0 {
			if err := q.RecordGold(ctx, sqlcdb.RecordGoldParams{
				PlayerID: playerID, Delta: -fee, BalanceAfter: after.Gold, Reason: "treasury_fee", RefID: nil,
			}); err != nil {
				return err
			}
		}
		res.Fee, res.Banked = fee, banked
		return nil
	})
	if err != nil {
		return nil, err
	}
	res.Snapshot, err = d.GetState(ctx, playerID)
	return &res, err
}
