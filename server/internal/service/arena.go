package service

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/yigitkarabulut0/emperors/server/internal/db"
	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
	"github.com/yigitkarabulut0/emperors/server/internal/game"
	"github.com/yigitkarabulut0/emperors/server/internal/game/arena"
	"github.com/yigitkarabulut0/emperors/server/internal/game/combat"
	"github.com/yigitkarabulut0/emperors/server/internal/game/deeds"
	"github.com/yigitkarabulut0/emperors/server/internal/game/economy"
	"github.com/yigitkarabulut0/emperors/server/internal/game/rewards"
	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
	"github.com/yigitkarabulut0/emperors/server/internal/ledger"
)

// THE HONOUR ARENA -- the Attack tab's second sub-tab (pvp.json, arena).
//
// A fight here is a real battle: the same combat.Simulate on the same two
// armies, stored with its replay like any other. And it is NOT a raid. No gold
// moves either way, no energy is spent, no shield is applied and none is
// broken, no revenge token is granted, no cooldown is touched and no kingdom
// renown is earned. What moves is a rating, and what bounds it is five fights a
// day that nothing in the game may buy.
//
// That list is the feature. It is also exactly the sort of list that erodes one
// well-meaning line at a time, so arena_test.go reads this file and fails the
// build if it ever names any of them.
//
// LOCKING ORDER: app.players (LockTwoPlayers, ascending uuid), then app.arena
// (LockArenaRows, ascending player_id). Nothing else is locked here.

var (
	ErrArenaLocked    = errors.New("the Honour Arena opens later")
	ErrNoTickets      = errors.New("you have used today's arena fights")
	ErrNoRefreshes    = errors.New("you have used today's opponent refreshes")
	ErrArenaSelf      = errors.New("you cannot meet yourself in the lists")
	ErrArenaOutOfBand = errors.New("that lord is not in your part of the ladder")
)

// arenaSection is the navigation section that opens the arena.
const arenaSection = "arena"

// arenaBotID is the opponent id that names the hired champion. The client sends
// it back as an empty string; nothing in the database carries it.
const arenaBotID = ""

// arenaRepeatHours is how far back the "not one of your last opponents" rule
// looks. A day: long enough that two alts cannot trade wins on a loop, short
// enough that a small ladder still offers somebody.
const arenaRepeatHours = 24

// ArenaView is the ARENA sub-tab.
type ArenaView struct {
	Unlocked    bool `json:"unlocked"`
	UnlockLevel int  `json:"unlock_level"`

	Season int `json:"season"`
	// The season's clock, from this answer's moment.
	SeasonEndsIn int64 `json:"season_ends_in"`

	Rating int `json:"rating"`
	Peak   int `json:"peak"`
	// The lord's place on the ladder, 0 when they have not fought this season.
	Place  int `json:"place"`
	Wins   int `json:"wins"`
	Losses int `json:"losses"`
	Streak int `json:"streak"`

	League ArenaLeagueView `json:"league"`
	// Where the bar stands: the band's floor, the next band's rating, and the
	// next band's name. All three the server's, because a client that works out
	// its own league threshold is a second implementation of the ladder.
	BarFrom int              `json:"bar_from"`
	BarTo   int              `json:"bar_to"`
	Next    *ArenaLeagueView `json:"next"`

	Tickets      int `json:"tickets"`
	TicketsTotal int `json:"tickets_total"`
	// Tickets held from Honour Hour, already counted in Tickets.
	TicketTokens int `json:"ticket_tokens"`
	Refreshes    int `json:"refreshes"`

	// Whether the day's first win still pays, and what it pays.
	FirstWin      bool     `json:"first_win"`
	FirstWinLines []string `json:"first_win_lines,omitempty"`

	Rivals []ArenaRival    `json:"rivals"`
	Chests []ArenaChest    `json:"chests"`
	Rules  ArenaRulesView  `json:"rules"`
	Recent []ArenaLogEntry `json:"recent"`
}

// ArenaLeagueView is a league as the card draws it.
type ArenaLeagueView struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	Emblem   string `json:"emblem"`
	AtRating int    `json:"at_rating"`
	TopN     int    `json:"top_n,omitempty"`
}

