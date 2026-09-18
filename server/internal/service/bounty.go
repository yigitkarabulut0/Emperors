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
	"github.com/yigitkarabulut0/emperors/server/internal/game/deeds"
	"github.com/yigitkarabulut0/emperors/server/internal/game/rewards"
)

// THE BOUNTY BOARD -- the Attack tab's fourth sub-tab (pvp.json, bounty).
//
// A bounty is a GOLD SINK dressed as a grudge. The placer's purse loses the
// escrow and the fee together; the escrow is held in app.bounties and paid out
// to whoever collects; the fee is burned and never re-minted. The two ledger
// rows of a claim therefore do NOT cancel, unlike a raid's -- and that is the
// point, so the economy dashboard reads it as the sink it is.
//
// A hunt is a RAID (service.raid): same energy, same steal, same ransom, same
// revenge token for the loser, same renown. The bounty is what it pays on top.

var (
	ErrBountyLocked    = errors.New("the bounty board opens later")
	ErrBountyPlate     = errors.New("that is not a price the board offers")
	ErrBountySelf      = errors.New("you cannot put a price on your own head")
	ErrBountyAlly      = errors.New("you cannot put a price on a lord of your own kingdom")
	ErrBountyBot       = errors.New("that lord cannot be hunted")
	ErrBountyPunchDown = errors.New("that lord is too far beneath you to hunt for coin")
	ErrBountyCooling   = errors.New("you have hunted that head too often today")
	ErrBountyPairSpent = errors.New("you have collected too many of that lord's prices this week")
	ErrBountyTooNew    = errors.New("your house is too new to hunt for coin")
	ErrBountyGone      = errors.New("that price has already been collected")
	ErrBountyLimit     = errors.New("you have set today's prices")
	ErrBountyCrowded   = errors.New("that head already carries all the prices it can")
)

// bountySection is the navigation section that opens the board.
const bountySection = "bounty"

// bountyHunt is a claim riding on a raid (raidOpts.Bounty).
type bountyHunt struct {
	ID uuid.UUID
	// Filled by checkBountyHunt, so drawBounty does not read the row twice.
	row sqlcdb.AppBounty
}

// BountyBoard is the BOUNTIES sub-tab.
type BountyBoard struct {
	Unlocked    bool `json:"unlocked"`
	UnlockLevel int  `json:"unlock_level"`

	// The prices this lord may hunt.
	Posters []BountyPoster `json:"posters"`
	// What stands on their own head, and what they have set.
	OnMyHead []BountyRow `json:"on_my_head"`
	Mine     []BountyRow `json:"mine"`

	// The plates the board offers, priced by the server. The client sends a
	// plate's id and never an amount.
	Presets []BountyPreset `json:"presets"`
	// The lords a price may be set on, chosen by the server: recent raiders and
	// recent targets, already filtered by every rule that could refuse one.
	CanPlace []BountyTarget `json:"can_place"`
	// How many more may be set today.
	PlacesLeft int    `json:"places_left"`
	Gold       string `json:"gold"`

	Rules BountyRules `json:"rules"`
}

// BountyPoster is one WANTED sheet.
type BountyPoster struct {
	ID       string `json:"id"`
	TargetID string `json:"target_id"`
	Name     string `json:"name"`
	Avatar   string `json:"avatar"`
	Level    int64  `json:"level"`
	// What is still on the head, and what THIS lord would collect for it.
	Pot  int64 `json:"pot"`
	Pays int64 `json:"pays"`
	// Seconds left before it lapses, from this answer's moment.
	ExpiresIn int64 `json:"expires_in"`
	// A shield stops a hunt, as it stops a raid. The card draws the raid's own
	// shield pill rather than deciding anything itself.
	ShieldSeconds int64 `json:"shield_seconds"`
	EnergyCost    int64 `json:"energy_cost"`
	Look
}

// BountyRow is a price on this lord's head, or one they set.
type BountyRow struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	Pot       int64  `json:"pot"`
	ExpiresIn int64  `json:"expires_in"`
	State     string `json:"state"`
}

