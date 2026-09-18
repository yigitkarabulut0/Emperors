package service

import (
	"context"
	"errors"
	"fmt"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/yigitkarabulut0/emperors/server/internal/db"
	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
)

// Badges is what the rail and the pills flag as waiting for the player: work
// that is finished and not yet claimed, or a decision somebody else is waiting
// on. Nothing on the rail said any of it, so a finished quest, a revenge strike
// and a lord asking to join all waited until the player happened to open the
// right tab.
//
// Counts, never amounts: the tabs say what is waiting when they are opened.
type Badges struct {
	Quests   int  `json:"quests"`   // done and not claimed
	Daily    bool `json:"daily"`    // the day's reward can be claimed
	Revenge  int  `json:"revenge"`  // raiders there is still a day to answer
	Requests int  `json:"requests"` // lords asking to join (a king or captain's)
	Mail     int  `json:"mail"`     // letters unread, or with something still to claim
	// Offers open now, and how many the lord has not yet been shown.
	Offers       int `json:"offers"`
	OffersUnseen int `json:"offers_unseen"`
	// Something in the Royal Store is free to take today: the Stipend's share
	// or Royal Favour's gift.
	StoreFree bool `json:"store_free"`
	// The daily loop: carts waiting at the gate (and writs held), the week's
	// tasks done and chests earned but not claimed, and Victory Road
	// milestones reached and not claimed.
	Cart   int `json:"cart"`
	Weekly int `json:"weekly"`
	Road   int `json:"road"`
	// Live ops: the Royal Courier's gift waiting this hour, the running
	// festival's tasks and milestones done and unclaimed, the Charter's tiers
	// reached and unclaimed, and the deeds' tiers.
	Hourly       bool `json:"hourly"`
	Events       int  `json:"events"`
	Season       int  `json:"season"`
	Achievements int  `json:"achievements"`
	// Rekabet: fights left in the lists today, prices standing on this lord's
	// own head, and an emperor's undeclared decree. A count, not a flag, for
	// the bounties: TabStrip.set_count takes an int and an empty bubble reads
	// as though something waits.
	Arena      int  `json:"arena"`
	BountyOnMe int  `json:"bounty_on_me"`
	Decree     bool `json:"decree"`
	// Sosyal: lines said in this lord's hall since they last read it, friend
	// requests waiting for an answer, and gifts waiting to be taken. A hall
	// nobody knows has spoken is a hall nobody opens twice.
	Chat     int `json:"chat"`
	Friends  int `json:"friends"`
	Gifts    int `json:"gifts"`
	AidCalls int `json:"aid_calls"`
	// PvE ve derinlik: soldiers standing at the gate with a haul nobody has let
	// in, and chapter chests whose stars are earned and unclaimed. The game has
	// no push notifications, so the ribbon on the rail is how a lord learns
	// their scout is home.
	Hunt     int `json:"hunt"`
	Campaign int `json:"campaign"`
}

// chaptersWaiting counts chapter chests whose stars are earned and untaken.
//
// Two queries for the whole road, not two a chapter: this runs on the rail's
// heartbeat. Each part that fails is left at zero, as every part of the badges
// is -- a missing badge costs a nudge, not a screen.
func (d Deps) chaptersWaiting(ctx context.Context, q *sqlcdb.Queries, playerID uuid.UUID) int {
	stars, err := d.loadStars(ctx, q, playerID)
	if err != nil {
		return 0
	}
	rows, err := q.ListAllCampaignChests(ctx, playerID)
	if err != nil {
		return 0
	}
	claimed := make(map[string]map[int]bool, len(rows))
	for _, r := range rows {
		if claimed[r.ChapterID] == nil {
			claimed[r.ChapterID] = map[int]bool{}
		}
		claimed[r.ChapterID][int(r.ChestIx)] = true
	}
	n := 0
	for ci := range d.Config.Campaign.Chapters {
		ch := &d.Config.Campaign.Chapters[ci]
		held := stars.InChapter(ch.ID)
		if held == 0 {
			continue
		}
		for i, chest := range ch.Chests {
			if held >= chest.Stars && !claimed[ch.ID][i] {
				n++
			}
		}
	}
	return n
}

