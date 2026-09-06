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
	"github.com/yigitkarabulut0/emperors/server/internal/game/economy"
)

var (
	ErrShielded   = errors.New("that lord is under protection")
	ErrOnCooldown = errors.New("you attacked them too recently")
	ErrSelfAttack = errors.New("you cannot attack yourself")
	ErrNoTargets  = errors.New("no targets available")
	ErrNoRevenge  = errors.New("you have no score to settle with them")
)

// attackCooldown stops a strong player farming one weak target the moment each
// shield lapses — the fastest way to drive a new player off.
const attackCooldown = 30 * time.Minute

// TargetView is one row on the Attack tab.
type TargetView struct {
	PlayerID string `json:"player_id"`
	Name     string `json:"name"`
	Avatar   string `json:"avatar"`
	Level    int64  `json:"level"`
	Might    int64  `json:"might"`
	Gold     string `json:"gold_on_hand"`
	Estimate int64  `json:"estimated_steal"`
	IsBot    bool   `json:"is_bot"`
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
	Targets []TargetView   `json:"targets"`
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
	}
	if rev, err := d.listRevenge(ctx, q, playerID); err == nil {
		view.Revenge = rev
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
			Estimate: d.estimateStealWithCap(int64(me.Level), r.Gold, eff.StealCapBP),
			IsBot:    r.IsBot,
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

// estimateStealWithCap applies the War Chest bonus to the ceiling.
func (d Deps) estimateStealWithCap(attackerLevel, defenderGold, capBonusBP int64) int64 {
	const rateBP = 300 // 3%
	const minSteal = minStealFloor
	stolen := defenderGold * rateBP / 10000
	cap := 250 * (10000 + 3500*attackerLevel) / 10000
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
func (d Deps) Attack(ctx context.Context, playerID, targetID uuid.UUID, wantSeq int64, wantRevenge bool) (*AttackResult, error) {
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
		if me.KingdomID != nil && target.KingdomID != nil && *me.KingdomID == *target.KingdomID {
			return ErrSameKingdom
		}
		// A revenge strike is claimed FIRST, because claiming it is what lifts
		// the two guards below. Zero rows back means there was no live token and
		// this is an ordinary raid, which then has to obey them.
		avenging := false
		if wantRevenge {
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

		if !avenging {
			if target.ShieldUntil != nil && target.ShieldUntil.After(now) {
				return ErrShielded
			}
			if cd, err := q.GetCooldown(ctx, sqlcdb.GetCooldownParams{
				AttackerID: playerID, DefenderID: targetID,
			}); err == nil && cd.LastAt.Add(attackCooldown).After(now) {
				return ErrOnCooldown
			}
		}

		eff, err := d.loadEffects(ctx, q, me)
		if err != nil {
			return err
		}

		cost := d.attackEnergyCost(int64(me.Level))
		if avenging {
			cost = cost * revengeEnergyBP / 10000
			if cost < 1 {
				cost = 1
			}
		}
		settled, _, _ := settleEnergy(d.Config, me, eff, now)
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
		replay.AttackerMight = mine.Totals.Might
		replay.DefenderMight = theirs.Totals.Might
		won := replay.Winner == combat.SideAttacker

		// Only ON-HAND gold is at risk. Treasury deposits are safe, which is the
		// whole point of paying the deposit fee, and uncollected income is not
		// stealable either — both give players a legitimate way to shelter.
		var stolen, ransom int64
		if won {
			stolen = d.estimateSteal(int64(me.Level), target.Gold)
			if avenging {
				stolen = stolen * revengeStealBP / 10000
				if stolen > target.Gold {
					stolen = target.Gold
				}
			}
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
		up := economy.AwardXP(d.Config, int(me.Level), me.Xp, xp, eff.Bonuses)

		final := spent
		if up.Refilled {
			final = economy.Refill(economy.MaxEnergy(d.Config, int64(me.Level), int64(me.StatEnergy), eff.MaxEnergyFlat), now)
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
			ID:         battleID,
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

		wins := int64(0)
		if won {
			wins = 1
		}
		if err := d.bumpQuests(ctx, q, me, 0, wins, 0, cost); err != nil {
			d.logQuestBump(err)
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
	a := combat.Army{PlayerID: p.ID.String(), Name: p.DisplayName, Avatar: p.Avatar, Level: int64(p.Level)}
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
			Rounds:         int64(r.Rounds),
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

// GetBattleReplay returns one stored fight so it can be watched again.
//
// Membership is checked here rather than in the query: a battle is readable by
// the two people who fought it and nobody else, and that is an authorisation
// rule, not a filter.
func (d Deps) GetBattleReplay(ctx context.Context, playerID, battleID uuid.UUID) (*combat.Replay, error) {
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
	return &rep, nil
}

// RevengeEntry is one score left to settle.
type RevengeEntry struct {
	BattleID     string `json:"battle_id"`
	TargetID     string `json:"target_id"`
	TargetName   string `json:"target_name"`
	TargetAvatar string `json:"target_avatar"`
	TargetLevel  int64  `json:"target_level"`
	ExpiresAt    string `json:"expires_at"`
}

// listRevenge returns this player's live, unspent tokens.
func (d Deps) listRevenge(ctx context.Context, q *sqlcdb.Queries, playerID uuid.UUID) ([]RevengeEntry, error) {
	rows, err := q.ListRevenge(ctx, playerID)
	if err != nil {
		return nil, fmt.Errorf("revenge: %w", err)
	}
	out := make([]RevengeEntry, 0, len(rows))
	for _, r := range rows {
		out = append(out, RevengeEntry{
			BattleID: r.BattleID.String(), TargetID: r.TargetID.String(),
			TargetName: r.TargetName, TargetAvatar: r.TargetAvatar,
			TargetLevel: int64(r.TargetLevel),
			ExpiresAt:   r.ExpiresAt.UTC().Format(time.RFC3339),
		})
	}
	return out, nil
}
