package httpx

import (
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"

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

func decode(w http.ResponseWriter, r *http.Request, into any) bool {
	r.Body = http.MaxBytesReader(w, r.Body, maxBodyBytes)
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields() // a typo'd field is a bug, not something to ignore
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

// fail maps a service error to a status code. Services never know about HTTP;
// this is the single place the translation happens.
func (a *api) fail(w http.ResponseWriter, r *http.Request, err error) {
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
	case errors.Is(err, service.ErrNotEnoughGold):
		WriteProblem(w, r, http.StatusConflict, "not_enough_gold", "not enough gold")
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
	case errors.Is(err, service.ErrShielded):
		WriteProblem(w, r, http.StatusConflict, "shielded", "that lord is under protection")
	case errors.Is(err, service.ErrOnCooldown):
		WriteProblem(w, r, http.StatusConflict, "on_cooldown", "you raided them too recently")
	case errors.Is(err, service.ErrSelfAttack):
		WriteProblem(w, r, http.StatusBadRequest, "self_attack", "you cannot attack yourself")
	case errors.Is(err, service.ErrNoStatPoints):
		WriteProblem(w, r, http.StatusConflict, "no_stat_points", "not enough stat points")
	case errors.Is(err, service.ErrNothingToSpend):
		WriteProblem(w, r, http.StatusBadRequest, "nothing_to_spend", "allocate at least one point")
	case errors.Is(err, service.ErrUpgradeMaxed):
		WriteProblem(w, r, http.StatusConflict, "maxed", "already at maximum level")
	case errors.Is(err, service.ErrNoTax):
		WriteProblem(w, r, http.StatusConflict, "no_tax", "nothing to collect yet")
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
	case errors.Is(err, service.ErrDonationCap):
		WriteProblem(w, r, http.StatusConflict, "donation_cap", "you have donated all you can today")
	case errors.Is(err, service.ErrLastKing):
		WriteProblem(w, r, http.StatusConflict, "last_king", "promote another lord before you leave")
	case errors.Is(err, service.ErrSameKingdom):
		WriteProblem(w, r, http.StatusForbidden, "same_kingdom", "you cannot raid your own kingdom")
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
	WriteJSON(w, http.StatusCreated, tok)
}

type loginReq struct {
	Username string `json:"username"`
	Password string `json:"password"`
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

func (a *api) train(w http.ResponseWriter, r *http.Request) {
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
	v, err := a.s().Train(r.Context(), pid, sid, req.ActionSeq)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
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
	res, err := a.s().Attack(r.Context(), pid, tid, req.ActionSeq)
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

func (a *api) claimTax(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	var req seqReq
	if !decode(w, r, &req) {
		return
	}
	res, err := a.s().ClaimTax(r.Context(), pid, req.ActionSeq)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, res)
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
		if !isKnownServiceError(err) {
			WriteProblem(w, r, http.StatusBadRequest, "invalid_name", err.Error())
			return
		}
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

type kingdomTargetReq struct {
	PlayerID  string `json:"player_id,omitempty"`
	KingdomID string `json:"kingdom_id,omitempty"`
	Role      string `json:"role,omitempty"`
	Amount    int64  `json:"amount,omitempty"`
	ID        string `json:"id,omitempty"`
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
		service.ErrNoStatPoints, service.ErrNothingToSpend,
		service.ErrUpgradeMaxed, service.ErrNoTax,
		service.ErrAlreadyInKingdom, service.ErrNotInKingdom, service.ErrKingdomFull,
		service.ErrNotInvited, service.ErrNotPermitted, service.ErrKingdomNameTaken,
		service.ErrDonationCap, service.ErrLastKing, service.ErrSameKingdom,
	} {
		if errors.Is(err, e) {
			return true
		}
	}
	return false
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


// --- treasury ---
//
// Banked gold cannot be stolen. Depositing costs a fee, withdrawing is free.

type treasuryReq struct {
	Amount    int64 `json:"amount"`
	ActionSeq int64 `json:"action_seq"`
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
