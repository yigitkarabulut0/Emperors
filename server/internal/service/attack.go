package service

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/yigitkarabulut0/emperors/server/internal/db"
	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
	"github.com/yigitkarabulut0/emperors/server/internal/game"
	"github.com/yigitkarabulut0/emperors/server/internal/game/combat"
	"github.com/yigitkarabulut0/emperors/server/internal/game/economy"
)

var (
	ErrShielded   = errors.New("that lord is under protection")
	ErrOnCooldown = errors.New("you attacked them too recently")
	ErrSelfAttack = errors.New("you cannot attack yourself")
	ErrNoTargets  = errors.New("no targets available")
)

// attackCooldown stops a strong player farming one weak target the moment each
// shield lapses — the fastest way to drive a new player off.
const attackCooldown = 30 * time.Minute

// TargetView is one row on the Attack tab.
type TargetView struct {
	PlayerID string `json:"player_id"`
	Name     string `json:"name"`
	Level    int64  `json:"level"`
	Might    int64  `json:"might"`
	Gold     string `json:"gold_on_hand"`
	Estimate int64  `json:"estimated_steal"`
	IsBot    bool   `json:"is_bot"`
}

// AttackView is the Attack tab.
type AttackView struct {
	Might       int64        `json:"might"`
	EnergyCost  int64        `json:"energy_cost"`
	Energy      int64        `json:"energy"`
	ShieldUntil *time.Time   `json:"shield_until"`
	Targets     []TargetView `json:"targets"`
}

// attackEnergyCost rises slowly with level: roughly a quarter of a top-tier job,
// so attacking always competes with collecting rather than being free.
func (d Deps) attackEnergyCost(level int64) int64 { return 6 + level/6 }

// GetTargets offers a shortlist to choose from.
//
// Offer-N-choose-1 rather than forced pairing: a perfectly fair matchmaker gives
// a 50% win rate, which players experience as losing half the time. Letting them
// pick from a band makes every fight a decision they own.
func (d Deps) GetTargets(ctx context.Context, playerID uuid.UUID) (*AttackView, error) {
	q := sqlcdb.New(d.Pool)

	me, err := q.GetPlayerByID(ctx, playerID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, fmt.Errorf("load player: %w", err)
	}
	mine, err := d.GetArmy(ctx, playerID)
	if err != nil {
		return nil, err
	}

	now := d.Now()
	settled, maxE, period := settleEnergy(d.Config, me, now)
	_ = maxE
	_ = period

	view := &AttackView{
		Might:      mine.Totals.Might,
		EnergyCost: d.attackEnergyCost(int64(me.Level)),
		Energy:     economy.Whole(settled),
		Targets:    []TargetView{},
	}
	if me.ShieldUntil != nil && me.ShieldUntil.After(now) {
		view.ShieldUntil = me.ShieldUntil
	}

	// A level band rather than a Might band: Might needs a per-candidate army
	// query, and at this population a band of +-4 levels already produces a
	// spread of roughly 0.7x to 1.4x Might, which is the range where every fight
	// is a live decision.
	lo := int32(me.Level) - 4
	if lo < 1 {
		lo = 1
	}
	rows, err := q.FindTargets(ctx, sqlcdb.FindTargetsParams{
		ID: playerID, Level: lo, Level_2: int32(me.Level) + 4, Limit: 12,
	})
	if err != nil {
		return nil, fmt.Errorf("find targets: %w", err)
	}

	// Two passes: targets actually worth raiding first, broke ones only as
	// filler. A raid costs energy, so offering someone with nothing on hand
	// invites the player to win and get paid zero — which reads as the game
	// cheating them even though the arithmetic is correct.
	var rich, broke []TargetView
	for _, r := range rows {
		if len(rich) >= 3 {
			break
		}
		if cd, err := q.GetCooldown(ctx, sqlcdb.GetCooldownParams{
			AttackerID: playerID, DefenderID: r.ID,
		}); err == nil && cd.LastAt.Add(attackCooldown).After(now) {
			continue
		}
		theirs, err := d.GetArmy(ctx, r.ID)
		if err != nil {
			continue
		}
		tv := TargetView{
			PlayerID: r.ID.String(), Name: r.DisplayName, Level: int64(r.Level),
			Might: theirs.Totals.Might, Gold: itoa(r.Gold),
			Estimate: d.estimateSteal(int64(me.Level), r.Gold),
			IsBot:    r.IsBot,
		}
		if tv.Estimate >= minStealFloor {
			rich = append(rich, tv)
		} else if len(broke) < 3 {
			broke = append(broke, tv)
		}
	}

	view.Targets = rich
	for _, t := range broke {
		if len(view.Targets) >= 3 {
			break
		}
		view.Targets = append(view.Targets, t)
	}
	return view, nil
}

