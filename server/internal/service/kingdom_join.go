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

// Joining a kingdom without an invitation.
//
// Kingdoms were invite-only, and an invite needs a king who already knows your
// name, so a new player had no way in and a new king no way to be found. A
// player can now find kingdoms -- suggested, or by name -- and join one. How is
// the king's choice: an open kingdom seats anyone while there is room; one that
// joins by request stores the ask for the king or a captain to answer.
//
// Every path that puts a player in a kingdom -- joining an open one, accepting
// an invitation, a king accepting a request, a king inviting someone who had
// already asked -- goes through joinKingdom, so the cap, the cooldown and the
// "one kingdom at a time" rule are checked once, in one order.

const (
	policyOpen    = "open"
	policyRequest = "request"

	// How many kingdoms the hall suggests, and how many candidates are read to
	// find them: the full ones are dropped in Go against the real cap.
	recommendShown      = 8
	recommendCandidates = 40
	// A member seen this recently counts as active when kingdoms are ranked for
	// the hall. A kingdom that will answer beats a big one that has gone quiet.
	activeWindow = 72 * time.Hour
)

// joinKingdom seats a locked, kingdomless player in a kingdom.
//
// The caller has locked the joiner's row; this locks the kingdom's. Every path
// takes them in that order -- player, then kingdom -- so a player pressing JOIN
// while a king accepts their request cannot deadlock the two.
//
// forKing words a refusal for the king who is doing the seating ("they can
// join again in 42m") rather than for the joiner.
func (d Deps) joinKingdom(ctx context.Context, q *sqlcdb.Queries, joiner sqlcdb.AppPlayer,
	kingdomID uuid.UUID, forKing bool) error {
	if joiner.KingdomID != nil {
		if forKing {
			return ErrTargetInKingdom
		}
		return ErrAlreadyInKingdom
	}
	if wait := d.rejoinWait(joiner); wait > 0 {
		return d.cooldownError(wait, forKing)
	}

	k, err := q.LockKingdom(ctx, kingdomID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		return fmt.Errorf("lock kingdom: %w", err)
	}
	count, err := q.CountKingdomMembers(ctx, &kingdomID)
	if err != nil {
		return fmt.Errorf("count members: %w", err)
	}
	// A kingdom whose last lord left is deleted, and one that is empty in the
	// instant before that has no king to answer to.
	if count == 0 {
		return ErrKingdomEmpty
	}
	if int(count) >= d.memberCap(int(k.Level), d.courtLevel(ctx, q, k.ID)) {
		return ErrKingdomFull
	}

	now := d.Now()
	if _, err := q.SetPlayerKingdom(ctx, sqlcdb.SetPlayerKingdomParams{
		ID: joiner.ID, KingdomID: &kingdomID, KingdomRole: "member", KingdomJoinedAt: &now,
	}); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			if forKing {
				return ErrTargetInKingdom
			}
			return ErrAlreadyInKingdom
		}
		return fmt.Errorf("seat player: %w", err)
	}
	// The hall is told, in the same transaction that seated them: a lord who
	// appears in the roll with nothing said about it reads as a stranger.
	if _, err := d.systemLine(ctx, q, kingdomID, SysJoined,
		fmt.Sprintf("%s has joined the kingdom.", joiner.DisplayName),
		map[string]any{"player_id": joiner.ID.String()}); err != nil {
		return err
	}
	// Every other invitation and request goes: holding them would let a player
	// appear to be on their way into several kingdoms at once.
	return q.DeleteInvitesForPlayer(ctx, joiner.ID)
}

// rejoinWait is how long this player must still wait before joining a kingdom.
func (d Deps) rejoinWait(p sqlcdb.AppPlayer) time.Duration {
	if p.KingdomLeftAt == nil {
		return 0
	}
	until := p.KingdomLeftAt.Add(time.Duration(d.Config.Kingdoms.RejoinCooldownMinutes) * time.Minute)
	if wait := until.Sub(d.Now()); wait > 0 {
		return wait
	}
	return 0
}

