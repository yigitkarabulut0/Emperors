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
	"github.com/yigitkarabulut0/emperors/server/internal/game"
	"github.com/yigitkarabulut0/emperors/server/internal/game/boss"
	"github.com/yigitkarabulut0/emperors/server/internal/game/combat"
	"github.com/yigitkarabulut0/emperors/server/internal/game/deeds"
	"github.com/yigitkarabulut0/emperors/server/internal/game/economy"
	"github.com/yigitkarabulut0/emperors/server/internal/game/rewards"
	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
)

// KRALLIK BOSS BASKINI -- the Kingdom tab's BOSS section (boss.json, Wave 8).
//
// One beast stands against one kingdom for forty-eight hours. Every member may
// strike it six times, each blow costing the energy a raid costs, and a blow is
// an ORDINARY fight cut to eight rounds: what the lord did to the beast in them
// is their damage. So a stronger army digs deeper, a lord who falls early digs
// less, and the client animates the same replay it animates for a raid.
//
// The wall is the KINGDOM'S own Might -- every member's, times the blows each of
// them has, times a calibrated share -- so the beast is the same siege for five
// lords and for twenty: what changes is how many swords are raised at it, not
// whether it can be broken at all. internal/game/boss/calibration_test.go fights
// whole cycles of reference lords and holds the kill rate to the design's
// 65-80%.
//
// Nothing is paid at the moment of the blow. The chests go out by letter when
// the cycle closes (the boss_settle job), because what a lord earned depends on
// what the KINGDOM did -- whether it fell, and what an equal share of the damage
// turned out to be -- and neither is known while the beast still stands.
//
// LOCKING ORDER: app.players (LockPlayer), then app.kingdom_bosses
// (LockKingdomBoss). One beast per kingdom means blows at one beast queue
// behind each other, which is exactly what makes the damage list add up: two
// lords who both read "a thousand left" and both deal eight hundred must not
// both be credited with eight hundred.

var (
	ErrBossLocked = errors.New("the kingdom's beast comes later")
	ErrNoBoss     = errors.New("no beast stands against your kingdom")
	ErrBossDown   = errors.New("the beast is already down")
	ErrBossOver   = errors.New("this beast's days are over")
	ErrNoBlows    = errors.New("you have struck the beast as often as you may")
)

// bossListShown is how many of the damage list the screen is sent.
const bossListShown = 25

// BossView is the BOSS section.
type BossView struct {
	Unlocked    bool `json:"unlocked"`
	UnlockLevel int  `json:"unlock_level"`
	// A beast is a KINGDOM'S. A lord with none is told so in as many words
	// rather than shown an empty room.
	HasKingdom bool `json:"has_kingdom"`

	// The beast standing, or the last one that stood. Nil for a kingdom that
	// has never seen one.
	Beast *BeastView `json:"beast"`
	// Whether Beast is the one standing now. False means it is the last one,
	// kept on the screen so a lord who looks the morning after is told what
	// happened rather than shown nothing.
	Standing bool `json:"standing"`
	// When the next beast rises, from this answer's moment. Zero while one
	// stands.
	RisesIn int64 `json:"rises_in"`

	// This lord's own part in it.
	Mine BossMine `json:"mine"`

	// Who has hurt it most, biggest first.
	Damage []BossDamageRow `json:"damage"`
	// What the first three on that list take, and what the first is called.
	TopDiamonds []int64 `json:"top_diamonds"`
	TopTitle    string  `json:"top_title,omitempty"`

	Chests []BossChestView `json:"chests"`
	Rules  BossRules       `json:"rules"`
}

// BeastView is one beast, standing or fallen.
type BeastView struct {
	ID    string `json:"id"`
	Name  string `json:"name"`
	Blurb string `json:"blurb"`
	Art   string `json:"art"`
	// How many times this kingdom has put one down before this one, plus one.
	Level int `json:"level"`
	// The wall, what is left of it, and the fraction for the bar -- all three
	// the server's, because a bar drawn from a figure the client divided is a
	// bar that disagrees with the number beside it.
	HPMax    int64 `json:"hp_max"`
	HPLeft   int64 `json:"hp_left"`
	HPLeftBP int64 `json:"hp_left_bp"`
	// What it is worth on the scale a lord is measured on, for the card to say
	// whether the kingdom is out of its depth.
	Might int64 `json:"might"`

	// The muster the wall was cut from.
	KingdomMight int64 `json:"kingdom_might"`
	Members      int   `json:"members"`

	// Seconds left of the window; zero once it has shut.
	EndsIn int64 `json:"ends_in"`
	// Whether it fell, who struck last, and how long the kingdom took.
	Killed     bool   `json:"killed"`
	KilledBy   string `json:"killed_by,omitempty"`
	KilledIn   int64  `json:"killed_in,omitempty"`
	Fighters   int    `json:"fighters"`
	DamageDone int64  `json:"damage_done"`
}