// BountyPreset is one plate.
type BountyPreset struct {
	ID     string `json:"id"`
	Amount int64  `json:"amount"`
	Fee    int64  `json:"fee"`
	Total  int64  `json:"total"`
	// Whether this lord's purse covers it now.
	Affordable bool `json:"affordable"`
}

// BountyTarget is a lord a price may be set on.
type BountyTarget struct {
	PlayerID string `json:"player_id"`
	Name     string `json:"name"`
	Avatar   string `json:"avatar"`
	Level    int64  `json:"level"`
	Look
}

// BountyRules are the board's terms, for the sheet behind the (i).
type BountyRules struct {
	Hours             int   `json:"hours"`
	FeeBP             int64 `json:"fee_bp"`
	ClaimCapMultiple  int64 `json:"claim_cap_multiple"`
	ClaimsPerTarget   int   `json:"claims_per_target"`
	CooldownMinutes   int   `json:"cooldown_minutes"`
	PairClaimsPerWeek int   `json:"pair_claims_per_week"`
	MinAccountHours   int   `json:"min_account_hours"`
	MaxLevelsAbove    int   `json:"max_levels_above"`
	PlacesPerDay      int   `json:"places_per_day"`
	// What one claim would pay THIS lord, so the sheet says a real number.
	ClaimCap int64 `json:"claim_cap"`
}

// BountyPlaced is the answer to setting one.
type BountyPlaced struct {
	ID       string    `json:"id"`
	TargetID string    `json:"target_id"`
	Name     string    `json:"name"`
	Pot      int64     `json:"pot"`
	Fee      int64     `json:"fee"`
	Snapshot *Snapshot `json:"snapshot"`
}

// bountyPlacedToday is how many prices the lord has set on their own day.
func bountyPlacedToday(p sqlcdb.AppPlayer, today time.Time) int {
	if !p.BountyDay.Valid || !p.BountyDay.Time.Equal(today) {
		return 0
	}
	return int(p.BountyPlaced)
}

// bountyPayout is what one claim carries off: never more than the escrow still
// holds, and never more than the balance's multiple of the raid cap.
//
// The one place it is worked out -- the poster prints it and the claim pays it.
// The two drifted apart once on the Attack tab (the War Chest), and the fix
// there was exactly this.
func (d Deps) bountyPayout(claimerLevel, remaining int64) int64 {
	pay := d.Config.PvP.Bounty.ClaimCapMultiple * raidCap(claimerLevel)
	if pay > remaining {
		pay = remaining
	}
	return pay
}

