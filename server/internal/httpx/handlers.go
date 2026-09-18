package httpx

import (
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"strconv"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"

	"github.com/yigitkarabulut0/emperors/server/internal/auth"
	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
	"github.com/yigitkarabulut0/emperors/server/internal/service"
)

// maxBodyBytes caps request bodies. Every endpoint here takes a tiny JSON
// object; without a cap, a client can stream gigabytes into the decoder.
const maxBodyBytes = 8 << 10

type api struct {
	svc   service.Deps
	store *gameconfig.Store
	log   *slog.Logger
	// presence is the live board. Optional: a nil registry makes the heartbeat
	// endpoint a no-op rather than a crash, which is what the router tests use.
	presence Presenter
	// verifier is kept for the one route that needs more than "who is this":
	// the hall's socket, which closes itself when the token it was opened with
	// runs out (httpx/social.go).
	verifier TokenVerifier
	// wsOrigins is what the hall's websocket accepts as an Origin. The phone
	// sends none at all, which the websocket library treats as same-origin.
	wsOrigins []string
}

// s returns the service bound to the balance version live RIGHT NOW.
//
// Taken once per request and used throughout, so a publish mid-request cannot
// change the rules underneath a transaction that has already started pricing
// something. Deps is a small value struct, so this copy is free.
func (a *api) s() service.Deps {
	d := a.svc
	if a.store != nil {
		d.Config = a.store.Get()
	}
	return d
}

// jsonStrict is a decoder that refuses fields it does not know.
func jsonStrict(body io.Reader) *json.Decoder {
	dec := json.NewDecoder(body)
	dec.DisallowUnknownFields() // a typo'd field is a bug, not something to ignore
	return dec
}

func decode(w http.ResponseWriter, r *http.Request, into any) bool {
	r.Body = http.MaxBytesReader(w, r.Body, maxBodyBytes)
	dec := jsonStrict(r.Body)
	if err := dec.Decode(into); err != nil {
		msg := "malformed request body"
		if errors.Is(err, io.EOF) {
			msg = "request body is empty"
		}
		WriteProblem(w, r, http.StatusBadRequest, CodeBadRequest, msg)
		return false
	}
	return true
}

// decodeQuiet reads an optional body and never writes a response.
//
// For endpoints where a malformed or absent body is not worth failing over --
// the leaving beacon fires while iOS is suspending the app, and half a body is
// still worth more than a rejected request.
func decodeQuiet(r *http.Request, into any) error {
	r.Body = http.MaxBytesReader(nil, r.Body, maxBodyBytes)
	return json.NewDecoder(r.Body).Decode(into)
}