// ArenaRival is one of the lords offered.
type ArenaRival struct {
	PlayerID string `json:"player_id"`
	Name     string `json:"name"`
	Avatar   string `json:"avatar"`
	Level    int64  `json:"level"`
	Might    int64  `json:"might"`
	Rating   int    `json:"rating"`
	League   string `json:"league"`
	// What this fight moves, BOTH ways, worked out by the server running the
	// ladder's own arithmetic twice. A client that computed "+16" from its own
	// formula would be the second implementation of Elo, which is the easiest
	// formula in the game to get subtly wrong.
	RatingGain int `json:"rating_gain"`
	RatingLoss int `json:"rating_loss"`
	// The hired champion, when the band held nobody.
	IsBot bool `json:"is_bot"`
	Look
}

// ArenaChest is one rating milestone.
type ArenaChest struct {
	Index   int      `json:"index"`
	Rating  int      `json:"rating"`
	Reached bool     `json:"reached"`
	Claimed bool     `json:"claimed"`
	Lines   []string `json:"lines"`
}

// ArenaRulesView is the arena's terms, for the sheet behind the (i).
type ArenaRulesView struct {
	TicketsPerDay   int               `json:"tickets_per_day"`
	RefreshesPerDay int               `json:"refreshes_per_day"`
	StartRating     int               `json:"start_rating"`
	FloorRating     int               `json:"floor_rating"`
	KFactor         int               `json:"k_factor"`
	DefenderKBP     int64             `json:"defender_k_bp"`
	ResetBP         int64             `json:"reset_bp"`
	Leagues         []ArenaLeagueView `json:"leagues"`
}

// ArenaLogEntry is one recent fight, told from this lord's side.
type ArenaLogEntry struct {
	BattleID string `json:"battle_id"`
	At       string `json:"at"`
	Won      bool   `json:"won"`
	Name     string `json:"opponent_name"`
	Avatar   string `json:"opponent_avatar"`
}

// ArenaResult is what the client animates and then celebrates.
type ArenaResult struct {
	BattleID string `json:"battle_id"`
	Won      bool   `json:"won"`
	// The rating before and after, and the change, all the server's.
	Rating       int            `json:"rating"`
	RatingBefore int            `json:"rating_before"`
	RatingDelta  int            `json:"rating_delta"`
	League       string         `json:"league"`
	LeagueBefore string         `json:"league_before"`
	Chests       []string       `json:"chest_lines,omitempty"`
	FirstWin     []string       `json:"first_win_lines,omitempty"`
	Replay       *combat.Replay `json:"replay"`
	Snapshot     *Snapshot      `json:"snapshot"`
}

// arenaRules builds the pure package's Rules from the balance.
func (d Deps) arenaRules() arena.Rules {
	a := d.Config.PvP.Arena
	return arena.Rules{
		Start: a.StartRating, Floor: a.FloorRating, Ceiling: a.MaxRating,
		K: a.KFactor, DefenderKBP: a.DefenderKBP, ResetBP: a.ResetBP,
	}
}

// arenaTiers builds the pure package's leagues from the balance.
func (d Deps) arenaTiers() []arena.Tier {
	out := make([]arena.Tier, 0, len(d.Config.PvP.Arena.Leagues))
	for _, l := range d.Config.PvP.Arena.Leagues {
		out = append(out, arena.Tier{
			ID: l.ID, Name: l.Name, Emblem: l.Emblem, Cosmetic: l.Cosmetic,
			AtRating: l.AtRating, TopN: l.TopN,
		})
	}
	return out
}

func leagueView(t arena.Tier) ArenaLeagueView {
	return ArenaLeagueView{ID: t.ID, Name: t.Name, Emblem: t.Emblem, AtRating: t.AtRating, TopN: t.TopN}
}

// arenaFightsToday is how many fights the lord has taken on their own day. A
// count stamped with another day is yesterday's and reads as none -- the shape
// refillsUsedToday and shopRerollsToday already use.
func arenaFightsToday(p sqlcdb.AppPlayer, today time.Time) int {
	if !p.ArenaDay.Valid || !p.ArenaDay.Time.Equal(today) {
		return 0
	}
	return int(p.ArenaFightsUsed)
}

