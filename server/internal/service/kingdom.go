package service

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/yigitkarabulut0/emperors/server/internal/auth"
	"github.com/yigitkarabulut0/emperors/server/internal/db"
	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
)

var (
	ErrAlreadyInKingdom = errors.New("you already belong to a kingdom")
	ErrNotInKingdom     = errors.New("you are not in a kingdom")
	ErrKingdomFull      = errors.New("the kingdom is full")
	ErrNotInvited       = errors.New("you have not been invited")
	ErrNotPermitted     = errors.New("your rank does not allow that")
	ErrKingdomNameTaken = errors.New("that name or tag is taken")
	ErrDonationCap      = errors.New("you have donated all you can today")
	ErrLastKing         = errors.New("promote another lord before you leave")
	ErrSameKingdom      = errors.New("you cannot raid your own kingdom")
	ErrNotEnoughFavour  = errors.New("not enough favour")
)

// KingdomView is the Kingdom panel.
type KingdomView struct {
	InKingdom  bool            `json:"in_kingdom"`
	Kingdom    *KingdomInfo    `json:"kingdom"`
	Members    []MemberView    `json:"members"`
	Upgrades   []UpgradeView   `json:"upgrades"`
	Me         *MembershipView `json:"me"`
	Invites    []InviteView    `json:"invites"`
	FoundCost  int64           `json:"found_cost"`
	FoundLevel int             `json:"found_level"`
	Top        []KingdomInfo   `json:"leaderboard"`
}

type KingdomInfo struct {
	ID         string `json:"id"`
	Name       string `json:"name"`
	Tag        string `json:"tag"`
	Level      int    `json:"level"`
	XP         int64  `json:"xp"`
	XPToNext   int64  `json:"xp_to_next"`
	Treasury   string `json:"treasury"`
	Reputation int64  `json:"reputation"`
	Members    int    `json:"members"`
	MemberCap  int    `json:"member_cap"`
}

type MemberView struct {
	PlayerID string `json:"player_id"`
	Name     string `json:"name"`
	Level    int    `json:"level"`
	Role     string `json:"role"`
	Donated  string `json:"donated"`
}

type MembershipView struct {
	Role           string `json:"role"`
	Donated        string `json:"donated"`
	Favour         int64  `json:"favour"`
	DailyCap       int64  `json:"daily_cap"`
	DonatedToday   int64  `json:"donated_today"`
	RemainingToday int64  `json:"remaining_today"`
}

type InviteView struct {
	KingdomID string `json:"kingdom_id"`
	Name      string `json:"name"`
	Tag       string `json:"tag"`
	Level     int    `json:"level"`
}

// reputationScale keeps reputation as hundredths internally, so a 2%/day decay
// does not round a small kingdom's score away to nothing on the first night.
const reputationScale = 100

