//go:build integration

package itest

import (
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
	"github.com/yigitkarabulut0/emperors/server/internal/game/deeds"
	"github.com/yigitkarabulut0/emperors/server/internal/service"
)

// goldSum is what the gold ledger says a lord's flows add up to.
func goldSum(t *testing.T, id uuid.UUID, reasons ...string) int64 {
	t.Helper()
	var sum int64
	q := `SELECT coalesce(sum(delta), 0) FROM app.gold_ledger WHERE player_id = $1`
	args := []any{id}
	if len(reasons) > 0 {
		q += ` AND reason = ANY($2)`
		args = append(args, reasons)
	}
	if err := pool.QueryRow(t.Context(), q, args...).Scan(&sum); err != nil {
		t.Fatal(err)
	}
	return sum
}

// An arena fight moves two ratings and NOTHING else.
//
// This is the wave's central rule and exactly the sort that erodes: it is
// cheaper to check here, against a real database, than to find out from a
// player that the lists cost them a shield.
func TestAnArenaFightMovesRatingsAndNothingElse(t *testing.T) {
	w := newWorld(t)
	att := w.player(20, 10_000)
	def := w.player(20, 10_000)
	shield := w.now.Add(4 * time.Hour)
	w.exec(`UPDATE app.players SET shield_until = $2 WHERE id = $1`, def.ID, shield)

	// Read the state once first, so the pool is already settled against its
	// cap: a lord seeded above their maximum is clamped on the next look, and
	// that clamp is not the lists spending anything.
	if _, err := w.d.GetState(w.ctx, att.ID); err != nil {
		t.Fatal(err)
	}
	before := w.reload(att.ID)
	res, err := w.d.ArenaFight(w.ctx, att.ID, def.ID, before.ActionSeq+1)
	if err != nil {
		t.Fatal(err)
	}
	after, defAfter := w.reload(att.ID), w.reload(def.ID)

	if res.RatingDelta == 0 {
		t.Fatal("the fight moved no rating at all")
	}
	if after.EnergyMilli != before.EnergyMilli {
		t.Fatalf("energy moved %d -> %d: the lists cost no energy",
			before.EnergyMilli, after.EnergyMilli)
	}
	if defAfter.ShieldUntil == nil || !defAfter.ShieldUntil.Equal(shield) {
		t.Fatalf("the defender's shield was touched: %v", defAfter.ShieldUntil)
	}
	if after.ShieldUntil != nil {
		t.Fatal("the attacker was given a shield by a fight in the lists")
	}
	if defAfter.Gold != def.Gold {
		t.Fatalf("the defender lost gold in the lists: %d -> %d", def.Gold, defAfter.Gold)
	}
	if got := goldSum(t, def.ID); got != 0 {
		t.Fatalf("the defender has %d in the gold ledger from a fight in the lists", got)
	}
	if after.ActionSeq != before.ActionSeq+1 {
		t.Fatalf("action_seq moved %d -> %d, want exactly one", before.ActionSeq, after.ActionSeq)
	}
	// No revenge token, no cooldown: the lists are not a grudge.
	var tokens, cooldowns int
	if err := pool.QueryRow(w.ctx,
		`SELECT count(*) FROM app.revenge_tokens WHERE player_id = $1`, def.ID).Scan(&tokens); err != nil {
		t.Fatal(err)
	}
	if err := pool.QueryRow(w.ctx,
		`SELECT count(*) FROM app.attack_cooldowns WHERE attacker_id = $1`, att.ID).Scan(&cooldowns); err != nil {
		t.Fatal(err)
	}
	if tokens != 0 || cooldowns != 0 {
		t.Fatalf("the lists granted %d revenge tokens and %d cooldowns", tokens, cooldowns)
	}
	// And the away report must not read it as a raid.
	n, err := w.q.CountRaidsSince(w.ctx, sqlcdb.CountRaidsSinceParams{
		PlayerID: def.ID, Since: w.now.Add(-time.Hour),
	})
	if err != nil {
		t.Fatal(err)
	}
	if n.Raids != 0 {
		t.Fatalf("an arena defence counted as %d raids suffered", n.Raids)
	}
}