func arenaRefreshesToday(p sqlcdb.AppPlayer, today time.Time) int {
	if !p.ArenaDay.Valid || !p.ArenaDay.Time.Equal(today) {
		return 0
	}
	return int(p.ArenaRefreshUsed)
}

// arenaFirstWinPaid reports whether the day's first win has already paid.
func arenaFirstWinPaid(p sqlcdb.AppPlayer, today time.Time) bool {
	return p.ArenaFirstWinOn.Valid && !p.ArenaFirstWinOn.Time.Before(today)
}

// GetArena is the ARENA sub-tab.
func (d Deps) GetArena(ctx context.Context, playerID uuid.UUID) (*ArenaView, error) {
	q := sqlcdb.New(d.Pool)
	me, err := q.GetPlayerByID(ctx, playerID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, fmt.Errorf("load player: %w", err)
	}
	return d.arenaView(ctx, q, me)
}

// arenaView paints the tab from a player row. A GET never writes: a lord below
// the level, or in a season that has not begun, is told so rather than given a
// row.
func (d Deps) arenaView(ctx context.Context, q *sqlcdb.Queries, me sqlcdb.AppPlayer) (*ArenaView, error) {
	cfg := d.Config.PvP.Arena
	now := d.Now()
	season := d.seasonNow(now)
	at := d.Config.SectionLevel(cfg.Section)

	v := &ArenaView{
		Unlocked: int(me.Level) >= at, UnlockLevel: at,
		Season: season.Number, SeasonEndsIn: secondsUntil(season.End, now),
		Rating: cfg.StartRating, Peak: cfg.StartRating,
		Rivals: []ArenaRival{}, Chests: []ArenaChest{}, Recent: []ArenaLogEntry{},
		Rules: ArenaRulesView{
			TicketsPerDay: cfg.TicketsPerDay, RefreshesPerDay: cfg.RefreshesPerDay,
			StartRating: cfg.StartRating, FloorRating: cfg.FloorRating,
			KFactor: cfg.KFactor, DefenderKBP: cfg.DefenderKBP, ResetBP: cfg.ResetBP,
		},
	}
	for _, t := range d.arenaTiers() {
		v.Rules.Leagues = append(v.Rules.Leagues, leagueView(t))
	}
	if !v.Unlocked || season.Number < 1 {
		return v, nil
	}

	st, err := q.GetArena(ctx, me.ID)
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return nil, fmt.Errorf("arena row: %w", err)
	}
	if err == nil && int(st.Season) == season.Number {
		v.Rating, v.Peak = int(st.Rating), int(st.Peak)
		v.Wins, v.Losses, v.Streak = int(st.Wins), int(st.Losses), int(st.Streak)
	} else if err == nil {
		// A row from a season past: what the half reset will make of it, so the
		// card never shows last season's number for a moment.
		v.Rating = arena.HalfReset(d.arenaRules(), int(st.Rating))
		v.Peak = v.Rating
	}
	if place, err := q.ArenaRank(ctx, sqlcdb.ArenaRankParams{
		Season: int32(season.Number), PlayerID: me.ID,
	}); err == nil {
		v.Place = int(place)
	}

	tiers := d.arenaTiers()
	cur := arena.League(tiers, v.Rating, v.Place)
	v.League = leagueView(cur)
	v.BarFrom = arena.Floor(tiers, v.Rating)
	if nx, at := arena.Next(tiers, v.Rating); nx != nil {
		nv := leagueView(*nx)
		v.Next, v.BarTo = &nv, at
	} else {
		v.BarTo = cfg.MaxRating
	}

	today := localDay(now, me.ResetOffsetMinutes)
	held, _ := tokenCounts(ctx, q, me.ID)
	v.TicketTokens = int(held[arenaTicketToken])
	v.TicketsTotal = cfg.TicketsPerDay + v.TicketTokens
	v.Tickets = maxInt(0, v.TicketsTotal-arenaFightsToday(me, today))
	v.Refreshes = maxInt(0, cfg.RefreshesPerDay-arenaRefreshesToday(me, today))
	v.FirstWin = !arenaFirstWinPaid(me, today)
	if v.FirstWin {
		v.FirstWinLines = d.rewardLines(cfg.FirstWin, int(me.Level))
	}

	// The chests: reached against the PEAK, so a chest earned and then lost to a
	// bad evening is still there to take.
	var mask uint64
	if err == nil && int(st.Season) == season.Number {
		mask = uint64(st.Milestones)
	}
	for i, m := range cfg.Milestones {
		v.Chests = append(v.Chests, ArenaChest{
			Index: i, Rating: m.Rating, Reached: v.Peak >= m.Rating,
			Claimed: mask&(uint64(1)<<uint(i)) != 0,
			Lines:   d.rewardLines(m.Grant, int(me.Level)),
		})
	}

	rivals, err := d.arenaRivals(ctx, q, me, v.Rating, season.Number, today, arenaRefreshesToday(me, today))
	if err != nil {
		return nil, err
	}
	v.Rivals = rivals
	if rows, err := q.ListArenaLog(ctx, sqlcdb.ListArenaLogParams{PlayerID: me.ID, Lim: 5}); err == nil {
		for _, r := range rows {
			v.Recent = append(v.Recent, ArenaLogEntry{
				BattleID: r.ID.String(), At: r.CreatedAt.UTC().Format(time.RFC3339),
				Won:  r.AttackerID == me.ID == r.AttackerWon,
				Name: r.OpponentName, Avatar: r.OpponentAvatar,
			})
		}
	}
	return v, nil
}