// BossMine is what this lord has done and may still do.
type BossMine struct {
	Hits      int   `json:"hits"`
	HitsLeft  int   `json:"hits_left"`
	HitsTotal int   `json:"hits_total"`
	Damage    int64 `json:"damage"`
	// Their place on the damage list, 0 when they have not struck.
	Place int `json:"place"`
	// What one blow costs this lord, and whether they can pay it.
	Energy    int64 `json:"energy"`
	CanStrike bool  `json:"can_strike"`
	// The damage that would count as valour, as things stand: a share of an
	// EQUAL share of what the kingdom has managed, so it moves as more lords
	// turn up. The server works it out; the client prints it.
	ValourNeed int64 `json:"valour_need"`
}

// BossDamageRow is one lord on the damage list.
type BossDamageRow struct {
	Place    int    `json:"place"`
	PlayerID string `json:"player_id"`
	Name     string `json:"name"`
	Avatar   string `json:"avatar"`
	Level    int64  `json:"level"`
	Hits     int    `json:"hits"`
	Damage   int64  `json:"damage"`
	// The share of the whole wall this lord took down, in basis points.
	ShareBP int64 `json:"share_bp"`
	Mine    bool  `json:"mine"`
	// The diamonds this place takes when the cycle closes, when it takes any.
	Diamonds int64 `json:"diamonds,omitempty"`
	Look
}

// BossChestView is one of the three under the beast.
type BossChestView struct {
	ID    string   `json:"id"`
	Name  string   `json:"name"`
	Need  string   `json:"need"`
	Lines []string `json:"lines"`
	// Whether this lord has earned it as things stand. The kill chest is only
	// ever earned once the beast is down.
	Earned bool `json:"earned"`
}

// BossRules are the raid's terms, for the sheet behind the (i).
type BossRules struct {
	CycleHours    int   `json:"cycle_hours"`
	HitsPerMember int   `json:"hits_per_member"`
	RoundsPerHit  int   `json:"rounds_per_hit"`
	ValourShareBP int64 `json:"valour_share_bp"`
}

// BossHitResult is one blow, for the client to animate and then celebrate.
type BossHitResult struct {
	// What the blow took out of it, and what the beast has left after it.
	Damage   int64 `json:"damage"`
	HPLeft   int64 `json:"hp_left"`
	HPLeftBP int64 `json:"hp_left_bp"`
	// Whether THIS blow put it down.
	Killed bool `json:"killed"`
	// What the lord has done and has left, after this blow.
	MyDamage int64          `json:"my_damage"`
	HitsLeft int            `json:"hits_left"`
	Replay   *combat.Replay `json:"replay"`
	Snapshot *Snapshot      `json:"snapshot"`
}

