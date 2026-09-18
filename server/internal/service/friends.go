package service

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/yigitkarabulut0/emperors/server/internal/db"
	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
	"github.com/yigitkarabulut0/emperors/server/internal/game/deeds"
	"github.com/yigitkarabulut0/emperors/server/internal/game/economy"
)

// FRIENDS -- the profile page's FRIENDS row and the strip under it
// (social.json, friends).
//
// A friendship is one row, the pair in id order. Two rows would be two truths,
// and the day they disagreed one lord would see a friend the other did not.
//
// The gift is a FLASK. Energy has always entered this game through the pool,
// the day's three refills and a flask, and a friend's gift is not a fourth
// door: it is a share of the TAKER's own pool, drunk the moment it is taken,
// through exactly the code a flask from a chest goes through.
//
// Three leashes, and each exists because of a specific way this feature is
// farmed: a day old for the account and a day old for the friendship (so a
// morning's fresh accounts cannot gift each other), and a count on the day's
// take (so fifty friends are not fifty pools).

var (
	ErrFriendsLocked  = errors.New("friends open later")
	ErrFriendSelf     = errors.New("you cannot befriend yourself")
	ErrFriendFull     = errors.New("your roll of friends is full")
	ErrFriendTheirs   = errors.New("that lord's roll of friends is full")
	ErrFriendAlready  = errors.New("you are already friends")
	ErrFriendAsked    = errors.New("that request is already waiting")
	ErrFriendRefused  = errors.New("that lord is not taking requests")
	ErrFriendDayFull  = errors.New("you have asked as many lords as the day allows")
	ErrFriendNone     = errors.New("there is no such request")
	ErrGiftSentToday  = errors.New("you have already sent them today's draught")
	ErrGiftDayFull    = errors.New("you have taken all of today's draughts")
	ErrGiftNone       = errors.New("there is no gift waiting from that lord")
	ErrGiftTooNew     = errors.New("a friendship is a day old before it carries gifts")
	ErrAccountTooNew  = errors.New("your house is too new to send gifts")
	ErrBlockedByOther = errors.New("that lord cannot be reached")
)

// FriendsView is the roll, the requests waiting, and the day's gifts.
type FriendsView struct {
	Unlocked    bool `json:"unlocked"`
	UnlockLevel int  `json:"unlock_level"`

	Friends  []FriendRow    `json:"friends"`
	Requests []FriendAsking `json:"requests"`

	MaxFriends int `json:"max_friends"`
	// How many draughts are left in the day, and how many a day there are.
	GiftsLeft   int `json:"gifts_left"`
	GiftsPerDay int `json:"gifts_per_day"`
	// What one draught would restore to this lord right now, so the strip can
	// say what a gift is worth instead of a percentage nobody can picture.
	GiftEnergy int64 `json:"gift_energy"`
}

// FriendRow is one lord on the roll.
type FriendRow struct {
	PlayerID string `json:"player_id"`
	Name     string `json:"name"`
	Username string `json:"username"`
	Avatar   string `json:"avatar"`
	Level    int64  `json:"level"`
	Might    int64  `json:"might"`
	Look     Look   `json:"look,omitzero"`
	Kingdom  string `json:"kingdom,omitempty"`
	// Seconds since they were last in the game, and whether they are here now.
	SeenAgo int64 `json:"seen_ago"`
	Online  bool  `json:"online"`
	Since   int64 `json:"since"`

	// The day's gift, both ways: whether I have sent theirs, and whether one of
	// theirs is waiting for me.
	GaveToday   bool `json:"gave_today"`
	GiftWaiting bool `json:"gift_waiting"`
}

// FriendAsking is a request waiting for an answer.
type FriendAsking struct {
	PlayerID string `json:"player_id"`
	Name     string `json:"name"`
	Username string `json:"username"`
	Avatar   string `json:"avatar"`
	Level    int64  `json:"level"`
	Might    int64  `json:"might"`
	Look     Look   `json:"look,omitzero"`
	Kingdom  string `json:"kingdom,omitempty"`
	At       int64  `json:"at"`
}

