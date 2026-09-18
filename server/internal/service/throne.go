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
	"github.com/yigitkarabulut0/emperors/server/internal/game/estates"
	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
)

// EMPEROR OF THE WEEK -- the Throne (pvp.json, throne).
//
// Settled every Monday from the UTC week just closed. The kingdom with at least
// min_members and the most renown GAINED in that week (app.kingdom_week --
// kingdom renown as it stands is cumulative and decays, and would crown the
// same kingdom every week) crowns its king Crowned Emperor for the reign. Every
// member wears the Imperial Court; the emperor wears the imperial frame; both
// lapse with the reign, taken off by the cosmetics_lapse job that was already
// there.
//
// Once in the reign the emperor declares one sixty-minute decree, and the WHOLE
// REALM feels it -- which is what makes a lord with no kingdom care who sits on
// the throne. It rides the TIMED lane like an hourly event, through the same
// addLiveBonus, so no new path into the economy is opened by any of this.

var (
	ErrNotEmperor    = errors.New("only the Crowned Emperor may declare a decree")
	ErrDecreeSpent   = errors.New("this reign's decree has already been declared")
	ErrDecreeUnknown = errors.New("there is no such decree")
	ErrNoThrone      = errors.New("nobody sits the throne")
)

// closeThrone is the period_closes key a settled week is written under.
const closeThrone = "throne"

// Decree is the edict in force, as the boost poll holds it.
type Decree struct {
	UWeek       int64
	KingdomID   uuid.UUID
	KingdomName string
	EmperorID   uuid.UUID
	EmperorName string
	ID          string
	EndsAt      time.Time
}

// ThroneView is THE THRONE.
type ThroneView struct {
	// The reign in force, or nil when nobody sits.
	Reign *ReignView `json:"reign"`
	// When the next crowning falls, from this answer's moment.
	CrownsIn int64 `json:"crowns_in"`
	// This week's race, on the measure the Throne is decided by.
	Race []ThroneRacer `json:"race"`
	// The asker's own kingdom's place in it, 0 for none.
	MyPlace  int   `json:"my_place"`
	MyRenown int64 `json:"my_renown"`

	// Whether the asker may declare, and the choices.
	CanDeclare bool         `json:"can_declare"`
	Decrees    []DecreeView `json:"decrees"`
	// What was declared, if anything, and how long it has left.
	Declared   string `json:"declared,omitempty"`
	DecreeEnds int64  `json:"decree_ends_in,omitempty"`
	// Realm, kingdom or emperor: who a decree reaches. The client says so in
	// words, and never guesses.
	Scope string `json:"scope"`

	Past  []ReignView `json:"past"`
	Rules ThroneRules `json:"rules"`
}

// ReignView is one reign, past or present.
type ReignView struct {
	Week        int64  `json:"week"`
	KingdomID   string `json:"kingdom_id"`
	KingdomName string `json:"kingdom_name"`
	KingdomTag  string `json:"kingdom_tag"`
	EmperorID   string `json:"emperor_id"`
	EmperorName string `json:"emperor_name"`
	Avatar      string `json:"avatar,omitempty"`
	Renown      int64  `json:"renown"`
	Members     int    `json:"members"`
	// Seconds the reign has left; 0 for one that has ended.
	EndsIn int64 `json:"ends_in"`
	Look
}

// ThroneRacer is one kingdom in the week's race.
type ThroneRacer struct {
	Place       int    `json:"place"`
	KingdomID   string `json:"kingdom_id"`
	KingdomName string `json:"kingdom_name"`
	KingdomTag  string `json:"kingdom_tag"`
	Renown      int64  `json:"renown"`
	Members     int    `json:"members"`
	Mine        bool   `json:"mine"`
}

// DecreeView is one edict on offer.
type DecreeView struct {
	ID      string `json:"id"`
	Name    string `json:"name"`
	Blurb   string `json:"blurb"`
	Icon    string `json:"icon"`
	Bucket  string `json:"bucket"`
	BP      int64  `json:"bp"`
	Minutes int    `json:"minutes"`
}

