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
)

// A RIVAL'S PAGE and the SPYGLASS -- rival.png (social.json, spy).
//
// The page itself is free and says what anybody could work out by fighting the
// lord: their level, their kingdom, their Might, what they wear, what gear they
// carry BY NAME, and what their army is made of BY TYPE AND RANK. No numbers
// on any of it.
//
// The spyglass is the numbers, for gold, for an hour. Three things make that
// fair rather than surveillance: it costs (a sink), the report is FROZEN at the
// moment it was bought (an army that changed since is exactly what the rival
// hopes you are looking at), and the rival is TOLD -- their own raid page
// counts how many lords have scouted them today.
//
// Whose page may be opened at all is the rival's own choice
// (privacy_profile): everybody, friends only, or their own kingdom. A blocked
// lord is answered "no such lord", never "you are blocked", because the second
// is a notification a blocked lord should not be given.

var (
	ErrRivalHidden = errors.New("that lord's page is not open to you")
	ErrSpySelf     = errors.New("you know your own army")
	ErrSpyDayFull  = errors.New("you have used the day's spyglasses")
	ErrSpyGold     = errors.New("you cannot afford the spyglass")
)

// RivalView is a lord's page as another lord sees it.
type RivalView struct {
	PlayerID string `json:"player_id"`
	Name     string `json:"name"`
	Username string `json:"username"`
	Avatar   string `json:"avatar"`
	Level    int64  `json:"level"`
	Might    int64  `json:"might"`
	Look     Look   `json:"look,omitzero"`

	Kingdom    string `json:"kingdom,omitempty"`
	KingdomTag string `json:"kingdom_tag,omitempty"`
	Online     bool   `json:"online"`
	SeenAgo    int64  `json:"seen_ago,omitempty"`

	Gear []RivalGear `json:"gear"`
	Army []RivalUnit `json:"army"`

	// A live report: what the spyglass bought, and how long it has left.
	Scouted    bool  `json:"scouted"`
	ScoutedFor int64 `json:"scouted_for,omitempty"`
	// What another look would cost now, and how many are left today.
	SpyCost int64 `json:"spy_cost"`
	SpyLeft int   `json:"spy_left"`

	// What the three plates at the foot may do.
	IsFriend  bool `json:"is_friend"`
	Requested bool `json:"requested"`
	Blocked   bool `json:"blocked"`
	CanAttack bool `json:"can_attack"`
	Shielded  bool `json:"shielded"`
	IsMe      bool `json:"is_me"`
}

// RivalGear is one piece a rival carries: its name and its rank, never its
// numbers. What it is worth is what the spyglass is for.
type RivalGear struct {
	Slot string `json:"slot"`
	Name string `json:"name,omitempty"`
	Tier string `json:"tier,omitempty"`
	Art  string `json:"art,omitempty"`
	// Empty when the rival carries nothing in that slot: the page draws the
	// painting's own empty frame rather than hiding the slot.
	Empty bool `json:"empty,omitempty"`
}

// RivalUnit is one soldier in a rival's army. The numbers are filled in only
// when a live report has been bought.
type RivalUnit struct {
	Type string `json:"type"`
	Name string `json:"name"`
	Tier string `json:"tier"`
	Art  string `json:"art,omitempty"`

	Attack  int64 `json:"attack,omitempty"`
	Defense int64 `json:"defense,omitempty"`
	HP      int64 `json:"hp,omitempty"`
	Might   int64 `json:"might,omitempty"`
}

// spyReport is what is frozen into app.spy_reports.
type spyReport struct {
	At    int64       `json:"at"`
	Might int64       `json:"might"`
	Army  []RivalUnit `json:"army"`
}