// fail maps a service error to a status code. Services never know about HTTP;
// this is the single place the translation happens.
func (a *api) fail(w http.ResponseWriter, r *http.Request, err error) {
	if promoProblem(w, r, err) {
		return
	}
	if purchaseProblem(w, r, err) {
		if errors.Is(err, service.ErrIAPInvalid) || errors.Is(err, service.ErrIAPWrongApp) {
			// The reason is for the log, not the client: it says which check failed.
			a.log.Warn("purchase refused", "err", err, "route", r.URL.Path)
		}
		return
	}
	switch {
	case errors.Is(err, service.ErrUsernameTaken):
		WriteProblem(w, r, http.StatusConflict, "username_taken", "that name is already taken")
	case errors.Is(err, service.ErrBadCredentials):
		WriteProblem(w, r, http.StatusUnauthorized, "bad_credentials", "wrong username or password")
	case errors.Is(err, service.ErrPlayerBanned):
		WriteProblem(w, r, http.StatusForbidden, "banned", "this account is banned")
	case errors.Is(err, service.ErrSessionInvalid):
		WriteProblem(w, r, http.StatusUnauthorized, "session_invalid", "please sign in again")
	case errors.Is(err, service.ErrNotFound):
		WriteProblem(w, r, http.StatusNotFound, CodeNotFound, "not found")
	case errors.Is(err, service.ErrJobLocked):
		WriteProblem(w, r, http.StatusForbidden, "job_locked", "that job is not unlocked yet")
	case errors.Is(err, service.ErrNotEnoughEnergy):
		WriteProblem(w, r, http.StatusConflict, "not_enough_energy", "not enough energy")
	case errors.Is(err, service.ErrAlreadyPurchased):
		WriteProblem(w, r, http.StatusConflict, "already_purchased", "someone already took that one")
	case errors.Is(err, service.ErrInvalidAmount):
		WriteProblem(w, r, http.StatusBadRequest, CodeBadRequest, "amount must be positive")
	case errors.Is(err, service.ErrNothingToBuy):
		WriteProblem(w, r, http.StatusConflict, "nothing_to_buy", "that would do nothing right now")
	case errors.Is(err, service.ErrNotEnoughDiamonds):
		WriteProblem(w, r, http.StatusConflict, "not_enough_diamonds", "not enough diamonds")
	case errors.Is(err, service.ErrMailClaimed):
		WriteProblem(w, r, http.StatusConflict, "already_claimed", err.Error())
	case errors.Is(err, service.ErrMailExpired):
		WriteProblem(w, r, http.StatusConflict, "mail_expired", "that letter has expired")
	case errors.Is(err, service.ErrMailKeep):
		WriteProblem(w, r, http.StatusConflict, "mail_unclaimed", err.Error())
	case errors.Is(err, service.ErrMailBad):
		WriteProblem(w, r, http.StatusBadRequest, "mail_invalid", err.Error())
	case errors.Is(err, service.ErrNoToken):
		WriteProblem(w, r, http.StatusConflict, "no_token", "you have none of those left")
	case errors.Is(err, service.ErrRewardInvalid):
		WriteProblem(w, r, http.StatusBadRequest, "reward_invalid", err.Error())
	case errors.Is(err, service.ErrRerollsExhausted):
		WriteProblem(w, r, http.StatusConflict, "rerolls_exhausted", "you have used today's market rerolls — the count resets at midnight")
	case errors.Is(err, service.ErrRefillsExhausted):
		WriteProblem(w, r, http.StatusConflict, "refills_exhausted", "you have used today's refills — the count resets at midnight")
	case errors.Is(err, service.ErrNotEnoughGold):
		WriteProblem(w, r, http.StatusConflict, "not_enough_gold", "not enough gold")

	// Rekabet (Wave 5). Every message says the RULE, never "no": a refusal a
	// player cannot read is one they will meet again tomorrow.
	case errors.Is(err, service.ErrArenaLocked):
		WriteProblem(w, r, http.StatusForbidden, "arena_locked", err.Error())
	case errors.Is(err, service.ErrNoTickets):
		WriteProblem(w, r, http.StatusConflict, "no_tickets", "you have used today's arena fights — they come round at midnight")
	case errors.Is(err, service.ErrNoRefreshes):
		WriteProblem(w, r, http.StatusConflict, "no_refreshes", "you have used today's refreshes — these are the lords on offer")
	case errors.Is(err, service.ErrArenaSelf):
		WriteProblem(w, r, http.StatusConflict, "arena_self", err.Error())
	case errors.Is(err, service.ErrArenaOutOfBand):
		WriteProblem(w, r, http.StatusConflict, "arena_out_of_band", err.Error())
	case errors.Is(err, service.ErrBountyLocked):
		WriteProblem(w, r, http.StatusForbidden, "bounty_locked", err.Error())
	case errors.Is(err, service.ErrBountyPlate):
		WriteProblem(w, r, http.StatusBadRequest, "bounty_plate", err.Error())
	case errors.Is(err, service.ErrBountySelf):
		WriteProblem(w, r, http.StatusConflict, "bounty_self", err.Error())
	case errors.Is(err, service.ErrBountyAlly):
		WriteProblem(w, r, http.StatusConflict, "bounty_ally", err.Error())
	case errors.Is(err, service.ErrBountyBot):
		WriteProblem(w, r, http.StatusConflict, "bounty_bot", err.Error())
	case errors.Is(err, service.ErrBountyPunchDown):
		WriteProblem(w, r, http.StatusConflict, "bounty_punch_down", err.Error())
	case errors.Is(err, service.ErrBountyCooling):
		WriteProblem(w, r, http.StatusTooManyRequests, "bounty_cooling", err.Error())
	case errors.Is(err, service.ErrBountyPairSpent):
		WriteProblem(w, r, http.StatusConflict, "bounty_pair_spent", err.Error())
	case errors.Is(err, service.ErrBountyTooNew):
		WriteProblem(w, r, http.StatusForbidden, "bounty_too_new", err.Error())
	case errors.Is(err, service.ErrBountyGone):
		WriteProblem(w, r, http.StatusConflict, "bounty_gone", err.Error())
	case errors.Is(err, service.ErrBountyLimit):
		WriteProblem(w, r, http.StatusConflict, "bounty_limit", err.Error())
	case errors.Is(err, service.ErrBountyCrowded):
		WriteProblem(w, r, http.StatusConflict, "bounty_crowded", err.Error())
	case errors.Is(err, service.ErrNotEmperor):
		WriteProblem(w, r, http.StatusForbidden, "not_emperor", err.Error())
	case errors.Is(err, service.ErrDecreeSpent):
		WriteProblem(w, r, http.StatusConflict, "decree_spent", err.Error())
	case errors.Is(err, service.ErrDecreeUnknown):
		WriteProblem(w, r, http.StatusBadRequest, "decree_unknown", err.Error())
	case errors.Is(err, service.ErrNoThrone):
		WriteProblem(w, r, http.StatusConflict, "no_throne", err.Error())
	// Sosyal (Wave 6). Same rule as Rekabet's: every message says the RULE.
	case errors.Is(err, service.ErrNoHall):
		WriteProblem(w, r, http.StatusConflict, "no_hall", err.Error())
	case errors.Is(err, service.ErrRulesUnread):
		WriteProblem(w, r, http.StatusForbidden, "rules_unread", err.Error())
	case errors.Is(err, service.ErrMuted):
		WriteProblem(w, r, http.StatusForbidden, "muted", err.Error())
	case errors.Is(err, service.ErrSaidTooFast):
		WriteProblem(w, r, http.StatusTooManyRequests, "too_fast", err.Error())
	case errors.Is(err, service.ErrSaidTooMuch):
		WriteProblem(w, r, http.StatusTooManyRequests, "too_much", err.Error())
	case errors.Is(err, service.ErrLineTooLong):
		WriteProblem(w, r, http.StatusBadRequest, "line_too_long", err.Error())
	case errors.Is(err, service.ErrLineEmpty):
		WriteProblem(w, r, http.StatusBadRequest, "line_empty", err.Error())
	case errors.Is(err, service.ErrLineRefused):
		WriteProblem(w, r, http.StatusUnprocessableEntity, "line_refused", err.Error())
	case errors.Is(err, service.ErrReportedFast):
		WriteProblem(w, r, http.StatusTooManyRequests, "reported_fast", err.Error())
	case errors.Is(err, service.ErrBlockedLimit):
		WriteProblem(w, r, http.StatusConflict, "blocked_limit", err.Error())
	case errors.Is(err, service.ErrBlockSelf):
		WriteProblem(w, r, http.StatusBadRequest, "block_self", err.Error())
	case errors.Is(err, service.ErrBadPrivacy):
		WriteProblem(w, r, http.StatusBadRequest, "bad_privacy", err.Error())
	case errors.Is(err, service.ErrFriendsLocked):
		WriteProblem(w, r, http.StatusForbidden, "friends_locked", err.Error())
	case errors.Is(err, service.ErrFriendSelf):
		WriteProblem(w, r, http.StatusBadRequest, "friend_self", err.Error())
	case errors.Is(err, service.ErrFriendFull):
		WriteProblem(w, r, http.StatusConflict, "friends_full", err.Error())
	case errors.Is(err, service.ErrFriendTheirs):
		WriteProblem(w, r, http.StatusConflict, "their_roll_full", err.Error())
	case errors.Is(err, service.ErrFriendAlready):
		WriteProblem(w, r, http.StatusConflict, "already_friends", err.Error())
	case errors.Is(err, service.ErrFriendAsked):
		WriteProblem(w, r, http.StatusConflict, "already_asked", err.Error())
	case errors.Is(err, service.ErrFriendRefused):
		WriteProblem(w, r, http.StatusForbidden, "requests_shut", err.Error())
	case errors.Is(err, service.ErrFriendDayFull):
		WriteProblem(w, r, http.StatusConflict, "requests_day_full", err.Error())
	case errors.Is(err, service.ErrFriendNone):
		WriteProblem(w, r, http.StatusNotFound, "no_request", err.Error())
	case errors.Is(err, service.ErrGiftSentToday):
		WriteProblem(w, r, http.StatusConflict, "gift_sent", err.Error())
	case errors.Is(err, service.ErrGiftDayFull):
		WriteProblem(w, r, http.StatusConflict, "gifts_day_full", err.Error())
	case errors.Is(err, service.ErrGiftNone):
		WriteProblem(w, r, http.StatusNotFound, "no_gift", err.Error())
	case errors.Is(err, service.ErrGiftTooNew):
		WriteProblem(w, r, http.StatusForbidden, "friendship_too_new", err.Error())
	case errors.Is(err, service.ErrAccountTooNew):
		WriteProblem(w, r, http.StatusForbidden, "account_too_new", err.Error())
	case errors.Is(err, service.ErrRivalHidden):
		WriteProblem(w, r, http.StatusForbidden, "page_hidden", err.Error())
	case errors.Is(err, service.ErrSpySelf):
		WriteProblem(w, r, http.StatusBadRequest, "spy_self", err.Error())
	case errors.Is(err, service.ErrSpyDayFull):
		WriteProblem(w, r, http.StatusConflict, "spy_day_full", err.Error())
	case errors.Is(err, service.ErrSpyGold):
		WriteProblem(w, r, http.StatusConflict, "not_enough_gold", err.Error())
	case errors.Is(err, service.ErrNoKingdomHelp):
		WriteProblem(w, r, http.StatusConflict, "no_kingdom", err.Error())
	case errors.Is(err, service.ErrAidSoon):
		WriteProblem(w, r, http.StatusTooManyRequests, "aid_soon", err.Error())
	case errors.Is(err, service.ErrAidDayFull):
		WriteProblem(w, r, http.StatusConflict, "aid_day_full", err.Error())
	case errors.Is(err, service.ErrAidOwn):
		WriteProblem(w, r, http.StatusBadRequest, "aid_own", err.Error())
	case errors.Is(err, service.ErrAidGone):
		WriteProblem(w, r, http.StatusConflict, "aid_gone", err.Error())
	case errors.Is(err, service.ErrAidFull):
		WriteProblem(w, r, http.StatusConflict, "aid_full", err.Error())
	case errors.Is(err, service.ErrGoalNone):
		WriteProblem(w, r, http.StatusConflict, "no_goal", err.Error())
	case errors.Is(err, service.ErrGoalShort):
		WriteProblem(w, r, http.StatusConflict, "goal_short", err.Error())
	case errors.Is(err, service.ErrGoalShare):
		WriteProblem(w, r, http.StatusForbidden, "goal_share", err.Error())
	case errors.Is(err, service.ErrGoalTaken):
		WriteProblem(w, r, http.StatusConflict, "goal_taken", err.Error())

	// PvE ve derinlik (Wave 7).
	case errors.Is(err, service.ErrCampaignLocked):
		WriteProblem(w, r, http.StatusForbidden, "campaign_locked", err.Error())
	case errors.Is(err, service.ErrStageUnknown):
		WriteProblem(w, r, http.StatusNotFound, CodeNotFound, err.Error())
	case errors.Is(err, service.ErrStageShut):
		WriteProblem(w, r, http.StatusConflict, "stage_shut", err.Error())
	case errors.Is(err, service.ErrChestShut):
		WriteProblem(w, r, http.StatusConflict, "chest_shut", err.Error())
	case errors.Is(err, service.ErrChestTaken):
		WriteProblem(w, r, http.StatusConflict, "chest_taken", err.Error())
	case errors.Is(err, service.ErrHuntLocked):
		WriteProblem(w, r, http.StatusForbidden, "hunt_locked", err.Error())
	case errors.Is(err, service.ErrHuntSlots):
		WriteProblem(w, r, http.StatusConflict, "hunt_slots", err.Error())
	case errors.Is(err, service.ErrHuntField):
		WriteProblem(w, r, http.StatusNotFound, CodeNotFound, err.Error())
	case errors.Is(err, service.ErrHuntAway):
		WriteProblem(w, r, http.StatusConflict, "soldier_away", err.Error())
	case errors.Is(err, service.ErrHuntSoon):
		WriteProblem(w, r, http.StatusConflict, "hunt_soon", err.Error())
	case errors.Is(err, service.ErrHuntGone):
		WriteProblem(w, r, http.StatusConflict, "hunt_gone", err.Error())
	case errors.Is(err, service.ErrForgeLocked):
		WriteProblem(w, r, http.StatusForbidden, "forge_locked", err.Error())
	case errors.Is(err, service.ErrForgePieces):
		WriteProblem(w, r, http.StatusBadRequest, "forge_pieces", err.Error())
	case errors.Is(err, service.ErrForgeTop):
		WriteProblem(w, r, http.StatusConflict, "forge_top", err.Error())
	case errors.Is(err, service.ErrForgeWorn):
		WriteProblem(w, r, http.StatusConflict, "item_equipped", err.Error())
	case errors.Is(err, service.ErrTalentsLocked):
		WriteProblem(w, r, http.StatusForbidden, "talents_locked", err.Error())
	case errors.Is(err, service.ErrTalentUnknown):
		WriteProblem(w, r, http.StatusNotFound, CodeNotFound, err.Error())
	case errors.Is(err, service.ErrTalentMaxed):
		WriteProblem(w, r, http.StatusConflict, "talent_maxed", err.Error())
	case errors.Is(err, service.ErrTalentPoints):
		WriteProblem(w, r, http.StatusConflict, "no_talent_points", err.Error())
	case errors.Is(err, service.ErrTalentShut):
		WriteProblem(w, r, http.StatusConflict, "talent_shut", err.Error())
	case errors.Is(err, service.ErrNoTalents):
		WriteProblem(w, r, http.StatusConflict, "no_talents", err.Error())

	// Krallik Boss ve Savaslari (Wave 8). Same rule as every wave before it:
	// the message says the RULE, never "no".
	case errors.Is(err, service.ErrBossLocked):
		WriteProblem(w, r, http.StatusForbidden, "boss_locked", err.Error())
	case errors.Is(err, service.ErrNoBoss):
		WriteProblem(w, r, http.StatusConflict, "no_boss", err.Error())
	case errors.Is(err, service.ErrBossDown):
		WriteProblem(w, r, http.StatusConflict, "boss_down", err.Error())
	case errors.Is(err, service.ErrBossOver):
		WriteProblem(w, r, http.StatusConflict, "boss_over", err.Error())
	case errors.Is(err, service.ErrNoBlows):
		WriteProblem(w, r, http.StatusConflict, "no_blows", err.Error())
	case errors.Is(err, service.ErrWarLocked):
		WriteProblem(w, r, http.StatusForbidden, "war_locked", err.Error())
	case errors.Is(err, service.ErrNoWar):
		WriteProblem(w, r, http.StatusConflict, "no_war", err.Error())
	case errors.Is(err, service.ErrWarBye):
		WriteProblem(w, r, http.StatusConflict, "war_bye", err.Error())
	case errors.Is(err, service.ErrWarNotLive):
		WriteProblem(w, r, http.StatusConflict, "war_not_live", err.Error())
	case errors.Is(err, service.ErrWarOver):
		WriteProblem(w, r, http.StatusConflict, "war_over", err.Error())
	case errors.Is(err, service.ErrWarNotFoe):
		WriteProblem(w, r, http.StatusConflict, "war_not_foe", err.Error())
	case errors.Is(err, service.ErrWarSelf):
		WriteProblem(w, r, http.StatusBadRequest, "war_self", err.Error())
	case errors.Is(err, service.ErrNoWarAttack):
		WriteProblem(w, r, http.StatusConflict, "no_war_attacks", err.Error())

	// Herald's Tidings: the rewarded advert.
	case errors.Is(err, service.ErrHeraldShut):
		WriteProblem(w, r, http.StatusConflict, "herald_shut", err.Error())
	case errors.Is(err, service.ErrHeraldEarly):
		WriteProblem(w, r, http.StatusConflict, "herald_early", err.Error())
	case errors.Is(err, service.ErrHeraldSpent):
		WriteProblem(w, r, http.StatusConflict, "herald_spent", err.Error())
	case errors.Is(err, service.ErrHeraldSoon):
		WriteProblem(w, r, http.StatusTooManyRequests, "herald_soon", err.Error())

	case errors.Is(err, service.ErrInventoryFull):
		WriteProblem(w, r, http.StatusConflict, "inventory_full", "your armory is full — sell something first")
	case errors.Is(err, service.ErrShopStale):
		WriteProblem(w, r, http.StatusConflict, "shop_stale", "the market has restocked")
	case errors.Is(err, service.ErrItemEquipped):
		WriteProblem(w, r, http.StatusConflict, "item_equipped", "unequip it first")
	case errors.Is(err, service.ErrNoSlot):
		WriteProblem(w, r, http.StatusConflict, "no_slot", "buy that barracks slot first")
	case errors.Is(err, service.ErrSlotsMaxed):
		WriteProblem(w, r, http.StatusConflict, "slots_maxed", "every barracks slot is already yours")
	case errors.Is(err, service.ErrLevelTooLow):
		WriteProblem(w, r, http.StatusForbidden, "level_too_low", err.Error())
	case errors.Is(err, service.ErrAlreadyMaxed):
		WriteProblem(w, r, http.StatusConflict, "already_maxed", "already at your level")
	case errors.Is(err, service.ErrNoRevenge):
		WriteProblem(w, r, http.StatusConflict, "no_revenge", err.Error())
	case errors.Is(err, service.ErrShielded):
		WriteProblem(w, r, http.StatusConflict, "shielded", "that lord is under protection")
	case errors.Is(err, service.ErrOnCooldown):
		WriteProblem(w, r, http.StatusConflict, "on_cooldown", "you raided them too recently")
	case errors.Is(err, service.ErrSelfAttack):
		WriteProblem(w, r, http.StatusBadRequest, "self_attack", "you cannot attack yourself")
	case errors.Is(err, service.ErrTooNewToRaid):
		WriteProblem(w, r, http.StatusConflict, "too_new_to_raid", err.Error())
	case errors.Is(err, service.ErrNoStatPoints):
		WriteProblem(w, r, http.StatusConflict, "no_stat_points", "not enough stat points")
	case errors.Is(err, service.ErrNothingToSpend):
		WriteProblem(w, r, http.StatusBadRequest, "nothing_to_spend", "allocate at least one point")
	case errors.Is(err, service.ErrUpgradeMaxed):
		WriteProblem(w, r, http.StatusConflict, "maxed", "already at maximum level")
	case errors.Is(err, service.ErrStorehouseEmpty):
		WriteProblem(w, r, http.StatusConflict, "storehouse_empty", "the storehouse holds nothing yet")
	case errors.Is(err, service.ErrBadDestination):
		WriteProblem(w, r, http.StatusBadRequest, CodeBadRequest, err.Error())
	case errors.Is(err, service.ErrAlreadyInKingdom):
		WriteProblem(w, r, http.StatusConflict, "already_in_kingdom", "you already belong to a kingdom")
	case errors.Is(err, service.ErrNotInKingdom):
		WriteProblem(w, r, http.StatusConflict, "not_in_kingdom", "you are not in a kingdom")
	case errors.Is(err, service.ErrKingdomFull):
		WriteProblem(w, r, http.StatusConflict, "kingdom_full", "the kingdom is full")
	case errors.Is(err, service.ErrNotInvited):
		WriteProblem(w, r, http.StatusForbidden, "not_invited", "you have not been invited")
	case errors.Is(err, service.ErrNotPermitted):
		WriteProblem(w, r, http.StatusForbidden, "not_permitted", "your rank does not allow that")
	case errors.Is(err, service.ErrKingdomNameTaken):
		WriteProblem(w, r, http.StatusConflict, "name_taken", "that name or tag is taken")
	case errors.Is(err, service.ErrBadKingdomName):
		WriteProblem(w, r, http.StatusBadRequest, "invalid_name", err.Error())
	case errors.Is(err, service.ErrKingdomEmpty):
		WriteProblem(w, r, http.StatusConflict, "kingdom_empty", "that kingdom has no lords left")
	case errors.Is(err, service.ErrAlreadyRequested):
		WriteProblem(w, r, http.StatusConflict, "already_requested", "you have already asked to join")
	case errors.Is(err, service.ErrTooManyRequests):
		WriteProblem(w, r, http.StatusConflict, "too_many_requests", err.Error())
	case errors.Is(err, service.ErrRejoinCooldown):
		WriteProblem(w, r, http.StatusConflict, "rejoin_cooldown", err.Error())
	case errors.Is(err, service.ErrTargetInKingdom):
		WriteProblem(w, r, http.StatusConflict, "target_in_kingdom", "that lord already belongs to a kingdom")
	case errors.Is(err, service.ErrBadRole):
		WriteProblem(w, r, http.StatusBadRequest, "bad_role", "no such rank")
	case errors.Is(err, service.ErrBadPolicy):
		WriteProblem(w, r, http.StatusBadRequest, "bad_policy", "a kingdom is either open or joins by request")
	case errors.Is(err, service.ErrBadTarget):
		WriteProblem(w, r, http.StatusBadRequest, "bad_target", err.Error())
	case errors.Is(err, service.ErrNotAtCap), errors.Is(err, service.ErrLegacyMaxed):
		WriteProblem(w, r, http.StatusConflict, "legacy_unavailable", err.Error())
	case errors.Is(err, service.ErrAlreadyCollected):
		WriteProblem(w, r, http.StatusConflict, "already_collected", err.Error())
	case errors.Is(err, service.ErrQuestUnfinished):
		WriteProblem(w, r, http.StatusConflict, "quest_unfinished", err.Error())
	case errors.Is(err, service.ErrCartEmpty):
		WriteProblem(w, r, http.StatusConflict, "cart_empty", "no cart is waiting at your gate")
	case errors.Is(err, service.ErrCartLocked):
		WriteProblem(w, r, http.StatusForbidden, "locked", err.Error())
	case errors.Is(err, service.ErrCalendarBroken):
		WriteProblem(w, r, http.StatusConflict, "calendar_broken", err.Error())
	case errors.Is(err, service.ErrNothingToMend):
		WriteProblem(w, r, http.StatusConflict, "nothing_to_mend", err.Error())
	case errors.Is(err, service.ErrBadMend), errors.Is(err, service.ErrNotUsable):
		WriteProblem(w, r, http.StatusBadRequest, CodeBadRequest, err.Error())
	case errors.Is(err, service.ErrRoadEmpty):
		WriteProblem(w, r, http.StatusConflict, "nothing_to_claim", err.Error())
	case errors.Is(err, service.ErrGuideMoved):
		WriteProblem(w, r, http.StatusConflict, "guide_moved", err.Error())
	case errors.Is(err, service.ErrGuideNotReady):
		WriteProblem(w, r, http.StatusConflict, "guide_not_ready", err.Error())
	case errors.Is(err, service.ErrEnergyFull):
		WriteProblem(w, r, http.StatusConflict, "energy_full", err.Error())
	case errors.Is(err, service.ErrAlreadyClaimed), errors.Is(err, service.ErrHourlyClaimed):
		WriteProblem(w, r, http.StatusConflict, "already_claimed", err.Error())
	case errors.Is(err, service.ErrHourlyNone):
		WriteProblem(w, r, http.StatusConflict, "hourly_over", err.Error())
	case errors.Is(err, service.ErrNoFestival):
		WriteProblem(w, r, http.StatusConflict, "no_festival", err.Error())
	case errors.Is(err, service.ErrNoSeason):
		WriteProblem(w, r, http.StatusConflict, "no_season", err.Error())
	case errors.Is(err, service.ErrCharterLocked):
		WriteProblem(w, r, http.StatusForbidden, "charter_locked", err.Error())
	case errors.Is(err, service.ErrRoyalOpen):
		WriteProblem(w, r, http.StatusConflict, "royal_open", err.Error())
	case errors.Is(err, service.ErrCharterEmpty), errors.Is(err, service.ErrFestivalEmpty),
		errors.Is(err, service.ErrDeedsEmpty):
		WriteProblem(w, r, http.StatusConflict, "nothing_to_claim", err.Error())
	case errors.Is(err, service.ErrNotEnoughFavour):
		WriteProblem(w, r, http.StatusConflict, "not_enough_favour", "not enough favour")
	case errors.Is(err, service.ErrLastKing):
		WriteProblem(w, r, http.StatusConflict, "last_king", "promote another lord before you leave")
	case errors.Is(err, service.ErrSameKingdom):
		WriteProblem(w, r, http.StatusForbidden, "same_kingdom", "you cannot raid your own kingdom")
	case errors.Is(err, service.ErrBadName):
		WriteProblem(w, r, http.StatusBadRequest, "invalid_username", err.Error())
	case errors.Is(err, service.ErrSameName):
		WriteProblem(w, r, http.StatusConflict, "same_name", "that is already your name")
	case errors.Is(err, service.ErrStaleAction):
		// 409, not 400: the request was well-formed, the client is just behind.
		// It should re-read state rather than retry blindly.
		WriteProblem(w, r, http.StatusConflict, "stale_action", "out of sync — reload state")
	case errors.Is(err, auth.ErrPasswordPolicy):
		WriteProblem(w, r, http.StatusBadRequest, "weak_password", err.Error())
	default:
		a.log.Error("unhandled service error", "err", err, "path", r.URL.Path)
		WriteProblem(w, r, http.StatusInternalServerError, CodeInternal, "internal error")
	}
}