// GetBountyBoard is the BOUNTIES sub-tab.
func (d Deps) GetBountyBoard(ctx context.Context, playerID uuid.UUID) (*BountyBoard, error) {
	q := sqlcdb.New(d.Pool)
	me, err := q.GetPlayerByID(ctx, playerID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, fmt.Errorf("load player: %w", err)
	}
	cfg := d.Config.PvP.Bounty
	now := d.Now()
	at := d.Config.SectionLevel(cfg.Section)

	v := &BountyBoard{
		Unlocked: int(me.Level) >= at, UnlockLevel: at,
		Posters: []BountyPoster{}, OnMyHead: []BountyRow{}, Mine: []BountyRow{},
		Presets: []BountyPreset{}, CanPlace: []BountyTarget{},
		Gold: itoa(me.Gold),
		Rules: BountyRules{
			Hours: cfg.Hours, FeeBP: cfg.FeeBP, ClaimCapMultiple: cfg.ClaimCapMultiple,
			ClaimsPerTarget: cfg.ClaimsPerTarget, CooldownMinutes: cfg.CooldownMinutes,
			PairClaimsPerWeek: cfg.PairClaimsPerWeek, MinAccountHours: cfg.MinAccountHours,
			MaxLevelsAbove: cfg.MaxLevelsAbove, PlacesPerDay: cfg.PlacesPerDay,
			ClaimCap: cfg.ClaimCapMultiple * raidCap(int64(me.Level)),
		},
	}
	for _, pl := range cfg.Plates {
		_, fee, total := cfg.Cost(pl.Amount)
		v.Presets = append(v.Presets, BountyPreset{
			ID: pl.ID, Amount: pl.Amount, Fee: fee, Total: total,
			Affordable: me.Gold >= total,
		})
	}
	if !v.Unlocked {
		return v, nil
	}
	v.PlacesLeft = maxInt(0, cfg.PlacesPerDay-bountyPlacedToday(me, localDay(now, me.ResetOffsetMinutes)))

	rows, err := q.ListOpenBounties(ctx, sqlcdb.ListOpenBountiesParams{
		Me: playerID, MinLevel: int32(d.Config.SectionLevel(fightSection)),
		KingdomID: me.KingdomID, Lim: 4,
	})
	if err != nil {
		return nil, fmt.Errorf("board: %w", err)
	}
	for _, r := range rows {
		// The last two rules that cannot be a filter: punching down needs the
		// target's Might, which is a query of its own.
		if int(me.Level)-int(r.Level) > cfg.MaxLevelsAbove {
			continue
		}
		var shield int64
		if r.ShieldUntil != nil && r.ShieldUntil.After(now) {
			shield = int64(r.ShieldUntil.Sub(now) / time.Second)
		}
		v.Posters = append(v.Posters, BountyPoster{
			ID: r.ID.String(), TargetID: r.TargetID.String(), Name: r.DisplayName,
			Avatar: r.Avatar, Level: int64(r.Level), Pot: r.Remaining,
			Pays:          d.bountyPayout(int64(me.Level), r.Remaining),
			ExpiresIn:     secondsUntil(r.ExpiresAt, now),
			ShieldSeconds: shield, EnergyCost: d.attackEnergyCost(int64(me.Level)),
			Look: lookOf(d.Config, r.CosFrame, r.CosTitle, r.CosColor, r.CosCrest, r.VipPoints),
		})
	}
	if mine, err := q.ListBountiesOnMe(ctx, sqlcdb.ListBountiesOnMeParams{Me: playerID, Lim: 5}); err == nil {
		for _, r := range mine {
			v.OnMyHead = append(v.OnMyHead, BountyRow{
				ID: r.ID.String(), Name: r.PlacerName, Pot: r.Remaining,
				ExpiresIn: secondsUntil(r.ExpiresAt, now), State: "open",
			})
		}
	}
	if set, err := q.ListMyBounties(ctx, sqlcdb.ListMyBountiesParams{Me: playerID, Lim: 5}); err == nil {
		for _, r := range set {
			state := "open"
			if r.ClosedAs != nil {
				state = *r.ClosedAs
			}
			v.Mine = append(v.Mine, BountyRow{
				ID: r.ID.String(), Name: r.TargetName, Pot: r.Remaining,
				ExpiresIn: secondsUntil(r.ExpiresAt, now), State: state,
			})
		}
	}
	v.CanPlace = d.bountyTargets(ctx, q, me)
	return v, nil
}

// bountyTargets is who a price may be set on: the lords this one has raided or
// been raided by lately, filtered by every rule that would refuse the placing.
//
// Chosen by the SERVER. A client that offered a name field would let a player
// name a lord no rule allows, and the refusal would arrive as an error where a
// list would have been an answer.
func (d Deps) bountyTargets(ctx context.Context, q *sqlcdb.Queries, me sqlcdb.AppPlayer) []BountyTarget {
	out := []BountyTarget{}
	rows, err := q.ListBattleLog(ctx, sqlcdb.ListBattleLogParams{PlayerID: me.ID, Lim: 20})
	if err != nil {
		return out
	}
	fightAt := d.Config.SectionLevel(fightSection)
	seen := map[uuid.UUID]bool{me.ID: true}
	for _, r := range rows {
		other := r.DefenderID
		if r.AttackerID != me.ID {
			other = r.AttackerID
		}
		if seen[other] || r.OpponentIsBot || int(r.OpponentLevel) < fightAt {
			continue
		}
		seen[other] = true
		if n, err := q.CountOpenBountiesOn(ctx, other); err == nil &&
			int(n) >= d.Config.PvP.Bounty.OpenPerTarget {
			continue
		}
		out = append(out, BountyTarget{
			PlayerID: other.String(), Name: r.OpponentName, Avatar: r.OpponentAvatar,
			Level: int64(r.OpponentLevel),
			Look: lookOf(d.Config, r.OpponentCosFrame, r.OpponentCosTitle,
				r.OpponentCosColor, r.OpponentCosCrest, r.OpponentVipPoints),
		})
		if len(out) >= 8 {
			break
		}
	}
	return out
}