// GetRival reads another lord's page.
func (d Deps) GetRival(ctx context.Context, playerID, targetID uuid.UUID) (*RivalView, error) {
	var out RivalView
	err := db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
		q := sqlcdb.New(tx)
		me, err := q.GetPlayerByID(ctx, playerID)
		if err != nil {
			return ErrNotFound
		}
		them, err := q.GetPlayerByID(ctx, targetID)
		if err != nil {
			return ErrNotFound
		}
		blocked, err := q.BlockedBetween(ctx, sqlcdb.BlockedBetweenParams{A: playerID, B: targetID})
		if err != nil {
			return fmt.Errorf("blocks: %w", err)
		}
		if blocked && playerID != targetID {
			return ErrNotFound
		}
		friends, err := q.AreFriends(ctx, sqlcdb.AreFriendsParams{A: playerID, B: targetID})
		if err != nil {
			return fmt.Errorf("friends: %w", err)
		}
		if err := d.rivalMayLook(me, them, friends); err != nil {
			return err
		}

		now := d.Now()
		out = RivalView{
			PlayerID: them.ID.String(), Name: them.DisplayName, Username: them.Username,
			Avatar: them.Avatar, Level: int64(them.Level), Might: them.Might,
			Look:     lookOf(d.Config, them.CosFrame, them.CosTitle, them.CosColor, them.CosCrest, them.VipPoints),
			IsFriend: friends, IsMe: playerID == targetID,
			Shielded: them.ShieldUntil != nil && them.ShieldUntil.After(now),
			SpyCost:  d.Config.Social.Spy.Cost(int(them.Level)),
			Gear:     []RivalGear{}, Army: []RivalUnit{},
		}
		if them.PrivacyOnline {
			out.Online = now.Sub(them.LastSeenAt) < onlineWithin
			out.SeenAgo = int64(now.Sub(them.LastSeenAt).Seconds())
		}
		if them.KingdomID != nil {
			if k, err := q.GetKingdom(ctx, *them.KingdomID); err == nil {
				out.Kingdom, out.KingdomTag = k.Name, k.Tag
			}
		}
		out.SpyLeft = max(0, d.Config.Social.Spy.PerDay-spiesToday(me, localDay(now, me.ResetOffsetMinutes)))
		if asked, err := q.HasFriendRequest(ctx, sqlcdb.HasFriendRequestParams{
			FromID: playerID, ToID: targetID,
		}); err == nil {
			out.Requested = asked
		}
		out.Blocked = false
		if bl, err := q.BlockedBetween(ctx, sqlcdb.BlockedBetweenParams{A: playerID, B: targetID}); err == nil {
			out.Blocked = bl
		}
		// Raiding has its own rules and its own refusals; the page only says
		// whether the button is worth drawing lit.
		out.CanAttack = playerID != targetID && !them.IsBot &&
			int(me.Level) >= d.Config.SectionLevel(fightSection) &&
			int(them.Level) >= d.Config.SectionLevel(fightSection) &&
			(me.KingdomID == nil || them.KingdomID == nil || *me.KingdomID != *them.KingdomID)

		gear, army, err := d.rivalArmy(ctx, q, them)
		if err != nil {
			return err
		}
		out.Gear, out.Army = gear, army

		// A live report replaces the plain army with the one that was frozen,
		// numbers and all: what you paid for is what you saw when you paid.
		rep, err := q.LiveSpyReport(ctx, sqlcdb.LiveSpyReportParams{ViewerID: playerID, TargetID: targetID})
		if err != nil && !errors.Is(err, pgx.ErrNoRows) {
			return fmt.Errorf("report: %w", err)
		}
		if err == nil {
			var r spyReport
			if json.Unmarshal(rep.Report, &r) == nil {
				out.Scouted = true
				out.ScoutedFor = int64(rep.ExpiresAt.Sub(now).Seconds()) + 1
				out.Army = r.Army
				out.Might = r.Might
			}
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return &out, nil
}

// rivalMayLook is the rival's own choice about who may open their page.
func (d Deps) rivalMayLook(me, them sqlcdb.AppPlayer, friends bool) error {
	if me.ID == them.ID {
		return nil
	}
	switch them.PrivacyProfile {
	case "friends":
		if !friends {
			return ErrRivalHidden
		}
	case "kingdom":
		if !friends && (me.KingdomID == nil || them.KingdomID == nil || *me.KingdomID != *them.KingdomID) {
			return ErrRivalHidden
		}
	}
	return nil
}

// spiesToday is the day's count, or zero on a new day.
func spiesToday(p sqlcdb.AppPlayer, today time.Time) int {
	if !p.SpyDay.Valid || !p.SpyDay.Time.Equal(today) {
		return 0
	}
	return int(p.SpyUsed)
}

// rivalArmy reads what a rival carries and who stands with them, WITHOUT the
// numbers: the names and ranks anybody could see on a battlefield.
func (d Deps) rivalArmy(ctx context.Context, q *sqlcdb.Queries, them sqlcdb.AppPlayer) ([]RivalGear, []RivalUnit, error) {
	gear := []RivalGear{}
	items, err := q.ListPlayerItems(ctx, them.ID)
	if err != nil {
		return nil, nil, fmt.Errorf("their gear: %w", err)
	}
	bySlot := map[string]*sqlcdb.AppPlayerItem{}
	for i := range items {
		if items[i].EquippedOnHero {
			r := items[i]
			bySlot[r.Slot] = &r
		}
	}
	for _, slot := range []string{"weapon", "armor", "horse"} {
		r, ok := bySlot[slot]
		if !ok {
			gear = append(gear, RivalGear{Slot: slot, Empty: true})
			continue
		}
		g := RivalGear{Slot: slot, Tier: r.Tier}
		if def := d.Config.ItemDef(r.DefID); def != nil {
			g.Name, g.Art = def.Name, def.Art
		}
		gear = append(gear, g)
	}

	army := []RivalUnit{}
	soldiers, err := q.ListSoldiers(ctx, them.ID)
	if err != nil {
		return nil, nil, fmt.Errorf("their army: %w", err)
	}
	for _, s := range soldiers {
		army = append(army, RivalUnit{Type: s.TypeID, Tier: s.Tier, Name: d.soldierTypeName(s.TypeID)})
	}
	return gear, army, nil
}

// Spy buys an hour's look at a rival's army.
//
// The lord's own sequenced action: it spends gold, so the client's purse is
// counting on the number.
func (d Deps) Spy(ctx context.Context, playerID, targetID uuid.UUID, wantSeq int64) (*RivalView, error) {
	cfg := d.Config.Social.Spy
	if playerID == targetID {
		return nil, ErrSpySelf
	}
	err := db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
		q := sqlcdb.New(tx)
		locked, err := q.LockTwoPlayers(ctx, []uuid.UUID{playerID, targetID})
		if err != nil {
			return fmt.Errorf("lock players: %w", err)
		}
		var me, them sqlcdb.AppPlayer
		for _, p := range locked {
			if p.ID == playerID {
				me = p
			} else {
				them = p
			}
		}
		if me.ID == uuid.Nil || them.ID == uuid.Nil {
			return ErrNotFound
		}
		if err := checkSeq(me, wantSeq); err != nil {
			return err
		}
		blocked, err := q.BlockedBetween(ctx, sqlcdb.BlockedBetweenParams{A: playerID, B: targetID})
		if err != nil {
			return fmt.Errorf("blocks: %w", err)
		}
		if blocked {
			return ErrNotFound
		}
		friends, err := q.AreFriends(ctx, sqlcdb.AreFriendsParams{A: playerID, B: targetID})
		if err != nil {
			return fmt.Errorf("friends: %w", err)
		}
		if err := d.rivalMayLook(me, them, friends); err != nil {
			return err
		}

		now := d.Now()
		cost := cfg.Cost(int(them.Level))
		after, err := q.PayForSpy(ctx, sqlcdb.PayForSpyParams{
			Cost: cost, ActionSeq: wantSeq, Today: dateOf(localDay(now, me.ResetOffsetMinutes)),
			ID: playerID, PerDay: int32(cfg.PerDay),
		})
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				// One statement refused two things. Which one is worth saying,
				// because "you cannot afford it" and "come back tomorrow" ask
				// for different answers from the lord.
				if spiesToday(me, localDay(now, me.ResetOffsetMinutes)) >= cfg.PerDay {
					return ErrSpyDayFull
				}
				return ErrSpyGold
			}
			return fmt.Errorf("pay for the spyglass: %w", err)
		}
		if err := q.RecordGold(ctx, sqlcdb.RecordGoldParams{
			PlayerID: playerID, Delta: -cost, BalanceAfter: after.Gold,
			Reason: "spy", RefID: strPtr(targetID.String()),
		}); err != nil {
			return fmt.Errorf("log the spyglass: %w", err)
		}

		_, army, err := d.rivalArmy(ctx, q, them)
		if err != nil {
			return err
		}
		// The numbers, as they stand at this moment. Read through the same
		// soldierUnit every screen uses, so a scouted soldier and a fought one
		// are the same soldier.
		eff, err := d.loadEffects(ctx, q, them)
		if err != nil {
			return err
		}
		soldiers, err := q.ListSoldiers(ctx, them.ID)
		if err != nil {
			return fmt.Errorf("their army: %w", err)
		}
		gearBySoldier, err := d.soldierGear(ctx, q, them.ID)
		if err != nil {
			return err
		}
		for i := range soldiers {
			u := d.soldierUnit(them, soldiers[i], gearBySoldier[soldiers[i].ID], eff)
			if i < len(army) {
				army[i].Attack, army[i].Defense = u.Attack, u.Defense
				army[i].HP, army[i].Might = u.HP, u.Might
			}
		}
		raw, err := json.Marshal(spyReport{At: now.Unix(), Might: them.Might, Army: army})
		if err != nil {
			return fmt.Errorf("freeze the report: %w", err)
		}
		if _, err := q.InsertSpyReport(ctx, sqlcdb.InsertSpyReportParams{
			ViewerID: playerID, TargetID: targetID, Cost: cost, Report: raw,
			ExpiresAt: now.Add(time.Duration(cfg.Minutes) * time.Minute),
		}); err != nil {
			return fmt.Errorf("report: %w", err)
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	// Read the page back the ordinary way, which now finds the live report.
	return d.GetRival(ctx, playerID, targetID)
}

