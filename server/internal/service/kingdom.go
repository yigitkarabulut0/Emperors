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
)

var (
	ErrAlreadyInKingdom = errors.New("you already belong to a kingdom")
	ErrNotInKingdom     = errors.New("you are not in a kingdom")
	ErrKingdomFull      = errors.New("the kingdom is full")
	ErrNotInvited       = errors.New("you have not been invited")
	ErrNotPermitted     = errors.New("your rank does not allow that")
	ErrKingdomNameTaken = errors.New("that name or tag is taken")
	ErrLastKing         = errors.New("promote another lord before you leave")
	ErrSameKingdom      = errors.New("you cannot raid your own kingdom")
	ErrNotEnoughFavour  = errors.New("not enough favour")

	ErrKingdomEmpty     = errors.New("that kingdom has no lords left")
	ErrAlreadyRequested = errors.New("you have already asked to join")
	ErrTooManyRequests  = errors.New("you are asking too many kingdoms at once")
	ErrRejoinCooldown   = errors.New("left a kingdom too recently")
	ErrBadRole          = errors.New("no such rank")
	ErrBadPolicy        = errors.New("a kingdom is either open or joins by request")
	ErrBadTarget        = errors.New("you cannot do that to yourself")
	ErrTargetInKingdom  = errors.New("that lord already belongs to a kingdom")
	ErrBadKingdomName   = errors.New("that is not a kingdom name")
)

// ruleError is a refusal whose message is worth showing as written -- a name
// that is too long, a wait with the time left on it -- while still matching the
// sentinel it belongs to, which is what the HTTP layer maps by.
type ruleError struct {
	kind error
	msg  string
}

func (e ruleError) Error() string        { return e.msg }
func (e ruleError) Is(target error) bool { return target == e.kind }

// KingdomView is the Kingdom panel.
type KingdomView struct {
	InKingdom bool            `json:"in_kingdom"`
	Kingdom   *KingdomInfo    `json:"kingdom"`
	Members   []MemberView    `json:"members"`
	Upgrades  []UpgradeView   `json:"upgrades"`
	Me        *MembershipView `json:"me"`
	// Cards, so an invitation reads like any other kingdom in the hall. They
	// still carry kingdom_id, name, tag and level, which is all an installed
	// build reads from an invite.
	Invites    []KingdomCard `json:"invites"`
	FoundCost  int64         `json:"found_cost"`
	FoundLevel int           `json:"found_level"`
	Top        []KingdomInfo `json:"leaderboard"`

	// The hall: what a player with no kingdom is offered.
	Recommended []KingdomCard `json:"recommended"`
	// Seconds until this player may join a kingdom again; 0 when they may now.
	RejoinIn    int64  `json:"rejoin_in"`
	CanFound    bool   `json:"can_found"`
	FoundReason string `json:"found_reason"`
	MaxRequests int    `json:"max_requests"`

	// Who is asking to join. Only a king or captain sees them, because only they
	// can answer.
	Requests []JoinRequestView `json:"requests"`

	// Set by Join alone: "joined" or "requested".
	Result string `json:"result,omitempty"`
}

// KingdomCard is a kingdom as someone outside it sees one: enough to choose it,
// and the one thing they can do about it, decided here -- the client shows the
// button it is told to, rather than working out whether a kingdom is full.
type KingdomCard struct {
	ID         string `json:"id"`
	KingdomID  string `json:"kingdom_id"`
	Name       string `json:"name"`
	Tag        string `json:"tag"`
	Level      int    `json:"level"`
	Members    int    `json:"members"`
	MemberCap  int    `json:"member_cap"`
	Reputation int64  `json:"reputation"`
	JoinPolicy string `json:"join_policy"`
	King       string `json:"king"`
	// join | request | requested | accept | full | cooldown, or "" for a viewer
	// who already has a kingdom.
	Action string `json:"action"`
}

// JoinRequestView is one lord asking to join.
type JoinRequestView struct {
	PlayerID string `json:"player_id"`
	Name     string `json:"name"`
	Level    int    `json:"level"`
	// How long they have been waiting, in seconds.
	Waiting int64 `json:"waiting"`
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
	JoinPolicy string `json:"join_policy"`
}

type MemberView struct {
	PlayerID string `json:"player_id"`
	Name     string `json:"name"`
	Level    int    `json:"level"`
	Role     string `json:"role"`
	Donated  string `json:"donated"`
}

