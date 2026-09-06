package admin

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
	"github.com/yigitkarabulut0/emperors/server/internal/game/items"
)

// The panel's write surface over one player.
//
// Two rules hold for every method here.
//
// Stock quantities are DELTAS, never absolutes. Estate income is continuous, so
// "set gold to 5,000" quietly destroys whatever accrued between the page
// rendering and the form submitting; "+1000" is race-free by construction.
// Rank-shaped values -- level, energy, luck -- are absolutes, because there is
// no meaningful "+1 level" that is not just a level.
//
// Every method writes an audit row with the before and after values. An admin
// surface that can grant currency and change odds is worth nothing if it cannot
// answer "who did this, and why" three months later.

// ErrNothingToDo is returned when a form was submitted with every field empty.
var ErrNothingToDo = errors.New("nothing to change")

// ErrOutOfRange is returned for a value the game could not represent.
var ErrOutOfRange = errors.New("that value is out of range")

// AdjustPlayer moves the four stock quantities by the given deltas.
//
// XP is added to the current level's bar and deliberately does NOT level anyone
// up: crossing a boundary grants stat points, diamonds and an energy refill, and
// a panel that silently did all of that would be a very surprising "+500 xp".
func (s *Service) AdjustPlayer(ctx context.Context, who *Identity, playerID uuid.UUID,
	gold, diamonds, xp int64, statPoints int32, note string) (*PlayerRow, error) {
	if !AtLeast(who.Role, "moderator") {
		return nil, ErrForbidden
	}
	if gold == 0 && diamonds == 0 && xp == 0 && statPoints == 0 {
		return nil, ErrNothingToDo
	}

	q := sqlcdb.New(s.Pool)
	before, err := q.GetPlayerByID(ctx, playerID)
	if err != nil {
		return nil, ErrNotFound
	}
	if before.Gold+gold < 0 {
		return nil, fmt.Errorf("%w: that would leave a negative balance", ErrOutOfRange)
	}
	if before.Diamonds+diamonds < 0 {
		return nil, fmt.Errorf("%w: that would leave negative diamonds", ErrOutOfRange)
	}

	after, err := q.AdminAdjustPlayer(ctx, sqlcdb.AdminAdjustPlayerParams{
		ID: playerID, Gold: gold, Diamonds: diamonds, Xp: xp, StatPoints: statPoints,
	})
	if err != nil {
		return nil, err
	}

	// Gold that appears from nowhere has to appear in the ledger too, or the
	// economy dashboard is quietly wrong about how much currency exists.
	if gold != 0 {
		if err := q.RecordGold(ctx, sqlcdb.RecordGoldParams{
			PlayerID: playerID, Delta: gold, BalanceAfter: after.Gold,
			Reason: "admin_grant", RefID: &who.Username,
		}); err != nil {
			return nil, err
		}
	}

	s.Audit(ctx, who, "player.adjust", playerID.String(),
		map[string]any{"gold": before.Gold, "diamonds": before.Diamonds,
			"xp": before.Xp, "stat_points": before.StatPointsUnspent},
		map[string]any{"gold": after.Gold, "diamonds": after.Diamonds,
			"xp": after.Xp, "stat_points": after.StatPointsUnspent}, note)
	return playerRow(after), nil
}

// SetLevel sets a player's level outright.
//
// The XP bar resets to the bottom of the new level: an xp value measured against
// a different level's requirement is meaningless. Stat points are NOT granted --
// that is a separate deliberate act, through AdjustPlayer.
func (s *Service) SetLevel(ctx context.Context, who *Identity, playerID uuid.UUID,
	level int32, note string) (*PlayerRow, error) {
	if !AtLeast(who.Role, "designer") {
		return nil, ErrForbidden
	}
	cap := int32(s.Config.Get().Progression.LevelCap)
	if level < 1 || level > cap {
		return nil, fmt.Errorf("%w: level must be between 1 and %d", ErrOutOfRange, cap)
	}

	q := sqlcdb.New(s.Pool)
	before, err := q.GetPlayerByID(ctx, playerID)
	if err != nil {
		return nil, ErrNotFound
	}
	after, err := q.AdminSetLevel(ctx, sqlcdb.AdminSetLevelParams{ID: playerID, Level: level})
	if err != nil {
		return nil, err
	}
	s.Audit(ctx, who, "player.level", playerID.String(),
		map[string]any{"level": before.Level, "xp": before.Xp},
		map[string]any{"level": after.Level, "xp": after.Xp}, note)
	return playerRow(after), nil
}

// SetEnergy sets the pool to a whole number of points.
//
// Energy is (value, anchor) settled on read, so the anchor moves with the value.
// Writing one without the other would have the next settle immediately undo it.
func (s *Service) SetEnergy(ctx context.Context, who *Identity, playerID uuid.UUID,
	energy int64, note string) (*PlayerRow, error) {
	if !AtLeast(who.Role, "moderator") {
		return nil, ErrForbidden
	}
	if energy < 0 {
		return nil, fmt.Errorf("%w: energy cannot be negative", ErrOutOfRange)
	}

	q := sqlcdb.New(s.Pool)
	before, err := q.GetPlayerByID(ctx, playerID)
	if err != nil {
		return nil, ErrNotFound
	}
	after, err := q.AdminSetEnergy(ctx, sqlcdb.AdminSetEnergyParams{
		ID: playerID, EnergyMilli: energy * 1000, Now: s.now(),
	})
	if err != nil {
		return nil, err
	}
	s.Audit(ctx, who, "player.energy", playerID.String(),
		map[string]any{"energy": before.EnergyMilli / 1000},
		map[string]any{"energy": after.EnergyMilli / 1000}, note)
	return playerRow(after), nil
}

// SetLuck sets a player's luck override.
//
// expiresAt nil means permanent, which is why this needs a designer: a luck
// override moves no counter anyone watches and writes no ledger row, so a
// forgotten permanent one compounds silently for as long as nobody looks.
func (s *Service) SetLuck(ctx context.Context, who *Identity, playerID uuid.UUID,
	luckBP int32, expiresAt *time.Time, note string) (*PlayerRow, error) {
	if !AtLeast(who.Role, "designer") {
		return nil, ErrForbidden
	}
	if int64(luckBP) != int64(items.ClampLuckBP(int64(luckBP))) {
		return nil, fmt.Errorf("%w: luck must be between -10000 and 10000", ErrOutOfRange)
	}

	q := sqlcdb.New(s.Pool)
	before, err := q.GetPlayerByID(ctx, playerID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, err
	}
	after, err := q.AdminSetLuck(ctx, sqlcdb.AdminSetLuckParams{
		ID: playerID, LuckBp: luckBP, ExpiresAt: expiresAt,
	})
	if err != nil {
		return nil, err
	}
	s.Audit(ctx, who, "player.luck", playerID.String(),
		map[string]any{"luck_bp": before.LuckBp, "expires_at": before.LuckExpiresAt},
		map[string]any{"luck_bp": after.LuckBp, "expires_at": after.LuckExpiresAt}, note)
	return playerRow(after), nil
}

// playerRow is the shared shape the panel renders, built in one place so a new
// write endpoint cannot return a subtly different player than the list does.
func playerRow(p sqlcdb.AppPlayer) *PlayerRow {
	return &PlayerRow{
		ID: p.ID.String(), Username: p.Username, Name: p.DisplayName,
		Level: int(p.Level), Gold: fmt.Sprint(p.Gold), Diamonds: p.Diamonds,
		State: p.State, IsBot: p.IsBot,
		LastSeen: p.LastSeenAt.UTC().Format("2006-01-02 15:04"),
	}
}