// The day's fights run out, and the first win pays once.
func TestTheDaysFightsRunOutAndTheFirstWinPaysOnce(t *testing.T) {
	w := newWorld(t)
	me := w.player(20, 10_000)
	foe := w.player(20, 10_000)
	cfg := w.d.Config.PvP.Arena

	paid := 0
	for i := 0; i < cfg.TicketsPerDay; i++ {
		p := w.reload(me.ID)
		res, err := w.d.ArenaFight(w.ctx, me.ID, foe.ID, p.ActionSeq+1)
		if err != nil {
			t.Fatalf("fight %d: %v", i+1, err)
		}
		if len(res.FirstWin) > 0 {
			paid++
		}
	}
	p := w.reload(me.ID)
	if _, err := w.d.ArenaFight(w.ctx, me.ID, foe.ID, p.ActionSeq+1); err != service.ErrNoTickets {
		t.Fatalf("the sixth fight answered %v, want ErrNoTickets", err)
	}
	if paid > 1 {
		t.Fatalf("the day's first win paid %d times", paid)
	}
}

// A bounty's fee is BURNED: the flows do not cancel, and that is the point.
func TestABountysFeeIsBurnedAndTheEscrowIsHeld(t *testing.T) {
	w := newWorld(t)
	placer := w.player(20, 1_000_000)
	target := w.player(20, 1_000_000)
	cfg := w.d.Config.PvP.Bounty
	plate := cfg.Plates[0]
	_, fee, total := cfg.Cost(plate.Amount)

	p := w.reload(placer.ID)
	out, err := w.d.PlaceBounty(w.ctx, placer.ID, target.ID, plate.ID, p.ActionSeq+1)
	if err != nil {
		t.Fatal(err)
	}
	after := w.reload(placer.ID)
	if got := p.Gold - after.Gold; got != total {
		t.Fatalf("the purse lost %d, want %d (%d escrowed + %d burned)", got, total, plate.Amount, fee)
	}
	if got := goldSum(t, placer.ID); got != -total {
		t.Fatalf("the gold ledger says %d, want %d", got, -total)
	}
	var remaining, burned int64
	if err := pool.QueryRow(w.ctx,
		`SELECT remaining, fee_burned FROM app.bounties WHERE id = $1`,
		uuid.MustParse(out.ID)).Scan(&remaining, &burned); err != nil {
		t.Fatal(err)
	}
	if remaining != plate.Amount || burned != fee {
		t.Fatalf("the board holds %d with %d burned, want %d and %d",
			remaining, burned, plate.Amount, fee)
	}
	// The hunted lord is told. It is why a shield is allowed to stop a hunt.
	var letters int
	if err := pool.QueryRow(w.ctx,
		`SELECT count(*) FROM app.mail WHERE player_id = $1 AND kind = 'bounty'`,
		target.ID).Scan(&letters); err != nil {
		t.Fatal(err)
	}
	if letters != 1 {
		t.Fatalf("the hunted lord got %d letters, want 1", letters)
	}
}

// A shield stops a hunt, which is the owner's decision made real.
func TestAShieldStopsABountyHunt(t *testing.T) {
	w := newWorld(t)
	placer := w.player(20, 1_000_000)
	hunter := w.player(20, 100_000)
	target := w.player(20, 100_000)
	w.exec(`UPDATE app.players SET created_at = $2 WHERE id = $1`,
		hunter.ID, w.now.Add(-200*time.Hour))
	give(w, target.ID)
	give(w, hunter.ID)

	p := w.reload(placer.ID)
	out, err := w.d.PlaceBounty(w.ctx, placer.ID, target.ID,
		w.d.Config.PvP.Bounty.Plates[0].ID, p.ActionSeq+1)
	if err != nil {
		t.Fatal(err)
	}
	w.exec(`UPDATE app.players SET shield_until = $2 WHERE id = $1`,
		target.ID, w.now.Add(4*time.Hour))

	h := w.reload(hunter.ID)
	_, err = w.d.ClaimBounty(w.ctx, hunter.ID, uuid.MustParse(out.ID), h.ActionSeq+1)
	if err != service.ErrShielded {
		t.Fatalf("a hunt against a shielded head answered %v, want ErrShielded", err)
	}
	// And with the shield gone it lands.
	w.exec(`UPDATE app.players SET shield_until = NULL WHERE id = $1`, target.ID)
	h = w.reload(hunter.ID)
	if _, err := w.d.ClaimBounty(w.ctx, hunter.ID, uuid.MustParse(out.ID), h.ActionSeq+1); err != nil {
		t.Fatalf("a hunt against an unshielded head answered %v", err)
	}
}

