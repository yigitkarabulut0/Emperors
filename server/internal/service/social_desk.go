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
	"github.com/yigitkarabulut0/emperors/server/internal/realtime"
)

// THE MODERATION DESK (admin/social.go): the halls, what has been reported in
// them, and the crown's two answers -- hide the line, silence the tongue.
//
// The rules live here, beside the game, so the panel and the hall can never
// disagree about what a mute is. What the panel adds is the ROLE (who may) and
// the AUDIT (who did).
//
// The queue is oldest first, because the clock a moderator is judged by starts
// when the line was said and not when somebody got round to it.

// ModQueueView is the desk.
type ModQueueView struct {
	Rows []ModRow `json:"rows"`
	// The other queue: lords reported as lords -- their name, their look, or
	// their play -- where there is no line to point at (app.lord_reports).
	Lords []LordRow `json:"lords"`

	// The hall at a glance: what was said today, what is reported, what is
	// hidden, and how many tongues are silenced right now.
	Said     int64 `json:"said_today"`
	Reported int64 `json:"reported"`
	Hidden   int64 `json:"hidden"`
	Muted    int64 `json:"muted"`
	// The roll, and the day's kindnesses: the two numbers that say whether the
	// social half of the game is being used at all.
	Friendships int64 `json:"friendships"`
	Gifts       int64 `json:"gifts_today"`
	// Lords waiting to be judged, which is the count of the second queue.
	ReportedLords int64 `json:"reported_lords"`

	// What the rules say, so the desk does not need a second copy of them.
	ReportsToHide int `json:"reports_to_hide"`
	MuteMinutes   int `json:"mute_minutes"`
	RetentionDays int `json:"retention_days"`
}

// ModRow is one reported line.
type ModRow struct {
	ID      string `json:"id"`
	Seq     int64  `json:"seq"`
	Room    string `json:"room"`
	Kingdom string `json:"kingdom"`

	PlayerID string `json:"player_id,omitempty"`
	Name     string `json:"name,omitempty"`
	Username string `json:"username,omitempty"`
	Level    int64  `json:"level,omitempty"`
	State    string `json:"state,omitempty"`
	// Seconds left on this lord's silence, 0 if they are not silenced.
	MutedFor int64 `json:"muted_for,omitempty"`

	// What was TYPED, which is what a moderator has to read, and what the hall
	// showed after the filter.
	Body  string `json:"body"`
	Shown string `json:"shown"`

	At       int64  `json:"at"`
	Reports  int    `json:"reports"`
	Reasons  string `json:"reasons"`
	Hidden   bool   `json:"hidden"`
	HiddenBy string `json:"hidden_by,omitempty"`
	// Seconds since the first report: the desk's own clock.
	WaitingFor int64 `json:"waiting_for"`
}

// LordRow is one lord with open reports against them: who they are, how many
// lords have said so and what for. There is no body to read, which is the
// point of this queue -- the judgement is about the lord, so the desk's answer
// is a silence, a rename asked for by mail, or nothing.
type LordRow struct {
	PlayerID string `json:"player_id"`
	Name     string `json:"name,omitempty"`
	Username string `json:"username,omitempty"`
	Avatar   string `json:"avatar,omitempty"`
	Level    int64  `json:"level,omitempty"`
	State    string `json:"state,omitempty"`
	Kingdom  string `json:"kingdom,omitempty"`
	// Seconds left on this lord's silence, 0 if they are not silenced.
	MutedFor int64 `json:"muted_for,omitempty"`

	Reports int    `json:"reports"`
	Reasons string `json:"reasons"`
	At      int64  `json:"at"`
	// Seconds since the first open report against them.
	WaitingFor int64 `json:"waiting_for"`
}

