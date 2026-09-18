package service

import (
	"context"
	"errors"
	"fmt"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/yigitkarabulut0/emperors/server/internal/db"
	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
)

// SETTINGS -- the profile page's SETTINGS row: what the realm may send, when it
// may send it, who may look, and who this lord will not hear from.
//
// Each preference is a column rather than a document. A jsonb of preferences is
// a place for a typo to live, and the server reads every one of these before it
// sends anything.
//
// A BLOCK is one-way and total: the hall, a request, a page, a spyglass. The
// blocked lord is never told -- they are answered "no such lord", which is the
// same answer a deleted account gives, because telling somebody they have been
// blocked is a notification nobody should be able to send.

// SettingsView is the page.
type SettingsView struct {
	Notify  NotifyPrefs  `json:"notify"`
	Privacy PrivacyPrefs `json:"privacy"`
	Blocked []BlockedRow `json:"blocked"`
	// The hall's rules, so SETTINGS can show them without opening the hall.
	Rules ChatRules `json:"rules"`
	// Where a lord writes to a person about any of it. App Review 1.2 wants an
	// address, and this is the one the realm answers.
	Support string `json:"support"`
}

// NotifyPrefs is what the realm may send, and when it may not.
type NotifyPrefs struct {
	Raid    bool `json:"raid"`
	Chat    bool `json:"chat"`
	Mail    bool `json:"mail"`
	Events  bool `json:"events"`
	Friends bool `json:"friends"`
	// Quiet hours in the lord's OWN day, as two hours of the clock. Equal means
	// no quiet hours; from > to wraps midnight, which is the usual case.
	QuietFrom int `json:"quiet_from"`
	QuietTo   int `json:"quiet_to"`
}

// PrivacyPrefs is who may look, and whether this lord shows as here.
type PrivacyPrefs struct {
	// all, friends or kingdom.
	Profile  string `json:"profile"`
	Online   bool   `json:"online"`
	Requests bool   `json:"requests"`
}

// BlockedRow is one lord this lord will not hear from.
type BlockedRow struct {
	PlayerID string `json:"player_id"`
	Name     string `json:"name"`
	Username string `json:"username"`
	Avatar   string `json:"avatar"`
	Level    int64  `json:"level"`
	At       int64  `json:"at"`
}

var (
	ErrBadPrivacy = errors.New("that is not a way a page can be shown")
	ErrBlockSelf  = errors.New("you cannot block yourself")
)

// GetSettings reads the page.
func (d Deps) GetSettings(ctx context.Context, playerID uuid.UUID) (*SettingsView, error) {
	cfg := d.Config.Social.Chat
	q := sqlcdb.New(d.Pool)
	p, err := q.GetPlayerByID(ctx, playerID)
	if err != nil {
		return nil, ErrNotFound
	}
	out := &SettingsView{
		Notify:  notifyOf(p),
		Privacy: privacyOf(p),
		Blocked: []BlockedRow{},
		Rules: ChatRules{
			Version: cfg.RulesVersion, Title: cfg.RulesTitle,
			Lines: cfg.Rules, Support: cfg.SupportEmail,
		},
		Support: cfg.SupportEmail,
	}
	rows, err := q.ListBlocked(ctx, playerID)
	if err != nil {
		return nil, fmt.Errorf("blocked: %w", err)
	}
	for _, r := range rows {
		out.Blocked = append(out.Blocked, BlockedRow{
			PlayerID: r.BlockedID.String(), Name: r.DisplayName, Username: r.Username,
			Avatar: r.Avatar, Level: int64(r.Level), At: r.CreatedAt.Unix(),
		})
	}
	return out, nil
}

func notifyOf(p sqlcdb.AppPlayer) NotifyPrefs {
	return NotifyPrefs{
		Raid: p.NotifRaid, Chat: p.NotifChat, Mail: p.NotifMail,
		Events: p.NotifEvents, Friends: p.NotifFriends,
		QuietFrom: int(p.QuietFrom), QuietTo: int(p.QuietTo),
	}
}

