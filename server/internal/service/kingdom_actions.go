package service

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/yigitkarabulut0/emperors/server/internal/db"
	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
)

// Invite offers membership. Only a Marshal or the King may invite.
func (d Deps) Invite(ctx context.Context, playerID, targetID uuid.UUID) (*KingdomView, error) {
	err := db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
		q := sqlcdb.New(tx)

		me, err := q.GetPlayerByID(ctx, playerID)
		if err != nil {
			return ErrNotFound
		}
		if me.KingdomID == nil {
			return ErrNotInKingdom
		}
		if me.KingdomRole != "king" && me.KingdomRole != "marshal" {
			return ErrNotPermitted
		}

		target, err := q.GetPlayerByID(ctx, targetID)
		if err != nil {
			return ErrNotFound
		}
		if target.KingdomID != nil {
			return ErrAlreadyInKingdom
		}

		// Checked at invite time as a courtesy, and again at accept time because
		// the roster can fill in between.
		count, err := q.CountKingdomMembers(ctx, me.KingdomID)
		if err != nil {
			return err
		}
		k, err := q.GetKingdom(ctx, *me.KingdomID)
		if err != nil {
			return err
		}
		if int(count) >= d.Config.KingdomMemberCap(int(k.Level), d.courtBonus(ctx, q, k.ID)) {
			return ErrKingdomFull
		}

		return q.CreateInvite(ctx, sqlcdb.CreateInviteParams{
			KingdomID: *me.KingdomID, PlayerID: targetID, InvitedBy: &playerID,
		})
	})
	if err != nil {
		return nil, err
	}
	return d.GetKingdom(ctx, playerID)
}

// AcceptInvite joins a kingdom.
func (d Deps) AcceptInvite(ctx context.Context, playerID, kingdomID uuid.UUID) (*KingdomView, error) {
	err := db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
		q := sqlcdb.New(tx)

		p, err := q.LockPlayer(ctx, playerID)
		if err != nil {
			return ErrNotFound
		}
		if p.KingdomID != nil {
			return ErrAlreadyInKingdom
		}
		if _, err := q.GetInvite(ctx, sqlcdb.GetInviteParams{
			KingdomID: kingdomID, PlayerID: playerID,
		}); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrNotInvited
			}
			return err
		}

		// The kingdom row is locked before the count, so two people accepting the
		// last seat at the same instant cannot both get in.
		k, err := q.LockKingdom(ctx, kingdomID)
		if err != nil {
			return ErrNotFound
		}
		count, err := q.CountKingdomMembers(ctx, &kingdomID)
		if err != nil {
			return err
		}
		if int(count) >= d.Config.KingdomMemberCap(int(k.Level), d.courtBonus(ctx, q, k.ID)) {
			return ErrKingdomFull
		}

		now := d.Now()
		if _, err := q.SetPlayerKingdom(ctx, sqlcdb.SetPlayerKingdomParams{
			ID: playerID, KingdomID: &kingdomID, KingdomRole: "member", KingdomJoinedAt: &now,
		}); err != nil {
			return err
		}
		// Every other invite is dropped: holding stale offers would let a player
		// appear to belong to several kingdoms at once in the UI.
		return q.DeleteInvitesForPlayer(ctx, playerID)
	})
	if err != nil {
		return nil, err
	}
	return d.GetKingdom(ctx, playerID)
}

// Leave resigns from a kingdom.
func (d Deps) Leave(ctx context.Context, playerID uuid.UUID) (*KingdomView, error) {
	err := db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
		q := sqlcdb.New(tx)

		p, err := q.LockPlayer(ctx, playerID)
		if err != nil {
			return ErrNotFound
		}
		if p.KingdomID == nil {
			return ErrNotInKingdom
		}
		if p.KingdomRole == "king" {
			count, err := q.CountKingdomMembers(ctx, p.KingdomID)
			if err != nil {
				return err
			}
			// A kingdom with members but no king cannot invite, promote or spend,
			// and nothing in the game can fix it. Refuse rather than create one.
			if count > 1 {
				return ErrLastKing
			}
		}
		_, err = q.LeaveKingdom(ctx, playerID)
		return err
	})
	if err != nil {
		return nil, err
	}
	return d.GetKingdom(ctx, playerID)
}