// ModQueue is what the desk shows.
func (d Deps) ModQueue(ctx context.Context, limit int32) (*ModQueueView, error) {
	cfg := d.Config.Social.Chat
	q := sqlcdb.New(d.Pool)
	now := d.Now()
	out := &ModQueueView{
		Rows: []ModRow{}, ReportsToHide: cfg.ReportsToHide,
		MuteMinutes: cfg.MuteMinutes, RetentionDays: cfg.RetentionDays,
	}
	if s, err := q.ChatStats(ctx, now.Add(-24*time.Hour)); err == nil {
		out.Said, out.Reported, out.Hidden = s.Said, s.Reported, s.Hidden
		out.Muted, out.Friendships, out.Gifts = s.Muted, s.Friendships, s.Gifts
	}
	rows, err := q.ListReportedChat(ctx, limit)
	if err != nil {
		return nil, fmt.Errorf("the queue: %w", err)
	}
	for _, r := range rows {
		row := ModRow{
			ID: r.ID.String(), Seq: r.Seq, Room: r.KingdomID.String(),
			Body: r.Body, Shown: r.Shown, At: r.CreatedAt.Unix(),
			Reports: int(r.ReportCount), Hidden: r.HiddenAt != nil,
		}
		if r.KingdomName != nil {
			row.Kingdom = *r.KingdomName
		}
		if r.PlayerID != nil {
			row.PlayerID = r.PlayerID.String()
		}
		if r.DisplayName != nil {
			row.Name = *r.DisplayName
		}
		if r.Username != nil {
			row.Username = *r.Username
		}
		if r.Level.Valid {
			row.Level = int64(r.Level.Int32)
		}
		if r.State != nil {
			row.State = *r.State
		}
		if r.ChatMutedUntil != nil && r.ChatMutedUntil.After(now) {
			row.MutedFor = int64(r.ChatMutedUntil.Sub(now).Seconds())
		}
		if r.HiddenBy != nil {
			row.HiddenBy = *r.HiddenBy
		}
		row.Reasons = string(r.Reasons)
		// sqlc types a min() over a join as an interface: the row is read for
		// what it is rather than declared to be something it is not.
		if at, ok := r.FirstReportAt.(time.Time); ok {
			row.WaitingFor = int64(now.Sub(at).Seconds())
		}
		out.Rows = append(out.Rows, row)
	}
	lords, err := d.ModLords(ctx, limit)
	if err != nil {
		return nil, err
	}
	out.Lords = lords
	if n, err := q.CountReportedLords(ctx); err == nil {
		out.ReportedLords = n
	}
	return out, nil
}

// ModLords is the second queue: every lord with an open report, oldest first.
func (d Deps) ModLords(ctx context.Context, limit int32) ([]LordRow, error) {
	q := sqlcdb.New(d.Pool)
	now := d.Now()
	rows, err := q.ListReportedLords(ctx, limit)
	if err != nil {
		return nil, fmt.Errorf("the lords' queue: %w", err)
	}
	out := make([]LordRow, 0, len(rows))
	for _, r := range rows {
		row := LordRow{
			PlayerID: r.TargetID.String(), Name: r.DisplayName, Username: r.Username,
			Avatar: r.Avatar, Level: int64(r.Level), State: r.State,
			Reports: int(r.Reports), Reasons: string(r.Reasons),
			At: r.LastAt.Unix(), WaitingFor: int64(now.Sub(r.FirstAt).Seconds()),
		}
		if r.KingdomName != nil {
			row.Kingdom = *r.KingdomName
		}
		if r.ChatMutedUntil != nil && r.ChatMutedUntil.After(now) {
			row.MutedFor = int64(r.ChatMutedUntil.Sub(now).Seconds())
		}
		out = append(out, row)
	}
	return out, nil
}

// ClearLordReports answers every open report against a lord, whichever way the
// crown went: a lord judged and left alone must leave the queue too, or the
// desk reads the same name every morning.
func (d Deps) ClearLordReports(ctx context.Context, targetID uuid.UUID, by string) (int64, error) {
	q := sqlcdb.New(d.Pool)
	n, err := q.ResolveLordReports(ctx, sqlcdb.ResolveLordReportsParams{
		TargetID: targetID, By: &by,
	})
	if err != nil {
		return 0, fmt.Errorf("answer the reports: %w", err)
	}
	return n, nil
}