// GetBoss paints the BOSS section.
func (d Deps) GetBoss(ctx context.Context, playerID uuid.UUID) (*BossView, error) {
	q := sqlcdb.New(d.Pool)
	p, err := q.GetPlayerByID(ctx, playerID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, fmt.Errorf("boss: %w", err)
	}
	cfg := d.Config.Boss
	at := d.Config.SectionLevel(cfg.Section)
	now := d.Now()

	v := &BossView{
		Unlocked: d.Config.HasSection(cfg.Section) && int(p.Level) >= at, UnlockLevel: at,
		HasKingdom: p.KingdomID != nil,
		Damage:     []BossDamageRow{}, Chests: []BossChestView{},
		TopDiamonds: cfg.TopDiamonds,
		Rules: BossRules{
			CycleHours: cfg.CycleHours, HitsPerMember: cfg.HitsPerMember,
			RoundsPerHit: cfg.RoundsPerHit, ValourShareBP: cfg.ValourShareBP,
		},
		Mine: BossMine{HitsTotal: cfg.HitsPerMember, Energy: boss.EnergyCost(d.Config, int64(p.Level))},
	}
	if c := d.Config.Cosmetic(cfg.TopTitle); c != nil {
		v.TopTitle = c.Text
	}
	if !v.HasKingdom {
		// The three chests still show what they hold: a lord deciding whether a
		// kingdom is worth joining should be able to see what one is for.
		for i := range cfg.Chests {
			v.Chests = append(v.Chests, d.bossChestView(&cfg.Chests[i], int(p.Level), boss.Earned{}))
		}
		return v, nil
	}

	row, standing, err := d.bossCycle(ctx, q, *p.KingdomID)
	if err != nil {
		return nil, err
	}
	if row == nil {
		for i := range cfg.Chests {
			v.Chests = append(v.Chests, d.bossChestView(&cfg.Chests[i], int(p.Level), boss.Earned{}))
		}
		return v, nil
	}
	v.Standing = standing
	if !standing {
		v.RisesIn = secondsUntil(row.EndsAt, now)
	}

	counts, err := q.CountBossFighters(ctx, row.ID)
	if err != nil {
		return nil, fmt.Errorf("boss fighters: %w", err)
	}
	// What the kingdom has done is read off the wall, not added up from the
	// rows the screen shows: the list is drawn with a LIMIT.
	done := row.HpMax - row.HpLeft
	avg := avgMight(row.KingdomMight, int(row.Members))
	b := cfg.Boss(row.BossID)

	beast := &BeastView{
		ID: row.BossID, Level: int(row.Level),
		HPMax: row.HpMax, HPLeft: row.HpLeft,
		HPLeftBP:     row.HpLeft * 10000 / maxI64(row.HpMax, 1),
		Might:        boss.Might(d.Config, b, avg, row.HpLeft, int64(row.Level)),
		KingdomMight: row.KingdomMight, Members: int(row.Members),
		EndsIn:     secondsUntil(row.EndsAt, now),
		Killed:     row.KilledAt != nil,
		Fighters:   int(counts.Fighters),
		DamageDone: done,
	}
	if b != nil {
		beast.Name, beast.Blurb, beast.Art = b.Name, b.Blurb, b.Art
	}
	if row.KilledAt != nil {
		beast.KilledIn = int64(row.KilledAt.Sub(row.StartedAt).Seconds())
	}
	v.Beast = beast

	list, err := q.ListBossDamage(ctx, sqlcdb.ListBossDamageParams{CycleID: row.ID, Lim: bossListShown})
	if err != nil {
		return nil, fmt.Errorf("boss damage: %w", err)
	}
	for i, r := range list {
		if row.KilledBy != nil && *row.KilledBy == r.PlayerID {
			beast.KilledBy = r.DisplayName
		}
		dr := BossDamageRow{
			Place: i + 1, PlayerID: r.PlayerID.String(), Name: r.DisplayName, Avatar: r.Avatar,
			Level: int64(r.Level), Hits: int(r.Hits), Damage: r.Damage,
			ShareBP: r.Damage * 10000 / maxI64(row.HpMax, 1),
			Mine:    r.PlayerID == playerID,
			Look:    lookOf(d.Config, r.CosFrame, r.CosTitle, r.CosColor, r.CosCrest, r.VipPoints),
		}
		if i < len(cfg.TopDiamonds) {
			dr.Diamonds = cfg.TopDiamonds[i]
		}
		if dr.Mine {
			v.Mine.Place = dr.Place
		}
		v.Damage = append(v.Damage, dr)
	}
	// The one who struck last may be further down the list than it is long.
	if row.KilledBy != nil && beast.KilledBy == "" {
		if killer, err := q.GetPlayerByID(ctx, *row.KilledBy); err == nil {
			beast.KilledBy = killer.DisplayName
		}
	}

	mine, err := q.GetBossHit(ctx, sqlcdb.GetBossHitParams{CycleID: row.ID, PlayerID: playerID})
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return nil, fmt.Errorf("boss hits: %w", err)
	}
	v.Mine.Hits, v.Mine.Damage = int(mine.Hits), mine.Damage
	v.Mine.HitsLeft = cfg.HitsPerMember - v.Mine.Hits
	if v.Mine.HitsLeft < 0 {
		v.Mine.HitsLeft = 0
	}
	v.Mine.ValourNeed = boss.Valour(d.Config, done, int(counts.Fighters))
	v.Mine.CanStrike = v.Unlocked && standing && row.HpLeft > 0 && v.Mine.HitsLeft > 0

	earned := boss.Earns(d.Config, mine.Damage, done, int(counts.Fighters), row.KilledAt != nil)
	for i := range cfg.Chests {
		v.Chests = append(v.Chests, d.bossChestView(&cfg.Chests[i], int(p.Level), earned))
	}
	return v, nil
}

