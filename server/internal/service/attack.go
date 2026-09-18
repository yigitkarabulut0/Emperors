package service

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"time"

	"github.com/jackc/pgx/v5/pgtype"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/yigitkarabulut0/emperors/server/internal/db"
	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
	"github.com/yigitkarabulut0/emperors/server/internal/game"
	"github.com/yigitkarabulut0/emperors/server/internal/game/combat"
	"github.com/yigitkarabulut0/emperors/server/internal/game/deeds"
	"github.com/yigitkarabulut0/emperors/server/internal/game/economy"
	"github.com/yigitkarabulut0/emperors/server/internal/game/estates"
	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
	"github.com/yigitkarabulut0/emperors/server/internal/ledger"
)

var (
	ErrShielded   = errors.New("that lord is under protection")
	ErrOnCooldown = errors.New("you attacked them too recently")
	ErrSelfAttack = errors.New("you cannot attack yourself")
	ErrNoTargets  = errors.New("no targets available")
	ErrNoRevenge  = errors.New("you have no score to settle with them")
	// A lord below the Attack tab's level cannot raid and cannot be raided.
	ErrTooNewToRaid = errors.New("that lord is too new to the realm to be raided")
)

// attackCooldown stops a strong player farming one weak target the moment each
// shield lapses — the fastest way to drive a new player off.
const attackCooldown = 30 * time.Minute

// raidShield is what being robbed buys the loser of a defence: half an hour
// in which nobody can raid them.
const raidShield = 30 * time.Minute

// ransomPct is the share of the ordinary take a held defence is paid.
const ransomPct = 40

// bandLevels is how far either side of their own level a lord's targets run.
const bandLevels = 4

// TargetView is one row on the Attack tab.
type TargetView struct {
	PlayerID string `json:"player_id"`
	Name     string `json:"name"`
	Avatar   string `json:"avatar"`
	Level    int64  `json:"level"`
	Might    int64  `json:"might"`
	Gold     string `json:"gold_on_hand"`
	Estimate int64  `json:"estimated_steal"`
	// The share of their purse a won raid takes, before the level cap. The card
	// prints it ("Steal up to 3% gold"), and a revenge row's is higher.
	StealRateBP int64 `json:"steal_rate_bp"`
	// What this raid costs. Sent per row because a revenge row costs half, and
	// the client must never work that out for itself.
	EnergyCost int64 `json:"energy_cost"`
	IsBot      bool  `json:"is_bot"`
	Look
}

// AttackView is the Attack tab.
type AttackView struct {
	Might       int64      `json:"might"`
	EnergyCost  int64      `json:"energy_cost"`
	Energy      int64      `json:"energy"`
	ShieldUntil *time.Time `json:"shield_until"`
	// Scores left to settle. Shown above the ordinary targets because a raid you
	// did not choose is the one the player actually wants to answer.
	Revenge []RevengeEntry `json:"revenge"`
	// How many lords have bought a look at this one's army today (rival.go).
	// It is here, on the raid page, because being scouted is a thing that
	// happens TO a lord and they should feel it where the raiding is.
	ScoutedToday int64        `json:"scouted_today"`
	Targets      []TargetView `json:"targets"`
	// The rules of raiding, as numbers, for the sheet behind the notice's (i).
	Rules RaidRules `json:"rules"`
}

// RaidRules are raiding's terms, from the constants the raid itself uses.
type RaidRules struct {
	FightLevel      int   `json:"fight_level"`
	BandLevels      int   `json:"band_levels"`
	StealRateBP     int64 `json:"steal_rate_bp"`
	RevengeRateBP   int64 `json:"revenge_rate_bp"`
	RevengeHours    int64 `json:"revenge_hours"`
	ShieldMinutes   int64 `json:"shield_minutes"`
	CooldownMinutes int64 `json:"cooldown_minutes"`
	RansomPct       int64 `json:"ransom_pct"`
	// The ceiling on one raid's take at THIS lord's level (raidCap). The sheet
	// printed the rate and not the cap, so nobody could see why three per cent
	// of a rich purse is not three per cent.
	RaidCap int64 `json:"raid_cap"`
	// Raiding ends your own protection; a revenge strike does not. Sent so the
	// rules sheet states the rule the raid actually applies.
	ShieldBreaks bool `json:"shield_breaks"`
}

// attackerShieldAfter is the raider's own shield once the raid lands.
//
// An ordinary raid ends it (economy.md §10.2). A shield is the right to be left
// alone; a lord who keeps raiding has waived it, and a shield that survived your
// own attacks made the eight-hour one in the store a licence to raid while
// untouchable -- the moment diamonds can be bought, protection for money that
// never ends. A revenge strike keeps it: answering a raid you did not choose is
// not starting one.
func attackerShieldAfter(avenging bool, cur *time.Time) *time.Time {
	if avenging {
		return cur
	}
	return nil
}

