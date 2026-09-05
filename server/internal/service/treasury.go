package service

import (
	"context"
	"errors"
	"fmt"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/yigitkarabulut0/emperors/server/internal/db"
	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
)

// ErrInvalidAmount rejects a zero or negative move. Both directions guard it:
// a negative deposit would be a withdrawal that skipped the fee.
var ErrInvalidAmount = errors.New("amount must be positive")

// TreasuryResult is what the player sees after moving gold.
type TreasuryResult struct {
	Moved    int64     `json:"moved"`    // what left the purse (deposit) or arrived in it (withdraw)
	Fee      int64     `json:"fee"`      // burned on the way in
	Banked   int64     `json:"banked"`   // what actually landed in the vault
	Snapshot *Snapshot `json:"snapshot"`
}

// Deposit banks gold, minus a fee.
//
// This is the game's largest sink and its only standing risk decision: PvP steals
// a share of gold ON HAND and never touches the vault, so every session ends with
// a real choice about how much to carry. The fee is what stops "bank everything,
// always" from being free safety.
//
// The fee is BURNED, not moved. It leaves the economy entirely, which is the
// whole point -- a fee that landed anywhere would just be gold changing pockets.
func (d Deps) Deposit(ctx context.Context, playerID uuid.UUID, amount, wantSeq int64) (*TreasuryResult, error) {
	if amount <= 0 {
		return nil, ErrInvalidAmount
	}
	fee := amount * d.Config.Progression.Treasury.DepositFeeBP / 10000
	banked := amount - fee

	var res TreasuryResult
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

		after, err := q.MoveToTreasury(ctx, sqlcdb.MoveToTreasuryParams{
			ID: playerID, Gold: amount, TreasuryGold: banked, ActionSeq: wantSeq,
		})
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrNotEnoughGold
			}
			return fmt.Errorf("deposit: %w", err)
		}

		// Only the fee is a ledger event. The rest did not leave the economy, it
		// moved between two of this player's own pockets, and recording it as
		// destruction would make the sink dashboard lie.
		if fee > 0 {
			if err := q.RecordGold(ctx, sqlcdb.RecordGoldParams{
				PlayerID: playerID, Delta: -fee, BalanceAfter: after.Gold,
				Reason: "treasury_fee", RefID: nil,
			}); err != nil {
				return fmt.Errorf("ledger: %w", err)
			}
		}
		res = TreasuryResult{Moved: amount, Fee: fee, Banked: banked}
		return nil
	})
	if err != nil {
		return nil, err
	}
	res.Snapshot, err = d.GetState(ctx, playerID)
	return &res, err
}

// Withdraw takes gold back out. Free -- the fee was charged on the way in, and
// charging both ways would make the vault a trap rather than a decision.
func (d Deps) Withdraw(ctx context.Context, playerID uuid.UUID, amount, wantSeq int64) (*TreasuryResult, error) {
	if amount <= 0 {
		return nil, ErrInvalidAmount
	}
	var res TreasuryResult
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
		if _, err := q.MoveFromTreasury(ctx, sqlcdb.MoveFromTreasuryParams{
			ID: playerID, Gold: amount, ActionSeq: wantSeq,
		}); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrNotEnoughGold
			}
			return fmt.Errorf("withdraw: %w", err)
		}
		res = TreasuryResult{Moved: amount}
		return nil
	})
	if err != nil {
		return nil, err
	}
	res.Snapshot, err = d.GetState(ctx, playerID)
	return &res, err
}