func (d Deps) cooldownError(wait time.Duration, forKing bool) error {
	if forKing {
		return ruleError{kind: ErrRejoinCooldown,
			msg: "that lord left a kingdom recently and can join again in " + shortWait(wait)}
	}
	return ruleError{kind: ErrRejoinCooldown,
		msg: "you left a kingdom recently — you can join another in " + shortWait(wait)}
}

// shortWait writes a wait the way a person would say it: "42m", "1h 05m".
// Rounded up, so "in 1m" never turns out to mean "not yet".
func shortWait(wait time.Duration) string {
	m := int((wait + time.Minute - 1) / time.Minute)
	if m < 60 {
		return fmt.Sprintf("%dm", m)
	}
	return fmt.Sprintf("%dh %02dm", m/60, m%60)
}

// courtLevel is the kingdom's Royal Court level. Best effort: a failure shrinks
// the roster limit, it never blocks the action.
func (d Deps) courtLevel(ctx context.Context, q *sqlcdb.Queries, kingdomID uuid.UUID) int {
	ups, err := q.ListKingdomUpgrades(ctx, kingdomID)
	if err != nil {
		return 0
	}
	for _, r := range ups {
		if r.UpgradeID == courtUpgradeID {
			return int(r.Level)
		}
	}
	return 0
}

// Join joins a kingdom, or asks to.
//
// An open kingdom seats the player now. So does one that has already invited
// them -- the invitation is the kingdom's consent. Otherwise, for a kingdom
// that joins by request, the ask is stored for its king or a captain.
func (d Deps) Join(ctx context.Context, playerID, kingdomID uuid.UUID) (*KingdomView, error) {
	result := ""
	err := db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
		q := sqlcdb.New(tx)
		p, err := q.LockPlayer(ctx, playerID)
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrNotFound
			}
			return fmt.Errorf("lock player: %w", err)
		}
		if p.KingdomID != nil {
			return ErrAlreadyInKingdom
		}
		if wait := d.rejoinWait(p); wait > 0 {
			return d.cooldownError(wait, false)
		}
		k, err := q.GetKingdom(ctx, kingdomID)
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrNotFound
			}
			return fmt.Errorf("load kingdom: %w", err)
		}

		_, err = q.GetInvite(ctx, sqlcdb.GetInviteParams{KingdomID: kingdomID, PlayerID: playerID})
		invited := err == nil
		if err != nil && !errors.Is(err, pgx.ErrNoRows) {
			return fmt.Errorf("read invite: %w", err)
		}
		if k.JoinPolicy == policyOpen || invited {
			result = "joined"
			return d.joinKingdom(ctx, q, p, kingdomID, false)
		}

		// By request. Refused up front when it could not be granted anyway:
		// asking a full or empty kingdom is a request nobody can answer.
		if _, err := q.GetJoinRequest(ctx, sqlcdb.GetJoinRequestParams{
			KingdomID: kingdomID, PlayerID: playerID,
		}); err == nil {
			return ErrAlreadyRequested
		} else if !errors.Is(err, pgx.ErrNoRows) {
			return fmt.Errorf("read request: %w", err)
		}
		count, err := q.CountKingdomMembers(ctx, &kingdomID)
		if err != nil {
			return fmt.Errorf("count members: %w", err)
		}
		if count == 0 {
			return ErrKingdomEmpty
		}
		if int(count) >= d.memberCap(int(k.Level), d.courtLevel(ctx, q, k.ID)) {
			return ErrKingdomFull
		}
		asking, err := q.CountRequestsForPlayer(ctx, playerID)
		if err != nil {
			return fmt.Errorf("count requests: %w", err)
		}
		if int(asking) >= d.Config.Kingdoms.MaxJoinRequests {
			return ruleError{kind: ErrTooManyRequests, msg: fmt.Sprintf(
				"you are already asking %d kingdoms — withdraw one first", asking)}
		}
		n, err := q.CreateJoinRequest(ctx, sqlcdb.CreateJoinRequestParams{
			KingdomID: kingdomID, PlayerID: playerID,
		})
		if err != nil {
			return fmt.Errorf("create request: %w", err)
		}
		if n == 0 {
			return ErrAlreadyRequested
		}
		result = "requested"
		return nil
	})
	if err != nil {
		return nil, err
	}
	v, err := d.GetKingdom(ctx, playerID)
	if v != nil {
		v.Result = result
	}
	return v, err
}

