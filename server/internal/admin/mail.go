package admin

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/yigitkarabulut0/emperors/server/internal/db"
	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
)

// MailSegment picks who a segment letter reaches. Zero ActiveDays means anyone,
// however long ago they last played.
type MailSegment struct {
	MinLevel   int `json:"min_level"`
	MaxLevel   int `json:"max_level"`
	ActiveDays int `json:"active_days"`
}

// MailSend is one letter from the panel.
type MailSend struct {
	// "player", "segment" or "all".
	Target      string                  `json:"target"`
	PlayerID    string                  `json:"player_id"`
	Segment     MailSegment             `json:"segment"`
	Sender      string                  `json:"sender"`
	Title       string                  `json:"title"`
	Body        string                  `json:"body"`
	Attachments gameconfig.RewardBundle `json:"attachments"`
	ExpiresDays int                     `json:"expires_days"`
	// For "all": whether lords who arrive after it is sent receive it too.
	IncludeNew bool   `json:"include_new"`
	Note       string `json:"note"`
}

// MailSent is what a send reached.
type MailSent struct {
	BroadcastID int64 `json:"broadcast_id"`
	// Letters written now. An "all" letter is written as each lord next looks,
	// so this is 0 for one and Audience says how many it can reach.
	Delivered int `json:"delivered"`
	Audience  int `json:"audience"`
}

// mailRole is the least role that may send this letter.
//
// Escalated by what it carries: words cost nothing, a handful of diamonds or a
// potion is support's everyday tool, anything that moves the economy -- gold,
// gear, experience, a timed bonus, a cosmetic -- is a designer's call, and a
// gift to EVERY player is the owner's.
func mailRole(m MailSend) string {
	a := m.Attachments
	if m.Target == "all" && !a.Empty() {
		return "owner"
	}
	if a.Gold > 0 || a.GoldWages > 0 || a.XP > 0 || a.XPWages > 0 || a.Favour > 0 ||
		len(a.Items) > 0 || len(a.Boosts) > 0 || len(a.Cosmetics) > 0 || a.Diamonds > 100 {
		return "designer"
	}
	return "moderator"
}

func (s *Service) checkMail(cfg *gameconfig.Bundle, m *MailSend) error {
	m.Title = strings.TrimSpace(m.Title)
	if n := len([]rune(m.Title)); n < 1 || n > 80 {
		return fmt.Errorf("%w: the title must be 1 to 80 characters", ErrOutOfRange)
	}
	if len([]rune(m.Body)) > 2000 {
		return fmt.Errorf("%w: the body is over 2000 characters", ErrOutOfRange)
	}
	if strings.TrimSpace(m.Sender) == "" {
		m.Sender = "The Crown"
	}
	if len([]rune(m.Sender)) > 40 {
		return fmt.Errorf("%w: the sender is over 40 characters", ErrOutOfRange)
	}
	if m.ExpiresDays == 0 {
		m.ExpiresDays = cfg.Rewards.Mail.DefaultExpiryDays
	}
	if m.ExpiresDays < 1 || m.ExpiresDays > 90 {
		return fmt.Errorf("%w: a letter lasts 1 to 90 days", ErrOutOfRange)
	}
	if problems := cfg.CheckReward(m.Attachments, false); len(problems) > 0 {
		return fmt.Errorf("%w: %s", ErrOutOfRange, strings.Join(problems, "; "))
	}
	switch m.Target {
	case "player", "all":
	case "segment":
		seg := &m.Segment
		if seg.MinLevel < 1 {
			seg.MinLevel = 1
		}
		if seg.MaxLevel == 0 {
			seg.MaxLevel = cfg.Progression.LevelCap
		}
		if seg.MinLevel > seg.MaxLevel || seg.ActiveDays < 0 {
			return fmt.Errorf("%w: the segment selects nobody", ErrOutOfRange)
		}
	default:
		return fmt.Errorf("%w: target must be player, segment or all", ErrOutOfRange)
	}
	return nil
}