// --- auth ---

type registerReq struct {
	Username        string `json:"username"`
	Password        string `json:"password"`
	TZOffsetMinutes int    `json:"tz_offset_minutes"`
	// The phone's own identifier, optional; only a keyed hash of it is kept.
	Device string `json:"device"`
}

func (a *api) register(w http.ResponseWriter, r *http.Request) {
	var req registerReq
	if !decode(w, r, &req) {
		return
	}
	tok, err := a.s().Register(r.Context(), req.Username, req.Password, r.UserAgent(), req.TZOffsetMinutes)
	if err != nil {
		// A username that fails validation is a 400 with the reason, so the
		// signup form can say what is wrong instead of "invalid".
		if !isKnownServiceError(err) {
			WriteProblem(w, r, http.StatusBadRequest, "invalid_username", err.Error())
			return
		}
		a.fail(w, r, err)
		return
	}
	if id, err := uuid.Parse(tok.PlayerID); err == nil {
		a.s().SeeDevice(r.Context(), id, req.Device)
	}
	WriteJSON(w, http.StatusCreated, tok)
}

type loginReq struct {
	Username string `json:"username"`
	Password string `json:"password"`
	Device   string `json:"device"`
}

func (a *api) login(w http.ResponseWriter, r *http.Request) {
	var req loginReq
	if !decode(w, r, &req) {
		return
	}
	tok, err := a.s().Login(r.Context(), req.Username, req.Password, r.UserAgent())
	if err != nil {
		a.fail(w, r, err)
		return
	}
	if id, err := uuid.Parse(tok.PlayerID); err == nil {
		a.s().SeeDevice(r.Context(), id, req.Device)
	}
	WriteJSON(w, http.StatusOK, tok)
}