// onlineWithin is how recently a lord must have been seen to read as here. The
// presence board uses the same idea; this is the friends' strip's own green dot
// and it does not need a live connection to be right.
const onlineWithin = 5 * time.Minute

// GetFriends reads the roll.
func (d Deps) GetFriends(ctx context.Context, playerID uuid.UUID) (*FriendsView, error) {
	cfg := d.Config.Social.Friends
	var out FriendsView
	err := db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
		q := sqlcdb.New(tx)
		p, err := q.GetPlayerByID(ctx, playerID)
		if err != nil {
			return ErrNotFound
		}
		now := d.Now()
		at := d.Config.SectionLevel(cfg.Section)
		out = FriendsView{
			Unlocked: int(p.Level) >= at, UnlockLevel: at,
			MaxFriends: cfg.MaxFriends, GiftsPerDay: cfg.GiftsReceivedPerDay,
			Friends: []FriendRow{}, Requests: []FriendAsking{},
		}
		out.GiftsLeft = cfg.GiftsReceivedPerDay - giftsTakenToday(p, localDay(now, p.ResetOffsetMinutes))
		if out.GiftsLeft < 0 {
			out.GiftsLeft = 0
		}
		if tok := d.Config.Token(cfg.GiftToken); tok != nil {
			eff, err := d.loadEffects(ctx, q, p)
			if err != nil {
				return err
			}
			_, maxEnergy, _ := settleEnergy(d.Config, p, eff, now)
			out.GiftEnergy = flaskAmount(tok.EnergyPct, maxEnergy)
		}
		if !out.Unlocked {
			return nil
		}

		rows, err := q.ListFriends(ctx, sqlcdb.ListFriendsParams{
			Me: playerID, Today: dateOf(localDay(now, p.ResetOffsetMinutes)), Lim: int32(cfg.MaxFriends),
		})
		if err != nil {
			return fmt.Errorf("friends: %w", err)
		}
		for _, r := range rows {
			row := FriendRow{
				PlayerID: r.ID.String(), Name: r.DisplayName, Username: r.Username,
				Avatar: r.Avatar, Level: int64(r.Level), Might: r.Might,
				Look:    lookOf(d.Config, r.CosFrame, r.CosTitle, r.CosColor, r.CosCrest, r.VipPoints),
				SeenAgo: int64(now.Sub(r.LastSeenAt).Seconds()), Since: r.Since.Unix(),
				GaveToday: r.GaveToday, GiftWaiting: r.GiftWaiting,
			}
			if r.KingdomName != nil {
				row.Kingdom = *r.KingdomName
			}
			// A lord who has asked not to be shown as here is never shown as
			// here -- to anybody, including their friends.
			row.Online = r.PrivacyOnline && now.Sub(r.LastSeenAt) < onlineWithin
			if !r.PrivacyOnline {
				row.SeenAgo = 0
			}
			out.Friends = append(out.Friends, row)
		}

		asks, err := q.ListFriendRequests(ctx, sqlcdb.ListFriendRequestsParams{
			Me: playerID, Lim: int32(cfg.PendingMax),
		})
		if err != nil {
			return fmt.Errorf("requests: %w", err)
		}
		for _, r := range asks {
			a := FriendAsking{
				PlayerID: r.FromID.String(), Name: r.DisplayName, Username: r.Username,
				Avatar: r.Avatar, Level: int64(r.Level), Might: r.Might,
				Look: lookOf(d.Config, r.CosFrame, r.CosTitle, r.CosColor, r.CosCrest, r.VipPoints),
				At:   r.CreatedAt.Unix(),
			}
			if r.KingdomName != nil {
				a.Kingdom = *r.KingdomName
			}
			out.Requests = append(out.Requests, a)
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return &out, nil
}

// giftsTakenToday is the day's count, or zero on a new day.
func giftsTakenToday(p sqlcdb.AppPlayer, today time.Time) int {
	if !p.GiftDay.Valid || !p.GiftDay.Time.Equal(today) {
		return 0
	}
	return int(p.GiftsTaken)
}

// RequestFriend asks a lord by name. By NAME, not by id: a request is a thing
// one lord sends another on purpose, and an id is something a client scraped.
func (d Deps) RequestFriend(ctx context.Context, playerID uuid.UUID, username string) (*FriendAsking, error) {
	cfg := d.Config.Social.Friends
	username = strings.TrimSpace(username)
	var out FriendAsking
	err := db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
		q := sqlcdb.New(tx)
		me, err := q.GetPlayerByID(ctx, playerID)
		if err != nil {
			return ErrNotFound
		}
		at := d.Config.SectionLevel(cfg.Section)
		if int(me.Level) < at {
			return fmt.Errorf("%w: friends open at level %d", ErrFriendsLocked, at)
		}
		them, err := q.GetPlayerByUsername(ctx, username)
		if err != nil {
			return ErrNotFound
		}
		if them.ID == playerID {
			return ErrFriendSelf
		}
		if them.IsBot || them.State != "active" {
			return ErrNotFound
		}
		// A block hides a lord from the one who blocked them, either way round:
		// the answer is "no such lord", never "you are blocked", because the
		// second is a notification a blocked lord should not be given.
		blocked, err := q.BlockedBetween(ctx, sqlcdb.BlockedBetweenParams{A: playerID, B: them.ID})
		if err != nil {
			return fmt.Errorf("blocks: %w", err)
		}
		if blocked {
			return ErrNotFound
		}
		if !them.PrivacyRequests {
			return ErrFriendRefused
		}
		already, err := q.AreFriends(ctx, sqlcdb.AreFriendsParams{A: playerID, B: them.ID})
		if err != nil {
			return fmt.Errorf("friends: %w", err)
		}
		if already {
			return ErrFriendAlready
		}
		if n, err := q.CountFriends(ctx, playerID); err == nil && int(n) >= cfg.MaxFriends {
			return ErrFriendFull
		}
		if n, err := q.CountFriends(ctx, them.ID); err == nil && int(n) >= cfg.MaxFriends {
			return ErrFriendTheirs
		}
		if n, err := q.CountFriendRequestsTo(ctx, them.ID); err == nil && int(n) >= cfg.PendingMax {
			return ErrFriendTheirs
		}

		now := d.Now()
		today := localDay(now, me.ResetOffsetMinutes)
		if _, err := q.SpendFriendRequest(ctx, sqlcdb.SpendFriendRequestParams{
			Today: dateOf(today), PlayerID: playerID, PerDay: int32(cfg.RequestsPerDay),
		}); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrFriendDayFull
			}
			return fmt.Errorf("day's requests: %w", err)
		}

		// They asked me first: answering with a request of my own is an accept,
		// which is what a lord means by it.
		theirs, err := q.HasFriendRequest(ctx, sqlcdb.HasFriendRequestParams{FromID: them.ID, ToID: playerID})
		if err != nil {
			return fmt.Errorf("their request: %w", err)
		}
		if theirs {
			if err := d.befriend(ctx, q, playerID, them.ID); err != nil {
				return err
			}
			out = FriendAsking{PlayerID: them.ID.String(), Name: them.DisplayName,
				Username: them.Username, Avatar: them.Avatar, Level: int64(them.Level),
				Might: them.Might, At: now.Unix()}
			return nil
		}

		row, err := q.InsertFriendRequest(ctx, sqlcdb.InsertFriendRequestParams{
			FromID: playerID, ToID: them.ID,
		})
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrFriendAsked
			}
			return fmt.Errorf("ask: %w", err)
		}
		out = FriendAsking{PlayerID: them.ID.String(), Name: them.DisplayName,
			Username: them.Username, Avatar: them.Avatar, Level: int64(them.Level),
			Might: them.Might, At: row.CreatedAt.Unix()}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return &out, nil
}