// GetBadges gathers them. Each part that fails is left at zero rather than
// failing the whole: a missing badge costs a nudge, not a screen.
func (d Deps) GetBadges(ctx context.Context, playerID uuid.UUID) (*Badges, error) {
	q := sqlcdb.New(d.Pool)
	p, err := q.GetPlayerByID(ctx, playerID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, fmt.Errorf("badges: %w", err)
	}
	b := &Badges{}
	if qv, err := d.GetQuests(ctx, playerID); err == nil {
		for _, x := range qv.Quests {
			if x.Done && !x.Claimed {
				b.Quests++
			}
		}
	}
	// The day's square, read from the row alone: the calendar view prices every
	// square, which a heartbeat has no need of.
	b.Daily = d.calendarStatus(p, d.Now()).Claimable
	if held, err := tokenCounts(ctx, q, playerID); err == nil {
		if cs := d.cartSnap(p, held["cart"], d.Now()); cs.Unlocked {
			b.Cart = cs.Stock + int(cs.Tokens)
		}
	}
	if n, err := d.weeklyWaiting(ctx, q, p); err == nil {
		b.Weekly = n
	}
	b.Road = d.roadClaimable(p)
	now := d.Now()
	if h := d.runningHourly(now, gameconfig.HourlyGift); h != nil {
		b.Hourly = d.hourlyUsesLeft(ctx, q, p.ID, *h) > 0
	}
	b.Events = d.festivalClaimable(ctx, q, p, now)
	b.Season = d.seasonClaimable(ctx, q, p, now)
	b.Achievements = d.achievementsClaimable(ctx, q, p)
	// Rekabet. Each part that fails is left at zero, as every part here is.
	if a := d.Config.PvP.Arena; int(p.Level) >= d.Config.SectionLevel(a.Section) {
		today := localDay(now, p.ResetOffsetMinutes)
		held, _ := tokenCounts(ctx, q, p.ID)
		b.Arena = maxInt(0, a.TicketsPerDay+int(held[arenaTicketToken])-arenaFightsToday(p, today))
	}
	if n, err := q.CountOpenBountiesOnMe(ctx, p.ID); err == nil {
		b.BountyOnMe = int(n)
	}
	if p.KingdomID != nil {
		if n, err := q.ChatUnread(ctx, sqlcdb.ChatUnreadParams{
			KingdomID: *p.KingdomID, SeenSeq: p.ChatSeenSeq, Me: &p.ID,
		}); err == nil {
			b.Chat = int(n)
		}
		if calls, err := q.ListAidCalls(ctx, sqlcdb.ListAidCallsParams{
			Me: p.ID, KingdomID: *p.KingdomID, Lim: 20,
		}); err == nil {
			for _, c := range calls {
				if !c.Answered {
					b.AidCalls++
				}
			}
		}
	}
	if rows, err := q.ListExpeditions(ctx, p.ID); err == nil {
		for _, r := range rows {
			if !r.EndsAt.After(now) {
				b.Hunt++
			}
		}
	}
	if int(p.Level) >= d.Config.SectionLevel(d.Config.Campaign.Section) {
		b.Campaign = d.chaptersWaiting(ctx, q, p.ID)
	}
	if n, err := q.CountFriendRequestsTo(ctx, p.ID); err == nil {
		b.Friends = int(n)
	}
	if gifts, err := q.ListWaitingGifts(ctx, sqlcdb.ListWaitingGiftsParams{Me: p.ID, Lim: 50}); err == nil {
		// Capped by what the day still allows: a bubble promising ten draughts
		// to a lord who may take three is a bubble that lies.
		left := maxInt(0, d.Config.Social.Friends.GiftsReceivedPerDay-
			giftsTakenToday(p, localDay(now, p.ResetOffsetMinutes)))
		b.Gifts = minInt(len(gifts), left)
	}
	if dec := d.Boosts.Decree(); dec == nil {
		if row, err := q.CurrentThrone(ctx, now); err == nil {
			b.Decree = row.EmperorID == p.ID && row.DecreeID == nil
		}
	}
	// One per raider, as the Attack tab lists them: one strike settles every
	// token held against a lord. Allies are left out, as the list leaves them.
	if rows, err := q.ListRevenge(ctx, playerID); err == nil {
		seen := map[uuid.UUID]bool{}
		for _, r := range rows {
			if p.KingdomID != nil && r.TargetKingdomID != nil && *p.KingdomID == *r.TargetKingdomID {
				continue
			}
			if !seen[r.TargetID] {
				seen[r.TargetID] = true
				b.Revenge++
			}
		}
	}
	if p.KingdomID != nil && (p.KingdomRole == "king" || p.KingdomRole == "marshal") {
		if rows, err := q.ListRequestsForKingdom(ctx, *p.KingdomID); err == nil {
			b.Requests = len(rows)
		}
	}
	if ofs, err := q.ListOffers(ctx, playerID); err == nil {
		// A level reached is the moment its offer opens, and the badges are the
		// lord's next look; the popup then shows it at a calm moment. Written
		// only when something is due, so the steady heartbeat stays a read.
		if fire, lapse := d.levelOffersDue(p, d.shownFrom(ofs)); len(fire)+len(lapse) > 0 {
			err := db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
				return d.fireLevelOffers(ctx, sqlcdb.New(tx), p)
			})
			if err != nil {
				d.logSoftStep("level offers", err)
			} else if again, err := q.ListOffers(ctx, playerID); err == nil {
				ofs = again
			}
		}
		b.Offers, b.OffersUnseen = activeOffers(ofs, d.Now())
	}
	today := localDay(d.Now(), p.ResetOffsetMinutes)
	if st := d.stipendConfig(); st != nil && stipendDaysLeft(p, today) > 0 &&
		(!p.StipendClaimed.Valid || p.StipendClaimed.Time.Before(today)) {
		b.StoreFree = true
	}
	if v := d.vipView(p, today); v.GiftClaimable {
		b.StoreFree = true
	}
	if d.giftWaiting(ctx, q, p) {
		b.StoreFree = true
	}
	if n, err := d.mailWaiting(ctx, q, p); err == nil {
		b.Mail = n
	}
	return b, nil
}
