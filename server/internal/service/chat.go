package service

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/yigitkarabulut0/emperors/server/internal/db"
	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
	"github.com/yigitkarabulut0/emperors/server/internal/game/social"
	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
	"github.com/yigitkarabulut0/emperors/server/internal/realtime"
)

// THE HALL -- the Kingdom tab's CHAT sub-tab (social.json, chat).
//
// The room is the KINGDOM. A lord with no kingdom has no hall: there is nothing
// to belong to, and a realm-wide room would be a realm-wide moderation problem
// on day one.
//
// Three things stand between a lord and the room, in this order, and the order
// matters. The rules must have been agreed to (App Review 1.2 wants them where
// the talking is). The lord must not be silenced. And the line must pass the
// filter, which either says it, stars it, or refuses it.
//
// What a refusal costs is TIME, never money: three blocked words inside the
// window shut the hall for an hour. A fine would price bad words, and pricing
// them is selling them.
//
// Nothing here moves action_seq. A line said changes no gold, no energy and no
// counter the client is replaying against, so the client's queued taps are not
// waiting on it.

var (
	ErrNoHall       = errors.New("you have no kingdom, and so no hall")
	ErrRulesUnread  = errors.New("the Rules of the Hall have not been agreed to")
	ErrMuted        = errors.New("the hall is shut to you for now")
	ErrSaidTooFast  = errors.New("the hall is still listening to your last line")
	ErrSaidTooMuch  = errors.New("you have said enough for now")
	ErrLineTooLong  = errors.New("that line is too long for the hall")
	ErrLineEmpty    = errors.New("there is nothing to say")
	ErrLineRefused  = errors.New("the hall will not carry those words")
	ErrReportedFast = errors.New("you have just reported something")
	ErrBlockedLimit = errors.New("you are blocking as many lords as the realm allows")
)

// System lines the realm writes into a hall. Each is a thing another lord did
// that the room should see without anybody having to say it.
const (
	SysJoined   = "joined"   // a lord joined the kingdom
	SysLeft     = "left"     // a lord left
	SysDonated  = "donated"  // gold given to the treasury
	SysUpgrade  = "upgrade"  // a Work was raised
	SysRaided   = "raided"   // a lord of the hall raided, or was raided
	SysAid      = "aid"      // a call for help
	SysGoal     = "goal"     // the shared goal was set, or finished
	SysLargesse = "largesse" // the crown opened the treasury: a line with CLAIM
	SysThrone   = "throne"   // the kingdom was crowned
	// Krallik Boss ve Savaslari (Wave 8): a beast rose, was struck down or
	// walked away; a war was drawn, and a war was won or lost.
	SysBoss = "boss"
	SysWar  = "war"
)

// ChatView is the hall as one lord sees it.
type ChatView struct {
	Room        string `json:"room"`
	KingdomName string `json:"kingdom_name"`
	// The room's clock. A client that holds lines up to this has them all.
	Head  int64      `json:"head"`
	Lines []ChatLine `json:"lines"`

	MaxChars int `json:"max_chars"`
	// Seconds until the hall will take another line from this lord: the burst
	// spent, or the window full. 0 is now.
	NextIn int64 `json:"next_in"`
	// Seconds left on a silence. 0 is not silenced.
	MutedFor int64 `json:"muted_for"`
	// The rules, sent only when this lord has not agreed to the current ones --
	// its presence is what opens the page.
	Rules *ChatRules `json:"rules,omitempty"`
	// What this lord has not read, for the tab's dot.
	Unread int64 `json:"unread"`
}