// bossChestView is one chest as the card draws it. The lines are resolved at
// this lord's level AND at this beast's, so what the card promises is what the
// letter will carry.
func (d Deps) bossChestView(c *gameconfig.BossChest, level int, earned boss.Earned) BossChestView {
	return BossChestView{
		ID: c.ID, Name: c.Name, Need: c.Need,
		Lines: d.rewardLines(c.Grant, level), Earned: earned.Has(c.Need),
	}
}

// bossCycle is the beast standing against a kingdom, or the last one that
// stood. The bool says which.
func (d Deps) bossCycle(ctx context.Context, q *sqlcdb.Queries, kingdomID uuid.UUID) (*sqlcdb.AppKingdomBoss, bool, error) {
	row, err := q.GetKingdomBoss(ctx, kingdomID)
	if err == nil {
		return &row, true, nil
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return nil, false, fmt.Errorf("kingdom boss: %w", err)
	}
	last, err := q.LastKingdomBoss(ctx, kingdomID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, false, nil
		}
		return nil, false, fmt.Errorf("last kingdom boss: %w", err)
	}
	return &last, false, nil
}

// avgMight is what one member of the muster is worth: the beast's own numbers
// are shares of it, because what it swings at is one lord at a time.
func avgMight(kingdomMight int64, members int) int64 {
	if members < 1 {
		members = 1
	}
	return kingdomMight / int64(members)
}