// befriend writes the friendship and clears whatever was waiting either way.
func (d Deps) befriend(ctx context.Context, q *sqlcdb.Queries, a, b uuid.UUID) error {
	if _, err := q.MakeFriends(ctx, sqlcdb.MakeFriendsParams{A: a, B: b}); err != nil {
		return fmt.Errorf("befriend: %w", err)
	}
	if _, err := q.DeleteFriendRequestsBetween(ctx, sqlcdb.DeleteFriendRequestsBetweenParams{A: a, B: b}); err != nil {
		return fmt.Errorf("clear requests: %w", err)
	}
	return nil
}

// AnswerFriendRequest accepts or declines one waiting request.
func (d Deps) AnswerFriendRequest(ctx context.Context, playerID, fromID uuid.UUID, accept bool) error {
	cfg := d.Config.Social.Friends
	return db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
		q := sqlcdb.New(tx)
		has, err := q.HasFriendRequest(ctx, sqlcdb.HasFriendRequestParams{FromID: fromID, ToID: playerID})
		if err != nil {
			return fmt.Errorf("request: %w", err)
		}
		if !has {
			return ErrFriendNone
		}
		if !accept {
			if _, err := q.DeleteFriendRequest(ctx, sqlcdb.DeleteFriendRequestParams{
				FromID: fromID, ToID: playerID,
			}); err != nil {
				return fmt.Errorf("decline: %w", err)
			}
			return nil
		}
		if n, err := q.CountFriends(ctx, playerID); err == nil && int(n) >= cfg.MaxFriends {
			return ErrFriendFull
		}
		if n, err := q.CountFriends(ctx, fromID); err == nil && int(n) >= cfg.MaxFriends {
			return ErrFriendTheirs
		}
		return d.befriend(ctx, q, playerID, fromID)
	})
}