// SetRole promotes or demotes a member. Only the King may do this.
func (d Deps) SetRole(ctx context.Context, playerID, targetID uuid.UUID, role string) (*KingdomView, error) {
	switch role {
	case "member", "marshal", "king":
	default:
		return nil, ErrNotFound
	}

	err := db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
		q := sqlcdb.New(tx)

		me, err := q.GetPlayerByID(ctx, playerID)
		if err != nil {
			return ErrNotFound
		}
		if me.KingdomID == nil {
			return ErrNotInKingdom
		}
		if me.KingdomRole != "king" {
			return ErrNotPermitted
		}
		target, err := q.GetPlayerByID(ctx, targetID)
		if err != nil {
			return ErrNotFound
		}
		if target.KingdomID == nil || *target.KingdomID != *me.KingdomID {
			return ErrNotFound
		}

		if _, err := q.SetKingdomRole(ctx, sqlcdb.SetKingdomRoleParams{
			ID: targetID, KingdomRole: role, KingdomID: me.KingdomID,
		}); err != nil {
			return err
		}
		// Handing over the crown steps the old king down in the same
		// transaction, so a kingdom never has two.
		if role == "king" {
			if _, err := q.SetKingdomRole(ctx, sqlcdb.SetKingdomRoleParams{
				ID: playerID, KingdomRole: "marshal", KingdomID: me.KingdomID,
			}); err != nil {
				return err
			}
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return d.GetKingdom(ctx, playerID)
}

// Donate moves gold from a player into the kingdom treasury.
//
// Donating has to pay the donor something personally, or nobody donates: each
// 100 gold grants a Kingdom Favour.
func (d Deps) Donate(ctx context.Context, playerID uuid.UUID, amount int64, wantSeq int64) (*KingdomView, error) {
	if amount <= 0 {
		return nil, ErrNothingToSpend
	}

	err := db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
		q := sqlcdb.New(tx)

		p, err := q.LockPlayer(ctx, playerID)
		if err != nil {
			return ErrNotFound
		}
		if err := checkSeq(p, wantSeq); err != nil {
			return err
		}
		if p.KingdomID == nil {
			return ErrNotInKingdom
		}

		now := d.Now()
		today := int64(0)
		if p.KingdomDay.Valid && sameDay(p.KingdomDay.Time, now) {
			today = p.KingdomDonatedToday
		}
		remaining := d.donationCap(int64(p.Level)) - today
		if remaining <= 0 {
			return ErrDonationCap
		}
		if amount > remaining {
			amount = remaining
		}

		cfg := d.Config.Kingdoms.Donation
		favour := amount / cfg.FavourPerGold

		after, err := q.DonateGold(ctx, sqlcdb.DonateGoldParams{
			ID: playerID, Gold: amount,
			KingdomDay:    pgtype.Date{Time: now, Valid: true},
			KingdomFavour: favour,
			ActionSeq:     wantSeq,
		})
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrNotEnoughGold
			}
			return fmt.Errorf("donate: %w", err)
		}

		k, err := q.LockKingdom(ctx, *p.KingdomID)
		if err != nil {
			return err
		}
		newXP := k.Xp + amount*cfg.XPPerGold
		newLevel, _ := d.Config.KingdomLevelFor(newXP)
		if _, err := q.AddKingdomTreasury(ctx, sqlcdb.AddKingdomTreasuryParams{
			ID: k.ID, Treasury: amount, Xp: amount * cfg.XPPerGold, Level: int32(newLevel),
		}); err != nil {
			return err
		}

		return q.RecordGold(ctx, sqlcdb.RecordGoldParams{
			PlayerID: playerID, Delta: -amount, BalanceAfter: after.Gold,
			Reason: "kingdom_donate", RefID: strPtr(k.ID.String()),
		})
	})
	if err != nil {
		return nil, err
	}
	return d.GetKingdom(ctx, playerID)
}