// estimateSteal previews the take. Capped by the ATTACKER's level, which makes
// it structurally impossible for a low-level alt to drain a rich player and
// bounds the worst single loss to a fraction of a day's income.
// minStealFloor is the smallest take worth spending energy on. It doubles as the
// bar for putting someone on the target list at all.
const minStealFloor = 10

func (d Deps) estimateSteal(attackerLevel, defenderGold int64) int64 {
	const rateBP = 300 // 3%
	const minSteal = minStealFloor
	stolen := defenderGold * rateBP / 10000
	cap := 250 * (10000 + 3500*attackerLevel) / 10000
	if stolen > cap {
		stolen = cap
	}
	if stolen < minSteal {
		stolen = minSteal
	}
	if stolen > defenderGold {
		stolen = defenderGold
	}
	return stolen
}

// AttackResult is what the client animates and then celebrates.
type AttackResult struct {
	BattleID   string         `json:"battle_id"`
	Won        bool           `json:"won"`
	GoldStolen int64          `json:"gold_stolen"`
	RansomPaid int64          `json:"ransom_paid"`
	XPGained   int64          `json:"xp_gained"`
	Replay     *combat.Replay `json:"replay"`
	Snapshot   *Snapshot      `json:"snapshot"`
}

// Attack resolves one raid.
func (d Deps) Attack(ctx context.Context, playerID, targetID uuid.UUID, wantSeq int64) (*AttackResult, error) {
	if playerID == targetID {
		return nil, ErrSelfAttack
	}

	// Both armies are read BEFORE the transaction. They are large reads, and
	// holding row locks across them would serialise every attack in the game.
	// The snapshot is frozen into the battle record, so a change between here and
	// the commit affects the next fight, not this one.
	mine, err := d.GetArmy(ctx, playerID)
	if err != nil {
		return nil, err
	}
	theirs, err := d.GetArmy(ctx, targetID)
	if err != nil {
		return nil, err
	}

	var res AttackResult
	err = db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
		q := sqlcdb.New(tx)

		// Locked in ascending uuid order. Two players attacking each other at the
		// same instant would otherwise deadlock.
		locked, err := q.LockTwoPlayers(ctx, []uuid.UUID{playerID, targetID})
		if err != nil {
			return fmt.Errorf("lock players: %w", err)
		}
		var me, target sqlcdb.AppPlayer
		for _, p := range locked {
			if p.ID == playerID {
				me = p
			} else {
				target = p
			}
		}
		if me.ID == uuid.Nil || target.ID == uuid.Nil {
			return ErrNotFound
		}
		if err := checkSeq(me, wantSeq); err != nil {
			return err
		}

		now := d.Now()
		if target.ShieldUntil != nil && target.ShieldUntil.After(now) {
			return ErrShielded
		}
		if cd, err := q.GetCooldown(ctx, sqlcdb.GetCooldownParams{
			AttackerID: playerID, DefenderID: targetID,
		}); err == nil && cd.LastAt.Add(attackCooldown).After(now) {
			return ErrOnCooldown
		}

		cost := d.attackEnergyCost(int64(me.Level))
		settled, _, _ := settleEnergy(d.Config, me, now)
		spent, ok := economy.Spend(settled, cost)
		if !ok {
			return ErrNotEnoughEnergy
		}

		attArmy := toCombatArmy(me, mine)
		defArmy := toCombatArmy(target, theirs)

		battleID := uuid.New()
		rng := game.SeedForString(d.ShopSecret, battleID.String(),
			uint64(mine.Totals.Might), uint64(theirs.Totals.Might))
		seed := rng.Uint64()
		replay := combat.Simulate(d.Config, rng, seed, attArmy, defArmy)
		won := replay.Winner == combat.SideAttacker

		// Only ON-HAND gold is at risk. Treasury deposits are safe, which is the
		// whole point of paying the deposit fee, and uncollected income is not
		// stealable either — both give players a legitimate way to shelter.
		var stolen, ransom int64
		if won {
			stolen = d.estimateSteal(int64(me.Level), target.Gold)
		} else {
			// A ransom makes "you were attacked" sometimes good news, and it is the
			// only thing that makes Defense points worth buying. Minted, not
			// transferred, and small.
			ransom = d.estimateSteal(int64(me.Level), target.Gold) * 40 / 100
		}

		xp := (10 + 8*int64(target.Level)/10)
		if !won {
			xp = xp * 35 / 100
		}
		bonuses := playerBonuses(me)
		up := economy.AwardXP(d.Config, int(me.Level), me.Xp, xp, bonuses)

		final := spent
		if up.Refilled {
			final = economy.Refill(economy.MaxEnergy(d.Config, int64(me.StatEnergy), 0), now)
		}

		afterAtt, err := q.ApplyBattleAttacker(ctx, sqlcdb.ApplyBattleAttackerParams{
			ID: playerID, Gold: stolen, Xp: up.XP, Level: int32(up.Level),
			StatPointsUnspent: int32(up.StatPoints),
			EnergyMilli:       final.Milli, EnergyUpdatedAt: final.UpdatedAt,
			ActionSeq: wantSeq,
		})
		if err != nil {
			return fmt.Errorf("apply attacker: %w", err)
		}

		defDelta := -stolen + ransom
		var shieldUntil *time.Time
		if won {
			// The shield goes to the LOSER of the defence, so being robbed buys
			// half an hour of safety to recover.
			t := now.Add(30 * time.Minute)
			shieldUntil = &t
		} else if target.ShieldUntil != nil && target.ShieldUntil.After(now) {
			shieldUntil = target.ShieldUntil
		}
		afterDef, err := q.ApplyBattleDefender(ctx, sqlcdb.ApplyBattleDefenderParams{
			ID: targetID, Gold: defDelta, ShieldUntil: shieldUntil,
		})
		if err != nil {
			return fmt.Errorf("apply defender: %w", err)
		}

		if stolen > 0 {
			// Recorded as a transfer on both sides, never a mint: the two ledger
			// rows must cancel, or the economy dashboard silently drifts.
			if err := q.RecordGold(ctx, sqlcdb.RecordGoldParams{
				PlayerID: playerID, Delta: stolen, BalanceAfter: afterAtt.Gold,
				Reason: "pvp_steal", RefID: strPtr(battleID.String()),
			}); err != nil {
				return err
			}
			if err := q.RecordGold(ctx, sqlcdb.RecordGoldParams{
				PlayerID: targetID, Delta: -stolen, BalanceAfter: afterDef.Gold,
				Reason: "pvp_stolen_from", RefID: strPtr(battleID.String()),
			}); err != nil {
				return err
			}
		}
		if ransom > 0 {
			if err := q.RecordGold(ctx, sqlcdb.RecordGoldParams{
				PlayerID: targetID, Delta: ransom, BalanceAfter: afterDef.Gold,
				Reason: "pvp_ransom", RefID: strPtr(battleID.String()),
			}); err != nil {
				return err
			}
		}

		raw, err := json.Marshal(replay)
		if err != nil {
			return fmt.Errorf("encode replay: %w", err)
		}
		if _, err := q.InsertBattle(ctx, sqlcdb.InsertBattleParams{
			AttackerID: playerID, DefenderID: targetID, Seed: int64(seed),
			ConfigVersion: int32(d.Config.Version), AttackerWon: won,
			Rounds:        int32(replay.Rounds),
			AttackerMight: mine.Totals.Might, DefenderMight: theirs.Totals.Might,
			GoldStolen: stolen, RansomPaid: ransom, XpAwarded: xp,
			EnergySpent: cost, Replay: raw,
		}); err != nil {
			return fmt.Errorf("insert battle: %w", err)
		}
		if err := q.TouchCooldown(ctx, sqlcdb.TouchCooldownParams{
			AttackerID: playerID, DefenderID: targetID,
		}); err != nil {
			return fmt.Errorf("cooldown: %w", err)
		}

		res = AttackResult{
			BattleID: battleID.String(), Won: won,
			GoldStolen: stolen, RansomPaid: ransom, XPGained: xp, Replay: replay,
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	res.Snapshot, err = d.GetState(ctx, playerID)
	return &res, err
}

func toCombatArmy(p sqlcdb.AppPlayer, v *ArmyView) combat.Army {
	a := combat.Army{PlayerID: p.ID.String(), Name: p.DisplayName, Level: int64(p.Level)}
	add := func(u UnitView) {
		a.Units = append(a.Units, combat.Combatant{
			ID: u.ID, Name: u.Name, Tier: u.Tier, Type: u.Type, IsHero: u.IsHero,
			Attack: u.Attack, Defense: u.Defense, Speed: u.Speed, HP: u.HP,
		})
	}
	add(v.Hero)
	for _, s := range v.Slots {
		if s.Soldier != nil {
			add(*s.Soldier)
		}
	}
	return a
}