// StrikeBoss is one lord's blow at the kingdom's beast.
//
// Sequenced: it spends energy, and the client's queued collects are counting on
// the order.
func (d Deps) StrikeBoss(ctx context.Context, playerID uuid.UUID, wantSeq int64) (*BossHitResult, error) {
	// The army is read outside the transaction, as a raid and a campaign stage
	// read it: assembling it is a handful of queries and none of them need a
	// lock -- and holding the beast's row across them would queue the kingdom
	// behind one lord's inventory.
	mine, err := d.GetArmy(ctx, playerID)
	if err != nil {
		return nil, err
	}
	cfg := d.Config.Boss

	res := &BossHitResult{}
	var fellTo string
	var beastName string
	var kingdomID uuid.UUID
	err = db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
		q := sqlcdb.New(tx)
		p, err := q.LockPlayer(ctx, playerID)
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrNotFound
			}
			return fmt.Errorf("lock player: %w", err)
		}
		if err := checkSeq(p, wantSeq); err != nil {
			return err
		}
		if !d.Config.HasSection(cfg.Section) || int(p.Level) < d.Config.SectionLevel(cfg.Section) {
			return ErrBossLocked
		}
		if p.KingdomID == nil {
			return ErrNotInKingdom
		}
		kingdomID = *p.KingdomID

		standing, err := q.GetKingdomBoss(ctx, kingdomID)
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrNoBoss
			}
			return fmt.Errorf("kingdom boss: %w", err)
		}
		// Locked, and read again through the lock: what the fight is fought
		// against is the health the beast has at this instant, not the health it
		// had when the page was drawn.
		row, err := q.LockKingdomBoss(ctx, standing.ID)
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrNoBoss
			}
			return fmt.Errorf("lock boss: %w", err)
		}
		now := d.Now()
		if row.HpLeft <= 0 || row.KilledAt != nil {
			return ErrBossDown
		}
		if !row.EndsAt.After(now) {
			return ErrBossOver
		}

		hit, err := q.GetBossHit(ctx, sqlcdb.GetBossHitParams{CycleID: row.ID, PlayerID: playerID})
		if err != nil && !errors.Is(err, pgx.ErrNoRows) {
			return fmt.Errorf("boss hits: %w", err)
		}
		if int(hit.Hits) >= cfg.HitsPerMember {
			return ErrNoBlows
		}

		eff, err := d.loadEffects(ctx, q, p)
		if err != nil {
			return err
		}
		cost := boss.EnergyCost(d.Config, int64(p.Level))
		settled, _, _ := settleEnergy(d.Config, p, eff, now)
		spent, ok := economy.Spend(settled, cost)
		if !ok {
			return ErrNotEnoughEnergy
		}

		// The blow. The seed comes from a fresh id, as a raid's does, so the
		// same beast struck twice is two different fights.
		blowID := uuid.New()
		b := cfg.Boss(row.BossID)
		if b == nil {
			return fmt.Errorf("%w: the balance has forgotten %q", ErrNoBoss, row.BossID)
		}
		avg := avgMight(row.KingdomMight, int(row.Members))
		rng := game.SeedForString(d.ShopSecret, blowID.String(),
			uint64(mine.Field.Might), uint64(row.HpLeft))
		replay, dealt := boss.Blow(d.Config, rng, rng.Uint64(), myArmy(p, mine), mine.Field.Might,
			b, avg, row.HpLeft, int64(row.Level))
		res.Replay, res.Damage = replay, dealt
		beastName = b.Name

		after, err := q.SpendEnergySeq(ctx, sqlcdb.SpendEnergySeqParams{
			ID: playerID, EnergyMilli: spent.Milli, EnergyUpdatedAt: spent.UpdatedAt,
			ActionSeq: wantSeq,
		})
		if err != nil {
			return fmt.Errorf("spend energy: %w", err)
		}
		p = after

		wounded, err := q.WoundBoss(ctx, sqlcdb.WoundBossParams{
			Damage: dealt, Now: &now, PlayerID: &playerID, ID: row.ID,
		})
		if err != nil {
			return fmt.Errorf("wound boss: %w", err)
		}
		mineRow, err := q.RecordBossHit(ctx, sqlcdb.RecordBossHitParams{
			CycleID: row.ID, PlayerID: playerID, Damage: dealt, Now: now,
		})
		if err != nil {
			return fmt.Errorf("record blow: %w", err)
		}

		res.HPLeft = wounded.HpLeft
		res.HPLeftBP = wounded.HpLeft * 10000 / maxI64(wounded.HpMax, 1)
		res.Killed = wounded.KilledAt != nil && wounded.KilledBy != nil && *wounded.KilledBy == playerID
		res.MyDamage = mineRow.Damage
		res.HitsLeft = cfg.HitsPerMember - int(mineRow.Hits)
		if res.HitsLeft < 0 {
			res.HitsLeft = 0
		}
		if res.Killed {
			fellTo = p.DisplayName
		}

		dd := deeds.Deeds{deeds.BossHits: 1, deeds.BossDamage: dealt, deeds.Energy: cost}
		if res.Killed {
			dd[deeds.BossKills] = 1
		}
		d.recordDeeds(ctx, tx, p, dd)
		return nil
	})
	if err != nil {
		return nil, err
	}
	// The hall hears it fall. Outside the transaction on purpose: a line the
	// room could not be told must never cost a lord the blow they struck.
	if fellTo != "" {
		if _, err := d.systemLine(ctx, sqlcdb.New(d.Pool), kingdomID, SysBoss,
			fmt.Sprintf("%s struck the last blow. %s is down.", fellTo, beastName),
			map[string]any{"player": fellTo, "boss": beastName}); err != nil && d.Log != nil {
			d.Log.Warn("the hall was not told the beast fell", "err", err)
		}
	}
	snap, err := d.GetState(ctx, playerID)
	res.Snapshot = snap
	return res, err
}

// --- the two jobs -----------------------------------------------------------

// bossRaiseLimit and bossSettleLimit are how many kingdoms one run may see to.
// A tick that found the whole world waiting would rather do a hundred kingdoms
// now and the next hundred in ten minutes than hold one lease for an hour.
const (
	bossRaiseLimit  = 200
	bossSettleLimit = 50
)