// BuyKingdomUpgrade spends from the treasury. Only a Marshal or the King may.
func (d Deps) BuyKingdomUpgrade(ctx context.Context, playerID uuid.UUID, upgradeID string) (*KingdomView, error) {
	u := d.Config.KingdomUpgrade(upgradeID)
	if u == nil {
		return nil, ErrNotFound
	}

	err := db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
		q := sqlcdb.New(tx)

		p, err := q.GetPlayerByID(ctx, playerID)
		if err != nil {
			return ErrNotFound
		}
		if p.KingdomID == nil {
			return ErrNotInKingdom
		}
		if p.KingdomRole != "king" && p.KingdomRole != "marshal" {
			return ErrNotPermitted
		}

		if _, err := q.LockKingdom(ctx, *p.KingdomID); err != nil {
			return err
		}
		ups, err := q.ListKingdomUpgrades(ctx, *p.KingdomID)
		if err != nil {
			return err
		}
		level := 0
		for _, r := range ups {
			if r.UpgradeID == upgradeID {
				level = int(r.Level)
			}
		}
		cost, ok := u.Cost(level)
		if !ok {
			return ErrUpgradeMaxed
		}

		if _, err := q.SpendKingdomTreasury(ctx, sqlcdb.SpendKingdomTreasuryParams{
			ID: *p.KingdomID, Treasury: cost,
		}); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrNotEnoughGold
			}
			return err
		}
		if _, err := q.BuyKingdomUpgradeLevel(ctx, sqlcdb.BuyKingdomUpgradeLevelParams{
			KingdomID: *p.KingdomID, UpgradeID: upgradeID, Level: int32(level),
		}); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrStaleAction
			}
			return err
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return d.GetKingdom(ctx, playerID)
}

// courtBonus reads the Royal Court's member-cap bonus. Best-effort: a failure
// here should shrink the roster, never block the action.
func (d Deps) courtBonus(ctx context.Context, q *sqlcdb.Queries, kingdomID uuid.UUID) int {
	ups, err := q.ListKingdomUpgrades(ctx, kingdomID)
	if err != nil {
		return 0
	}
	u := d.Config.KingdomUpgrade(courtUpgradeID)
	if u == nil {
		return 0
	}
	for _, r := range ups {
		if r.UpgradeID == courtUpgradeID {
			return int(u.PerLevel) * int(r.Level)
		}
	}
	return 0
}

// SearchablePlayer is one result from the invite search.
type SearchablePlayer struct {
	PlayerID  string `json:"player_id"`
	Name      string `json:"name"`
	Avatar    string `json:"avatar"`
	Level     int    `json:"level"`
	InKingdom bool   `json:"in_kingdom"`
}

// SearchPlayers finds people to invite.
//
// Kingdoms are invite-only and Invite takes a player UUID, so without a way to
// turn a name into an id the whole system was a dead end: you could found a
// kingdom and then sit in it alone forever. This is the missing half.
//
// Deliberately thin. It returns a name, a face, a level and whether they already
// belong somewhere -- enough to recognise the person you meant, and nothing that
// would make it a way to scout targets.
func (d Deps) SearchPlayers(ctx context.Context, playerID uuid.UUID, term string) ([]SearchablePlayer, error) {
	term = strings.TrimSpace(term)
	if len(term) < 2 {
		return []SearchablePlayer{}, nil
	}
	rows, err := sqlcdb.New(d.Pool).FindInvitablePlayers(ctx, sqlcdb.FindInvitablePlayersParams{
		ID: playerID, Lower: term + "%",
	})
	if err != nil {
		return nil, fmt.Errorf("search players: %w", err)
	}
	out := make([]SearchablePlayer, 0, len(rows))
	for _, r := range rows {
		out = append(out, SearchablePlayer{
			PlayerID: r.ID.String(), Name: r.DisplayName, Avatar: r.Avatar,
			Level: int(r.Level), InKingdom: r.KingdomID != nil,
		})
	}
	return out, nil
}