type refreshReq struct {
	RefreshToken string `json:"refresh_token"`
}

func (a *api) refresh(w http.ResponseWriter, r *http.Request) {
	var req refreshReq
	if !decode(w, r, &req) {
		return
	}
	tok, err := a.s().Refresh(r.Context(), req.RefreshToken, r.UserAgent())
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, tok)
}

// --- game ---

func (a *api) state(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	snap, err := a.s().GetState(r.Context(), pid)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, snap)
}

type collectReq struct {
	JobID     string `json:"job_id"`
	ActionSeq int64  `json:"action_seq"`
}

func (a *api) collect(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	var req collectReq
	if !decode(w, r, &req) {
		return
	}
	res, err := a.s().Collect(r.Context(), pid, req.JobID, req.ActionSeq)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, res)
}

type collectBatchReq struct {
	JobIDs    []string `json:"job_ids"`
	ActionSeq int64    `json:"action_seq"` // the sequence of the FIRST action
}

// collectBatch applies a run of taps in one request and one transaction.
//
// action_seq is per-player and monotonic, so collects can never overlap and the
// client had to send them one at a time -- ten taps meant ten round trips, which
// on a phone is most of a second of visible lag.
func (a *api) collectBatch(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	var req collectBatchReq
	if !decode(w, r, &req) {
		return
	}
	if len(req.JobIDs) == 0 {
		WriteProblem(w, r, http.StatusBadRequest, CodeBadRequest, "no actions")
		return
	}
	res, err := a.s().CollectBatch(r.Context(), pid, req.JobIDs, req.ActionSeq)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, res)
}