// arenaTicketToken is the token Honour Hour gives: one more fight today, held
// until it is spent.
const arenaTicketToken = "arena_ticket"

// arenaRivals draws the lords on offer.
//
// The band is widened until it holds somebody; WHICH of the candidates is shown
// is a pure function of (secret, player, day, refresh), the market's own trick,
// so three refreshes a day need no table and reopening the tab cannot reroll.
func (d Deps) arenaRivals(ctx context.Context, q *sqlcdb.Queries, me sqlcdb.AppPlayer,
	rating, season int, today time.Time, refresh int) ([]ArenaRival, error) {

	cfg := d.Config.PvP.Arena
	tiers := d.arenaTiers()
	rules := d.arenaRules()
	fightAt := int32(d.Config.SectionLevel(fightSection))

	var rows []sqlcdb.ArenaOpponentsRow
	for step := 0; step <= cfg.BandSteps; step++ {
		lo, hi := arena.Band(cfg.BandRating, cfg.BandWiden, step, rating)
		got, err := q.ArenaOpponents(ctx, sqlcdb.ArenaOpponentsParams{
			Season: int32(season), Lo: int32(lo), Hi: int32(hi), Me: me.ID,
			FightAt: fightAt, KingdomID: me.KingdomID, RepeatHours: arenaRepeatHours,
			Rating: int32(rating), Lim: int32(cfg.OpponentsShown * 4),
		})
		if err != nil {
			return nil, fmt.Errorf("arena opponents: %w", err)
		}
		if len(got) > 0 {
			rows = got
			break
		}
	}

	out := make([]ArenaRival, 0, cfg.OpponentsShown)
	if len(rows) > 0 {
		// Deterministic in the day and the refresh: the same three until the
		// lord asks for others.
		rng := game.SeedForString(d.ShopSecret, me.ID.String(),
			uint64(today.Unix()), uint64(refresh), 0xA2E1A)
		perm := rng.Perm(len(rows))
		sort.Ints(perm[:minInt(len(perm), cfg.OpponentsShown)])
		for _, i := range perm[:minInt(len(perm), cfg.OpponentsShown)] {
			r := rows[i]
			mine, err := d.GetArmy(ctx, r.PlayerID)
			if err != nil {
				continue
			}
			win := arena.Fight(rules, rating, int(r.Rating), true)
			lose := arena.Fight(rules, rating, int(r.Rating), false)
			out = append(out, ArenaRival{
				PlayerID: r.PlayerID.String(), Name: r.DisplayName, Avatar: r.Avatar,
				Level: int64(r.Level), Might: mine.Totals.Might, Rating: int(r.Rating),
				League:     arena.League(tiers, int(r.Rating), 0).ID,
				RatingGain: win.DeltaA, RatingLoss: lose.DeltaA,
				Look: lookOf(d.Config, r.CosFrame, r.CosTitle, r.CosColor, r.CosCrest, r.VipPoints),
			})
		}
	}
	if len(out) == 0 {
		out = append(out, d.arenaChampion(ctx, me, rating))
	}
	return out, nil
}