// raiseBosses puts a beast in front of every kingdom whose window has come
// round.
//
// Idempotent: app.kingdom_bosses has one row per kingdom while nothing is
// settled (a partial unique index), and ListKingdomsDueBoss offers no kingdom
// whose last window is still open. A kingdom that put its beast down in an hour
// waits out the window all the same.
func raiseBosses(ctx context.Context, d Deps, now time.Time) error {
	cfg := d.Config.Boss
	if len(cfg.Rotation) == 0 || cfg.CycleHours <= 0 {
		return nil
	}
	q := sqlcdb.New(d.Pool)
	due, err := q.ListKingdomsDueBoss(ctx, sqlcdb.ListKingdomsDueBossParams{Now: now, Lim: bossRaiseLimit})
	if err != nil {
		return fmt.Errorf("kingdoms due a beast: %w", err)
	}
	raised := 0
	for _, k := range due {
		if k.Members < 1 || k.Might < 1 {
			continue // an empty kingdom has nobody to fight it
		}
		level := int(k.Kills) + 1
		if cfg.MaxLevel > 0 && level > cfg.MaxLevel {
			level = cfg.MaxLevel
		}
		b := cfg.BossAt(int(k.Cycles))
		if b == nil {
			continue
		}
		hp := boss.HP(d.Config, k.Might, level)
		if hp < 1 {
			continue
		}
		ends := now.Add(time.Duration(cfg.CycleHours) * time.Hour)
		if _, err := q.RaiseBoss(ctx, sqlcdb.RaiseBossParams{
			KingdomID: k.ID, BossID: b.ID, Level: int32(level), HpMax: hp,
			KingdomMight: k.Might, Members: int32(k.Members), Now: now, EndsAt: ends,
			ConfigVersion: int32(d.Config.Version),
		}); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				continue // one rose between the list and the insert
			}
			return fmt.Errorf("raise a beast for %s: %w", k.Name, err)
		}
		raised++
		if _, err := d.systemLine(ctx, q, k.ID, SysBoss,
			fmt.Sprintf("%s stands against the kingdom. Every lord has %d blows, and two days to strike them.",
				b.Name, cfg.HitsPerMember),
			map[string]any{"boss": b.ID, "level": level, "hp": hp}); err != nil && d.Log != nil {
			d.Log.Warn("the hall was not told a beast rose", "kingdom", k.Name, "err", err)
		}
	}
	if raised > 0 && d.Log != nil {
		d.Log.Info("beasts rose", "kingdoms", raised)
	}
	return nil
}

// settleBosses pays out every cycle that is over -- the window shut, or the
// beast down.
//
// Idempotent three times over: the cycle's settled_at, a paid_at on every lord's
// row, and an idempotency key on every letter. Each lord is paid in their own
// transaction, as the throne's court is, so one lord whose letter cannot be
// written never holds up the rest of the kingdom.
func settleBosses(ctx context.Context, d Deps, now time.Time) error {
	cfg := d.Config.Boss
	q := sqlcdb.New(d.Pool)
	due, err := q.ListDueBossCycles(ctx, sqlcdb.ListDueBossCyclesParams{Now: now, Lim: bossSettleLimit})
	if err != nil {
		return fmt.Errorf("cycles due: %w", err)
	}
	for _, cycle := range due {
		if err := d.settleBossCycle(ctx, cycle, now); err != nil {
			return fmt.Errorf("settle %s: %w", cycle.ID, err)
		}
	}
	if len(due) > 0 && d.Log != nil {
		d.Log.Info("beast cycles settled", "cycles", len(due), "hits_per_member", cfg.HitsPerMember)
	}
	return nil
}