// Unfriend takes a lord off the roll. Both sides lose the friendship, because
// there was only ever one row.
func (d Deps) Unfriend(ctx context.Context, playerID, otherID uuid.UUID) error {
	q := sqlcdb.New(d.Pool)
	n, err := q.Unfriend(ctx, sqlcdb.UnfriendParams{A: playerID, B: otherID})
	if err != nil {
		return fmt.Errorf("unfriend: %w", err)
	}
	if n == 0 {
		return ErrNotFound
	}
	return nil
}

// GiftSent is what the sender gets back.
type GiftSent struct {
	To string `json:"to"`
	// The day the gift belongs to, in the SENDER's own day.
	Day string `json:"day"`
}

// SendGift sends one friend today's draught. It costs the sender nothing: a
// gift that cost energy would be a trade, and a trade between two accounts one
// person owns is a pipe.
func (d Deps) SendGift(ctx context.Context, playerID, toID uuid.UUID) (*GiftSent, error) {
	cfg := d.Config.Social.Friends
	if playerID == toID {
		return nil, ErrFriendSelf
	}
	tok := d.Config.Token(cfg.GiftToken)
	if tok == nil || tok.EnergyPct <= 0 {
		return nil, ErrNotUsable
	}
	var out GiftSent
	err := db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
		q := sqlcdb.New(tx)
		me, err := q.GetPlayerByID(ctx, playerID)
		if err != nil {
			return ErrNotFound
		}
		at := d.Config.SectionLevel(cfg.Section)
		if int(me.Level) < at {
			return fmt.Errorf("%w: friends open at level %d", ErrFriendsLocked, at)
		}
		now := d.Now()
		if now.Sub(me.CreatedAt) < time.Duration(cfg.MinAccountHours)*time.Hour {
			return ErrAccountTooNew
		}
		since, err := q.FriendSince(ctx, sqlcdb.FriendSinceParams{A: playerID, B: toID})
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrNotFound
			}
			return fmt.Errorf("friendship: %w", err)
		}
		if now.Sub(since) < time.Duration(cfg.MinFriendHours)*time.Hour {
			return ErrGiftTooNew
		}
		today := localDay(now, me.ResetOffsetMinutes)
		row, err := q.SendGift(ctx, sqlcdb.SendGiftParams{
			FromID: playerID, ToID: toID, SentOn: dateOf(today), Token: cfg.GiftToken,
		})
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrGiftSentToday
			}
			return fmt.Errorf("gift: %w", err)
		}
		d.recordDeeds(ctx, tx, me, deeds.Deeds{deeds.GiftsGiven: 1})
		out = GiftSent{To: toID.String(), Day: row.SentOn.Time.Format("2006-01-02")}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return &out, nil
}