// arenaChampion is the hired champion, offered when the band held nobody.
//
// Built from the asker's own army, as the steward's bandit is, and it holds no
// row of its own: a bot with a rating would have to be kept off every board in
// the game, and every board in the game already excludes bots for a reason.
func (d Deps) arenaChampion(ctx context.Context, me sqlcdb.AppPlayer, rating int) ArenaRival {
	cfg := d.Config.PvP.Arena
	rules := d.arenaRules()
	// The champion moves the ladder less than a lord would.
	rules.K = maxInt(1, int(int64(rules.K)*cfg.Bot.RatingBP/10000))
	var might int64
	if a, err := d.GetArmy(ctx, me.ID); err == nil {
		might = a.Totals.Might * cfg.Bot.MightBP / 10000
	}
	win := arena.Fight(rules, rating, rating, true)
	lose := arena.Fight(rules, rating, rating, false)
	return ArenaRival{
		PlayerID: arenaBotID, Name: cfg.Bot.Name, Avatar: cfg.Bot.Avatar,
		Level: int64(me.Level), Might: might, Rating: rating,
		League:     arena.League(d.arenaTiers(), rating, 0).ID,
		RatingGain: win.DeltaA, RatingLoss: lose.DeltaA, IsBot: true,
	}
}

// RefreshArena spends one of the day's refreshes and draws another list.
func (d Deps) RefreshArena(ctx context.Context, playerID uuid.UUID, wantSeq int64) (*ArenaView, error) {
	cfg := d.Config.PvP.Arena
	var out *ArenaView
	err := db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
		q := sqlcdb.New(tx)
		me, err := q.LockPlayer(ctx, playerID)
		if err != nil {
			return fmt.Errorf("lock player: %w", err)
		}
		if err := checkSeq(me, wantSeq); err != nil {
			return err
		}
		if int(me.Level) < d.Config.SectionLevel(cfg.Section) {
			return ErrArenaLocked
		}
		now := d.Now()
		today := localDay(now, me.ResetOffsetMinutes)
		used := arenaRefreshesToday(me, today)
		if used >= cfg.RefreshesPerDay {
			return ErrNoRefreshes
		}
		after, err := q.SpendArenaRefresh(ctx, sqlcdb.SpendArenaRefreshParams{
			ID: playerID, Day: dateOf(today), Used: int16(used + 1), ActionSeq: wantSeq,
		})
		if err != nil {
			return fmt.Errorf("spend refresh: %w", err)
		}
		// The count the refresh just wrote is what seeds the new list, so the
		// answer shows the lords the next GET will.
		out, err = d.arenaView(ctx, q, after)
		return err
	})
	if err != nil {
		return nil, err
	}
	return out, nil
}