// --- shop and inventory ---

func (a *api) shop(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	v, err := a.s().GetShop(r.Context(), pid)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

type buyReq struct {
	Slot      int   `json:"slot"`
	ActionSeq int64 `json:"action_seq"`
}

func (a *api) buy(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	var req buyReq
	if !decode(w, r, &req) {
		return
	}
	res, err := a.s().Buy(r.Context(), pid, req.Slot, req.ActionSeq)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, res)
}

func (a *api) inventory(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	v, err := a.s().GetInventory(r.Context(), pid)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

type itemReq struct {
	ItemID    string `json:"item_id"`
	ActionSeq int64  `json:"action_seq"`
}

func (a *api) equip(w http.ResponseWriter, r *http.Request)   { a.equipSet(w, r, true) }
func (a *api) unequip(w http.ResponseWriter, r *http.Request) { a.equipSet(w, r, false) }

func (a *api) equipSet(w http.ResponseWriter, r *http.Request, on bool) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	var req itemReq
	if !decode(w, r, &req) {
		return
	}
	itemID, err := uuid.Parse(req.ItemID)
	if err != nil {
		WriteProblem(w, r, http.StatusBadRequest, CodeBadRequest, "item_id must be a uuid")
		return
	}
	var v *service.InventoryView
	if on {
		v, err = a.s().Equip(r.Context(), pid, itemID)
	} else {
		v, err = a.s().Unequip(r.Context(), pid, itemID)
	}
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

func (a *api) sell(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	var req itemReq
	if !decode(w, r, &req) {
		return
	}
	itemID, err := uuid.Parse(req.ItemID)
	if err != nil {
		WriteProblem(w, r, http.StatusBadRequest, CodeBadRequest, "item_id must be a uuid")
		return
	}
	res, err := a.s().Sell(r.Context(), pid, itemID, req.ActionSeq)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, res)
}