// CancelRequest withdraws a request to join.
func (d Deps) CancelRequest(ctx context.Context, playerID, kingdomID uuid.UUID) (*KingdomView, error) {
	n, err := sqlcdb.New(d.Pool).DeleteInvite(ctx, sqlcdb.DeleteInviteParams{
		KingdomID: kingdomID, PlayerID: playerID, Direction: policyRequest,
	})
	if err != nil {
		return nil, fmt.Errorf("cancel request: %w", err)
	}
	if n == 0 {
		return nil, ErrNotFound
	}
	return d.GetKingdom(ctx, playerID)
}

// DeclineInvite turns an invitation down.
func (d Deps) DeclineInvite(ctx context.Context, playerID, kingdomID uuid.UUID) (*KingdomView, error) {
	n, err := sqlcdb.New(d.Pool).DeleteInvite(ctx, sqlcdb.DeleteInviteParams{
		KingdomID: kingdomID, PlayerID: playerID, Direction: "invite",
	})
	if err != nil {
		return nil, fmt.Errorf("decline invite: %w", err)
	}
	if n == 0 {
		return nil, ErrNotInvited
	}
	return d.GetKingdom(ctx, playerID)
}

// AnswerRequest lets a king or captain accept or refuse a lord who asked to join.
func (d Deps) AnswerRequest(ctx context.Context, playerID, targetID uuid.UUID, accept bool) (*KingdomView, error) {
	err := db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
		q := sqlcdb.New(tx)
		me, err := q.GetPlayerByID(ctx, playerID)
		if err != nil {
			return ErrNotFound
		}
		if me.KingdomID == nil {
			return ErrNotInKingdom
		}
		if me.KingdomRole != "king" && me.KingdomRole != "marshal" {
			return ErrNotPermitted
		}
		kid := *me.KingdomID
		if _, err := q.GetJoinRequest(ctx, sqlcdb.GetJoinRequestParams{
			KingdomID: kid, PlayerID: targetID,
		}); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrNotFound
			}
			return fmt.Errorf("read request: %w", err)
		}
		if !accept {
			_, err := q.DeleteInvite(ctx, sqlcdb.DeleteInviteParams{
				KingdomID: kid, PlayerID: targetID, Direction: policyRequest,
			})
			return err
		}
		them, err := q.LockPlayer(ctx, targetID)
		if err != nil {
			return ErrNotFound
		}
		return d.joinKingdom(ctx, q, them, kid, true)
	})
	if err != nil {
		return nil, err
	}
	return d.GetKingdom(ctx, playerID)
}

// Kick removes a lord from the kingdom.
//
// The king may remove anyone but himself; a captain, only lords below him. The
// removed lord waits out the rejoin cooldown like anyone who leaves -- that is
// the point: with open joining, a removal they could undo by walking back in
// would be no removal at all.
func (d Deps) Kick(ctx context.Context, playerID, targetID uuid.UUID) (*KingdomView, error) {
	if playerID == targetID {
		return nil, ruleError{kind: ErrBadTarget, msg: "you cannot remove yourself — leave the kingdom instead"}
	}
	err := db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
		q := sqlcdb.New(tx)
		me, err := q.GetPlayerByID(ctx, playerID)
		if err != nil {
			return ErrNotFound
		}
		if me.KingdomID == nil {
			return ErrNotInKingdom
		}
		them, err := q.LockPlayer(ctx, targetID)
		if err != nil {
			return ErrNotFound
		}
		if them.KingdomID == nil || *them.KingdomID != *me.KingdomID {
			return ErrNotFound
		}
		switch me.KingdomRole {
		case "king":
		case "marshal":
			if them.KingdomRole != "member" {
				return ErrNotPermitted
			}
		default:
			return ErrNotPermitted
		}
		now := d.Now()
		if _, err := q.KickFromKingdom(ctx, sqlcdb.KickFromKingdomParams{
			ID: targetID, KingdomID: me.KingdomID, LeftAt: &now,
		}); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrNotFound
			}
			return fmt.Errorf("remove lord: %w", err)
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return d.GetKingdom(ctx, playerID)
}