// SendMail sends a letter from the panel.
func (s *Service) SendMail(ctx context.Context, who *Identity, m MailSend) (*MailSent, error) {
	if !AtLeast(who.Role, mailRole(m)) {
		return nil, ErrForbidden
	}
	cfg := s.Config.Get()
	if err := s.checkMail(cfg, &m); err != nil {
		return nil, err
	}
	var playerID uuid.UUID
	if m.Target == "player" {
		id, err := uuid.Parse(m.PlayerID)
		if err != nil {
			return nil, fmt.Errorf("%w: player_id must be a uuid", ErrOutOfRange)
		}
		playerID = id
	}
	attach, err := json.Marshal(m.Attachments)
	if err != nil {
		return nil, err
	}
	seg, _ := json.Marshal(m.Segment)
	expires := s.now().Add(time.Duration(m.ExpiresDays) * 24 * time.Hour)

	var res MailSent
	err = db.InTx(ctx, s.Pool, func(tx pgx.Tx) error {
		q := sqlcdb.New(tx)
		b, err := q.InsertBroadcast(ctx, sqlcdb.InsertBroadcastParams{
			Audience: m.Target, Segment: seg, Sender: m.Sender, Title: m.Title, Body: m.Body,
			Attachments: attach, IncludeNew: m.IncludeNew, ExpiresAt: expires,
			CreatedBy: who.Username, Note: m.Note,
		})
		if err != nil {
			return fmt.Errorf("broadcast: %w", err)
		}
		res.BroadcastID = b.ID
		switch m.Target {
		case "player":
			if _, err := q.GetPlayerByID(ctx, playerID); err != nil {
				return ErrNotFound
			}
			key := fmt.Sprintf("bc:%d", b.ID)
			if _, err := q.InsertMail(ctx, sqlcdb.InsertMailParams{
				PlayerID: playerID, Kind: "admin", Sender: m.Sender, Title: m.Title, Body: m.Body,
				Attachments: attach, IdemKey: &key,
				BroadcastID: pgInt8(b.ID), ExpiresAt: expires,
			}); err != nil {
				return fmt.Errorf("letter: %w", err)
			}
			res.Delivered, res.Audience = 1, 1
		case "segment":
			n, err := q.SendSegmentMail(ctx, sqlcdb.SendSegmentMailParams{
				BroadcastID: b.ID, MinLevel: int32(m.Segment.MinLevel),
				MaxLevel: int32(m.Segment.MaxLevel), ActiveDays: int32(m.Segment.ActiveDays),
			})
			if err != nil {
				return fmt.Errorf("segment letters: %w", err)
			}
			res.Delivered, res.Audience = int(n), int(n)
		case "all":
			n, err := q.CountActivePlayers(ctx)
			if err != nil {
				return err
			}
			res.Audience = int(n)
		}
		return q.SetBroadcastSent(ctx, sqlcdb.SetBroadcastSentParams{ID: b.ID, SentCount: int32(res.Delivered)})
	})
	if err != nil {
		return nil, err
	}
	s.Audit(ctx, who, "mail.send", fmt.Sprint(res.BroadcastID), nil,
		map[string]any{"target": m.Target, "player_id": m.PlayerID, "segment": m.Segment,
			"title": m.Title, "attachments": m.Attachments, "expires_days": m.ExpiresDays,
			"delivered": res.Delivered, "audience": res.Audience}, m.Note)
	return &res, nil
}