// PlaceBounty sets a price on a head.
func (d Deps) PlaceBounty(ctx context.Context, playerID, targetID uuid.UUID,
	plate string, wantSeq int64) (*BountyPlaced, error) {

	if playerID == targetID {
		return nil, ErrBountySelf
	}
	cfg := d.Config.PvP.Bounty
	pl := cfg.Plate(plate)
	if pl == nil {
		return nil, ErrBountyPlate
	}
	escrow, fee, total := cfg.Cost(pl.Amount)

	var out BountyPlaced
	err := db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
		q := sqlcdb.New(tx)
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
		at := d.Config.SectionLevel(cfg.Section)
		if int(me.Level) < at {
			return fmt.Errorf("%w: the board opens at level %d", ErrBountyLocked, at)
		}
		if target.IsBot {
			return ErrBountyBot
		}
		if int(target.Level) < d.Config.SectionLevel(fightSection) {
			return ErrTooNewToRaid
		}
		if me.KingdomID != nil && target.KingdomID != nil && *me.KingdomID == *target.KingdomID {
			return ErrBountyAlly
		}
		now := d.Now()
		today := localDay(now, me.ResetOffsetMinutes)
		placed := bountyPlacedToday(me, today)
		if placed >= cfg.PlacesPerDay {
			return ErrBountyLimit
		}
		if n, err := q.CountOpenBountiesOn(ctx, targetID); err == nil && int(n) >= cfg.OpenPerTarget {
			return ErrBountyCrowded
		}

		after, err := q.PayForBounty(ctx, sqlcdb.PayForBountyParams{
			ID: playerID, Total: total, ActionSeq: wantSeq,
			Day: dateOf(today), Placed: int16(placed + 1),
		})
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrNotEnoughGold
			}
			return fmt.Errorf("pay for bounty: %w", err)
		}
		id := uuid.New()
		row, err := q.InsertBounty(ctx, sqlcdb.InsertBountyParams{
			ID: id, TargetID: targetID, PlacedBy: playerID,
			Amount: escrow, FeeBurned: fee, Plate: pl.ID,
			ExpiresAt: now.Add(time.Duration(cfg.Hours) * time.Hour),
		})
		if err != nil {
			return fmt.Errorf("insert bounty: %w", err)
		}
		// One ledger row for the whole cut. The fee inside it is BURNED: there
		// is no answering credit anywhere, which is what makes the board a sink
		// rather than a pipe between two accounts, and what lets the economy
		// dashboard read it as one.
		if err := q.RecordGold(ctx, sqlcdb.RecordGoldParams{
			PlayerID: playerID, Delta: -total, BalanceAfter: after.Gold,
			Reason: "bounty_place", RefID: strPtr(id.String()),
		}); err != nil {
			return err
		}
		// The hunted lord is told. It is the whole reason a shield is allowed to
		// stop a hunt: a price you cannot see is one you cannot answer.
		if _, err := d.SendMail(ctx, q, targetID, MailDraft{
			Kind: MailBounty, Title: "A price on your head",
			Body: fmt.Sprintf("%s has set %s gold on your head. It stands for %d hours, and any lord in your reach may come for it.",
				me.DisplayName, rewards.Group(escrow), cfg.Hours),
			IdemKey: "bounty:" + id.String() + ":target",
		}); err != nil {
			return err
		}
		d.recordDeeds(ctx, tx, me, deeds.Deeds{deeds.BountiesPlaced: 1})
		out = BountyPlaced{
			ID: row.ID.String(), TargetID: targetID.String(), Name: target.DisplayName,
			Pot: escrow, Fee: fee,
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	snap, err := d.GetState(ctx, playerID)
	out.Snapshot = snap
	return &out, err
}