type MembershipView struct {
	Role         string `json:"role"`
	Donated      string `json:"donated"`
	Favour       int64  `json:"favour"`
	DonatedToday int64  `json:"donated_today"`
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

	view := newKingdomView(d)

	if top, err := q.TopKingdoms(ctx, sqlcdb.TopKingdomsParams{CourtID: courtUpgradeID, MaxRows: 20}); err == nil {
		for _, k := range top {
			view.Top = append(view.Top, KingdomInfo{
				ID: k.ID.String(), Name: k.Name, Tag: k.Tag,
				Level: int(k.Level), XP: k.Xp, Treasury: itoa(k.Treasury),
				Reputation: k.Reputation / reputationScale, Members: int(k.Members),
				MemberCap:  d.memberCap(int(k.Level), int(k.CourtLevel)),
				JoinPolicy: k.JoinPolicy,
			})
		}
	}

	if p.KingdomID == nil {
		if err := d.fillHall(ctx, q, p, view); err != nil {
			return nil, err
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

	today := int64(0)
	if p.KingdomDay.Valid && sameDay(p.KingdomDay.Time, d.Now()) {
		today = p.KingdomDonatedToday
	}
	view.Me = &MembershipView{
		Role: p.KingdomRole, Donated: itoa(p.KingdomDonatedTotal), Favour: p.KingdomFavour,
		DonatedToday: today,
	}

	if p.KingdomRole == "king" || p.KingdomRole == "marshal" {
		reqs, err := q.ListRequestsForKingdom(ctx, k.ID)
		if err != nil {
			return nil, fmt.Errorf("join requests: %w", err)
		}
		now := d.Now()
		for _, r := range reqs {
			view.Requests = append(view.Requests, JoinRequestView{
				PlayerID: r.ID.String(), Name: r.DisplayName, Level: int(r.Level),
				Waiting: int64(now.Sub(r.CreatedAt) / time.Second),
			})
		}
	}
	return view, nil
}

// newKingdomView is the empty panel, every list present and empty. A JSON null
// where a list belongs is a crash in the client, which iterates without asking.
func newKingdomView(d Deps) *KingdomView {
	return &KingdomView{
		FoundCost:   d.Config.Kingdoms.FoundCost,
		FoundLevel:  d.Config.Kingdoms.FoundLevel,
		MaxRequests: d.Config.Kingdoms.MaxJoinRequests,
		Members:     []MemberView{},
		Upgrades:    []UpgradeView{},
		Invites:     []KingdomCard{},
		Top:         []KingdomInfo{},
		Recommended: []KingdomCard{},
		Requests:    []JoinRequestView{},
	}
}

const courtUpgradeID = "royal_court"

func (d Deps) kingdomInfo(k sqlcdb.AppKingdom, members, courtLevel int) KingdomInfo {
	_, nextXP := d.Config.KingdomLevelFor(k.Xp)
	return KingdomInfo{
		ID: k.ID.String(), Name: k.Name, Tag: k.Tag,
		Level: int(k.Level), XP: k.Xp, XPToNext: nextXP,
		Treasury: itoa(k.Treasury), Reputation: k.Reputation / reputationScale,
		Members: members, MemberCap: d.memberCap(int(k.Level), courtLevel),
		JoinPolicy: k.JoinPolicy,
	}
}

// memberCap is a kingdom's roster limit: its level's cap plus the Royal Court.
//
// One place, because there were three and they disagreed: the invite and
// accept paths added the Court's seats, and the table beside them passed zero,
// so a kingdom could be shown full at 45 while it still had room for 55.
func (d Deps) memberCap(level, courtLevel int) int {
	bonus := 0
	if u := d.Config.KingdomUpgrade(courtUpgradeID); u != nil {
		bonus = int(u.PerLevel) * courtLevel
	}
	return d.Config.KingdomMemberCap(level, bonus)
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
	bad := func(msg string) error { return ruleError{kind: ErrBadKingdomName, msg: msg} }
	if n := len([]rune(name)); n < 3 || n > 24 {
		return bad("a kingdom name must be between 3 and 24 characters")
	}
	if n := len([]rune(tag)); n < 2 || n > 4 {
		return bad("a tag must be between 2 and 4 characters")
	}
	// Same homograph reasoning as usernames: a kingdom name appears in battle
	// logs and on the leaderboard, so it must not be spoofable with lookalikes.
	for _, r := range name + tag {
		if r > 127 {
			return bad("names may use letters, digits, spaces and apostrophes only")
		}
	}
	return nil
}