// Revenge: what a raid you lost buys you back.
//
// The terms are all asymmetric in the victim's favour on purpose. It is meant to
// be taken — a token nobody uses is a notification nobody opens.
const (
	revengeWindow = 24 * time.Hour
	// Half energy, so being raided while low does not put the answer out of
	// reach until tomorrow.
	revengeEnergyBP = 5000
	// Their shield does not stop you. Somebody who robs you and hides behind
	// half an hour of protection is precisely the case this exists for.
	// Reputation and the steal both pay more, because a raid you did not choose
	// to start should be worth answering.
	revengeStealBP = 13333 // 3% of their purse becomes 4%
	revengeRepBP   = 15000
)

// attackEnergyCost rises slowly with level: roughly a quarter of a top-tier job,
// so attacking always competes with collecting rather than being free.
func (d Deps) attackEnergyCost(level int64) int64 { return 6 + level/6 }

// revengeEnergyCost is the half-price answer, never below one. The only place
// it is worked out: the Attack tab prints it and the raid charges it, and the
// client used to round it up while the server rounded it down.
func (d Deps) revengeEnergyCost(level int64) int64 {
	cost := d.attackEnergyCost(level) * revengeEnergyBP / 10000
	if cost < 1 {
		cost = 1
	}
	return cost
}

// raidTake is what a won raid carries off.
//
// The one place the take is decided, used by the preview on the Attack tab and
// by the raid itself. They were two calls: the preview applied the War Chest
// and the raid did not, so the War Chest raised the number the player read and
// never the gold they got.
func (d Deps) raidTake(attackerLevel, defenderGold int64, attacker estates.Effects, avenging bool) int64 {
	stolen := d.estimateStealWithCap(attackerLevel, defenderGold, attacker.StealCapBP)
	if avenging {
		stolen = stolen * revengeStealBP / 10000
		if stolen > defenderGold {
			stolen = defenderGold
		}
	}
	return stolen
}

// raidRansom is what a defender is paid for holding: forty per cent of the
// ordinary take, raised by the DEFENDER's Ransom Coffers.
//
// Based on the take without the raider's War Chest, which is the raider's
// upgrade and says nothing about what the defence was worth. The Coffers were
// on sale for months and applied to nothing.
func (d Deps) raidRansom(attackerLevel, defenderGold int64, defender estates.Effects) int64 {
	ransom := d.estimateSteal(attackerLevel, defenderGold) * ransomPct / 100
	if defender.RansomBP > 0 {
		ransom = ransom * (10000 + defender.RansomBP) / 10000
	}
	return ransom
}

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

	eff, err := d.loadEffects(ctx, q, me)
	if err != nil {
		return nil, err
	}

	now := d.Now()
	settled, _, _ := settleEnergy(d.Config, me, eff, now)

	view := &AttackView{
		Might:      mine.Totals.Might,
		EnergyCost: d.attackEnergyCost(int64(me.Level)),
		Energy:     economy.Whole(settled),
		Targets:    []TargetView{},
		Revenge:    []RevengeEntry{},
		Rules: RaidRules{
			FightLevel: d.Config.SectionLevel(fightSection), BandLevels: bandLevels,
			StealRateBP: raidRateBP, RevengeRateBP: revengeRateBP,
			RevengeHours:    int64(revengeWindow / time.Hour),
			ShieldMinutes:   int64(raidShield / time.Minute),
			CooldownMinutes: int64(attackCooldown / time.Minute),
			RansomPct:       ransomPct,
			RaidCap:         raidCap(int64(me.Level)),
			ShieldBreaks:    true,
		},
	}
	if rev, err := d.listRevenge(ctx, q, me, eff, now); err == nil {
		view.Revenge = rev
	}
	view.ScoutedToday = d.ScoutedToday(ctx, q, playerID, localDay(now, me.ResetOffsetMinutes))
	if me.ShieldUntil != nil && me.ShieldUntil.After(now) {
		view.ShieldUntil = me.ShieldUntil
	}

	// A level band rather than a Might band: Might needs a per-candidate army
	// query, and at this population a band of +-4 levels already produces a
	// spread of roughly 0.7x to 1.4x Might, which is the range where every fight
	// is a live decision.
	//
	// Floored at the level that opens the Attack tab: below it a lord has no way
	// to answer a raid, so they are not offered as a target at all.
	lo, hi := raidBand(me.Level, int32(d.Config.SectionLevel(fightSection)))
	rows, err := q.FindTargets(ctx, sqlcdb.FindTargetsParams{
		ID: playerID, Level: lo, Level_2: hi, Limit: 12,
	})
	if err != nil {
		return nil, fmt.Errorf("find targets: %w", err)
	}

	// Score every candidate, then choose. Two earlier attempts were both wrong:
	// taking the first three offered fights nobody wanted to win, and preferring
	// the richest correlated wealth with strength, so every target came back
	// "stronger" and the list stopped being a decision.
	//
	// The rule that works: prefer targets inside the 0.85x-1.35x Might band,
	// where the win rate spans roughly 25%-87% and every choice is live, and
	// within the band prefer the bigger prize.
	type candidate struct {
		view   TargetView
		inBand bool
	}
	var cands []candidate
	myMight := mine.Totals.Might
	if myMight < 1 {
		myMight = 1
	}

	for _, r := range rows {
		// Members of your own kingdom are never offered. Raiding an ally would
		// make the kingdom a liability rather than a reason to join one.
		if me.KingdomID != nil && r.KingdomID != nil && *r.KingdomID == *me.KingdomID {
			continue
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
			PlayerID: r.ID.String(), Name: r.DisplayName, Avatar: r.Avatar, Level: int64(r.Level),
			Might: theirs.Totals.Might, Gold: itoa(r.Gold),
			Estimate:    d.raidTake(int64(me.Level), r.Gold, eff, false),
			StealRateBP: raidRateBP,
			EnergyCost:  view.EnergyCost,
			IsBot:       r.IsBot,
			Look:        lookOf(d.Config, r.CosFrame, r.CosTitle, r.CosColor, r.CosCrest, r.VipPoints),
		}
		ratioBP := tv.Might * 10000 / myMight
		cands = append(cands, candidate{
			view:   tv,
			inBand: ratioBP >= bandLowBP && ratioBP <= bandHighBP && tv.Estimate >= minStealFloor,
		})
	}

	sort.SliceStable(cands, func(i, j int) bool {
		if cands[i].inBand != cands[j].inBand {
			return cands[i].inBand
		}
		return cands[i].view.Estimate > cands[j].view.Estimate
	})
	for _, c := range cands {
		if len(view.Targets) >= 3 {
			break
		}
		view.Targets = append(view.Targets, c.view)
	}
	return view, nil
}