func privacyOf(p sqlcdb.AppPlayer) PrivacyPrefs {
	return PrivacyPrefs{
		Profile: p.PrivacyProfile, Online: p.PrivacyOnline, Requests: p.PrivacyRequests,
	}
}

// SetNotifyPrefs writes what the realm may send.
func (d Deps) SetNotifyPrefs(ctx context.Context, playerID uuid.UUID, n NotifyPrefs) (*NotifyPrefs, error) {
	if n.QuietFrom < 0 || n.QuietFrom > 23 || n.QuietTo < 0 || n.QuietTo > 23 {
		return nil, fmt.Errorf("%w: quiet hours are hours of the clock", ErrBadPrivacy)
	}
	q := sqlcdb.New(d.Pool)
	p, err := q.SetNotifyPrefs(ctx, sqlcdb.SetNotifyPrefsParams{
		NotifRaid: n.Raid, NotifChat: n.Chat, NotifMail: n.Mail,
		NotifEvents: n.Events, NotifFriends: n.Friends,
		QuietFrom: int16(n.QuietFrom), QuietTo: int16(n.QuietTo), PlayerID: playerID,
	})
	if err != nil {
		return nil, fmt.Errorf("notify: %w", err)
	}
	out := notifyOf(p)
	return &out, nil
}

// SetPrivacyPrefs writes who may look.
func (d Deps) SetPrivacyPrefs(ctx context.Context, playerID uuid.UUID, pr PrivacyPrefs) (*PrivacyPrefs, error) {
	switch pr.Profile {
	case "all", "friends", "kingdom":
	default:
		return nil, ErrBadPrivacy
	}
	q := sqlcdb.New(d.Pool)
	p, err := q.SetPrivacyPrefs(ctx, sqlcdb.SetPrivacyPrefsParams{
		PrivacyProfile: pr.Profile, PrivacyOnline: pr.Online,
		PrivacyRequests: pr.Requests, PlayerID: playerID,
	})
	if err != nil {
		return nil, fmt.Errorf("privacy: %w", err)
	}
	out := privacyOf(p)
	return &out, nil
}

// BlockLord stops everything between two lords, one way. It also clears
// whatever was already between them: a request waiting, and the friendship
// itself -- blocking somebody you are friends with is an answer to that
// friendship, not a note about it.
func (d Deps) BlockLord(ctx context.Context, playerID, otherID uuid.UUID) error {
	if playerID == otherID {
		return ErrBlockSelf
	}
	cfg := d.Config.Social.Chat
	return db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
		q := sqlcdb.New(tx)
		if n, err := q.CountBlocked(ctx, playerID); err == nil && int(n) >= cfg.BlockedMax {
			return ErrBlockedLimit
		}
		if _, err := q.GetPlayerByID(ctx, otherID); err != nil {
			return ErrNotFound
		}
		if err := q.BlockLord(ctx, sqlcdb.BlockLordParams{
			PlayerID: playerID, BlockedID: otherID,
		}); err != nil {
			return fmt.Errorf("block: %w", err)
		}
		if _, err := q.DeleteFriendRequestsBetween(ctx, sqlcdb.DeleteFriendRequestsBetweenParams{
			A: playerID, B: otherID,
		}); err != nil {
			return fmt.Errorf("clear requests: %w", err)
		}
		if _, err := q.Unfriend(ctx, sqlcdb.UnfriendParams{A: playerID, B: otherID}); err != nil {
			return fmt.Errorf("unfriend: %w", err)
		}
		return nil
	})
}

// UnblockLord lets a lord be heard again.
func (d Deps) UnblockLord(ctx context.Context, playerID, otherID uuid.UUID) error {
	q := sqlcdb.New(d.Pool)
	n, err := q.UnblockLord(ctx, sqlcdb.UnblockLordParams{PlayerID: playerID, BlockedID: otherID})
	if err != nil {
		return fmt.Errorf("unblock: %w", err)
	}
	if n == 0 {
		return ErrNotFound
	}
	return nil
}