// ThroneRules are the Throne's terms.
type ThroneRules struct {
	MinMembers int    `json:"min_members"`
	ReignDays  int    `json:"reign_days"`
	Measure    string `json:"measure"`
	Scope      string `json:"scope"`
}

// LiveThrone is the snapshot's block: what the banner reads without a request.
type LiveThrone struct {
	KingdomID   string `json:"kingdom_id"`
	KingdomName string `json:"kingdom_name"`
	KingdomTag  string `json:"kingdom_tag"`
	EmperorName string `json:"emperor_name"`
	ReignEndsIn int64  `json:"reign_ends_in"`
	// The edict in force, when there is one.
	Decree *LiveDecree `json:"decree"`
	// When the next crowning falls.
	CrownsIn int64 `json:"crowns_in"`
}

// LiveDecree is a running edict, as the snapshot carries it.
type LiveDecree struct {
	ID    string `json:"id"`
	Name  string `json:"name"`
	Blurb string `json:"blurb"`
	Icon  string `json:"icon"`
	// The bucket and the figure, and what the figure is worth TO THIS LORD once
	// the lane's cap has had its say.
	Bucket      string `json:"bucket"`
	BP          int64  `json:"bp"`
	EffectiveBP int64  `json:"effective_bp"`
	EndsIn      int64  `json:"ends_in"`
	Scope       string `json:"scope"`
}

// decreeReaches is the one place "who feels it" is asked.
func (d Deps) decreeReaches(dec *Decree, p sqlcdb.AppPlayer) bool {
	switch d.Config.PvP.Throne.DecreeScope {
	case gameconfig.ThroneScopeKingdom:
		return p.KingdomID != nil && *p.KingdomID == dec.KingdomID
	case gameconfig.ThroneScopeEmperor:
		return p.ID == dec.EmperorID
	default:
		return true
	}
}

// throneEpoch is the first UTC week a reign may be settled for. A week that
// began before the Throne existed was not played for, so it is never crowned --
// the rule boardsEpoch sets for the boards.
func (d Deps) throneEpoch() int64 {
	t, err := time.Parse("2006-01-02", d.Config.PvP.Throne.Epoch)
	if err != nil {
		return 0
	}
	return deeds.UWeek(t)
}

// nextCrowning is the Monday the next settlement falls on.
func nextCrowning(now time.Time) time.Time {
	return time.Unix((deeds.UWeek(now)+7)*86400, 0).UTC()
}