// raidBand is the level range a lord's targets are drawn from: four either side,
// never below the level that opens the Attack tab. Empty (lo > hi) for a lord
// who is under it themselves.
func raidBand(level, fightAt int32) (lo, hi int32) {
	if level < fightAt {
		return fightAt, fightAt - 1
	}
	lo, hi = level-bandLevels, level+bandLevels
	if lo < fightAt {
		lo = fightAt
	}
	if lo < 1 {
		lo = 1
	}
	return lo, hi
}

// raidRateBP is the share of a purse a won raid takes, before the cap.
const raidRateBP = 300 // 3%

// revengeRateBP is the same share on a revenge strike, rounded for the card.
const revengeRateBP = (raidRateBP*revengeStealBP + 5000) / 10000

// estimateSteal previews the take. Capped by the ATTACKER's level, which makes
// it structurally impossible for a low-level alt to drain a rich player and
// bounds the worst single loss to a fraction of a day's income.
// minStealFloor is the smallest take worth spending energy on. It doubles as the
// bar for calling a target worth offering.
const minStealFloor = 10

// The matchmaking band, in basis points of the attacker's own Might. Inside it
// the win rate runs from roughly 25% to 87%, which is the range where choosing a
// target is a real decision rather than reading a number.
const (
	bandLowBP  = 8500
	bandHighBP = 13500
)

func (d Deps) estimateSteal(attackerLevel, defenderGold int64) int64 {
	return d.estimateStealWithCap(attackerLevel, defenderGold, 0)
}

// raidCap is the ceiling on what one won fight carries off, by the ATTACKER's
// level, and the one place that ceiling is written down.
//
// It was a literal inside estimateStealWithCap, which was fine while the raid
// was the only thing that used it. A bounty pays a multiple of it, and a second
// copy of "250 * (10000 + 3500*level)" is the shape of the War Chest bug: two
// call sites with different arguments, one of which the player read and the
// other of which the game ran on. The two numbers are declared INSIDE it so a
// second reader cannot reach them.
func raidCap(attackerLevel int64) int64 {
	const (
		raidCapBase       = 250
		raidCapPerLevelBP = 3500
	)
	return raidCapBase * (10000 + raidCapPerLevelBP*attackerLevel) / 10000
}