// ArenaFight resolves one fight in the lists.
func (d Deps) ArenaFight(ctx context.Context, playerID, opponentID uuid.UUID, wantSeq int64) (*ArenaResult, error) {
	if playerID == opponentID {
		return nil, ErrArenaSelf
	}
	cfg := d.Config.PvP.Arena
	againstBot := opponentID == uuid.Nil

	// Both armies are read BEFORE the transaction, for the reason Attack states:
	// they are large reads, and holding row locks across them would serialise
	// every fight in the game.
	mine, err := d.GetArmy(ctx, playerID)
	if err != nil {
		return nil, err
	}
	var theirs *ArmyView
	if !againstBot {
		if theirs, err = d.GetArmy(ctx, opponentID); err != nil {
			return nil, err
		}
	}

	var res ArenaResult
	err = db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
		q := sqlcdb.New(tx)
		now := d.Now()
		season := d.seasonNow(now)
		if season.Number < 1 {
			return ErrArenaLocked
		}

		var me, opp sqlcdb.AppPlayer
		if againstBot {
			if me, err = q.LockPlayer(ctx, playerID); err != nil {
				return fmt.Errorf("lock player: %w", err)
			}
		} else {
			locked, err := q.LockTwoPlayers(ctx, []uuid.UUID{playerID, opponentID})
			if err != nil {
				return fmt.Errorf("lock players: %w", err)
			}
			for _, p := range locked {
				if p.ID == playerID {
					me = p
				} else {
					opp = p
				}
			}
			if me.ID == uuid.Nil || opp.ID == uuid.Nil {
				return ErrNotFound
			}
		}
		if err := checkSeq(me, wantSeq); err != nil {
			return err
		}
		at := d.Config.SectionLevel(cfg.Section)
		if int(me.Level) < at {
			return fmt.Errorf("%w: the lists open at level %d", ErrArenaLocked, at)
		}
		if !againstBot {
			if int(opp.Level) < at {
				return ErrArenaLocked
			}
			if me.KingdomID != nil && opp.KingdomID != nil && *me.KingdomID == *opp.KingdomID {
				return ErrSameKingdom
			}
		}

		rules := d.arenaRules()
		mineSt, err := q.UpsertArena(ctx, d.upsertArenaParams(playerID, season.Number))
		if err != nil {
			return fmt.Errorf("arena row: %w", err)
		}
		var oppSt sqlcdb.AppArena
		if !againstBot {
			if oppSt, err = q.UpsertArena(ctx, d.upsertArenaParams(opponentID, season.Number)); err != nil {
				return fmt.Errorf("opponent arena row: %w", err)
			}
			lo, hi := arena.Band(cfg.BandRating, cfg.BandWiden, cfg.BandSteps, int(mineSt.Rating))
			if int(oppSt.Rating) < lo || int(oppSt.Rating) > hi {
				return ErrArenaOutOfBand
			}
		}

		// The day's tickets, counted from the row this fight has already locked
		// and spent in the same statement, so two taps cannot both be the fifth.
		today := localDay(now, me.ResetOffsetMinutes)
		used := arenaFightsToday(me, today)
		held, _ := tokenCounts(ctx, q, me.ID)
		if used >= cfg.TicketsPerDay+int(held[arenaTicketToken]) {
			return ErrNoTickets
		}
		if used >= cfg.TicketsPerDay {
			if _, err := q.SpendToken(ctx, sqlcdb.SpendTokenParams{
				PlayerID: me.ID, Token: arenaTicketToken, Qty: 1,
			}); err != nil {
				return ErrNoTickets
			}
		}

		// The fight. The id is minted first because the seed derives from it --
		// the same shape a raid uses, so a replay is reproducible for audit.
		battleID := uuid.New()
		attArmy := myArmy(me, mine)
		var defArmy combat.Army
		var theirMight int64
		if againstBot {
			defArmy, theirMight = d.championArmy(me, mine)
		} else {
			defArmy = theirArmy(opp, theirs)
			theirMight = theirs.Totals.Might
		}
		rng := game.SeedForString(d.ShopSecret, battleID.String(),
			uint64(mine.Totals.Might), uint64(theirMight))
		replay := combat.Simulate(d.Config, rng, rng.Uint64(), attArmy, defArmy)
		replay.AttackerMight = mine.Totals.Might
		replay.DefenderMight = theirMight
		won := replay.Winner == combat.SideAttacker

		fightRules := rules
		before := int(mineSt.Rating)
		oppRating := int(oppSt.Rating)
		if againstBot {
			fightRules.K = maxInt(1, int(int64(rules.K)*cfg.Bot.RatingBP/10000))
			// The champion is hired at the lord's own rating. It has no row, so
			// oppSt is the zero value, and reading a rating of 0 out of it made
			// every champion an overwhelming favourite: the card promised +8
			// and the fight paid +1. This is the one number that has to agree
			// with arenaChampion's, and it is why both read it from here.
			oppRating = before
		}
		mv := arena.Fight(fightRules, before, oppRating, won)
		if againstBot {
			mv.Defender, mv.DeltaD = 0, 0
		}

		tiers := d.arenaTiers()
		res = ArenaResult{
			BattleID: battleID.String(), Won: won,
			Rating: mv.Attacker, RatingBefore: before, RatingDelta: mv.DeltaA,
			LeagueBefore: arena.League(tiers, before, 0).ID,
			League:       arena.League(tiers, mv.Attacker, 0).ID,
			Replay:       replay,
		}

		after, err := q.SpendArenaTicket(ctx, sqlcdb.SpendArenaTicketParams{
			ID: playerID, Day: dateOf(today), Used: int16(used + 1), ActionSeq: wantSeq,
		})
		if err != nil {
			return fmt.Errorf("spend ticket: %w", err)
		}

		streak := int32(1)
		if !won {
			streak = -1
		}
		if (mineSt.Streak > 0) == won && mineSt.Streak != 0 {
			streak = mineSt.Streak + streak
		}
		newMask := uint64(mineSt.Milestones)
		peak := maxInt(int(mineSt.Peak), mv.Attacker)
		rungs, mask := arena.MilestonesCrossed(peak, d.milestoneRatings(), newMask)
		if _, err := q.ApplyArenaResult(ctx, sqlcdb.ApplyArenaResultParams{
			PlayerID: playerID, Rating: int32(mv.Attacker),
			Won: boolToInt32(won), Lost: boolToInt32(!won),
			Streak: streak, Milestones: int64(mask),
		}); err != nil {
			return fmt.Errorf("apply arena: %w", err)
		}
		if !againstBot {
			oppStreak := int32(1)
			if won {
				oppStreak = -1
			}
			if (oppSt.Streak > 0) == !won && oppSt.Streak != 0 {
				oppStreak = oppSt.Streak + oppStreak
			}
			if _, err := q.ApplyArenaResult(ctx, sqlcdb.ApplyArenaResultParams{
				PlayerID: opponentID, Rating: int32(mv.Defender),
				Won: boolToInt32(!won), Lost: boolToInt32(won),
				Streak: oppStreak, Milestones: oppSt.Milestones,
			}); err != nil {
				return fmt.Errorf("apply opponent arena: %w", err)
			}
		}

		// The day's first win, and any rating milestone newly reached.
		if won {
			if paid, err := q.MarkArenaFirstWin(ctx, sqlcdb.MarkArenaFirstWinParams{
				ID: playerID, Day: dateOf(today),
			}); err == nil {
				after = paid
				g, err := d.grantBundle(ctx, q, &after, cfg.FirstWin, GrantSource{
					Diamonds: ledger.Arena, Gold: "arena_first_win",
					Ref: "arena:first:" + today.Format("2006-01-02"), ItemFrom: "arena",
				})
				if err != nil {
					return err
				}
				for _, l := range g.Lines {
					res.FirstWin = append(res.FirstWin, l.Text)
				}
			} else if !errors.Is(err, pgx.ErrNoRows) {
				return fmt.Errorf("first win: %w", err)
			}
		}
		for _, i := range rungs {
			g, err := d.grantBundle(ctx, q, &after, cfg.Milestones[i].Grant, GrantSource{
				Diamonds: ledger.Arena, Gold: "arena_milestone",
				Ref:      fmt.Sprintf("arena:%d:%d", season.Number, cfg.Milestones[i].Rating),
				ItemFrom: "arena",
			})
			if err != nil {
				return err
			}
			for _, l := range g.Lines {
				res.Chests = append(res.Chests, l.Text)
			}
		}

		raw, err := json.Marshal(replay)
		if err != nil {
			return fmt.Errorf("encode replay: %w", err)
		}
		defID := opponentID
		if againstBot {
			// A champion has no row, so the fight is recorded against the lord
			// who hired it: a battle needs two ids, and inventing one would
			// leave a replay link naming nobody.
			defID = playerID
		}
		if _, err := q.InsertBattle(ctx, sqlcdb.InsertBattleParams{
			ID: battleID, AttackerID: playerID, DefenderID: defID,
			Seed: int64(replay.Seed), ConfigVersion: int32(d.Config.Version),
			AttackerWon: won, Rounds: int32(replay.Rounds),
			AttackerMight: mine.Totals.Might, DefenderMight: theirMight,
			GoldStolen: 0, RansomPaid: 0, XpAwarded: 0, EnergySpent: 0,
			Replay: raw, Kind: "arena",
		}); err != nil {
			return fmt.Errorf("insert battle: %w", err)
		}

		dd := deeds.Deeds{deeds.ArenaFights: 1}
		if won {
			dd[deeds.ArenaWins] = 1
		}
		d.recordDeeds(ctx, tx, me, dd)
		return nil
	})
	if err != nil {
		return nil, err
	}
	res.Snapshot, err = d.GetState(ctx, playerID)
	return &res, err
}