// GiftTaken is what the taker gets back: the energy, and the state it left them
// in, exactly as drinking a flask answers.
type GiftTaken struct {
	From         string    `json:"from"`
	EnergyGained int64     `json:"energy_gained"`
	GiftsLeft    int       `json:"gifts_left"`
	Snapshot     *Snapshot `json:"snapshot,omitempty"`
}

// TakeGift drinks one friend's draught.
//
// It is the lord's own sequenced action, like every other flask: the client
// counts the energy it will have. A full pool refuses it and the gift stays
// where it is -- a draught poured onto the floor is a promise broken.
func (d Deps) TakeGift(ctx context.Context, playerID, fromID uuid.UUID, wantSeq int64) (*GiftTaken, error) {
	cfg := d.Config.Social.Friends
	var out GiftTaken
	err := db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
		q := sqlcdb.New(tx)
		p, err := q.LockPlayer(ctx, playerID)
		if err != nil {
			return ErrNotFound
		}
		if err := checkSeq(p, wantSeq); err != nil {
			return err
		}
		now := d.Now()
		today := localDay(now, p.ResetOffsetMinutes)

		// Which gift, and what flask it carries. The row names its own token,
		// so a balance that one day sends a bigger draught does not change what
		// was already promised.
		waiting, err := q.ListWaitingGifts(ctx, sqlcdb.ListWaitingGiftsParams{Me: playerID, Lim: 50})
		if err != nil {
			return fmt.Errorf("gifts: %w", err)
		}
		var pick *sqlcdb.ListWaitingGiftsRow
		for i := range waiting {
			if waiting[i].FromID == fromID {
				pick = &waiting[i]
				break
			}
		}
		if pick == nil {
			return ErrGiftNone
		}
		tok := d.Config.Token(pick.Token)
		if tok == nil || tok.EnergyPct <= 0 {
			return ErrNotUsable
		}

		eff, err := d.loadEffects(ctx, q, p)
		if err != nil {
			return err
		}
		settled, maxEnergy, _ := settleEnergy(d.Config, p, eff, now)
		before := economy.Whole(settled)
		if before >= maxEnergy {
			return ErrEnergyFull
		}
		taken, err := q.SpendGiftTake(ctx, sqlcdb.SpendGiftTakeParams{
			Today: dateOf(today), PlayerID: playerID, PerDay: int32(cfg.GiftsReceivedPerDay),
		})
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrGiftDayFull
			}
			return fmt.Errorf("day's draughts: %w", err)
		}
		if _, err := q.TakeGift(ctx, sqlcdb.TakeGiftParams{
			FromID: fromID, ToID: playerID, SentOn: pick.SentOn,
		}); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrGiftNone
			}
			return fmt.Errorf("take: %w", err)
		}
		after := economy.Restore(settled, flaskAmount(tok.EnergyPct, maxEnergy), maxEnergy, now)
		if _, err := q.DrinkFlask(ctx, sqlcdb.DrinkFlaskParams{
			ID: p.ID, EnergyMilli: after.Milli, EnergyUpdatedAt: after.UpdatedAt, ActionSeq: wantSeq,
		}); err != nil {
			return fmt.Errorf("drink: %w", err)
		}
		out = GiftTaken{
			From: fromID.String(), EnergyGained: economy.Whole(after) - before,
			GiftsLeft: max(0, cfg.GiftsReceivedPerDay-int(taken)),
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	out.Snapshot, err = d.GetState(ctx, playerID)
	return &out, err
}