// ChatLine is one line in the hall.
type ChatLine struct {
	ID  string `json:"id"`
	Seq int64  `json:"seq"`
	// "lord" or "system".
	Kind string `json:"kind"`
	// For a system line: what happened (SysJoined and friends).
	SystemKind string `json:"system_kind,omitempty"`

	// The lord who said it. Empty for a system line.
	PlayerID string `json:"player_id,omitempty"`
	Name     string `json:"name,omitempty"`
	Avatar   string `json:"avatar,omitempty"`
	Level    int64  `json:"level,omitempty"`
	Look     Look   `json:"look,omitzero"`
	// king, marshal or member -- the hall draws the crown on the first two.
	Role string `json:"role,omitempty"`

	Body string `json:"body"`
	At   int64  `json:"at"`
	// This lord's own line: drawn on their side of the hall.
	Mine bool `json:"mine"`
	// Hidden lines are only ever sent to the lord who said them, so a lord
	// whose line was taken down is not left wondering where it went.
	Hidden bool `json:"hidden,omitempty"`
	// Whatever a system line needs to draw: the gold given, the Work raised,
	// the letter a CLAIM opens.
	Payload json.RawMessage `json:"payload,omitempty"`
}

// ChatRules is the page a lord agrees to before speaking.
type ChatRules struct {
	Version int      `json:"version"`
	Title   string   `json:"title"`
	Lines   []string `json:"lines"`
	Support string   `json:"support"`
}

// chatRules is the pure core's view of the balance's numbers.
func (d Deps) chatRules() social.ChatRules {
	c := d.Config.Social.Chat
	return social.ChatRules{
		Burst: c.Burst, RefillSeconds: c.RefillSeconds,
		WindowMinutes: c.WindowMinutes, WindowMax: c.WindowMax, MaxChars: c.MaxChars,
	}
}

// TheRules is the current Rules of the Hall, whoever asks and whether or not
// they have agreed to them. GetChat sends them only to a lord who has not
// agreed -- their presence there is what opens the page -- but a lord who HAS
// agreed must still be able to read what they agreed to, which is what the
// settings' own row asks for (App Review 1.2).
func (d Deps) TheRules(_ context.Context) ChatRules {
	c := d.Config.Social.Chat
	return ChatRules{
		Version: c.RulesVersion, Title: c.RulesTitle,
		Lines: c.Rules, Support: c.SupportEmail,
	}
}

// GetChat reads the hall. after is the last line the client already holds: 0
// asks for the newest page, anything else for what has been said since.
func (d Deps) GetChat(ctx context.Context, playerID uuid.UUID, after int64) (*ChatView, error) {
	cfg := d.Config.Social.Chat
	var out ChatView
	err := db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
		q := sqlcdb.New(tx)
		p, err := q.GetPlayerByID(ctx, playerID)
		if err != nil {
			return ErrNotFound
		}
		if p.KingdomID == nil {
			return ErrNoHall
		}
		room := *p.KingdomID
		k, err := q.GetKingdom(ctx, room)
		if err != nil {
			return fmt.Errorf("kingdom: %w", err)
		}
		rows, err := q.ListChat(ctx, sqlcdb.ListChatParams{
			KingdomID: room, AfterSeq: after, Me: &playerID, Lim: int32(cfg.History),
		})
		if err != nil {
			return fmt.Errorf("hall: %w", err)
		}
		head, err := q.ChatHeadSeq(ctx, room)
		if err != nil {
			return fmt.Errorf("hall head: %w", err)
		}
		unread, err := q.ChatUnread(ctx, sqlcdb.ChatUnreadParams{
			KingdomID: room, SeenSeq: p.ChatSeenSeq, Me: &playerID,
		})
		if err != nil {
			return fmt.Errorf("unread: %w", err)
		}
		out = ChatView{
			Room: room.String(), KingdomName: k.Name, Head: head,
			MaxChars: cfg.MaxChars, Unread: unread,
			// An empty hall is an empty LIST, never null: a client that reads
			// the answer into a typed list has nothing to read from a null.
			Lines: []ChatLine{},
		}
		// Oldest first: the hall reads down the page, and the query answers
		// newest first so its LIMIT takes the right end.
		for i := len(rows) - 1; i >= 0; i-- {
			out.Lines = append(out.Lines, chatLine(d.Config, rows[i], playerID))
		}
		now := d.Now()
		if p.ChatMutedUntil != nil && p.ChatMutedUntil.After(now) {
			out.MutedFor = int64(p.ChatMutedUntil.Sub(now).Seconds()) + 1
		}
		if int(p.ChatRulesVersion) < cfg.RulesVersion {
			out.Rules = &ChatRules{
				Version: cfg.RulesVersion, Title: cfg.RulesTitle,
				Lines: cfg.Rules, Support: cfg.SupportEmail,
			}
		}
		said, last, windowStart, err := d.chatWindow(ctx, q, playerID, now)
		if err != nil {
			return err
		}
		if at := social.NextLineAt(d.chatRules(), last, said, windowStart); !at.IsZero() && at.After(now) {
			out.NextIn = int64(at.Sub(now).Seconds()) + 1
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return &out, nil
}

// chatWindow reads what the rate limit needs: how many lines this lord has said
// inside the window, when the last one was, and when the window began.
func (d Deps) chatWindow(ctx context.Context, q *sqlcdb.Queries, playerID uuid.UUID, now time.Time) (int, time.Time, time.Time, error) {
	cfg := d.Config.Social.Chat
	windowStart := now.Add(-time.Duration(cfg.WindowMinutes) * time.Minute)
	said, err := q.CountChatSince(ctx, sqlcdb.CountChatSinceParams{PlayerID: &playerID, Since: windowStart})
	if err != nil {
		return 0, time.Time{}, windowStart, fmt.Errorf("lines said: %w", err)
	}
	last, err := q.LastChatAt(ctx, &playerID)
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return 0, time.Time{}, windowStart, fmt.Errorf("last line: %w", err)
	}
	return int(said), last, windowStart, nil
}