// GetThrone is THE THRONE.
func (d Deps) GetThrone(ctx context.Context, playerID uuid.UUID) (*ThroneView, error) {
	q := sqlcdb.New(d.Pool)
	me, err := q.GetPlayerByID(ctx, playerID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, fmt.Errorf("load player: %w", err)
	}
	cfg := d.Config.PvP.Throne
	now := d.Now()

	v := &ThroneView{
		CrownsIn: secondsUntil(nextCrowning(now), now),
		Race:     []ThroneRacer{}, Decrees: []DecreeView{}, Past: []ReignView{},
		Scope: cfg.DecreeScope,
		Rules: ThroneRules{
			MinMembers: cfg.MinMembers, ReignDays: cfg.ReignDays,
			Measure: cfg.Measure, Scope: cfg.DecreeScope,
		},
	}
	for _, dc := range cfg.Decrees {
		v.Decrees = append(v.Decrees, DecreeView{
			ID: dc.ID, Name: dc.Name, Blurb: dc.Blurb, Icon: dc.Icon,
			Bucket: dc.Bucket, BP: dc.BP, Minutes: dc.Minutes,
		})
	}

	if row, err := q.CurrentThrone(ctx, now); err == nil {
		r := ReignView{
			Week: row.Uweek, KingdomID: row.KingdomID.String(), KingdomName: row.KingdomName,
			KingdomTag: row.KingdomTag, EmperorID: row.EmperorID.String(),
			EmperorName: row.EmperorName, Avatar: row.EmperorAvatar,
			Renown: row.Reputation / reputationScale, Members: int(row.Members),
			EndsIn: secondsUntil(row.ReignEnds, now),
			Look:   lookOf(d.Config, row.CosFrame, row.CosTitle, row.CosColor, row.CosCrest, row.VipPoints),
		}
		v.Reign = &r
		if row.DecreeID != nil {
			v.Declared = *row.DecreeID
			if row.DecreeEnds != nil {
				v.DecreeEnds = secondsUntil(*row.DecreeEnds, now)
			}
		}
		v.CanDeclare = row.EmperorID == playerID && row.DecreeID == nil
	} else if !errors.Is(err, pgx.ErrNoRows) {
		return nil, fmt.Errorf("throne: %w", err)
	}

	race, err := d.throneRace(ctx, q, deeds.UWeek(now), 10)
	if err != nil {
		return nil, err
	}
	for i := range race {
		race[i].Place = i + 1
		if me.KingdomID != nil && race[i].KingdomID == me.KingdomID.String() {
			race[i].Mine = true
			v.MyPlace, v.MyRenown = i+1, race[i].Renown
		}
	}
	v.Race = race

	if past, err := q.ListThrones(ctx, int32(cfg.PastReignsShown)); err == nil {
		for _, r := range past {
			v.Past = append(v.Past, ReignView{
				Week: r.Uweek, KingdomID: r.KingdomID.String(), KingdomName: r.KingdomName,
				KingdomTag: r.KingdomTag, EmperorID: r.EmperorID.String(),
				EmperorName: r.EmperorName, Renown: r.Reputation / reputationScale,
				Members: int(r.Members), EndsIn: secondsUntil(r.ReignEnds, now),
			})
		}
	}
	return v, nil
}

// throneRace is the week's standings on the measure the balance names.
func (d Deps) throneRace(ctx context.Context, q *sqlcdb.Queries, uweek int64, lim int32) ([]ThroneRacer, error) {
	cfg := d.Config.PvP.Throne
	out := []ThroneRacer{}
	if cfg.Measure == gameconfig.ThroneTotal {
		rows, err := q.ThroneRaceByTotal(ctx, sqlcdb.ThroneRaceByTotalParams{
			MinMembers: int32(cfg.MinMembers), Lim: lim,
		})
		if err != nil {
			return nil, fmt.Errorf("throne race: %w", err)
		}
		for _, r := range rows {
			out = append(out, ThroneRacer{
				KingdomID: r.KingdomID.String(), KingdomName: r.Name, KingdomTag: r.Tag,
				Renown: r.Reputation / reputationScale, Members: int(r.Members),
			})
		}
		return out, nil
	}
	rows, err := q.ThroneRaceByWeekGain(ctx, sqlcdb.ThroneRaceByWeekGainParams{
		Uweek: uweek, MinMembers: int32(cfg.MinMembers), Lim: lim,
	})
	if err != nil {
		return nil, fmt.Errorf("throne race: %w", err)
	}
	for _, r := range rows {
		out = append(out, ThroneRacer{
			KingdomID: r.KingdomID.String(), KingdomName: r.Name, KingdomTag: r.Tag,
			Renown: r.Reputation / reputationScale, Members: int(r.Members),
		})
	}
	return out, nil
}