// settleBossCycle closes one cycle.
func (d Deps) settleBossCycle(ctx context.Context, cycle sqlcdb.AppKingdomBoss, now time.Time) error {
	cfg := d.Config.Boss
	q := sqlcdb.New(d.Pool)
	counts, err := q.CountBossFighters(ctx, cycle.ID)
	if err != nil {
		return fmt.Errorf("fighters: %w", err)
	}
	// What the kingdom managed, read off the wall: a settle that runs twice must
	// weigh every lord against the same number, and the unpaid rows are fewer
	// the second time.
	done := cycle.HpMax - cycle.HpLeft
	killed := cycle.KilledAt != nil

	// The damage list decides the first three's diamonds, and it is the WHOLE
	// list: a lord paid on the first run must not be re-placed by the second.
	places := map[uuid.UUID]int{}
	if len(cfg.TopDiamonds) > 0 {
		top, err := q.ListBossDamage(ctx, sqlcdb.ListBossDamageParams{
			CycleID: cycle.ID, Lim: int32(len(cfg.TopDiamonds)),
		})
		if err != nil {
			return fmt.Errorf("damage list: %w", err)
		}
		for i, r := range top {
			places[r.PlayerID] = i + 1
		}
	}

	hits, err := q.ListUnpaidBossHits(ctx, cycle.ID)
	if err != nil {
		return fmt.Errorf("unpaid blows: %w", err)
	}
	name := cycle.BossID
	if b := cfg.Boss(cycle.BossID); b != nil {
		name = b.Name
	}
	// The Slayer wears it until the next beast's window shuts, which is when the
	// next Slayer is named.
	until := now.Add(time.Duration(cfg.CycleHours) * time.Hour)
	ref := "boss:" + cycle.ID.String()

	for _, h := range hits {
		hit := h
		earned := boss.Earns(d.Config, hit.Damage, done, int(counts.Fighters), killed)
		var bundle gameconfig.RewardBundle
		var got []string
		for i := range cfg.Chests {
			c := &cfg.Chests[i]
			if !earned.Has(c.Need) {
				continue
			}
			bundle = rewards.Merge(bundle, boss.Chest(d.Config, c, int(cycle.Level)))
			got = append(got, c.Name)
		}
		place := places[hit.PlayerID]
		if place > 0 && place <= len(cfg.TopDiamonds) {
			bundle.Diamonds += cfg.TopDiamonds[place-1]
		}

		err := db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
			tq := sqlcdb.New(tx)
			if _, err := d.SendMail(ctx, tq, hit.PlayerID, MailDraft{
				Kind: MailBoss, Title: bossLetterTitle(name, killed),
				Body:        bossLetterBody(name, killed, hit, done, place, got),
				Attachments: bundle, IdemKey: ref,
			}); err != nil {
				return err
			}
			// The Slayer: the lord who hurt it most, whether or not it fell.
			if place == 1 && cfg.TopTitle != "" && d.Config.Cosmetic(cfg.TopTitle) != nil {
				if err := tq.HoldCosmeticUntil(ctx, sqlcdb.HoldCosmeticUntilParams{
					PlayerID: hit.PlayerID, CosmeticID: cfg.TopTitle, Source: "boss",
					SourceRef: &ref, Until: &until,
				}); err != nil {
					return fmt.Errorf("hold %s: %w", cfg.TopTitle, err)
				}
			}
			return tq.MarkBossHitPaid(ctx, sqlcdb.MarkBossHitPaidParams{
				Now: &now, CycleID: cycle.ID, PlayerID: hit.PlayerID,
			})
		})
		if err != nil {
			return err
		}
	}

	if err := q.SettleBossCycle(ctx, sqlcdb.SettleBossCycleParams{Now: &now, ID: cycle.ID}); err != nil {
		return fmt.Errorf("close the cycle: %w", err)
	}
	line := fmt.Sprintf("%s leaves the kingdom standing. %d lords struck it for %s.",
		name, counts.Fighters, rewards.Group(done))
	if killed {
		line = fmt.Sprintf("%s is dead. %d lords brought it down, and the chests are in the post.",
			name, counts.Fighters)
	}
	if _, err := d.systemLine(ctx, q, cycle.KingdomID, SysBoss, line,
		map[string]any{"boss": cycle.BossID, "killed": killed, "damage": done}); err != nil && d.Log != nil {
		d.Log.Warn("the hall was not told the cycle closed", "err", err)
	}
	return nil
}

// bossLetterTitle and bossLetterBody are what a cycle's chests arrive as.
func bossLetterTitle(name string, killed bool) string {
	if killed {
		return name + " has fallen"
	}
	return name + " walks away"
}

func bossLetterBody(name string, killed bool, hit sqlcdb.AppBossHit, done int64, place int,
	chests []string) string {

	what := fmt.Sprintf("You struck %s %s, for %s of the %s your kingdom did to it.",
		name, times(int(hit.Hits)), rewards.Group(hit.Damage), rewards.Group(done))
	how := " The beast walked away, and what you earned is in this letter."
	if killed {
		how = " The beast is dead, and what you earned is in this letter."
	}
	if place > 0 {
		how = fmt.Sprintf(" You did the %s most damage in the kingdom.%s", ordinal(place), how)
	}
	if len(chests) > 0 {
		how += " " + joinWords(chests) + "."
	}
	return what + how
}

// times says a count the way a letter would.
func times(n int) string {
	switch n {
	case 1:
		return "once"
	case 2:
		return "twice"
	}
	return fmt.Sprintf("%d times", n)
}

// joinWords is a list as a sentence: "A, B and C".
func joinWords(w []string) string {
	switch len(w) {
	case 0:
		return ""
	case 1:
		return w[0]
	}
	out := ""
	for i, s := range w[:len(w)-1] {
		if i > 0 {
			out += ", "
		}
		out += s
	}
	return out + " and " + w[len(w)-1]
}