// SetPolicy is the king's choice of who may join: anyone while there is room,
// or those he accepts.
func (d Deps) SetPolicy(ctx context.Context, playerID uuid.UUID, policy string) (*KingdomView, error) {
	if policy != policyOpen && policy != policyRequest {
		return nil, ErrBadPolicy
	}
	q := sqlcdb.New(d.Pool)
	me, err := q.GetPlayerByID(ctx, playerID)
	if err != nil {
		return nil, ErrNotFound
	}
	if me.KingdomID == nil {
		return nil, ErrNotInKingdom
	}
	if me.KingdomRole != "king" {
		return nil, ErrNotPermitted
	}
	if err := q.SetJoinPolicy(ctx, sqlcdb.SetJoinPolicyParams{ID: *me.KingdomID, JoinPolicy: policy}); err != nil {
		return nil, fmt.Errorf("set policy: %w", err)
	}
	return d.GetKingdom(ctx, playerID)
}

// fillHall fills in what a player with no kingdom is offered: their
// invitations, the kingdoms worth suggesting, and whether they may found one.
func (d Deps) fillHall(ctx context.Context, q *sqlcdb.Queries, p sqlcdb.AppPlayer, view *KingdomView) error {
	wait := d.rejoinWait(p)
	view.RejoinIn = int64((wait + time.Second - 1) / time.Second)
	view.CanFound = int(p.Level) >= d.Config.Kingdoms.FoundLevel
	if !view.CanFound {
		// Said on the founding card's plate, under RAISE YOUR OWN BANNER: short
		// enough to read at the plate's own size.
		view.FoundReason = fmt.Sprintf("Reach level %d", d.Config.Kingdoms.FoundLevel)
	}

	look, err := d.viewerState(ctx, q, p)
	if err != nil {
		return err
	}

	invites, err := q.ListInvitesForPlayer(ctx, sqlcdb.ListInvitesForPlayerParams{
		CourtID: courtUpgradeID, PlayerID: p.ID,
	})
	if err != nil {
		return fmt.Errorf("invites: %w", err)
	}
	for _, i := range invites {
		view.Invites = append(view.Invites, d.card(look, cardRow{
			id: i.ID, name: i.Name, tag: i.Tag, level: i.Level, reputation: i.Reputation,
			policy: i.JoinPolicy, members: i.Members, court: i.CourtLevel, king: i.KingName,
		}))
	}

	rows, err := q.RecommendKingdoms(ctx, sqlcdb.RecommendKingdomsParams{
		ActiveSince: d.Now().Add(-activeWindow), CourtID: courtUpgradeID,
		MaxRows: recommendCandidates,
	})
	if err != nil {
		return fmt.Errorf("recommend kingdoms: %w", err)
	}
	for _, r := range rows {
		c := d.card(look, cardRow{
			id: r.ID, name: r.Name, tag: r.Tag, level: r.Level, reputation: r.Reputation,
			policy: r.JoinPolicy, members: r.Members, court: r.CourtLevel, king: r.KingName,
		})
		// Only kingdoms with a seat, and none the player is already invited
		// to -- those are listed as invitations, above.
		if c.Members >= c.MemberCap || look.invited[r.ID] {
			continue
		}
		view.Recommended = append(view.Recommended, c)
		if len(view.Recommended) == recommendShown {
			break
		}
	}
	return nil
}