func (d Deps) GetKingdom(ctx context.Context, playerID uuid.UUID) (*KingdomView, error) {
	q := sqlcdb.New(d.Pool)

	p, err := q.GetPlayerByID(ctx, playerID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, fmt.Errorf("load player: %w", err)
	}

	view := &KingdomView{
		FoundCost:  d.Config.Kingdoms.FoundCost,
		FoundLevel: d.Config.Kingdoms.FoundLevel,
		Members:    []MemberView{},
		Upgrades:   []UpgradeView{},
		Invites:    []InviteView{},
		Top:        []KingdomInfo{},
	}

	if top, err := q.TopKingdoms(ctx, 20); err == nil {
		for _, k := range top {
			view.Top = append(view.Top, KingdomInfo{
				ID: k.ID.String(), Name: k.Name, Tag: k.Tag,
				Level: int(k.Level), XP: k.Xp, Treasury: itoa(k.Treasury),
				Reputation: k.Reputation / reputationScale, Members: int(k.Members),
				MemberCap: d.Config.KingdomMemberCap(int(k.Level), 0),
			})
		}
	}

	if p.KingdomID == nil {
		if invites, err := q.ListInvitesForPlayer(ctx, playerID); err == nil {
			for _, i := range invites {
				view.Invites = append(view.Invites, InviteView{
					KingdomID: i.KingdomID.String(), Name: i.Name, Tag: i.Tag, Level: int(i.Level),
				})
			}
		}
		return view, nil
	}

	k, err := q.GetKingdom(ctx, *p.KingdomID)
	if err != nil {
		return nil, fmt.Errorf("load kingdom: %w", err)
	}
	ups, err := q.ListKingdomUpgrades(ctx, k.ID)
	if err != nil {
		return nil, fmt.Errorf("kingdom upgrades: %w", err)
	}
	levels := map[string]int{}
	for _, u := range ups {
		levels[u.UpgradeID] = int(u.Level)
	}

	members, err := q.ListKingdomMembers(ctx, p.KingdomID)
	if err != nil {
		return nil, fmt.Errorf("members: %w", err)
	}

	view.InKingdom = true
	info := d.kingdomInfo(k, len(members), levels[courtUpgradeID])
	view.Kingdom = &info

	for _, m := range members {
		view.Members = append(view.Members, MemberView{
			PlayerID: m.ID.String(), Name: m.DisplayName, Level: int(m.Level),
			Role: m.KingdomRole, Donated: itoa(m.KingdomDonatedTotal),
		})
	}
	for _, u := range d.Config.Kingdoms.Upgrades {
		lv := levels[u.ID]
		cost, ok := u.Cost(lv)
		view.Upgrades = append(view.Upgrades, UpgradeView{
			ID: u.ID, Name: u.Name, Blurb: u.Blurb, Bucket: u.Bucket,
			Level: lv, MaxLevel: u.MaxLevel, PerLevel: u.PerLevel,
			NextCost: cost, Maxed: !ok, Effect: u.PerLevel * int64(lv),
		})
	}

	cap := d.donationCap(int64(p.Level))
	today := int64(0)
	if p.KingdomDay.Valid && sameDay(p.KingdomDay.Time, d.Now()) {
		today = p.KingdomDonatedToday
	}
	view.Me = &MembershipView{
		Role: p.KingdomRole, Donated: itoa(p.KingdomDonatedTotal), Favour: p.KingdomFavour,
		DailyCap: cap, DonatedToday: today, RemainingToday: max64(cap-today, 0),
	}
	return view, nil
}

const courtUpgradeID = "royal_court"

func (d Deps) kingdomInfo(k sqlcdb.AppKingdom, members, courtBonus int) KingdomInfo {
	_, nextXP := d.Config.KingdomLevelFor(k.Xp)
	return KingdomInfo{
		ID: k.ID.String(), Name: k.Name, Tag: k.Tag,
		Level: int(k.Level), XP: k.Xp, XPToNext: nextXP,
		Treasury: itoa(k.Treasury), Reputation: k.Reputation / reputationScale,
		Members: members, MemberCap: d.Config.KingdomMemberCap(int(k.Level), courtBonus),
	}
}

// donationCap bounds a player's daily contribution. It stops one whale from
// instantly maxing a kingdom, and it blocks alt-account gold laundering.
func (d Deps) donationCap(level int64) int64 {
	c := d.Config.Kingdoms.Donation
	return c.DailyCapBase + c.DailyCapPerLevel*level
}

func sameDay(a time.Time, b time.Time) bool {
	ay, am, ad := a.UTC().Date()
	by, bm, bd := b.UTC().Date()
	return ay == by && am == bm && ad == bd
}

func max64(a, b int64) int64 {
	if a > b {
		return a
	}
	return b
}