// ModContext is the lines around a reported one, so a moderator reads the room
// and not a sentence on its own.
func (d Deps) ModContext(ctx context.Context, id uuid.UUID, span int64) ([]ChatLine, error) {
	q := sqlcdb.New(d.Pool)
	m, err := q.GetChatMessage(ctx, id)
	if err != nil {
		return nil, ErrNotFound
	}
	if span <= 0 || span > 50 {
		span = 10
	}
	rows, err := q.ChatContext(ctx, sqlcdb.ChatContextParams{
		KingdomID: m.KingdomID, FromSeq: m.Seq - span, ToSeq: m.Seq + span,
	})
	if err != nil {
		return nil, fmt.Errorf("the room: %w", err)
	}
	out := make([]ChatLine, 0, len(rows))
	for _, r := range rows {
		line := ChatLine{
			ID: r.ID.String(), Seq: r.Seq, Kind: r.Kind, Body: r.Body,
			At: r.CreatedAt.Unix(), Hidden: r.HiddenAt != nil,
		}
		if r.SystemKind != nil {
			line.SystemKind = *r.SystemKind
		}
		if r.PlayerID != nil {
			line.PlayerID = r.PlayerID.String()
		}
		if r.DisplayName != nil {
			line.Name = *r.DisplayName
		}
		out = append(out, line)
	}
	return out, nil
}

// HideLine takes a line down, or puts it back, and clears its reports either
// way: the queue is what is waiting to be JUDGED, and a judged line has left
// it whichever way the judgement went.
func (d Deps) HideLine(ctx context.Context, id uuid.UUID, hide bool, by string) error {
	var room uuid.UUID
	err := db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
		q := sqlcdb.New(tx)
		row, err := q.SetChatHidden(ctx, sqlcdb.SetChatHiddenParams{Hide: hide, ByWhom: by, ID: id})
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrNotFound
			}
			return fmt.Errorf("hide: %w", err)
		}
		room = row.KingdomID
		if _, err := q.ResolveChatReports(ctx, id); err != nil {
			return fmt.Errorf("clear reports: %w", err)
		}
		if _, err := q.ClearChatReportCount(ctx, id); err != nil {
			return fmt.Errorf("clear count: %w", err)
		}
		return nil
	})
	if err != nil {
		return err
	}
	if hide {
		d.tell(room, realtime.KindChatHidden, map[string]string{"id": id.String()})
	}
	return nil
}

// MuteLord silences a tongue for a while, by hand. The guard the hall reads is
// the column; the trail the desk shows is the row; both are written here.
func (d Deps) MuteLord(ctx context.Context, playerID uuid.UUID, minutes int, reason, by string) (time.Time, error) {
	if minutes <= 0 {
		minutes = d.Config.Social.Chat.MuteMinutes
	}
	until := d.Now().Add(time.Duration(minutes) * time.Minute)
	err := db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
		q := sqlcdb.New(tx)
		if _, err := q.MutePlayer(ctx, sqlcdb.MutePlayerParams{PlayerID: playerID, Until: &until}); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrNotFound
			}
			return fmt.Errorf("mute: %w", err)
		}
		if _, err := q.RecordMute(ctx, sqlcdb.RecordMuteParams{
			PlayerID: playerID, Until: until, Reason: reason, ByWhom: by,
		}); err != nil {
			return fmt.Errorf("record: %w", err)
		}
		return nil
	})
	return until, err
}

// UnmuteLord lifts a silence and forgets the strikes behind it: an operator who
// lifts a mute means the lord starts again, not that they are one word from the
// next one.
func (d Deps) UnmuteLord(ctx context.Context, playerID uuid.UUID) error {
	q := sqlcdb.New(d.Pool)
	if err := q.UnmutePlayer(ctx, playerID); err != nil {
		return fmt.Errorf("unmute: %w", err)
	}
	return nil
}

// ModMutes is the trail of silences, newest first.
func (d Deps) ModMutes(ctx context.Context, limit int32) ([]ModMute, error) {
	q := sqlcdb.New(d.Pool)
	rows, err := q.ListMutes(ctx, limit)
	if err != nil {
		return nil, fmt.Errorf("mutes: %w", err)
	}
	out := make([]ModMute, 0, len(rows))
	now := d.Now()
	for _, r := range rows {
		out = append(out, ModMute{
			PlayerID: r.PlayerID.String(), Name: r.DisplayName, Username: r.Username,
			Until: r.Until.Unix(), Live: r.Until.After(now),
			Reason: r.Reason, By: r.ByWhom, At: r.CreatedAt.Unix(),
		})
	}
	return out, nil
}

// ModMute is one silence in the trail.
type ModMute struct {
	PlayerID string `json:"player_id"`
	Name     string `json:"name"`
	Username string `json:"username"`
	Until    int64  `json:"until"`
	Live     bool   `json:"live"`
	Reason   string `json:"reason"`
	By       string `json:"by"`
	At       int64  `json:"at"`
}