// HallRoom is which room a lord belongs in, and that room's clock right now:
// what the websocket needs to put them somewhere and tell them what they have
// missed. A lord with no kingdom has no room, which is ErrNoHall.
func (d Deps) HallRoom(ctx context.Context, playerID uuid.UUID) (uuid.UUID, int64, error) {
	q := sqlcdb.New(d.Pool)
	p, err := q.GetPlayerByID(ctx, playerID)
	if err != nil {
		return uuid.Nil, 0, ErrNotFound
	}
	if p.KingdomID == nil {
		return uuid.Nil, 0, ErrNoHall
	}
	head, err := q.ChatHeadSeq(ctx, *p.KingdomID)
	if err != nil {
		return uuid.Nil, 0, fmt.Errorf("hall head: %w", err)
	}
	return *p.KingdomID, head, nil
}

// SaidLine is what the sender gets back: their own line as the hall now holds
// it, so a masked word is visible to the lord who wrote it too.
type SaidLine struct {
	Line   ChatLine `json:"line"`
	Masked bool     `json:"masked"`
	// Seconds until the hall will take another.
	NextIn int64 `json:"next_in"`
}

// SendChat says one line in the lord's own hall.
func (d Deps) SendChat(ctx context.Context, playerID uuid.UUID, body string) (*SaidLine, error) {
	cfg := d.Config.Social.Chat
	body = strings.TrimSpace(body)
	// Control characters would let one line draw over another; a run of
	// newlines would let one line take the whole screen.
	body = strings.Map(func(r rune) rune {
		if r == '\n' || r == '\t' {
			return ' '
		}
		if r < 0x20 || r == 0x7f {
			return -1
		}
		return r
	}, body)
	body = strings.Join(strings.Fields(body), " ")

	var out SaidLine
	var room uuid.UUID
	// A refusal that COSTS something -- a strike, and the third one's silence --
	// has to be committed, so it is carried out of the transaction rather than
	// returned from it: returning an error would roll the strike back with the
	// line, and a lord could say the same word all evening.
	var refused error
	err := db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
		q := sqlcdb.New(tx)
		p, err := q.LockPlayer(ctx, playerID)
		if err != nil {
			return ErrNotFound
		}
		if p.KingdomID == nil {
			return ErrNoHall
		}
		room = *p.KingdomID
		now := d.Now()
		if int(p.ChatRulesVersion) < cfg.RulesVersion {
			return ErrRulesUnread
		}
		if p.ChatMutedUntil != nil && p.ChatMutedUntil.After(now) {
			return fmt.Errorf("%w: %d seconds", ErrMuted, int64(p.ChatMutedUntil.Sub(now).Seconds())+1)
		}

		said, last, windowStart, err := d.chatWindow(ctx, q, playerID, now)
		if err != nil {
			return err
		}
		switch social.MaySpeak(d.chatRules(), utf8.RuneCountInString(body), last, said, now) {
		case social.RefusalEmpty:
			return ErrLineEmpty
		case social.RefusalLong:
			return ErrLineTooLong
		case social.RefusalWindow:
			return ErrSaidTooMuch
		case social.RefusalSilence:
			return ErrSaidTooFast
		}

		shown, verdict := social.Check(body)
		if verdict == social.Blocked {
			// A strike, and the hour's silence if it is the third. Both are
			// written here, in the same transaction that refused the line, so a
			// refusal can never be counted twice or lost.
			strikes, err := q.StrikePlayer(ctx, sqlcdb.StrikePlayerParams{
				PlayerID:    playerID,
				WindowStart: now.Add(-time.Duration(cfg.StrikeWindowHours) * time.Hour),
			})
			if err != nil {
				return fmt.Errorf("strike: %w", err)
			}
			if mute, until := social.StrikesThatMute(int(strikes), cfg.StrikesToMute, cfg.MuteMinutes, now); mute {
				if _, err := q.MutePlayer(ctx, sqlcdb.MutePlayerParams{PlayerID: playerID, Until: &until}); err != nil {
					return fmt.Errorf("mute: %w", err)
				}
				if _, err := q.RecordMute(ctx, sqlcdb.RecordMuteParams{
					PlayerID: playerID, Until: until,
					Reason: fmt.Sprintf("%d blocked words inside %dh", strikes, cfg.StrikeWindowHours),
					ByWhom: "auto",
				}); err != nil {
					return fmt.Errorf("record mute: %w", err)
				}
				refused = fmt.Errorf("%w: %d seconds", ErrMuted, int64(until.Sub(now).Seconds())+1)
				return nil
			}
			refused = ErrLineRefused
			return nil
		}

		row, err := q.InsertChat(ctx, sqlcdb.InsertChatParams{
			KingdomID: room, PlayerID: &playerID, Kind: "lord",
			Body: body, Shown: shown,
		})
		if err != nil {
			return fmt.Errorf("say: %w", err)
		}
		// The lord has read their own line by writing it.
		if err := q.MarkChatSeen(ctx, sqlcdb.MarkChatSeenParams{Seq: row.Seq, PlayerID: playerID}); err != nil {
			return fmt.Errorf("seen: %w", err)
		}
		out.Line = chatLine(d.Config, listChatRowOf(row, p), playerID)
		out.Masked = verdict == social.Masked
		if at := social.NextLineAt(d.chatRules(), now, said+1, windowStart); !at.IsZero() && at.After(now) {
			out.NextIn = int64(at.Sub(now).Seconds()) + 1
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	if refused != nil {
		return nil, refused
	}
	// Everyone else in the room hears it. Outside the transaction: the line is
	// already true, and a push is never allowed to fail an action.
	line := out.Line
	line.Mine = false
	d.tell(room, realtime.KindChat, line)
	return &out, nil
}

// SystemLine writes a line the realm says, inside whatever transaction the
// thing that happened is already in -- a lord joining, a Work raised, the
// treasury opened. It is never refused and never rate limited: the realm is not
// a lord.
//
// It takes the queries rather than opening its own transaction, so a line about
// a thing that then failed is rolled back with it.
func (d Deps) systemLine(ctx context.Context, q *sqlcdb.Queries, room uuid.UUID, kind, text string, payload any) (int64, error) {
	if room == uuid.Nil {
		return 0, nil
	}
	var raw []byte
	if payload != nil {
		b, err := json.Marshal(payload)
		if err != nil {
			return 0, fmt.Errorf("system line payload: %w", err)
		}
		raw = b
	}
	row, err := q.InsertChat(ctx, sqlcdb.InsertChatParams{
		KingdomID: room, Kind: "system", SystemKind: &kind,
		Body: text, Shown: text, Payload: raw,
	})
	if err != nil {
		return 0, fmt.Errorf("system line: %w", err)
	}
	return row.Seq, nil
}

// SystemLine writes one line the realm says, in its own transaction, and tells
// the room. For the callers that are not already inside one.
func (d Deps) SystemLine(ctx context.Context, room uuid.UUID, kind, text string, payload any) {
	if room == uuid.Nil {
		return
	}
	var line ChatLine
	err := db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
		q := sqlcdb.New(tx)
		seq, err := d.systemLine(ctx, q, room, kind, text, payload)
		if err != nil {
			return err
		}
		var raw []byte
		if payload != nil {
			raw, _ = json.Marshal(payload)
		}
		line = ChatLine{
			Seq: seq, Kind: "system", SystemKind: kind, Body: text,
			At: d.Now().Unix(), Payload: raw,
		}
		return nil
	})
	if err != nil {
		if d.Log != nil {
			d.Log.Warn("could not write a system line", "kind", kind, "err", err)
		}
		return
	}
	d.tell(room, realtime.KindChat, line)
}