// ClaimBounty hunts a head for its price. It is an ordinary raid with the
// bounty riding on it (raidOpts.Bounty).
func (d Deps) ClaimBounty(ctx context.Context, playerID, bountyID uuid.UUID, wantSeq int64) (*AttackResult, error) {
	b, err := sqlcdb.New(d.Pool).GetBounty(ctx, bountyID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrBountyGone
		}
		return nil, fmt.Errorf("bounty: %w", err)
	}
	if b.ClosedAt != nil || !b.ExpiresAt.After(d.Now()) {
		return nil, ErrBountyGone
	}
	if b.PlacedBy == playerID {
		return nil, ErrBountySelf
	}
	return d.raid(ctx, playerID, b.TargetID, wantSeq, raidOpts{Bounty: &bountyHunt{ID: bountyID}})
}

// checkBountyHunt is every leash on a claim, applied inside the raid's own
// transaction and before a single coin of energy is spent.
func (d Deps) checkBountyHunt(ctx context.Context, q *sqlcdb.Queries, me, target sqlcdb.AppPlayer,
	h *bountyHunt, now time.Time) error {

	cfg := d.Config.PvP.Bounty
	if int(me.Level) < d.Config.SectionLevel(cfg.Section) {
		return ErrBountyLocked
	}
	if me.CreatedAt.Add(time.Duration(cfg.MinAccountHours) * time.Hour).After(now) {
		return ErrBountyTooNew
	}
	if target.IsBot {
		return ErrBountyBot
	}
	row, err := q.LockBounty(ctx, h.ID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrBountyGone
		}
		return fmt.Errorf("lock bounty: %w", err)
	}
	if row.ClosedAt != nil || !row.ExpiresAt.After(now) || row.TargetID != target.ID {
		return ErrBountyGone
	}
	if row.PlacedBy == me.ID {
		return ErrBountySelf
	}
	// Never punching down: a hunter far above the head, or a head far weaker
	// than the hunter, is a farm rather than a hunt.
	if int(me.Level)-int(target.Level) > cfg.MaxLevelsAbove {
		return ErrBountyPunchDown
	}
	mine, err := d.GetArmy(ctx, me.ID)
	if err == nil {
		theirs, err := d.GetArmy(ctx, target.ID)
		if err == nil && mine.Totals.Might > 0 &&
			theirs.Totals.Might*10000 < mine.Totals.Might*cfg.MinTargetMightBP {
			return ErrBountyPunchDown
		}
	}
	// Four claims on one head a day, then a two-hour wait. Counted from
	// app.attack_cooldowns, which TouchCooldown already keeps per pair: a second
	// counter for the same question is how two numbers start disagreeing. The
	// window is rolling from the last hit rather than a calendar day, which is
	// the stricter and the more honest of the two.
	if cd, err := q.GetCooldown(ctx, sqlcdb.GetCooldownParams{
		AttackerID: me.ID, DefenderID: target.ID,
	}); err == nil && int(cd.Count24h) >= cfg.ClaimsPerTarget &&
		cd.LastAt.Add(time.Duration(cfg.CooldownMinutes)*time.Minute).After(now) {
		return ErrBountyCooling
	}
	// The same placer and claimer, at most twice a week: the shape collusion
	// takes when two accounts trade a purse back and forth.
	if n, err := q.CountPairClaimsThisWeek(ctx, sqlcdb.CountPairClaimsThisWeekParams{
		PlacerID: row.PlacedBy, ClaimerID: me.ID, Uweek: deeds.UWeek(now),
	}); err == nil && int(n) >= cfg.PairClaimsPerWeek {
		return ErrBountyPairSpent
	}
	h.row = row
	return nil
}