// SearchKingdoms finds kingdoms by name or tag, as cards.
func (d Deps) SearchKingdoms(ctx context.Context, playerID uuid.UUID, term string) ([]KingdomCard, error) {
	term = strings.ToLower(strings.TrimSpace(term))
	out := []KingdomCard{}
	if len([]rune(term)) < 2 {
		return out, nil
	}
	q := sqlcdb.New(d.Pool)
	p, err := q.GetPlayerByID(ctx, playerID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, fmt.Errorf("load player: %w", err)
	}
	look, err := d.viewerState(ctx, q, p)
	if err != nil {
		return nil, err
	}
	rows, err := q.SearchKingdoms(ctx, sqlcdb.SearchKingdomsParams{
		CourtID: courtUpgradeID, Pattern: likePattern(term), Exact: term,
	})
	if err != nil {
		return nil, fmt.Errorf("search kingdoms: %w", err)
	}
	for _, r := range rows {
		out = append(out, d.card(look, cardRow{
			id: r.ID, name: r.Name, tag: r.Tag, level: r.Level, reputation: r.Reputation,
			policy: r.JoinPolicy, members: r.Members, court: r.CourtLevel, king: r.KingName,
		}))
	}
	return out, nil
}

// likePattern makes a search term safe to use inside LIKE: a kingdom named
// "100% Loyal" is searched for its percent sign, not for everything.
func likePattern(term string) string {
	r := strings.NewReplacer(`\`, `\\`, `%`, `\%`, `_`, `\_`)
	return "%" + r.Replace(term) + "%"
}

// viewer is what decides a card's button for the player looking at it.
type viewer struct {
	inKingdom bool
	waiting   bool
	invited   map[uuid.UUID]bool
	requested map[uuid.UUID]bool
}

func (d Deps) viewerState(ctx context.Context, q *sqlcdb.Queries, p sqlcdb.AppPlayer) (viewer, error) {
	v := viewer{
		inKingdom: p.KingdomID != nil,
		waiting:   d.rejoinWait(p) > 0,
		invited:   map[uuid.UUID]bool{},
		requested: map[uuid.UUID]bool{},
	}
	if v.inKingdom {
		return v, nil
	}
	asked, err := q.ListRequestsForPlayer(ctx, p.ID)
	if err != nil {
		return v, fmt.Errorf("requests: %w", err)
	}
	for _, id := range asked {
		v.requested[id] = true
	}
	invites, err := q.ListInvitesForPlayer(ctx, sqlcdb.ListInvitesForPlayerParams{
		CourtID: courtUpgradeID, PlayerID: p.ID,
	})
	if err != nil {
		return v, fmt.Errorf("invites: %w", err)
	}
	for _, i := range invites {
		v.invited[i.ID] = true
	}
	return v, nil
}

// cardRow is the kingdom columns every card query returns, whatever sqlc named
// its row type.
type cardRow struct {
	id         uuid.UUID
	name, tag  string
	level      int32
	reputation int64
	policy     string
	members    int32
	court      int32
	king       string
}

func (d Deps) card(look viewer, r cardRow) KingdomCard {
	c := KingdomCard{
		ID: r.id.String(), KingdomID: r.id.String(), Name: r.name, Tag: r.tag,
		Level: int(r.level), Members: int(r.members),
		MemberCap:  d.memberCap(int(r.level), int(r.court)),
		Reputation: r.reputation / reputationScale, JoinPolicy: r.policy, King: r.king,
	}
	c.Action = cardAction(look, r.id, r.policy, c.Members, c.MemberCap)
	return c
}

// cardAction is the one thing the viewer can do about a kingdom. In order: a
// player with a kingdom does nothing here; one waiting out a cooldown can only
// wait; a request already sent can be withdrawn even from a kingdom that has
// since filled; a full kingdom takes nobody; an invitation is accepted; and
// otherwise the kingdom's own rule says join or ask.
func cardAction(look viewer, id uuid.UUID, policy string, members, cap int) string {
	switch {
	case look.inKingdom:
		return ""
	case look.waiting:
		return "cooldown"
	case look.requested[id]:
		return "requested"
	case members >= cap:
		return "full"
	case look.invited[id]:
		return "accept"
	case policy == policyRequest:
		return "request"
	default:
		return "join"
	}
}