// RenameKingdom changes a kingdom's name. Only its king may.
//
// A name outlives the moment it was chosen: it is on the leaderboard, in every
// battle log and over the gate. Founding used to be the only chance to set it,
// which made a typo permanent.
func (d Deps) RenameKingdom(ctx context.Context, playerID uuid.UUID, name string) (*KingdomView, error) {
	name = strings.TrimSpace(name)
	// The tag is not changing, so it is validated as it stands.
	err := db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
		q := sqlcdb.New(tx)
		p, err := q.LockPlayer(ctx, playerID)
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrNotFound
			}
			return fmt.Errorf("lock player: %w", err)
		}
		if p.KingdomID == nil {
			return ErrNotInKingdom
		}
		k, err := q.LockKingdom(ctx, *p.KingdomID)
		if err != nil {
			return fmt.Errorf("lock kingdom: %w", err)
		}
		if err := validKingdomName(name, k.Tag); err != nil {
			return err
		}
		if _, err := q.RenameKingdom(ctx, sqlcdb.RenameKingdomParams{
			ID: k.ID, LeaderID: &playerID, Name: name,
		}); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrNotPermitted
			}
			if db.IsUniqueViolation(err, "") {
				return ErrKingdomNameTaken
			}
			return fmt.Errorf("rename kingdom: %w", err)
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return d.GetKingdom(ctx, playerID)
}

// Found creates a kingdom and installs the founder as its king.
func (d Deps) Found(ctx context.Context, playerID uuid.UUID, name, tag string, wantSeq int64) (*KingdomView, error) {
	name = strings.TrimSpace(name)
	tag = strings.ToUpper(strings.TrimSpace(tag))
	if err := validKingdomName(name, tag); err != nil {
		return nil, err
	}

	err := db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
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
		if p.KingdomID != nil {
			return ErrAlreadyInKingdom
		}
		if int(p.Level) < d.Config.Kingdoms.FoundLevel {
			return fmt.Errorf("%w: founding needs level %d", ErrLevelTooLow, d.Config.Kingdoms.FoundLevel)
		}

		k, err := q.CreateKingdom(ctx, sqlcdb.CreateKingdomParams{
			Name: name, Tag: tag, LeaderID: &playerID,
		})
		if err != nil {
			if db.IsUniqueViolation(err, "") {
				return ErrKingdomNameTaken
			}
			return fmt.Errorf("create kingdom: %w", err)
		}

		// Pay and join in one statement, so a failure cannot leave a kingdom
		// standing with no king.
		after, err := q.PayAndJoinKingdom(ctx, sqlcdb.PayAndJoinKingdomParams{
			ID: playerID, Gold: d.Config.Kingdoms.FoundCost,
			KingdomID: &k.ID, KingdomRole: "king", ActionSeq: wantSeq,
		})
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrNotEnoughGold
			}
			return fmt.Errorf("pay and join: %w", err)
		}
		if err := q.DeleteInvitesForPlayer(ctx, playerID); err != nil {
			return err
		}
		return q.RecordGold(ctx, sqlcdb.RecordGoldParams{
			PlayerID: playerID, Delta: -d.Config.Kingdoms.FoundCost, BalanceAfter: after.Gold,
			Reason: "kingdom_found", RefID: strPtr(k.ID.String()),
		})
	})
	if err != nil {
		return nil, err
	}
	return d.GetKingdom(ctx, playerID)
}

func validKingdomName(name, tag string) error {
	if n := len([]rune(name)); n < 3 || n > 24 {
		return fmt.Errorf("a kingdom name must be between 3 and 24 characters")
	}
	if n := len([]rune(tag)); n < 2 || n > 4 {
		return fmt.Errorf("a tag must be between 2 and 4 characters")
	}
	// Same homograph reasoning as usernames: a kingdom name appears in battle
	// logs and on the leaderboard, so it must not be spoofable with lookalikes.
	for _, r := range name + tag {
		if r > 127 {
			return fmt.Errorf("names may use letters, digits, spaces and apostrophes only")
		}
	}
	if _, _, err := auth.NormalizeUsername(strings.ReplaceAll(tag, " ", "")); err != nil && len(tag) < 2 {
		return err
	}
	return nil
}