// soldierGear is each soldier's three slots, for a lord whose army is being
// read from outside the Army tab.
func (d Deps) soldierGear(ctx context.Context, q *sqlcdb.Queries, playerID uuid.UUID) (map[uuid.UUID]map[string]*ItemView, error) {
	out := map[uuid.UUID]map[string]*ItemView{}
	items, err := q.ListPlayerItems(ctx, playerID)
	if err != nil {
		return nil, fmt.Errorf("gear: %w", err)
	}
	for _, r := range items {
		if r.EquippedSoldierID == nil {
			continue
		}
		m, ok := out[*r.EquippedSoldierID]
		if !ok {
			m = map[string]*ItemView{"weapon": nil, "armor": nil, "horse": nil}
			out[*r.EquippedSoldierID] = m
		}
		iv := d.itemView(r)
		m[r.Slot] = &iv
	}
	return out, nil
}

// ScoutedToday is how many lords have looked at this one since midnight: what
// the raid page tells a lord, so being watched is always felt.
func (d Deps) ScoutedToday(ctx context.Context, q *sqlcdb.Queries, playerID uuid.UUID, since time.Time) int64 {
	n, err := q.CountScoutedSince(ctx, sqlcdb.CountScoutedSinceParams{TargetID: playerID, Since: since})
	if err != nil {
		return 0
	}
	return n
}