// drawBounty pays a won hunt out of the escrow.
//
// The credit does NOT move action_seq: the raid's own ApplyBattleAttacker
// already moved it, and a second write would put the client's queued collects
// out of step by one.
func (d Deps) drawBounty(ctx context.Context, q *sqlcdb.Queries, att *sqlcdb.AppPlayer,
	h *bountyHunt, target sqlcdb.AppPlayer, battleID uuid.UUID, now time.Time) (int64, error) {

	pay := d.bountyPayout(int64(att.Level), h.row.Remaining)
	if pay <= 0 {
		return 0, ErrBountyGone
	}
	row, err := q.DrawBounty(ctx, sqlcdb.DrawBountyParams{ID: h.ID, Pay: pay})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return 0, ErrBountyGone
		}
		return 0, fmt.Errorf("draw bounty: %w", err)
	}
	after, err := q.RefundBounty(ctx, sqlcdb.RefundBountyParams{ID: att.ID, Gold: pay})
	if err != nil {
		return 0, fmt.Errorf("pay claim: %w", err)
	}
	*att = after
	if err := q.RecordGold(ctx, sqlcdb.RecordGoldParams{
		PlayerID: att.ID, Delta: pay, BalanceAfter: after.Gold,
		Reason: "bounty_claim", RefID: strPtr(h.ID.String()),
	}); err != nil {
		return 0, err
	}
	if _, err := q.InsertBountyClaim(ctx, sqlcdb.InsertBountyClaimParams{
		BountyID: h.ID, BattleID: battleID, ClaimerID: att.ID, TargetID: target.ID,
		PlacerID: row.PlacedBy, Paid: pay, Uweek: deeds.UWeek(now),
	}); err != nil {
		return 0, fmt.Errorf("record claim: %w", err)
	}
	if row.ClosedAt != nil {
		if _, err := d.SendMail(ctx, q, row.PlacedBy, MailDraft{
			Kind: MailBounty, Title: "Your price was collected",
			Body: fmt.Sprintf("%s has collected the price you set on %s. The purse is paid out in full.",
				att.DisplayName, target.DisplayName),
			IdemKey: "bounty:" + h.ID.String() + ":claimed",
		}); err != nil {
			return 0, err
		}
	}
	return pay, nil
}

func boolToI64(b bool) int64 {
	if b {
		return 1
	}
	return 0
}

// expireBounties gives back what a lapsed price still held.
//
// The fee stays burned: it left the economy when the price was set, and a
// bounty nobody collected is still a bounty that cost something to set. Three
// layers of idempotence -- the query returns only open rows, CloseBounty is
// guarded on closed_at IS NULL, and the letter carries a key -- so a double
// refund is impossible even if the job runs twice.
func expireBounties(ctx context.Context, d Deps, now time.Time) error {
	q := sqlcdb.New(d.Pool)
	rows, err := q.ExpireBounties(ctx, sqlcdb.ExpireBountiesParams{Now: now, Lim: 200})
	if err != nil {
		return fmt.Errorf("expiring bounties: %w", err)
	}
	for _, b := range rows {
		row := b
		err := db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
			tq := sqlcdb.New(tx)
			closed, err := tq.CloseBounty(ctx, sqlcdb.CloseBountyParams{
				ID: row.ID, ClosedAs: strPtr("expired"),
			})
			if err != nil {
				if errors.Is(err, pgx.ErrNoRows) {
					return nil // somebody collected it first
				}
				return fmt.Errorf("close: %w", err)
			}
			if closed.Remaining >= 0 && row.Remaining > 0 {
				// Given back WITHOUT moving action_seq: CreditGold writes one,
				// and a job must not move the number the client's queued
				// collects are counting on.
				after, err := tq.RefundBounty(ctx, sqlcdb.RefundBountyParams{
					ID: row.PlacedBy, Gold: row.Remaining,
				})
				if err != nil {
					return fmt.Errorf("refund: %w", err)
				}
				if err := tq.RecordGold(ctx, sqlcdb.RecordGoldParams{
					PlayerID: row.PlacedBy, Delta: row.Remaining, BalanceAfter: after.Gold,
					Reason: "bounty_refund", RefID: strPtr(row.ID.String()),
				}); err != nil {
					return err
				}
			}
			_, err = d.SendMail(ctx, tq, row.PlacedBy, MailDraft{
				Kind: MailBounty, Title: "Your price went uncollected",
				Body: fmt.Sprintf("The price you set stood for %d hours and nobody came for it. %s gold is returned to your purse; the crier's fee is not.",
					d.Config.PvP.Bounty.Hours, rewards.Group(row.Remaining)),
				IdemKey: "bounty:" + row.ID.String() + ":expired",
			})
			return err
		})
		if err != nil {
			return err
		}
	}
	return nil
}