// DeclareDecree fires the reign's one edict.
//
// NOT sequenced. It writes nothing on the lord's own row, its once-per-reign
// guard is the WHERE on DeclareDecree, and a decree must never move the
// action_seq the client's queued collects are counting on. The client adopts
// the answer the way it adopts a claimed letter.
func (d Deps) DeclareDecree(ctx context.Context, playerID uuid.UUID, decreeID string) (*ThroneView, error) {
	cfg := d.Config.PvP.Throne
	dc := cfg.Decree(decreeID)
	if dc == nil {
		return nil, ErrDecreeUnknown
	}
	now := d.Now()
	q := sqlcdb.New(d.Pool)
	cur, err := q.CurrentThrone(ctx, now)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrNoThrone
		}
		return nil, fmt.Errorf("throne: %w", err)
	}
	if cur.EmperorID != playerID {
		return nil, ErrNotEmperor
	}
	if cur.DecreeID != nil {
		return nil, ErrDecreeSpent
	}
	ends := now.Add(time.Duration(dc.Minutes) * time.Minute)
	if _, err := q.DeclareDecree(ctx, sqlcdb.DeclareDecreeParams{
		Uweek: cur.Uweek, EmperorID: playerID, DecreeID: dc.ID, Now: now, Ends: ends,
	}); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrDecreeSpent
		}
		return nil, fmt.Errorf("declare: %w", err)
	}
	// The realm feels it from this instant, so the poll is asked for a fresh
	// look rather than left to its own clock.
	if d.Boosts != nil {
		_ = d.Boosts.Refresh(ctx)
	}
	return d.GetThrone(ctx, playerID)
}

// settleThrone crowns every closed week that has not been crowned yet.
func settleThrone(ctx context.Context, d Deps, now time.Time) error {
	last := deeds.UWeek(now) - 7
	if last < d.throneEpoch() {
		return nil
	}
	q := sqlcdb.New(d.Pool)
	done, err := q.PeriodClosed(ctx, sqlcdb.PeriodClosedParams{What: closeThrone, Period: last})
	if err != nil {
		return fmt.Errorf("closed: %w", err)
	}
	if done {
		return nil
	}
	n, err := d.crownEmperor(ctx, last, now)
	if err != nil {
		return fmt.Errorf("crown %d: %w", last, err)
	}
	return q.ClosePeriod(ctx, sqlcdb.ClosePeriodParams{
		What: closeThrone, Period: last, Lords: int32(n),
	})
}

// crownEmperor settles one closed UTC week.
//
// Idempotent three times over: the period claim, the primary key on app.throne,
// and an idempotency key on every letter. The emperor is crowned in his own
// transaction and each courtier in theirs, as crownNobility does, so one lord
// whose armory is full cannot stop the rest being crowned.
func (d Deps) crownEmperor(ctx context.Context, uweek int64, now time.Time) (int, error) {
	cfg := d.Config.PvP.Throne
	q := sqlcdb.New(d.Pool)
	race, err := d.throneRace(ctx, q, uweek, 1)
	if err != nil {
		return 0, err
	}
	if len(race) == 0 || race[0].Renown <= 0 {
		// Nobody fought for it. The week is still closed, so it stops being
		// looked at.
		return 0, nil
	}
	win := race[0]
	kingdomID, err := uuid.Parse(win.KingdomID)
	if err != nil {
		return 0, err
	}
	kings, err := q.ListKingdomMembers(ctx, &kingdomID)
	if err != nil {
		return 0, fmt.Errorf("members: %w", err)
	}
	var emperor uuid.UUID
	for _, m := range kings {
		if m.KingdomRole == "king" {
			emperor = m.ID
			break
		}
	}
	if emperor == uuid.Nil {
		return 0, nil
	}
	reignEnds := time.Unix((uweek+14)*86400, 0).UTC()

	row, err := q.CrownEmperor(ctx, sqlcdb.CrownEmperorParams{
		Uweek: uweek, KingdomID: kingdomID, EmperorID: emperor,
		Reputation: win.Renown * reputationScale, Members: int32(win.Members),
		ReignEnds: reignEnds,
	})
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return 0, fmt.Errorf("crown: %w", err)
	}
	if errors.Is(err, pgx.ErrNoRows) {
		return 0, nil // already crowned
	}
	_ = row

	ref := fmt.Sprintf("throne:%d", uweek)
	crowned := 0
	court, err := q.ListCourt(ctx, kingdomID)
	if err != nil {
		return 0, fmt.Errorf("court: %w", err)
	}
	for _, m := range court {
		member := m
		isEmperor := member.ID == emperor
		err := db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
			tq := sqlcdb.New(tx)
			title, body := courtLetter(win.KingdomName, uweek, isEmperor)
			grant := cfg.CourtGrant
			key := ref + ":court"
			if isEmperor {
				grant, key = cfg.EmperorGrant, ref+":emperor"
			}
			sent, err := d.SendMail(ctx, tq, member.ID, MailDraft{
				Kind: MailThrone, Title: title, Body: body, Attachments: grant, IdemKey: key,
			})
			if err != nil || !sent {
				return err
			}
			wear := []string{cfg.CourtTitle}
			if isEmperor {
				wear = []string{cfg.EmperorFrame, cfg.EmperorTitle}
			}
			for _, c := range wear {
				if d.Config.Cosmetic(c) == nil {
					continue
				}
				if err := tq.HoldCosmeticUntil(ctx, sqlcdb.HoldCosmeticUntilParams{
					PlayerID: member.ID, CosmeticID: c, Source: "throne",
					SourceRef: &ref, Until: &reignEnds,
				}); err != nil {
					return fmt.Errorf("hold %s: %w", c, err)
				}
			}
			return nil
		})
		if err != nil {
			return crowned, err
		}
		crowned++
	}
	return crowned, nil
}