// AcceptChatRules records that a lord has read the Rules of the Hall.
func (d Deps) AcceptChatRules(ctx context.Context, playerID uuid.UUID, version int) (int, error) {
	cfg := d.Config.Social.Chat
	if version != cfg.RulesVersion {
		// Agreeing to a version the realm is not asking about is either an old
		// build or a guess; either way it does not open the hall.
		return 0, fmt.Errorf("%w: the hall's rules are at version %d", ErrRulesUnread, cfg.RulesVersion)
	}
	q := sqlcdb.New(d.Pool)
	got, err := q.AcceptChatRules(ctx, sqlcdb.AcceptChatRulesParams{
		Version: int16(version), PlayerID: playerID,
	})
	if err != nil {
		return 0, fmt.Errorf("agree: %w", err)
	}
	return int(got), nil
}

// MarkChatRead moves this lord's read mark, which is what clears the tab's dot.
func (d Deps) MarkChatRead(ctx context.Context, playerID uuid.UUID, seq int64) error {
	q := sqlcdb.New(d.Pool)
	if err := q.MarkChatSeen(ctx, sqlcdb.MarkChatSeenParams{Seq: seq, PlayerID: playerID}); err != nil {
		return fmt.Errorf("read mark: %w", err)
	}
	return nil
}