// MailAudience is how many a letter would reach, before it is sent.
func (s *Service) MailAudience(ctx context.Context, target string, seg MailSegment) (int, error) {
	q := sqlcdb.New(s.Pool)
	switch target {
	case "player":
		return 1, nil
	case "all":
		n, err := q.CountActivePlayers(ctx)
		return int(n), err
	case "segment":
		if seg.MinLevel < 1 {
			seg.MinLevel = 1
		}
		if seg.MaxLevel == 0 {
			seg.MaxLevel = s.Config.Get().Progression.LevelCap
		}
		n, err := q.CountSegment(ctx, sqlcdb.CountSegmentParams{
			MinLevel: int32(seg.MinLevel), MaxLevel: int32(seg.MaxLevel), ActiveDays: int32(seg.ActiveDays),
		})
		return int(n), err
	}
	return 0, fmt.Errorf("%w: target must be player, segment or all", ErrOutOfRange)
}

// Broadcast is one sent letter, for the panel's history.
type Broadcast struct {
	ID          int64                   `json:"id"`
	Audience    string                  `json:"audience"`
	Segment     json.RawMessage         `json:"segment"`
	Sender      string                  `json:"sender"`
	Title       string                  `json:"title"`
	Body        string                  `json:"body"`
	Attachments gameconfig.RewardBundle `json:"attachments"`
	ExpiresAt   string                  `json:"expires_at"`
	CreatedBy   string                  `json:"created_by"`
	CreatedAt   string                  `json:"created_at"`
	// Every copy written; the ones claimed; the unclaimed ones a revoke took back.
	Delivered int  `json:"delivered"`
	Claimed   int  `json:"claimed"`
	Withdrawn int  `json:"withdrawn"`
	Revoked   bool `json:"revoked"`
	// For "all": whether lords who join after the send receive it too.
	IncludeNew bool `json:"include_new"`
	// For "player": the lord it went to ("" once they have deleted their account).
	Recipient string `json:"recipient"`
	Note      string `json:"note"`
}

// Broadcasts lists recent letters from the panel, newest first.
func (s *Service) Broadcasts(ctx context.Context, limit int32) ([]Broadcast, error) {
	rows, err := sqlcdb.New(s.Pool).ListBroadcasts(ctx, limit)
	if err != nil {
		return nil, err
	}
	out := make([]Broadcast, 0, len(rows))
	for _, r := range rows {
		b := Broadcast{
			ID: r.ID, Audience: r.Audience, Segment: r.Segment, Sender: r.Sender, Title: r.Title,
			Body: r.Body, ExpiresAt: r.ExpiresAt.UTC().Format(time.RFC3339),
			CreatedBy: r.CreatedBy, CreatedAt: r.CreatedAt.UTC().Format(time.RFC3339),
			Delivered: int(r.Delivered), Claimed: int(r.Claimed), Withdrawn: int(r.Withdrawn),
			Revoked: r.RevokedAt != nil, IncludeNew: r.IncludeNew, Recipient: r.Recipient, Note: r.Note,
		}
		_ = json.Unmarshal(r.Attachments, &b.Attachments)
		out = append(out, b)
	}
	return out, nil
}

// RevokeBroadcast stops a letter reaching anyone else and takes back every copy
// nobody has opened. What was claimed stays claimed.
func (s *Service) RevokeBroadcast(ctx context.Context, who *Identity, id int64, note string) (int64, error) {
	if !AtLeast(who.Role, "designer") {
		return 0, ErrForbidden
	}
	var pulled int64
	err := db.InTx(ctx, s.Pool, func(tx pgx.Tx) error {
		q := sqlcdb.New(tx)
		if _, err := q.RevokeBroadcast(ctx, sqlcdb.RevokeBroadcastParams{ID: id, RevokedBy: &who.Username}); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return fmt.Errorf("%w: no live letter %d", ErrNothingToDo, id)
			}
			return err
		}
		n, err := q.DeleteUnclaimedBroadcastMail(ctx, pgInt8(id))
		pulled = n
		return err
	})
	if err != nil {
		return 0, err
	}
	s.Audit(ctx, who, "mail.revoke", fmt.Sprint(id), nil, map[string]any{"unclaimed_pulled": pulled}, note)
	return pulled, nil
}