// upsertArenaParams is the season roll, done lazily on the way into a fight.
func (d Deps) upsertArenaParams(id uuid.UUID, season int) sqlcdb.UpsertArenaParams {
	cfg := d.Config.PvP.Arena
	return sqlcdb.UpsertArenaParams{
		PlayerID: id, Season: int32(season),
		StartRating: int32(cfg.StartRating), FloorRating: int32(cfg.FloorRating),
		ResetBp: int32(cfg.ResetBP),
	}
}

func (d Deps) milestoneRatings() []int {
	out := make([]int, 0, len(d.Config.PvP.Arena.Milestones))
	for _, m := range d.Config.PvP.Arena.Milestones {
		out = append(out, m.Rating)
	}
	return out
}

// championArmy is the hired champion's roster: the lord's own, scaled, so the
// fight is recognisably a fight and never a wall.
func (d Deps) championArmy(me sqlcdb.AppPlayer, mine *ArmyView) (combat.Army, int64) {
	cfg := d.Config.PvP.Arena.Bot
	// The champion is a MIRROR of the lord's own army, and a mirror of who is
	// standing in the yard: sending soldiers out must not leave a lord fighting
	// a copy of an army they no longer have.
	a := myArmy(me, mine)
	a.PlayerID = ""
	a.Name = cfg.Name
	a.Avatar = cfg.Avatar
	for i := range a.Units {
		u := &a.Units[i]
		u.Attack = maxI64(1, u.Attack*cfg.MightBP/10000)
		u.Defense = u.Defense * cfg.MightBP / 10000
		u.HP = maxI64(1, u.HP*cfg.MightBP/10000)
	}
	return a, mine.Totals.Might * cfg.MightBP / 10000
}