// A claim never draws more than the escrow, nor more than the balance's
// multiple of the raid cap.
func TestAClaimNeverPaysMoreThanItMay(t *testing.T) {
	w := newWorld(t)
	placer := w.player(20, 10_000_000)
	hunter := w.player(15, 100_000)
	target := w.player(15, 100_000)
	w.exec(`UPDATE app.players SET created_at = $2 WHERE id = $1`,
		hunter.ID, w.now.Add(-200*time.Hour))
	give(w, target.ID)
	give(w, hunter.ID)
	cfg := w.d.Config.PvP.Bounty
	big := cfg.Plates[len(cfg.Plates)-1]

	p := w.reload(placer.ID)
	out, err := w.d.PlaceBounty(w.ctx, placer.ID, target.ID, big.ID, p.ActionSeq+1)
	if err != nil {
		t.Fatal(err)
	}
	id := uuid.MustParse(out.ID)
	// Win it (the hunter is given an army; a loss simply pays nothing, so the
	// test retries until a win or the fights run out).
	var paid int64
	for i := 0; i < 8 && paid == 0; i++ {
		h := w.reload(hunter.ID)
		res, err := w.d.ClaimBounty(w.ctx, hunter.ID, id, h.ActionSeq+1)
		if err != nil {
			t.Fatalf("hunt: %v", err)
		}
		paid = res.BountyPaid
		w.exec(`DELETE FROM app.attack_cooldowns WHERE attacker_id = $1`, hunter.ID)
	}
	if paid == 0 {
		t.Skip("the hunter never won in eight tries")
	}
	cap := cfg.ClaimCapMultiple * 250 * (10000 + 3500*15) / 10000
	if paid > cap {
		t.Fatalf("one claim paid %d, over the ceiling of %d", paid, cap)
	}
	var remaining int64
	if err := pool.QueryRow(w.ctx, `SELECT remaining FROM app.bounties WHERE id = $1`, id).
		Scan(&remaining); err != nil {
		t.Fatal(err)
	}
	if remaining != big.Amount-paid {
		t.Fatalf("the board still holds %d, want %d", remaining, big.Amount-paid)
	}
	if got := goldSum(t, hunter.ID, "bounty_claim"); got != paid {
		t.Fatalf("the hunter's ledger says %d for the claim, want %d", got, paid)
	}
}

// A lapsed price gives the escrow back, once, and without moving a sequence.
func TestABountyExpiresAndRefundsOnce(t *testing.T) {
	w := newWorld(t)
	placer := w.player(20, 1_000_000)
	target := w.player(20, 100_000)
	cfg := w.d.Config.PvP.Bounty
	plate := cfg.Plates[0]

	p := w.reload(placer.ID)
	if _, err := w.d.PlaceBounty(w.ctx, placer.ID, target.ID, plate.ID, p.ActionSeq+1); err != nil {
		t.Fatal(err)
	}
	mid := w.reload(placer.ID)
	w.now = w.now.Add(time.Duration(cfg.Hours+1) * time.Hour)

	for i := 0; i < 2; i++ {
		if err := w.d.DevRunJob(w.ctx, "bounty_expiry"); err != nil {
			t.Fatalf("run %d: %v", i+1, err)
		}
	}
	after := w.reload(placer.ID)
	if got := after.Gold - mid.Gold; got != plate.Amount {
		t.Fatalf("the refund gave back %d, want exactly %d once", got, plate.Amount)
	}
	if after.ActionSeq != mid.ActionSeq {
		t.Fatalf("the refund moved action_seq %d -> %d: a job must never",
			mid.ActionSeq, after.ActionSeq)
	}
	// The fee stays burned.
	_, fee, total := cfg.Cost(plate.Amount)
	if got := goldSum(t, placer.ID); got != -total+plate.Amount {
		t.Fatalf("the ledger nets %d, want %d burned", got, -fee)
	}
	var letters int
	if err := pool.QueryRow(w.ctx,
		`SELECT count(*) FROM app.mail WHERE player_id = $1 AND kind = 'bounty'`,
		placer.ID).Scan(&letters); err != nil {
		t.Fatal(err)
	}
	if letters != 1 {
		t.Fatalf("the placer got %d letters for one lapse", letters)
	}
}