// --- army ---

func (a *api) army(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	v, err := a.s().GetArmy(r.Context(), pid)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

type seqReq struct {
	ActionSeq int64 `json:"action_seq"`
}

func (a *api) buySlot(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	var req seqReq
	if !decode(w, r, &req) {
		return
	}
	v, err := a.s().BuySlot(r.Context(), pid, req.ActionSeq)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

type recruitReq struct {
	Slot      int    `json:"slot"`
	TypeID    string `json:"type_id"`
	ActionSeq int64  `json:"action_seq"`
}

func (a *api) recruit(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	var req recruitReq
	if !decode(w, r, &req) {
		return
	}
	res, err := a.s().Recruit(r.Context(), pid, req.Slot, req.TypeID, req.ActionSeq)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, res)
}

type soldierReq struct {
	SoldierID string `json:"soldier_id"`
	ItemID    string `json:"item_id,omitempty"`
	ActionSeq int64  `json:"action_seq"`
}

// recruitOdds publishes the real tier chances. Required disclosure, and also
// the thing that makes a budget an informed decision rather than a guess.
func (a *api) recruitOdds(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	v, err := a.s().GetOdds(r.Context(), pid)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

type deviceReq struct {
	Token    string `json:"token"`
	Platform string `json:"platform"`
}

// registerDevice records where a player can be reached when they are away.
//
// No action_seq: registering a token changes nothing a player owns, and it is
// naturally idempotent — the same token twice is the same row.
func (a *api) registerDevice(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	var req deviceReq
	if !decode(w, r, &req) {
		return
	}
	if err := a.s().RegisterDevice(r.Context(), pid, req.Token, req.Platform); err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

// legacy is the offer to start again.
func (a *api) legacy(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	v, err := a.s().GetLegacy(r.Context(), pid)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

type seqOnlyReq struct {
	ActionSeq int64 `json:"action_seq"`
}

func (a *api) legacyBegin(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	var req seqOnlyReq
	if !decode(w, r, &req) {
		return
	}
	v, err := a.s().BeginLegacy(r.Context(), pid, req.ActionSeq)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

// collection is the wall of one-of-each.
func (a *api) collection(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	v, err := a.s().GetCollection(r.Context(), pid)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

// donateItem gives a piece of gear to the collection, permanently.
func (a *api) donateItem(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	var req itemActionReq
	if !decode(w, r, &req) {
		return
	}
	id, err := uuid.Parse(req.ItemID)
	if err != nil {
		WriteProblem(w, r, http.StatusBadRequest, CodeBadRequest, "item_id must be a uuid")
		return
	}
	v, err := a.s().DonateToCollection(r.Context(), pid, id, req.ActionSeq)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

// itemActionReq names one item and the sequence the action belongs to.
type itemActionReq struct {
	ItemID    string `json:"item_id"`
	ActionSeq int64  `json:"action_seq"`
}

type sellBatchReq struct {
	ItemIDs   []string `json:"item_ids"`
	ActionSeq int64    `json:"action_seq"`
}

// sellBatch clears several items in one action.
func (a *api) sellBatch(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	var req sellBatchReq
	if !decode(w, r, &req) {
		return
	}
	ids := make([]uuid.UUID, 0, len(req.ItemIDs))
	for _, raw := range req.ItemIDs {
		id, err := uuid.Parse(raw)
		if err != nil {
			WriteProblem(w, r, http.StatusBadRequest, CodeBadRequest, "item_ids must be uuids")
			return
		}
		ids = append(ids, id)
	}
	v, err := a.s().SellMany(r.Context(), pid, ids, req.ActionSeq)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

// leaderboard serves one ranked snapshot.
func (a *api) leaderboard(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	v, err := a.s().GetLeaderboard(r.Context(), pid, chi.URLParam(r, "board"))
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

// quests is today's board.
func (a *api) quests(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	v, err := a.s().GetQuests(r.Context(), pid)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

type questClaimReq struct {
	Slot      int   `json:"slot"`
	ActionSeq int64 `json:"action_seq"`
}

func (a *api) questClaim(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	var req questClaimReq
	if !decode(w, r, &req) {
		return
	}
	v, err := a.s().ClaimQuest(r.Context(), pid, req.Slot, req.ActionSeq)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

// daily is the login calendar.
func (a *api) daily(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	v, err := a.s().GetDaily(r.Context(), pid)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

// favourShop is what donating to your kingdom buys you personally.
func (a *api) favourShop(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	v, err := a.s().GetFavourShop(r.Context(), pid)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

type favourBuyReq struct {
	GoodID    string `json:"good_id"`
	ActionSeq int64  `json:"action_seq"`
}

func (a *api) favourBuy(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	var req favourBuyReq
	if !decode(w, r, &req) {
		return
	}
	v, err := a.s().BuyFavourGood(r.Context(), pid, req.GoodID, req.ActionSeq)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

// battleLog is the raid history, attacking and defending.
//
// The defending half is the point: every fight was already stored, and without
// this a player who was raided overnight logged in with less gold and nothing
// telling them why.
func (a *api) battleLog(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	v, err := a.s().GetBattleLog(r.Context(), pid)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

// battleReplay re-serves a stored fight so it can be watched again.
func (a *api) battleReplay(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	bid, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		WriteProblem(w, r, http.StatusBadRequest, CodeBadRequest, "battle id must be a uuid")
		return
	}
	rep, err := a.s().GetBattleReplay(r.Context(), pid, bid)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, rep)
}

// trainGone answers builds that still think a soldier can be levelled.
//
// Soldiers are fixed now: the tier they are recruited at is the rank they keep,
// which is what makes the tier ladder mean something — while training existed,
// four levels of it was enough for an epic to overtake a legendary. 410 rather
// than 404 so an older .ipa reports something true rather than "that route does
// not exist".
func (a *api) trainGone(w http.ResponseWriter, r *http.Request) {
	WriteProblem(w, r, http.StatusGone, "gone",
		"Soldiers no longer train — a soldier's tier is its rank, and it is fixed.")
}

// dismissSoldier releases a soldier and frees the slot for another roll.
func (a *api) dismissSoldier(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	var req soldierReq
	if !decode(w, r, &req) {
		return
	}
	sid, err := uuid.Parse(req.SoldierID)
	if err != nil {
		WriteProblem(w, r, http.StatusBadRequest, CodeBadRequest, "soldier_id must be a uuid")
		return
	}
	v, err := a.s().Dismiss(r.Context(), pid, sid, req.ActionSeq)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

func (a *api) equipSoldier(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	var req soldierReq
	if !decode(w, r, &req) {
		return
	}
	sid, err := uuid.Parse(req.SoldierID)
	if err != nil {
		WriteProblem(w, r, http.StatusBadRequest, CodeBadRequest, "soldier_id must be a uuid")
		return
	}
	iid, err := uuid.Parse(req.ItemID)
	if err != nil {
		WriteProblem(w, r, http.StatusBadRequest, CodeBadRequest, "item_id must be a uuid")
		return
	}
	v, err := a.s().EquipSoldier(r.Context(), pid, sid, iid)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

// --- attack ---

func (a *api) targets(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	v, err := a.s().GetTargets(r.Context(), pid)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

type attackReq struct {
	TargetID  string `json:"target_id"`
	ActionSeq int64  `json:"action_seq"`
	// Spends a revenge token instead of raiding normally: half energy, ignores
	// their shield and the per-pair cooldown, pays more.
	Revenge bool `json:"revenge,omitempty"`
}

func (a *api) attack(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	var req attackReq
	if !decode(w, r, &req) {
		return
	}
	tid, err := uuid.Parse(req.TargetID)
	if err != nil {
		WriteProblem(w, r, http.StatusBadRequest, CodeBadRequest, "target_id must be a uuid")
		return
	}
	res, err := a.s().Attack(r.Context(), pid, tid, req.ActionSeq, req.Revenge)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, res)
}

type spendStatsReq struct {
	Energy    int32 `json:"energy"`
	Attack    int32 `json:"attack"`
	Defense   int32 `json:"defense"`
	ActionSeq int64 `json:"action_seq"`
}

func (a *api) spendStats(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	var req spendStatsReq
	if !decode(w, r, &req) {
		return
	}
	snap, err := a.s().SpendStats(r.Context(), pid, req.Energy, req.Attack, req.Defense, req.ActionSeq)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, snap)
}

// --- estates ---

func (a *api) estates(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	v, err := a.s().GetEstates(r.Context(), pid)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

type estateBuyReq struct {
	ID        string `json:"id"`
	ActionSeq int64  `json:"action_seq"`
}

func (a *api) buyUpgrade(w http.ResponseWriter, r *http.Request) { a.estateBuy(w, r, true) }
func (a *api) buyHolding(w http.ResponseWriter, r *http.Request) { a.estateBuy(w, r, false) }

func (a *api) estateBuy(w http.ResponseWriter, r *http.Request, upgrade bool) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	var req estateBuyReq
	if !decode(w, r, &req) {
		return
	}
	var v *service.EstatesView
	var err error
	if upgrade {
		v, err = a.s().BuyUpgrade(r.Context(), pid, req.ID, req.ActionSeq)
	} else {
		v, err = a.s().BuyHolding(r.Context(), pid, req.ID, req.ActionSeq)
	}
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

// claimTaxGone answers builds from before continuous income that still ask to
// claim it. Estate income fills the storehouse now, carried in through
// /estates/storehouse/carry; 410 rather than 404 so an old .ipa says something
// true.
func (a *api) claimTaxGone(w http.ResponseWriter, r *http.Request) {
	WriteProblem(w, r, http.StatusGone, "gone",
		"Estate income fills the storehouse now: update the game to carry it in.")
}

// --- kingdom ---

func (a *api) kingdom(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	v, err := a.s().GetKingdom(r.Context(), pid)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

type foundReq struct {
	Name      string `json:"name"`
	Tag       string `json:"tag"`
	ActionSeq int64  `json:"action_seq"`
}

func (a *api) found(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	var req foundReq
	if !decode(w, r, &req) {
		return
	}
	v, err := a.s().Found(r.Context(), pid, req.Name, req.Tag, req.ActionSeq)
	if err != nil {
		// A bad name is a typed error now, mapped in fail like any other.
		// Every unknown error used to be answered as invalid_name with its own
		// text, which turned a database failure into a message about spelling.
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

type kingdomTargetReq struct {
	PlayerID  string `json:"player_id,omitempty"`
	KingdomID string `json:"kingdom_id,omitempty"`
	Role      string `json:"role,omitempty"`
	Name      string `json:"name,omitempty"`
	Amount    int64  `json:"amount,omitempty"`
	ID        string `json:"id,omitempty"`
	// Answering a request: a pointer, so a body that forgot it is refused
	// rather than read as a refusal.
	Accept    *bool  `json:"accept,omitempty"`
	Policy    string `json:"policy,omitempty"`
	ActionSeq int64  `json:"action_seq,omitempty"`
}

func (a *api) kingdomAction(w http.ResponseWriter, r *http.Request, name string) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	var req kingdomTargetReq
	if !decode(w, r, &req) {
		return
	}

	parse := func(s string) (uuid.UUID, bool) {
		id, err := uuid.Parse(s)
		if err != nil {
			WriteProblem(w, r, http.StatusBadRequest, CodeBadRequest, "expected a uuid")
			return uuid.Nil, false
		}
		return id, true
	}

	var v *service.KingdomView
	var err error
	switch name {
	case "invite":
		tid, ok := parse(req.PlayerID)
		if !ok {
			return
		}
		v, err = a.s().Invite(r.Context(), pid, tid)
	case "accept":
		kid, ok := parse(req.KingdomID)
		if !ok {
			return
		}
		v, err = a.s().AcceptInvite(r.Context(), pid, kid)
	case "leave":
		v, err = a.s().Leave(r.Context(), pid)
	case "role":
		tid, ok := parse(req.PlayerID)
		if !ok {
			return
		}
		v, err = a.s().SetRole(r.Context(), pid, tid, req.Role)
	case "donate":
		v, err = a.s().Donate(r.Context(), pid, req.Amount, req.ActionSeq)
	case "upgrade":
		v, err = a.s().BuyKingdomUpgrade(r.Context(), pid, req.ID)
	case "rename":
		v, err = a.s().RenameKingdom(r.Context(), pid, req.Name)
	case "join":
		kid, ok := parse(req.KingdomID)
		if !ok {
			return
		}
		v, err = a.s().Join(r.Context(), pid, kid)
	case "request/cancel":
		kid, ok := parse(req.KingdomID)
		if !ok {
			return
		}
		v, err = a.s().CancelRequest(r.Context(), pid, kid)
	case "decline":
		kid, ok := parse(req.KingdomID)
		if !ok {
			return
		}
		v, err = a.s().DeclineInvite(r.Context(), pid, kid)
	case "requests/answer":
		tid, ok := parse(req.PlayerID)
		if !ok {
			return
		}
		if req.Accept == nil {
			WriteProblem(w, r, http.StatusBadRequest, CodeBadRequest, "say whether to accept")
			return
		}
		v, err = a.s().AnswerRequest(r.Context(), pid, tid, *req.Accept)
	case "kick":
		tid, ok := parse(req.PlayerID)
		if !ok {
			return
		}
		v, err = a.s().Kick(r.Context(), pid, tid)
	case "policy":
		v, err = a.s().SetPolicy(r.Context(), pid, req.Policy)
	}
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

func isKnownServiceError(err error) bool {
	for _, e := range []error{
		service.ErrUsernameTaken, service.ErrBadCredentials, service.ErrPlayerBanned,
		service.ErrSessionInvalid, service.ErrNotFound, service.ErrJobLocked,
		service.ErrNotEnoughEnergy, service.ErrStaleAction, auth.ErrPasswordPolicy,
		service.ErrAlreadyPurchased, service.ErrNotEnoughGold, service.ErrInventoryFull,
		service.ErrShopStale, service.ErrItemEquipped, service.ErrNoSlot,
		service.ErrSlotsMaxed, service.ErrLevelTooLow, service.ErrAlreadyMaxed,
		service.ErrShielded, service.ErrOnCooldown, service.ErrSelfAttack,
		service.ErrTooNewToRaid, service.ErrNoRevenge,
		service.ErrNoStatPoints, service.ErrNothingToSpend,
		service.ErrUpgradeMaxed, service.ErrStorehouseEmpty,
		service.ErrAlreadyInKingdom, service.ErrNotInKingdom, service.ErrKingdomFull,
		service.ErrNotInvited, service.ErrNotPermitted, service.ErrKingdomNameTaken,
		service.ErrLastKing, service.ErrSameKingdom,
		service.ErrBadName, service.ErrSameName,
		service.ErrBadKingdomName, service.ErrKingdomEmpty, service.ErrAlreadyRequested,
		service.ErrTooManyRequests, service.ErrRejoinCooldown, service.ErrTargetInKingdom,
		service.ErrBadRole, service.ErrBadPolicy, service.ErrBadTarget,
	} {
		if errors.Is(err, e) {
			return true
		}
	}
	return false
}

type rerollReq struct {
	SoldierID string `json:"soldier_id"`
	ActionSeq int64  `json:"action_seq"`
}

// rerollSoldier draws a soldier's tier again, once.
func (a *api) rerollSoldier(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	var req rerollReq
	if !decode(w, r, &req) {
		return
	}
	sid, err := uuid.Parse(req.SoldierID)
	if err != nil {
		WriteProblem(w, r, http.StatusBadRequest, CodeBadRequest, "expected a uuid")
		return
	}
	res, err := a.s().RerollSoldier(r.Context(), pid, sid, req.ActionSeq)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, res)
}

// avatars lists the pickable portraits and which one is worn.
func (a *api) avatars(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	list, err := a.s().Avatars(r.Context(), pid)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, map[string]any{"avatars": list})
}

type avatarReq struct {
	Avatar    string `json:"avatar"`
	ActionSeq int64  `json:"action_seq"`
}

func (a *api) setAvatar(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	var req avatarReq
	if !decode(w, r, &req) {
		return
	}
	v, err := a.s().SetAvatar(r.Context(), pid, req.Avatar, req.ActionSeq)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

// A new name costs diamonds and is held to the same rules as signup.
type renameReq struct {
	Name      string `json:"name"`
	ActionSeq int64  `json:"action_seq"`
}

func (a *api) rename(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	var req renameReq
	if !decode(w, r, &req) {
		return
	}
	v, err := a.s().Rename(r.Context(), pid, req.Name, req.ActionSeq)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

// away is what happened to the city since `since` (unix seconds).
func (a *api) away(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	secs, err := strconv.ParseInt(r.URL.Query().Get("since"), 10, 64)
	if err != nil || secs <= 0 {
		WriteProblem(w, r, http.StatusBadRequest, CodeBadRequest, "since must be a unix time in seconds")
		return
	}
	v, err := a.s().GetAway(r.Context(), pid, time.Unix(secs, 0).UTC())
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

// --- account ---

type deleteAccountReq struct {
	Password string `json:"password"`
}

// deleteAccount removes the player for good, confirmed with their password.
// 204 on success: there is no one left to send a body to.
func (a *api) deleteAccount(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	var req deleteAccountReq
	if !decode(w, r, &req) {
		return
	}
	if err := a.s().DeleteAccount(r.Context(), pid, req.Password); err != nil {
		if errors.Is(err, service.ErrBadCredentials) {
			// Not 401: the session is fine, the password typed to confirm is not,
			// and a 401 would make the client refresh and then sign out.
			WriteProblem(w, r, http.StatusForbidden, "wrong_password", "that is not your password")
			return
		}
		a.fail(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// --- treasury ---
//
// Banked gold cannot be stolen. Depositing costs a fee, withdrawing is free.

type treasuryReq struct {
	Amount    int64 `json:"amount"`
	ActionSeq int64 `json:"action_seq"`
}

type carryReq struct {
	To        string `json:"to"`
	ActionSeq int64  `json:"action_seq"`
}

// carryStorehouse carries the storehouse to the purse or the vault.
func (a *api) carryStorehouse(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	var req carryReq
	if !decode(w, r, &req) {
		return
	}
	v, err := a.s().CarryStorehouse(r.Context(), pid, req.To, req.ActionSeq)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

func (a *api) deposit(w http.ResponseWriter, r *http.Request)  { a.treasuryMove(w, r, true) }
func (a *api) withdraw(w http.ResponseWriter, r *http.Request) { a.treasuryMove(w, r, false) }

func (a *api) treasuryMove(w http.ResponseWriter, r *http.Request, in bool) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	var req treasuryReq
	if !decode(w, r, &req) {
		return
	}
	var v any
	var err error
	if in {
		v, err = a.s().Deposit(r.Context(), pid, req.Amount, req.ActionSeq)
	} else {
		v, err = a.s().Withdraw(r.Context(), pid, req.Amount, req.ActionSeq)
	}
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

// kingdomsSearch finds kingdoms by name or tag, for a player looking for one.
func (a *api) kingdomsSearch(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	list, err := a.s().SearchKingdoms(r.Context(), pid, r.URL.Query().Get("q"))
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, map[string]any{"kingdoms": list})
}

// kingdomSearch turns a name into a player id so a king can invite someone.
func (a *api) kingdomSearch(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	list, err := a.s().SearchPlayers(r.Context(), pid, r.URL.Query().Get("q"))
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, map[string]any{"players": list})
}

// rerollShop buys a fresh set of offers with diamonds.
func (a *api) rerollShop(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	var req struct {
		ActionSeq int64 `json:"action_seq"`
	}
	if !decode(w, r, &req) {
		return
	}
	v, err := a.s().RerollShop(r.Context(), pid, req.ActionSeq)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

// --- the diamond store ---
//
// Sits on the Shop screen beside the Market. Diamonds never buy gold and never
// buy power; these are convenience and protection.

func (a *api) diamondStore(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	v, err := a.s().GetStore(r.Context(), pid)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

func (a *api) buyStoreGood(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	var req struct {
		Good string `json:"good"`
		// "diamonds" (the default) or "token": an energy potion or a protection
		// charter the player holds, in place of the price.
		Pay       string `json:"pay,omitempty"`
		ActionSeq int64  `json:"action_seq"`
	}
	if !decode(w, r, &req) {
		return
	}
	v, err := a.s().BuyStoreGood(r.Context(), pid, req.Good, req.Pay, req.ActionSeq)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

// autoEquip puts the best gear the player owns on the hero, or on everyone.
func (a *api) autoEquip(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	var req struct {
		Scope     string `json:"scope"`
		ActionSeq int64  `json:"action_seq"`
	}
	if !decode(w, r, &req) {
		return
	}
	v, err := a.s().AutoEquip(r.Context(), pid, req.Scope, req.ActionSeq)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}