// rewardLines is what a bundle reads as, for a card that shows what a chest
// holds before it is opened. Resolved at the lord's own level, so a wage reads
// as the gold it will actually pay them.
func (d Deps) rewardLines(b gameconfig.RewardBundle, level int) []string {
	out := []string{}
	res := rewards.Resolve(d.Config, b, level, economy.Bonuses{})
	for _, l := range rewards.Lines(d.Config, b, res) {
		out = append(out, l.Text)
	}
	return out
}

func boolToInt32(b bool) int32 {
	if b {
		return 1
	}
	return 0
}

func maxInt(a, b int) int {
	if a > b {
		return a
	}
	return b
}

func minInt(a, b int) int {
	if a < b {
		return a
	}
	return b
}

func maxI64(a, b int64) int64 {
	if a > b {
		return a
	}
	return b
}

// resetArenaSeason halves every rating toward the start when a season turns.
//
// Claimed in admin.period_closes like every other settlement, so it runs once
// however many instances tick. A lord who fights before it runs is rolled on
// the way in by UpsertArena, and this is then a no-op for them.
func resetArenaSeason(ctx context.Context, d Deps, now time.Time) error {
	season := d.seasonNow(now)
	if season.Number < 2 {
		return nil
	}
	q := sqlcdb.New(d.Pool)
	done, err := q.PeriodClosed(ctx, sqlcdb.PeriodClosedParams{
		What: closeArenaReset, Period: int64(season.Number),
	})
	if err != nil {
		return fmt.Errorf("closed: %w", err)
	}
	if done {
		return nil
	}
	cfg := d.Config.PvP.Arena
	n, err := q.HalfResetArena(ctx, sqlcdb.HalfResetArenaParams{
		Season: int32(season.Number), StartRating: int32(cfg.StartRating),
		FloorRating: int32(cfg.FloorRating), ResetBp: int32(cfg.ResetBP),
	})
	if err != nil {
		return fmt.Errorf("half reset: %w", err)
	}
	return q.ClosePeriod(ctx, sqlcdb.ClosePeriodParams{
		What: closeArenaReset, Period: int64(season.Number), Lords: int32(n),
	})
}

// closeArenaReset is the period_closes key the half reset is claimed under.
const closeArenaReset = "arena_reset"