// ReportLord is one lord telling the crown about another, where there is no
// line to point at: a name nobody should have to read, a look, a lord who is
// cheating. The hall's own rows carry the other half (ReportChat), and both
// share one cooldown, because a flood is a flood whichever button it comes
// through.
//
// It answers the same to a lord who has just reported the same lord for the
// same thing and to one who has not: a report is not a conversation, and
// telling a reporter their report was a duplicate tells them nothing they can
// use and tells a griefer what to change.
func (d Deps) ReportLord(ctx context.Context, playerID, targetID uuid.UUID, reason string) error {
	switch reason {
	case "name", "look", "chat", "cheat", "other":
	default:
		reason = "other"
	}
	if playerID == targetID {
		// Reporting yourself is not a report.
		return ErrNotFound
	}
	cfg := d.Config.Social.Chat
	return db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
		q := sqlcdb.New(tx)
		now := d.Now()
		if _, err := q.GetPlayerByID(ctx, targetID); err != nil {
			return ErrNotFound
		}
		cool := time.Duration(cfg.ReportCooldownMinutes) * time.Minute
		last, err := q.LastReportAt(ctx, playerID)
		if err != nil && !errors.Is(err, pgx.ErrNoRows) {
			return fmt.Errorf("last report: %w", err)
		}
		if !last.IsZero() && now.Sub(last) < cool {
			return ErrReportedFast
		}
		lastLord, err := q.LastLordReportAt(ctx, playerID)
		if err != nil && !errors.Is(err, pgx.ErrNoRows) {
			return fmt.Errorf("last lord report: %w", err)
		}
		if !lastLord.IsZero() && now.Sub(lastLord) < cool {
			return ErrReportedFast
		}
		if _, err := q.ReportLord(ctx, sqlcdb.ReportLordParams{
			TargetID: targetID, ReporterID: playerID, Reason: reason,
		}); err != nil && !errors.Is(err, pgx.ErrNoRows) {
			return fmt.Errorf("report: %w", err)
		}
		return nil
	})
}