// The Throne goes to the week's GAIN, not the standing total -- and switching
// the balance's one knob switches which kingdom wears it.
func TestTheThroneGoesToTheWeeksGainNotTheTotal(t *testing.T) {
	w := newWorld(t)
	w.now = afterThroneEpoch(w)
	big := kingdom(w, "Bigge", "BIG", 500_000) // rich in standing renown
	small := kingdom(w, "Smalle", "SML", 1_000)
	uweek := deeds.UWeek(w.now) - 7
	w.exec(`INSERT INTO app.kingdom_week (kingdom_id, uweek, reputation) VALUES ($1,$2,$3)`,
		big, uweek, int64(100))
	w.exec(`INSERT INTO app.kingdom_week (kingdom_id, uweek, reputation) VALUES ($1,$2,$3)`,
		small, uweek, int64(50_000))

	if err := w.d.DevRunJob(w.ctx, "throne_settle"); err != nil {
		t.Fatal(err)
	}
	var crowned uuid.UUID
	if err := pool.QueryRow(w.ctx, `SELECT kingdom_id FROM app.throne WHERE uweek = $1`, uweek).
		Scan(&crowned); err != nil {
		t.Fatalf("nobody was crowned: %v", err)
	}
	if crowned != small {
		t.Fatal("the crown went to the standing total rather than the week's gain")
	}
	// Twice is once.
	if err := w.d.DevRunJob(w.ctx, "throne_settle"); err != nil {
		t.Fatal(err)
	}
	var reigns int
	if err := pool.QueryRow(w.ctx, `SELECT count(*) FROM app.throne`).Scan(&reigns); err != nil {
		t.Fatal(err)
	}
	if reigns != 1 {
		t.Fatalf("%d reigns were written for one week", reigns)
	}
	// Every member wears the court's title until the reign ends, and the
	// emperor the imperial frame.
	var worn int
	if err := pool.QueryRow(w.ctx,
		`SELECT count(*) FROM app.player_cosmetics WHERE source = 'throne' AND expires_at IS NOT NULL`).
		Scan(&worn); err != nil {
		t.Fatal(err)
	}
	if worn < 3 {
		t.Fatalf("only %d regalia were handed out", worn)
	}
}

// A kingdom under min_members is never crowned, however much it gained.
func TestAKingdomTooSmallIsNeverCrowned(t *testing.T) {
	w := newWorld(t)
	w.now = afterThroneEpoch(w)
	k := kingdomOfSize(w, "Twain", "TWO", 2)
	uweek := deeds.UWeek(w.now) - 7
	w.exec(`INSERT INTO app.kingdom_week (kingdom_id, uweek, reputation) VALUES ($1,$2,$3)`,
		k, uweek, int64(999_999))
	if err := w.d.DevRunJob(w.ctx, "throne_settle"); err != nil {
		t.Fatal(err)
	}
	// Scoped to this week: the package shares one database, and another test's
	// reign is not this one's.
	var reigns int
	if err := pool.QueryRow(w.ctx,
		`SELECT count(*) FROM app.throne WHERE kingdom_id = $1`, k).Scan(&reigns); err != nil {
		t.Fatal(err)
	}
	if reigns != 0 {
		t.Fatal("a kingdom of two was crowned")
	}
}

// give hands a lord a soldier, so a fight is a fight rather than a walkover.
func give(w *world, id uuid.UUID) {
	w.exec(`UPDATE app.players SET stat_attack = 40, stat_defense = 40, soldier_slots = 2 WHERE id = $1`, id)
}

// kingdom makes one with three lords, a king among them, and a standing renown.
func kingdom(w *world, name, tag string, reputation int64) uuid.UUID {
	return kingdomOfSize(w, name, tag, 3, reputation)
}

func kingdomOfSize(w *world, name, tag string, members int, reputation ...int64) uuid.UUID {
	w.t.Helper()
	var rep int64
	if len(reputation) > 0 {
		rep = reputation[0]
	}
	var id uuid.UUID
	if err := pool.QueryRow(w.ctx,
		`INSERT INTO app.kingdoms (name, tag, reputation) VALUES ($1,$2,$3) RETURNING id`,
		name+uuid.NewString()[:6], tag[:2]+uuid.NewString()[:2], rep).Scan(&id); err != nil {
		w.t.Fatal(err)
	}
	for i := 0; i < members; i++ {
		p := w.player(20, 1000)
		role := "member"
		if i == 0 {
			role = "king"
		}
		w.exec(`UPDATE app.players SET kingdom_id = $2, kingdom_role = $3 WHERE id = $1`, p.ID, id, role)
	}
	return id
}

// afterThroneEpoch is a Monday past the first week a reign may be settled for.
// A week that began before the Throne existed is never crowned (the rule
// boardsEpoch sets for the boards), so a test of a crowning has to stand after
// it -- and a test that did not would pass for the wrong reason forever.
func afterThroneEpoch(w *world) time.Time {
	e, err := time.Parse("2006-01-02", w.d.Config.PvP.Throne.Epoch)
	if err != nil {
		w.t.Fatal(err)
	}
	at := e.AddDate(0, 0, 14).UTC()
	if at.Before(w.now) {
		return w.now
	}
	return at
}
