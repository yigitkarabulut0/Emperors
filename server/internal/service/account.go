package service

import (
	"context"
	"errors"
	"fmt"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/yigitkarabulut0/emperors/server/internal/auth"
	"github.com/yigitkarabulut0/emperors/server/internal/db"
	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
)

// DeleteAccount removes a player and everything that is theirs.
//
// The App Store asks that an account made in an app can be deleted in it
// (Guideline 5.1.1(v)). Confirmed with the password, because a deletion cannot
// be taken back and a phone left unlocked on a table is not consent.
//
// One transaction, in this order:
//  1. a king's crown passes to the longest-serving captain, or else the
//     longest-serving lord, so the kingdom is never left without one;
//  2. the player leaves their kingdom, and a kingdom left empty is disbanded;
//  3. the account is written to app.deleted_accounts and its analytics events
//     are removed;
//  4. the player row is deleted, and every foreign key cascades -- sessions and
//     identities with it, so the next refresh is refused and the phone signs out.
//
// Their battles go too, from the other side's history as well: the lord who
// fought them no longer exists to be named, and a revenge token against them
// has nobody to strike.
//
// What has no foreign key stays, on purpose: the diamond ledger (purged 90 days
// on) and the days they played. A refund Apple sends after the deletion finds
// the deleted_accounts row and is settled as "nothing left to take back".
func (d Deps) DeleteAccount(ctx context.Context, playerID uuid.UUID, password string) error {
	q := sqlcdb.New(d.Pool)
	ident, err := q.GetPasswordIdentity(ctx, playerID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrBadCredentials
		}
		return fmt.Errorf("identity: %w", err)
	}
	if ident.SecretHash == nil || auth.VerifyPassword(password, *ident.SecretHash) != nil {
		return ErrBadCredentials
	}

	return db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
		q := sqlcdb.New(tx)
		p, err := q.LockPlayer(ctx, playerID)
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrNotFound
			}
			return fmt.Errorf("lock player: %w", err)
		}
		if p.KingdomID != nil {
			kid := *p.KingdomID
			if _, err := q.LockKingdom(ctx, kid); err != nil {
				return fmt.Errorf("lock kingdom: %w", err)
			}
			if p.KingdomRole == "king" {
				heir, err := q.PickSuccessor(ctx, sqlcdb.PickSuccessorParams{KingdomID: &kid, KingID: playerID})
				switch {
				case err == nil:
					if _, err := q.SetKingdomRole(ctx, sqlcdb.SetKingdomRoleParams{
						ID: heir, KingdomRole: "king", KingdomID: &kid,
					}); err != nil {
						return fmt.Errorf("crown the heir: %w", err)
					}
					if err := q.SetLeader(ctx, sqlcdb.SetLeaderParams{ID: kid, LeaderID: &heir}); err != nil {
						return fmt.Errorf("leader: %w", err)
					}
				case errors.Is(err, pgx.ErrNoRows):
					// The last lord: the kingdom is disbanded below.
				default:
					return fmt.Errorf("heir: %w", err)
				}
			}
			now := d.Now()
			if _, err := q.LeaveKingdom(ctx, sqlcdb.LeaveKingdomParams{ID: playerID, LeftAt: &now}); err != nil {
				return fmt.Errorf("leave: %w", err)
			}
			if _, err := q.DeleteKingdomIfEmpty(ctx, kid); err != nil {
				return fmt.Errorf("disband: %w", err)
			}
		}
		if err := q.RecordDeletedAccount(ctx, sqlcdb.RecordDeletedAccountParams{
			PlayerID: playerID, JoinedAt: p.CreatedAt, DeletedAt: d.Now(),
			Level: p.Level, Diamonds: p.Diamonds, DiamondDebt: p.DiamondDebt,
		}); err != nil {
			return fmt.Errorf("record the deletion: %w", err)
		}
		if err := q.DeletePlayerEvents(ctx, playerID); err != nil {
			return fmt.Errorf("delete events: %w", err)
		}
		n, err := q.DeletePlayer(ctx, playerID)
		if err != nil {
			return fmt.Errorf("delete: %w", err)
		}
		if n == 0 {
			return ErrNotFound
		}
		return nil
	})
}
