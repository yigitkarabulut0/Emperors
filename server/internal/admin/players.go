package admin

import (
	"context"
	"fmt"

	"github.com/google/uuid"

	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
)

// PlayerRow is a search result.
type PlayerRow struct {
	ID       string `json:"id"`
	Username string `json:"username"`
	Name     string `json:"name"`
	Level    int    `json:"level"`
	Gold     string `json:"gold"`
	Diamonds int64  `json:"diamonds"`
	State    string `json:"state"`
	IsBot    bool   `json:"is_bot"`
	LastSeen string `json:"last_seen"`
}

func (s *Service) SearchPlayers(ctx context.Context, term string) ([]PlayerRow, error) {
	rows, err := sqlcdb.New(s.Pool).SearchPlayers(ctx, "%"+term+"%")
	if err != nil {
		return nil, err
	}
	out := make([]PlayerRow, 0, len(rows))
	for _, r := range rows {
		out = append(out, PlayerRow{
			ID: r.ID.String(), Username: r.Username, Name: r.DisplayName,
			Level: int(r.Level), Gold: fmt.Sprint(r.Gold), Diamonds: r.Diamonds,
			State: r.State, IsBot: r.IsBot,
			LastSeen: r.LastSeenAt.UTC().Format("2006-01-02 15:04"),
		})
	}
	return out, nil
}

// SetState bans, unbans or mutes a player.
func (s *Service) SetState(ctx context.Context, who *Identity, playerID uuid.UUID, state, note string) (*PlayerRow, error) {
	if !AtLeast(who.Role, "moderator") {
		return nil, ErrForbidden
	}
	switch state {
	case "active", "banned":
	default:
		return nil, fmt.Errorf("unknown state %q", state)
	}

	q := sqlcdb.New(s.Pool)
	before, err := q.GetPlayerByID(ctx, playerID)
	if err != nil {
		return nil, ErrNotFound
	}
	after, err := q.AdminSetPlayerState(ctx, sqlcdb.AdminSetPlayerStateParams{ID: playerID, State: state})
	if err != nil {
		return nil, err
	}
	s.Audit(ctx, who, "player.state", playerID.String(),
		map[string]any{"state": before.State}, map[string]any{"state": after.State}, note)

	return &PlayerRow{
		ID: after.ID.String(), Username: after.Username, Name: after.DisplayName,
		Level: int(after.Level), Gold: fmt.Sprint(after.Gold), Diamonds: after.Diamonds,
		State: after.State, IsBot: after.IsBot,
		LastSeen: after.LastSeenAt.UTC().Format("2006-01-02 15:04"),
	}, nil
}

// AdjustCurrency grants or removes gold and diamonds.
//
// Every adjustment writes a ledger row as well as an audit entry, so the economy
// dashboard stays honest: a grant that did not appear in the ledger would show up
// as gold that materialised from nowhere.
func (s *Service) AdjustCurrency(ctx context.Context, who *Identity, playerID uuid.UUID, gold, diamonds int64, note string) (*PlayerRow, error) {
	if !AtLeast(who.Role, "moderator") {
		return nil, ErrForbidden
	}
	if gold == 0 && diamonds == 0 {
		return nil, fmt.Errorf("nothing to adjust")
	}

	q := sqlcdb.New(s.Pool)
	before, err := q.GetPlayerByID(ctx, playerID)
	if err != nil {
		return nil, ErrNotFound
	}
	if before.Gold+gold < 0 {
		return nil, fmt.Errorf("that would leave a negative balance")
	}

	after, err := q.AdminAdjustCurrency(ctx, sqlcdb.AdminAdjustCurrencyParams{
		ID: playerID, Gold: gold, Diamonds: diamonds,
	})
	if err != nil {
		return nil, err
	}
	if gold != 0 {
		if err := q.RecordGold(ctx, sqlcdb.RecordGoldParams{
			PlayerID: playerID, Delta: gold, BalanceAfter: after.Gold,
			Reason: "admin_grant", RefID: &who.Username,
		}); err != nil {
			return nil, err
		}
	}
	s.Audit(ctx, who, "player.currency", playerID.String(),
		map[string]any{"gold": before.Gold, "diamonds": before.Diamonds},
		map[string]any{"gold": after.Gold, "diamonds": after.Diamonds}, note)

	return &PlayerRow{
		ID: after.ID.String(), Username: after.Username, Name: after.DisplayName,
		Level: int(after.Level), Gold: fmt.Sprint(after.Gold), Diamonds: after.Diamonds,
		State: after.State, IsBot: after.IsBot,
		LastSeen: after.LastSeenAt.UTC().Format("2006-01-02 15:04"),
	}, nil
}

// Dashboard is the economy and population overview.
type Dashboard struct {
	Players     int64      `json:"players"`
	Bots        int64      `json:"bots"`
	Active1d    int64      `json:"active_1d"`
	Active7d    int64      `json:"active_7d"`
	New1d       int64      `json:"new_1d"`
	GoldHeld    string     `json:"gold_held"`
	AvgLevel    float64    `json:"avg_level"`
	Battles     int64      `json:"battles"`
	AttackerWin float64    `json:"attacker_win_pct"`
	GoldMoved   string     `json:"gold_moved"`
	AvgRounds   float64    `json:"avg_rounds"`
	Flows       []GoldFlow `json:"flows"`
	Days        int        `json:"days"`
	BalanceVer  int        `json:"balance_version"`
}

// GoldFlow is one source or sink.
type GoldFlow struct {
	Reason    string `json:"reason"`
	Created   string `json:"created"`
	Destroyed string `json:"destroyed"`
	Entries   int64  `json:"entries"`
	Net       string `json:"net"`
}

func (s *Service) Dashboard(ctx context.Context, days int) (*Dashboard, error) {
	if days <= 0 {
		days = 7
	}
	q := sqlcdb.New(s.Pool)

	counts, err := q.PlayerCounts(ctx)
	if err != nil {
		return nil, err
	}
	battles, err := q.BattleStats(ctx, int32(days))
	if err != nil {
		return nil, err
	}
	flows, err := q.GoldFlows(ctx, int32(days))
	if err != nil {
		return nil, err
	}

	d := &Dashboard{
		Players: counts.Players, Bots: counts.Bots,
		Active1d: counts.Active1d, Active7d: counts.Active7d, New1d: counts.New1d,
		GoldHeld: fmt.Sprint(counts.GoldHeld), AvgLevel: counts.AvgLevel,
		Battles: battles.Battles, GoldMoved: fmt.Sprint(battles.GoldMoved),
		AvgRounds: battles.AvgRounds, Days: days,
		BalanceVer: s.Config.Get().Version,
		Flows:      make([]GoldFlow, 0, len(flows)),
	}
	if battles.Battles > 0 {
		d.AttackerWin = float64(battles.AttackerWins) * 100 / float64(battles.Battles)
	}
	for _, f := range flows {
		d.Flows = append(d.Flows, GoldFlow{
			Reason: f.Reason, Created: fmt.Sprint(f.Created), Destroyed: fmt.Sprint(f.Destroyed),
			Entries: f.Entries, Net: fmt.Sprint(f.Created - f.Destroyed),
		})
	}
	return d, nil
}