// ReportChat is one lord saying a line should not stand. Enough of them and it
// is hidden from the room before any admin is awake; the queue then decides
// whether it stays hidden.
func (d Deps) ReportChat(ctx context.Context, playerID, messageID uuid.UUID, reason string) error {
	cfg := d.Config.Social.Chat
	switch reason {
	case "abuse", "hate", "spam", "private", "other":
	default:
		reason = "other"
	}
	var hidden bool
	var room uuid.UUID
	err := db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
		q := sqlcdb.New(tx)
		now := d.Now()
		last, err := q.LastReportAt(ctx, playerID)
		if err != nil && !errors.Is(err, pgx.ErrNoRows) {
			return fmt.Errorf("last report: %w", err)
		}
		if !last.IsZero() && now.Sub(last) < time.Duration(cfg.ReportCooldownMinutes)*time.Minute {
			return ErrReportedFast
		}
		msg, err := q.GetChatMessage(ctx, messageID)
		if err != nil {
			return ErrNotFound
		}
		if msg.PlayerID != nil && *msg.PlayerID == playerID {
			// Reporting your own line is not a report; it is a delete request,
			// and the hall does not have one.
			return ErrNotFound
		}
		room = msg.KingdomID
		if _, err := q.ReportChat(ctx, sqlcdb.ReportChatParams{
			MessageID: messageID, ReporterID: playerID, Reason: reason,
		}); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				// Already reported by this lord: nothing more to count.
				return nil
			}
			return fmt.Errorf("report: %w", err)
		}
		row, err := q.BumpChatReports(ctx, sqlcdb.BumpChatReportsParams{
			ToHide: int32(cfg.ReportsToHide), ID: messageID,
		})
		if err != nil {
			return fmt.Errorf("count report: %w", err)
		}
		hidden = row.HiddenAt != nil
		return nil
	})
	if err != nil {
		return err
	}
	if hidden {
		d.tell(room, realtime.KindChatHidden, map[string]string{"id": messageID.String()})
	}
	return nil
}