// courtLetter is what a crowning says, to the emperor and to his court.
func courtLetter(kingdom string, uweek int64, emperor bool) (string, string) {
	week := time.Unix(uweek*86400, 0).UTC().Format("2 January")
	if emperor {
		return "The Crown names you Emperor",
			fmt.Sprintf("For the week of %s no kingdom in the realm gained more renown than %s. You are crowned Emperor of the Week: wear the imperial frame, and declare one decree that every lord in the realm will feel.", week, kingdom)
	}
	return "Your kingdom wears the crown",
		fmt.Sprintf("For the week of %s no kingdom in the realm gained more renown than %s. Your king is crowned Emperor, and you are of the Imperial Court until the reign ends.", week, kingdom)
}

func derefStr(s *string) string {
	if s == nil {
		return ""
	}
	return *s
}

func derefTime(t *time.Time) time.Time {
	if t == nil {
		return time.Time{}
	}
	return *t
}

// liveThrone is the reign for the snapshot: enough for the Kingdom tab's banner
// and for the Collect band to name a running edict, without a request of its
// own. Nil when nobody sits, which the banner says in as many words.
func (d Deps) liveThrone(ctx context.Context, q *sqlcdb.Queries, p sqlcdb.AppPlayer,
	eff estates.Effects, now time.Time) *LiveThrone {

	row, err := q.CurrentThrone(ctx, now)
	if err != nil {
		return nil
	}
	out := &LiveThrone{
		KingdomID: row.KingdomID.String(), KingdomName: row.KingdomName,
		KingdomTag: row.KingdomTag, EmperorName: row.EmperorName,
		ReignEndsIn: secondsUntil(row.ReignEnds, now),
		CrownsIn:    secondsUntil(nextCrowning(now), now),
	}
	dec := d.Boosts.Decree()
	if dec == nil || !dec.EndsAt.After(now) || dec.UWeek != row.Uweek {
		return out
	}
	dc := d.Config.PvP.Throne.Decree(dec.ID)
	if dc == nil {
		return out
	}
	bp := int64(0)
	if d.decreeReaches(dec, p) {
		bp = liveBonusWorth(d.Config, eff, dc.Bucket, dc.BP)
	}
	out.Decree = &LiveDecree{
		ID: dc.ID, Name: dc.Name, Blurb: dc.Blurb, Icon: dc.Icon,
		Bucket: dc.Bucket, BP: dc.BP, EffectiveBP: bp,
		EndsIn: secondsUntil(dec.EndsAt, now), Scope: d.Config.PvP.Throne.DecreeScope,
	}
	return out
}
