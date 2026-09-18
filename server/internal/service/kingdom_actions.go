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
	"github.com/yigitkarabulut0/emperors/server/internal/game/deeds"
	"github.com/yigitkarabulut0/emperors/server/internal/game/rewards"
)

// Invite offers membership. Only a Marshal or the King may invite.
//
// When the lord invited has already asked to join, the invitation is the answer
// to that request: they are seated at once rather than left holding an invite
// and a request that say the same thing.
func (d Deps) Invite(ctx context.Context, playerID, targetID uuid.UUID) (*KingdomView, error) {
	if playerID == targetID {
		return nil, ruleError{kind: ErrBadTarget, msg: "you are already one of your own lords"}
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
		if me.KingdomRole != "king" && me.KingdomRole != "marshal" {
			return ErrNotPermitted
		}
		kid := *me.KingdomID

		target, err := q.LockPlayer(ctx, targetID)
		if err != nil {
			return ErrNotFound
		}
		if target.KingdomID != nil {
			return ErrTargetInKingdom
		}

		if _, err := q.GetJoinRequest(ctx, sqlcdb.GetJoinRequestParams{
			KingdomID: kid, PlayerID: targetID,
		}); err == nil {
			return d.joinKingdom(ctx, q, target, kid, true)
		} else if !errors.Is(err, pgx.ErrNoRows) {
			return fmt.Errorf("read request: %w", err)
		}

		// Checked at invite time as a courtesy, and again at accept time because
		// the roster can fill in between.
		count, err := q.CountKingdomMembers(ctx, &kid)
		if err != nil {
			return err
		}
		k, err := q.GetKingdom(ctx, kid)
		if err != nil {
			return err
		}
		if int(count) >= d.memberCap(int(k.Level), d.courtLevel(ctx, q, k.ID)) {
			return ErrKingdomFull
		}

		if _, err := q.CreateInvite(ctx, sqlcdb.CreateInviteParams{
			KingdomID: kid, PlayerID: targetID, InvitedBy: &playerID,
		}); err != nil {
			return fmt.Errorf("create invite: %w", err)
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return d.GetKingdom(ctx, playerID)
}

// AcceptInvite joins a kingdom that invited this player.
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
		// An invitation only. A request is the player's own ask and is no
		// licence to seat themselves.
		if _, err := q.GetInvite(ctx, sqlcdb.GetInviteParams{
			KingdomID: kingdomID, PlayerID: playerID,
		}); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrNotInvited
			}
			return err
		}
		return d.joinKingdom(ctx, q, p, kingdomID, false)
	})
	if err != nil {
		return nil, err
	}
	return d.GetKingdom(ctx, playerID)
}

// Leave resigns from a kingdom. The last lord out turns off the lights: a
// kingdom with nobody in it is deleted, which frees its name and tag and keeps
// it off the table and out of the hall.
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
		kid := *p.KingdomID
		// Locked before the count, so nobody can be seated between the count
		// and the leaving -- that is how a kingdom would end up with lords and
		// no king.
		if _, err := q.LockKingdom(ctx, kid); err != nil {
			return fmt.Errorf("lock kingdom: %w", err)
		}
		if p.KingdomRole == "king" {
			count, err := q.CountKingdomMembers(ctx, &kid)
			if err != nil {
				return err
			}
			// A kingdom with members but no king cannot invite, promote or spend,
			// and nothing in the game can fix it. Refuse rather than create one.
			if count > 1 {
				return ErrLastKing
			}
		}
		now := d.Now()
		if _, err := q.LeaveKingdom(ctx, sqlcdb.LeaveKingdomParams{ID: playerID, LeftAt: &now}); err != nil {
			return fmt.Errorf("leave: %w", err)
		}
		// Said before the kingdom is swept, so a hall that is about to be
		// deleted with its last lord does not fail on a line about them.
		if _, err := d.systemLine(ctx, q, kid, SysLeft,
			fmt.Sprintf("%s has left the kingdom.", p.DisplayName),
			map[string]any{"player_id": playerID.String()}); err != nil {
			return err
		}
		if _, err := q.DeleteKingdomIfEmpty(ctx, kid); err != nil {
			return fmt.Errorf("disband: %w", err)
		}
		return nil
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
		return nil, ErrBadRole
	}
	// A king naming himself anything would step himself down -- to king, the
	// handover demotes him to marshal -- and leave the kingdom with no king,
	// which nothing in the game can repair.
	if playerID == targetID {
		return nil, ruleError{kind: ErrBadTarget, msg: "hand the crown to another lord instead"}
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
		// transaction, so a kingdom never has two -- and moves leader_id, which
		// is what a rename is permitted by. It never used to, so a new king
		// could not rename the kingdom he ruled.
		if role == "king" {
			if _, err := q.SetKingdomRole(ctx, sqlcdb.SetKingdomRoleParams{
				ID: playerID, KingdomRole: "marshal", KingdomID: me.KingdomID,
			}); err != nil {
				return err
			}
			if err := q.SetLeader(ctx, sqlcdb.SetLeaderParams{
				ID: *me.KingdomID, LeaderID: &targetID,
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

		// There is no daily ceiling. A player gives what they have, and
		// DonateGold's own WHERE clause is what refuses more than that.
		now := d.Now()

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

		if err := q.RecordGold(ctx, sqlcdb.RecordGoldParams{
			PlayerID: playerID, Delta: -amount, BalanceAfter: after.Gold,
			Reason: "kingdom_donate", RefID: strPtr(k.ID.String()),
		}); err != nil {
			return err
		}
		d.recordDeeds(ctx, tx, p, deeds.Deeds{deeds.DonatedGold: amount})
		// The hall sees the treasury grow. A gift to a kingdom that nobody
		// hears about is a gift a lord makes once.
		if _, err := d.systemLine(ctx, q, k.ID, SysDonated,
			fmt.Sprintf("%s gave %s gold to the treasury.", p.DisplayName, rewards.Group(amount)),
			map[string]any{"player_id": playerID.String(), "gold": amount}); err != nil {
			return err
		}
		return nil
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
		// The hall sees the Work rise: it is everybody's Work, bought with
		// everybody's gold.
		name := upgradeID
		if u := d.Config.KingdomUpgrade(upgradeID); u != nil {
			name = u.Name
		}
		if _, err := d.systemLine(ctx, q, *p.KingdomID, SysUpgrade,
			fmt.Sprintf("%s raised %s to level %d.", p.DisplayName, name, level),
			map[string]any{"player_id": playerID.String(), "upgrade": upgradeID, "level": level}); err != nil {
			return err
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return d.GetKingdom(ctx, playerID)
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