// sweepChat is the retention job: the hall keeps what the balance says and no
// more. A hall that kept everything would be a subpoena target and a slow
// query; one that kept nothing would leave every report unreadable.
func (d Deps) sweepChat(ctx context.Context) (int64, error) {
	days := d.Config.Social.Chat.RetentionDays
	if days <= 0 {
		return 0, nil
	}
	q := sqlcdb.New(d.Pool)
	n, err := q.SweepChat(ctx, d.Now().AddDate(0, 0, -days))
	if err != nil {
		return 0, fmt.Errorf("sweep the hall: %w", err)
	}
	return n, nil
}

// chatLine turns a row into what the hall draws.
func chatLine(cfg *gameconfig.Bundle, r sqlcdb.ListChatRow, me uuid.UUID) ChatLine {
	line := ChatLine{
		ID: r.ID.String(), Seq: r.Seq, Kind: r.Kind, Body: r.Shown,
		At: r.CreatedAt.Unix(), Hidden: r.HiddenAt != nil, Payload: r.Payload,
	}
	if r.SystemKind != nil {
		line.SystemKind = *r.SystemKind
	}
	if r.PlayerID != nil {
		line.PlayerID = r.PlayerID.String()
		line.Mine = *r.PlayerID == me
	}
	if r.DisplayName != nil {
		line.Name = *r.DisplayName
	}
	if r.Avatar != nil {
		line.Avatar = *r.Avatar
	}
	if r.Level.Valid {
		line.Level = int64(r.Level.Int32)
	}
	if r.KingdomRole != nil {
		line.Role = *r.KingdomRole
	}
	var vip int64
	if r.VipPoints.Valid {
		vip = r.VipPoints.Int64
	}
	line.Look = lookOf(cfg, r.CosFrame, r.CosTitle, r.CosColor, r.CosCrest, vip)
	return line
}

// listChatRowOf dresses a freshly inserted row as a list row, so the sender's
// own answer is built by exactly the same code that builds everybody else's.
func listChatRowOf(m sqlcdb.AppChatMessage, p sqlcdb.AppPlayer) sqlcdb.ListChatRow {
	level := int32(p.Level)
	return sqlcdb.ListChatRow{
		ID: m.ID, Seq: m.Seq, KingdomID: m.KingdomID, PlayerID: m.PlayerID,
		Kind: m.Kind, SystemKind: m.SystemKind, Body: m.Body, Shown: m.Shown,
		Payload: m.Payload, CreatedAt: m.CreatedAt, HiddenAt: m.HiddenAt,
		Username: &p.Username, DisplayName: &p.DisplayName,
		Level:  pgtype.Int4{Int32: level, Valid: true},
		Avatar: &p.Avatar, CosFrame: p.CosFrame, CosTitle: p.CosTitle,
		CosColor: p.CosColor, CosCrest: p.CosCrest,
		VipPoints:   pgtype.Int8{Int64: p.VipPoints, Valid: true},
		KingdomRole: &p.KingdomRole,
	}
}