// estimateStealWithCap applies the War Chest bonus to the ceiling.
func (d Deps) estimateStealWithCap(attackerLevel, defenderGold, capBonusBP int64) int64 {
	const minSteal = minStealFloor
	stolen := defenderGold * raidRateBP / 10000
	cap := raidCap(attackerLevel)
	if capBonusBP > 0 {
		cap = cap * (10000 + capBonusBP) / 10000
	}
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

// fightSection is the navigation section that opens the Attack tab.
const fightSection = "fight"

// AttackResult is what the client animates and then celebrates.
//
// Told from the attacker's side, like a stored battle read back by the
// attacker: perspective says whose story it is, and Gold is signed from this
// player's purse. A ransom is the DEFENDER's -- it is reported so the loser can
// read what their failed raid paid the other side, not so it can be counted as
// theirs, which is what the result screen used to do.
type AttackResult struct {
	BattleID    string `json:"battle_id"`
	Perspective string `json:"perspective"`
	Won         bool   `json:"won"`
	Revenge     bool   `json:"revenge"`
	Gold        int64  `json:"gold"`
	GoldStolen  int64  `json:"gold_stolen"`
	RansomPaid  int64  `json:"ransom_paid"`
	XPGained    int64  `json:"xp_gained"`
	// What a bounty on this head paid the hunter, on top of the take.
	BountyPaid int64 `json:"bounty_paid,omitempty"`
	// The level-up grant, when the raid's experience crossed a level.
	DiamondsGained int64          `json:"diamonds_gained,omitempty"`
	Replay         *combat.Replay `json:"replay"`
	Snapshot       *Snapshot      `json:"snapshot"`
}

// raidOpts is what makes one raid different from another.
//
// A bounty hunt is a RAID: same energy, same steal, same ransom, same revenge
// token for the loser, same renown. Giving it its own fight path would be a
// second implementation of the one formula this file exists to keep single --
// the mistake raidTake was written to undo.
type raidOpts struct {
	Revenge bool
	// Set for a bounty hunt; nil for an ordinary raid.
	Bounty *bountyHunt
}

// ignoresShield is the one place the question is asked.
//
// A revenge strike always goes through a shield: answering a raid you did not
// choose is not starting one. A bounty hunt does only when the balance says so,
// and it does not -- a shield is a shield, the forty-eight hours outlast any
// shield sold, and the hunted lord is told a price is on their head.
func (o raidOpts) ignoresShield(cfg *gameconfig.Bundle) bool {
	return o.Revenge || (o.Bounty != nil && cfg.PvP.Bounty.IgnoresShield)
}

// battleKind is what app.battles records this fight as.
func battleKind(o raidOpts) string {
	if o.Bounty != nil {
		return "bounty"
	}
	return "raid"
}

// Attack resolves one raid. The signature is unchanged: every caller, route and
// test is untouched by the extraction.
func (d Deps) Attack(ctx context.Context, playerID, targetID uuid.UUID, wantSeq int64, wantRevenge bool) (*AttackResult, error) {
	return d.raid(ctx, playerID, targetID, wantSeq, raidOpts{Revenge: wantRevenge})
}

// raid is the one fight path: an ordinary raid, a revenge strike and a bounty
// hunt are the same transaction with three small differences.
func (d Deps) raid(ctx context.Context, playerID, targetID uuid.UUID, wantSeq int64, opts raidOpts) (*AttackResult, error) {
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
	var bountyPaid int64
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
		if me.KingdomID != nil && target.KingdomID != nil && *me.KingdomID == *target.KingdomID {
			return ErrSameKingdom
		}
		// Both sides of a raid must have the Attack tab: the raider to start
		// one, the target to be able to answer it.
		fightAt := int32(d.Config.SectionLevel(fightSection))
		if me.Level < fightAt {
			return fmt.Errorf("%w: raiding opens at level %d", ErrLevelTooLow, fightAt)
		}
		if target.Level < fightAt {
			return ErrTooNewToRaid
		}
		// A revenge strike is claimed FIRST, because claiming it is what lifts
		// the two guards below. Zero rows back means there was no live token and
		// this is an ordinary raid, which then has to obey them.
		avenging := false
		if opts.Revenge {
			if _, err := q.UseRevenge(ctx, sqlcdb.UseRevengeParams{
				PlayerID: playerID, TargetID: targetID,
			}); err != nil {
				if !errors.Is(err, pgx.ErrNoRows) {
					return fmt.Errorf("use revenge: %w", err)
				}
				return ErrNoRevenge
			}
			avenging = true
		}

		if !opts.ignoresShield(d.Config) {
			if target.ShieldUntil != nil && target.ShieldUntil.After(now) {
				return ErrShielded
			}
		}
		// The per-pair cooldown. A bounty hunt has its own, looser rule (four a
		// day on one head, then two hours), checked in checkBountyHunt against
		// the same app.attack_cooldowns row -- one counter, one answer.
		if !avenging && opts.Bounty == nil {
			if cd, err := q.GetCooldown(ctx, sqlcdb.GetCooldownParams{
				AttackerID: playerID, DefenderID: targetID,
			}); err == nil && cd.LastAt.Add(attackCooldown).After(now) {
				return ErrOnCooldown
			}
		}
		if opts.Bounty != nil {
			if err := d.checkBountyHunt(ctx, q, me, target, opts.Bounty, now); err != nil {
				return err
			}
		}

		eff, err := d.loadEffects(ctx, q, me)
		if err != nil {
			return err
		}
		// The defender's own estate decides what holding them off pays.
		defEff, err := d.loadEffects(ctx, q, target)
		if err != nil {
			return err
		}

		cost := d.attackEnergyCost(int64(me.Level))
		if avenging {
			cost = d.revengeEnergyCost(int64(me.Level))
		}
		settled, _, _ := settleEnergy(d.Config, me, eff, now)
		spent, ok := economy.Spend(settled, cost)
		if !ok {
			return ErrNotEnoughEnergy
		}

		attArmy := myArmy(me, mine)
		defArmy := theirArmy(target, theirs)

		battleID := uuid.New()
		rng := game.SeedForString(d.ShopSecret, battleID.String(),
			uint64(mine.Totals.Might), uint64(theirs.Totals.Might))
		seed := rng.Uint64()
		replay := combat.Simulate(d.Config, rng, seed, attArmy, defArmy)
		replay.AttackerMight = mine.Totals.Might
		replay.DefenderMight = theirs.Totals.Might
		won := replay.Winner == combat.SideAttacker

		// Only ON-HAND gold is at risk. Treasury deposits are safe, which is the
		// whole point of paying the deposit fee, and uncollected income is not
		// stealable either — both give players a legitimate way to shelter.
		var stolen, ransom int64
		if won {
			stolen = d.raidTake(int64(me.Level), target.Gold, eff, avenging)
		} else {
			// A ransom makes "you were attacked" sometimes good news, and it is the
			// only thing that makes Defense points worth buying. Minted, not
			// transferred, and small.
			ransom = d.raidRansom(int64(me.Level), target.Gold, defEff)
		}

		xp := (10 + 8*int64(target.Level)/10)
		if !won {
			xp = xp * 35 / 100
		}
		up := economy.AwardXP(d.Config, int(me.Level), me.Xp, xp, eff.Bonuses)

		final := spent
		if up.Refilled {
			final = economy.Refill(levelUpMax(d.Config, me, up, eff), now)
		}

		afterAtt, err := q.ApplyBattleAttacker(ctx, sqlcdb.ApplyBattleAttackerParams{
			ID: playerID, Gold: stolen, Xp: up.XP, Level: int32(up.Level),
			StatPointsUnspent: int32(up.StatPoints),
			EnergyMilli:       final.Milli, EnergyUpdatedAt: final.UpdatedAt,
			ActionSeq: wantSeq,
			// A level reached in a raid pays what a level reached anywhere pays.
			// This was dropped, so a level-up won on the Attack tab granted its
			// stat points and none of its diamonds.
			Diamonds: up.Diamonds,
			// Raiding ends your own protection; revenge keeps it.
			ShieldUntil: attackerShieldAfter(avenging, me.ShieldUntil),
		})
		if err != nil {
			return fmt.Errorf("apply attacker: %w", err)
		}
		if err := ledger.Diamonds(ctx, q, me, afterAtt, up.Diamonds, ledger.LevelUp,
			levelRef(me.Level, up.Level)); err != nil {
			return err
		}

		defDelta := -stolen + ransom
		var shieldUntil *time.Time
		if won {
			// The shield goes to the LOSER of the defence, so being robbed buys
			// half an hour of safety to recover.
			t := now.Add(raidShield)
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
			ID:         battleID,
			AttackerID: playerID, DefenderID: targetID, Seed: int64(seed),
			ConfigVersion: int32(d.Config.Version), AttackerWon: won,
			Rounds:        int32(replay.Rounds),
			AttackerMight: mine.Totals.Might, DefenderMight: theirs.Totals.Might,
			GoldStolen: stolen, RansomPaid: ransom, XpAwarded: xp,
			EnergySpent: cost, Replay: raw, Kind: battleKind(opts),
		}); err != nil {
			return fmt.Errorf("insert battle: %w", err)
		}
		if err := q.TouchCooldown(ctx, sqlcdb.TouchCooldownParams{
			AttackerID: playerID, DefenderID: targetID,
		}); err != nil {
			return fmt.Errorf("cooldown: %w", err)
		}

		// A won hunt draws its price. AFTER the battle row, because the claim
		// references it -- the same reason a revenge token is granted here and
		// not before.
		if opts.Bounty != nil && won {
			paid, err := d.drawBounty(ctx, q, &afterAtt, opts.Bounty, target, battleID, now)
			if err != nil {
				return err
			}
			bountyPaid = paid
		}

		// The loser of a defence earns the right to strike back.
		//
		// After the battle row, not before: the token references it, and the
		// foreign key is the thing that guarantees a token can always show the
		// player which raid it is answering.
		//
		// Independent of the shield. The shield is half an hour of safety; the
		// token is a day to answer, and it deliberately ignores the shield the
		// raider will be hiding behind.
		if won {
			until := now.Add(revengeWindow)
			if err := q.GrantRevenge(ctx, sqlcdb.GrantRevengeParams{
				BattleID: battleID, PlayerID: targetID, TargetID: playerID,
				ExpiresAt: until,
			}); err != nil {
				return fmt.Errorf("grant revenge: %w", err)
			}
		}

		repBP := eff.ReputationBP
		if avenging {
			repBP += revengeRepBP - 10000
		}
		if err := d.awardReputation(ctx, q, me, repBP, won,
			mine.Totals.Might, theirs.Totals.Might, now); err != nil {
			return err
		}

		raid := deeds.Deeds{
			deeds.Raids: 1, deeds.Energy: cost, deeds.GoldStolen: stolen,
			deeds.XP: economy.ApplyBucket(xp, eff.Bonuses, economy.BucketXPGain),
		}
		if won {
			raid[deeds.RaidWins] = 1
			if avenging {
				raid[deeds.RevengeWins] = 1
			}
		}
		if opts.Bounty != nil {
			raid[deeds.BountiesClaimed] = boolToI64(bountyPaid > 0)
			raid[deeds.BountyGold] = bountyPaid
		}
		d.recordDeeds(ctx, tx, me, raid)
		if !won {
			// A defence that held is the defender's deed, counted on their week.
			d.recordDeeds(ctx, tx, target, deeds.Deeds{deeds.DefensesHeld: 1})
		} else if !target.IsBot {
			// A raid suffered is the moment Walls and Watchmen is offered to the
			// lord who was raided. In a savepoint: an offer that cannot be written
			// never costs the raid.
			d.softStep(ctx, tx, "raided offer", func(sq *sqlcdb.Queries) error {
				return d.fireMomentOffers(ctx, sq, target.ID, target.Level, gameconfig.TriggerRaided, now)
			})
		}

		res = AttackResult{
			BattleID: battleID.String(), Perspective: "attacker", Won: won, Revenge: avenging,
			Gold: stolen + bountyPaid, GoldStolen: stolen, RansomPaid: ransom,
			BountyPaid: bountyPaid, XPGained: xp,
			DiamondsGained: up.Diamonds, Replay: replay,
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	res.Snapshot, err = d.GetState(ctx, playerID)
	return &res, err
}

// myArmy is the lord's own army as it marches: whoever is in the yard. A
// soldier away on an expedition does not fight, which is the whole cost of
// sending them -- the road pays no energy, so what it costs is the soldier.
func myArmy(p sqlcdb.AppPlayer, v *ArmyView) combat.Army { return toCombatArmy(p, v, false) }

// theirArmy is a lord's army as it DEFENDS: everybody, away or not.
//
// A lord cannot choose when they are raided. If an expedition thinned the
// defence, sending soldiers out would be a standing invitation -- and the raid
// band matches on the roster's Might (ArmyView.Totals), so a defence that left
// soldiers out would be weaker than the number the attacker was matched on.
func theirArmy(p sqlcdb.AppPlayer, v *ArmyView) combat.Army { return toCombatArmy(p, v, true) }

func toCombatArmy(p sqlcdb.AppPlayer, v *ArmyView, withAway bool) combat.Army {
	a := combat.Army{PlayerID: p.ID.String(), Name: p.DisplayName, Avatar: p.Avatar, Level: int64(p.Level)}
	add := func(u UnitView) {
		// The weapon rides along so the replay can swing the sword the player
		// actually bought rather than a stand-in.
		weapon := ""
		if w := u.Equipped["weapon"]; w != nil {
			weapon = w.Art
		}
		a.Units = append(a.Units, combat.Combatant{
			ID: u.ID, Name: u.Name, Tier: u.Tier, Type: u.Type, IsHero: u.IsHero,
			Weapon: weapon,
			Attack: u.Attack, Defense: u.Defense, Speed: u.Speed, HP: u.HP,
		})
	}
	add(v.Hero)
	for _, s := range v.Slots {
		if s.Soldier == nil || (!withAway && s.Soldier.Away != nil) {
			continue
		}
		add(*s.Soldier)
	}
	return a
}

// awardReputation credits the attacker's kingdom for a raid.
//
// Scaled by the Might gap, so punching up is worth more than farming down — the
// alternative rewards a kingdom for finding the weakest opponents, which is the
// opposite of what a leaderboard should encourage. Capped per member per day so
// one obsessive player cannot carry a kingdom alone.
func (d Deps) awardReputation(ctx context.Context, q *sqlcdb.Queries, me sqlcdb.AppPlayer,
	repBonusBP int64, won bool, myMight, theirMight int64, now time.Time) error {

	if me.KingdomID == nil {
		return nil
	}
	cfg := d.Config.Kingdoms.Reputation

	var rep int64 = 2 // a loss still shows you turned up
	if won {
		if myMight < 1 {
			myMight = 1
		}
		ratioBP := theirMight * 10000 / myMight
		rep = 8 * ratioBP / 10000
		if rep < 3 {
			rep = 3
		}
		if rep > 40 {
			rep = 40
		}
	}
	if repBonusBP > 0 {
		rep = rep * (10000 + repBonusBP) / 10000
	}

	today := int64(0)
	if me.KingdomDay.Valid && sameDay(me.KingdomDay.Time, now) {
		today = int64(me.KingdomRepToday)
	}
	remaining := cfg.DailyCapPerMember - today
	if remaining <= 0 {
		return nil
	}
	if rep > remaining {
		rep = remaining
	}

	if _, err := q.BumpMemberReputation(ctx, sqlcdb.BumpMemberReputationParams{
		ID: me.ID, KingdomRepToday: int32(rep), KingdomDay: pgtype.Date{Time: now, Valid: true},
	}); err != nil {
		return fmt.Errorf("member reputation: %w", err)
	}
	// Stored scaled so the nightly 2% decay does not round a small kingdom away.
	if err := q.AddKingdomReputation(ctx, sqlcdb.AddKingdomReputationParams{
		ID: *me.KingdomID, Reputation: rep * reputationScale,
	}); err != nil {
		return fmt.Errorf("kingdom reputation: %w", err)
	}
	// The same renown, counted on the WEEK, which is what the Throne is decided
	// on. The standing figure is cumulative and decays, so "most on Monday"
	// would crown the same kingdom every Monday and Emperor of the Week would be
	// over after one. Same transaction, same per-member cap, same scale.
	//
	// Note what does NOT call this: the Honour Arena. The Throne is meant to
	// reward kingdom war, and an arena feeding it would turn the crown into a
	// five-fights-a-day race carrying none of raiding's punch-down rules.
	if err := q.BumpKingdomWeek(ctx, sqlcdb.BumpKingdomWeekParams{
		KingdomID: *me.KingdomID, Uweek: deeds.UWeek(now), Reputation: rep * reputationScale,
	}); err != nil {
		return fmt.Errorf("kingdom week: %w", err)
	}

	// Reputation also levels the kingdom, so a warlike kingdom grows without
	// anyone donating a coin.
	k, err := q.LockKingdom(ctx, *me.KingdomID)
	if err != nil {
		return err
	}
	xp := rep * d.Config.Kingdoms.Donation.XPPerReputation
	newLevel, _ := d.Config.KingdomLevelFor(k.Xp + xp)
	_, err = q.AddKingdomTreasury(ctx, sqlcdb.AddKingdomTreasuryParams{
		ID: k.ID, Treasury: 0, Xp: xp, Level: int32(newLevel),
	})
	return err
}

// --- battle history -----------------------------------------------------
//
// Every fight was already being stored with its full replay and an index on
// both sides (00006_battles.sql). Nothing read it. A defender therefore logged
// in with less gold and no explanation, and the ransom rule -- which pays you
// for LOSING a defence, and is one of the more interesting things in the
// economy -- could never be experienced as news, only inferred from a balance.

// BattleLogEntry is one fight as it looks from one player's side.
//
// Deliberately told from the player's point of view rather than the record's:
// the stored row knows an attacker and a defender, but what the player needs to
// read is "you raided X" or "X raided you", and whether they ended up up or
// down. Working that out on the client would mean teaching it the same rule
// twice.
type BattleLogEntry struct {
	BattleID string `json:"battle_id"`
	At       string `json:"at"`

	// Raided is true when somebody attacked THIS player.
	Raided bool `json:"raided"`
	Won    bool `json:"won"`

	OpponentName   string `json:"opponent_name"`
	OpponentAvatar string `json:"opponent_avatar"`
	OpponentLevel  int64  `json:"opponent_level"`
	OpponentIsBot  bool   `json:"opponent_is_bot"`
	// How the opponent looks now (Look).
	OpponentLook Look `json:"opponent_look"`

	// Signed, from this player's purse: positive is gold that arrived.
	Gold     int64 `json:"gold"`
	XPGained int64 `json:"xp_gained"`
	Rounds   int64 `json:"rounds"`
}

// BattleLog is the history screen's payload.
type BattleLog struct {
	Entries []BattleLogEntry `json:"entries"`
}

// battleLogLimit is how far back the log goes.
//
// Not paginated: a screen nobody scrolls past the first dozen rows does not
// need a cursor, and capping the query is what keeps it index-only.
const battleLogLimit = 50

// GetBattleLog returns this player's recent fights, attacking and defending.
func (d Deps) GetBattleLog(ctx context.Context, playerID uuid.UUID) (*BattleLog, error) {
	q := sqlcdb.New(d.Pool)
	rows, err := q.ListBattleLog(ctx, sqlcdb.ListBattleLogParams{
		PlayerID: playerID, Lim: battleLogLimit,
	})
	if err != nil {
		return nil, fmt.Errorf("battle log: %w", err)
	}

	out := &BattleLog{Entries: make([]BattleLogEntry, 0, len(rows))}
	for _, r := range rows {
		raided := r.DefenderID == playerID
		e := BattleLogEntry{
			BattleID: r.ID.String(),
			At:       r.CreatedAt.UTC().Format(time.RFC3339),
			Raided:   raided,
			// "Won" is from this player's side, not the record's.
			Won:            r.AttackerWon != raided,
			OpponentName:   r.OpponentName,
			OpponentAvatar: r.OpponentAvatar,
			OpponentLevel:  int64(r.OpponentLevel),
			OpponentIsBot:  r.OpponentIsBot,
			OpponentLook: lookOf(d.Config, r.OpponentCosFrame, r.OpponentCosTitle, r.OpponentCosColor,
				r.OpponentCosCrest, r.OpponentVipPoints),
			Rounds: int64(r.Rounds),
		}
		if raided {
			// A defender loses the stolen gold and is paid the ransom. Exactly
			// one of the two is ever non-zero.
			e.Gold = r.RansomPaid - r.GoldStolen
		} else {
			e.Gold = r.GoldStolen
			e.XPGained = r.XpAwarded
		}
		out.Entries = append(out.Entries, e)
	}
	return out, nil
}

// BattleReplayView is one stored fight, told from the reader's side.
//
// The record knows an attacker and a defender; the screen needs to know which
// of the two is looking. A defence used to be replayed with the reader's own
// face on the raider, and the gold they lost read as "no spoils".
type BattleReplayView struct {
	BattleID string `json:"battle_id"`
	// "attacker" when the reader started the fight, "defender" when they were
	// raided. The replay's sides are the record's; this says which is "you".
	Perspective string `json:"perspective"`
	// From the reader's side.
	Won bool `json:"won"`
	// Signed, from the reader's purse: what arrived (a take, a ransom) or left.
	Gold       int64          `json:"gold"`
	GoldStolen int64          `json:"gold_stolen"`
	RansomPaid int64          `json:"ransom_paid"`
	XPGained   int64          `json:"xp_gained"`
	Replay     *combat.Replay `json:"replay"`
}

// GetBattleReplay returns one stored fight so it can be watched again.
//
// Membership is checked here rather than in the query: a battle is readable by
// the two people who fought it and nobody else, and that is an authorisation
// rule, not a filter.
func (d Deps) GetBattleReplay(ctx context.Context, playerID, battleID uuid.UUID) (*BattleReplayView, error) {
	q := sqlcdb.New(d.Pool)
	b, err := q.GetBattle(ctx, battleID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, fmt.Errorf("battle: %w", err)
	}
	if b.AttackerID != playerID && b.DefenderID != playerID {
		// Not "forbidden": a player has no business learning that a battle id
		// they guessed at exists.
		return nil, ErrNotFound
	}

	var rep combat.Replay
	if err := json.Unmarshal(b.Replay, &rep); err != nil {
		return nil, fmt.Errorf("decode replay: %w", err)
	}
	return battleReplayView(b, playerID, &rep), nil
}

// battleReplayView tells a stored battle from one side. Pure, so the side-taking
// is tested without a database.
func battleReplayView(b sqlcdb.AppBattle, playerID uuid.UUID, rep *combat.Replay) *BattleReplayView {
	v := &BattleReplayView{
		BattleID:   b.ID.String(),
		GoldStolen: b.GoldStolen, RansomPaid: b.RansomPaid,
		Replay: rep,
	}
	if b.DefenderID == playerID && b.AttackerID != playerID {
		v.Perspective = "defender"
		v.Won = !b.AttackerWon
		// Exactly one of the two is ever non-zero.
		v.Gold = b.RansomPaid - b.GoldStolen
		return v
	}
	v.Perspective = "attacker"
	v.Won = b.AttackerWon
	v.Gold = b.GoldStolen
	v.XPGained = b.XpAwarded
	return v
}

// RevengeEntry is one score left to settle.
//
// Shaped like a TargetView -- the same names for the same things -- because it
// is drawn on the same card. It used to carry target_name, target_level and no
// might or take at all, so the card read a blank name, level 1, 0 power and
// "steal 0", and the ATTACK button sent an empty target id.
type RevengeEntry struct {
	BattleID string `json:"battle_id"`
	PlayerID string `json:"player_id"`
	Name     string `json:"name"`
	Avatar   string `json:"avatar"`
	Level    int64  `json:"level"`
	Might    int64  `json:"might"`
	// With the revenge terms applied: a third more than an ordinary raid.
	Estimate    int64  `json:"estimated_steal"`
	StealRateBP int64  `json:"steal_rate_bp"`
	EnergyCost  int64  `json:"energy_cost"`
	ExpiresAt   string `json:"expires_at"`
	// Seconds left, so the countdown needs no clock arithmetic on the phone.
	ExpiresIn int64 `json:"expires_in"`
	Look
}

// revengeListMax bounds the Might lookups one Attack tab read will make.
const revengeListMax = 6

// listRevenge returns this player's live, unspent tokens, one per raider.
//
// One per raider because one strike settles them all: UseRevenge spends every
// token held against that lord. Two rows for one raider would offer a second
// strike that is already gone.
func (d Deps) listRevenge(ctx context.Context, q *sqlcdb.Queries, me sqlcdb.AppPlayer,
	eff estates.Effects, now time.Time) ([]RevengeEntry, error) {

	rows, err := q.ListRevenge(ctx, me.ID)
	if err != nil {
		return nil, fmt.Errorf("revenge: %w", err)
	}
	out := make([]RevengeEntry, 0, len(rows))
	at := map[uuid.UUID]int{}
	for _, r := range rows {
		// Somebody who has since joined your kingdom is an ally now, and the
		// raid would be refused.
		if me.KingdomID != nil && r.TargetKingdomID != nil && *me.KingdomID == *r.TargetKingdomID {
			continue
		}
		left := int64(r.ExpiresAt.Sub(now) / time.Second)
		if left <= 0 {
			continue
		}
		if i, seen := at[r.TargetID]; seen {
			// The strike settles every token, so the row shows the longest.
			if left > out[i].ExpiresIn {
				out[i].ExpiresIn = left
				out[i].ExpiresAt = r.ExpiresAt.UTC().Format(time.RFC3339)
			}
			continue
		}
		if len(out) >= revengeListMax {
			continue
		}
		var might int64
		if theirs, err := d.GetArmy(ctx, r.TargetID); err == nil {
			might = theirs.Totals.Might
		}
		at[r.TargetID] = len(out)
		out = append(out, RevengeEntry{
			BattleID: r.BattleID.String(), PlayerID: r.TargetID.String(),
			Name: r.TargetName, Avatar: r.TargetAvatar, Level: int64(r.TargetLevel),
			Look: lookOf(d.Config, r.TargetCosFrame, r.TargetCosTitle, r.TargetCosColor, r.TargetCosCrest,
				r.TargetVipPoints),
			Might:       might,
			Estimate:    d.raidTake(int64(me.Level), r.TargetGold, eff, true),
			StealRateBP: revengeRateBP,
			EnergyCost:  d.revengeEnergyCost(int64(me.Level)),
			ExpiresAt:   r.ExpiresAt.UTC().Format(time.RFC3339),
			ExpiresIn:   left,
		})
	}
	return out, nil
}
