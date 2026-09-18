package httpx

import (
	"errors"
	"io"
	"net/http"

	"github.com/google/uuid"
)

// The daily loop's endpoints (service/cart.go, daily.go, weekly.go, road.go,
// guide.go, tokens.go). Each claim is asynchronous like a letter -- none moves
// action_seq -- except a flask, which is the lord's own sequenced action.

// decodeOptional reads a body that may be absent: none is the zero request.
// One that is there is read strictly, as every body is.
func decodeOptional(w http.ResponseWriter, r *http.Request, into any) bool {
	if r.ContentLength == 0 {
		return true
	}
	r.Body = http.MaxBytesReader(w, r.Body, maxBodyBytes)
	dec := jsonStrict(r.Body)
	if err := dec.Decode(into); err != nil && !errors.Is(err, io.EOF) {
		WriteProblem(w, r, http.StatusBadRequest, CodeBadRequest, "malformed request body")
		return false
	}
	return true
}

// player is the signed-in lord, or a 401 written.
func player(w http.ResponseWriter, r *http.Request) (uuid.UUID, bool) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
	}
	return pid, ok
}

// answer writes a service result, or its error.
func (a *api) answer(w http.ResponseWriter, r *http.Request, v any, err error) {
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

// --- the Tax Cart ---

func (a *api) cart(w http.ResponseWriter, r *http.Request) {
	if pid, ok := player(w, r); ok {
		v, err := a.s().GetCart(r.Context(), pid)
		a.answer(w, r, v, err)
	}
}

func (a *api) cartOpen(w http.ResponseWriter, r *http.Request) {
	pid, ok := player(w, r)
	var req struct{}
	if !ok || !decodeOptional(w, r, &req) {
		return
	}
	v, err := a.s().OpenCart(r.Context(), pid)
	a.answer(w, r, v, err)
}

// --- the calendar ---

type dailyClaimReq struct {
	// "", "diamonds", "pardon" or "anew": how a broken run is mended.
	Mend string `json:"mend"`
}

// dailyClaim takes today's square. No action_seq: the claim is once per local
// day in its own UPDATE, so a retry is safe. The body is optional, as it was
// for the builds before the calendar had a mend to say.
func (a *api) dailyClaim(w http.ResponseWriter, r *http.Request) {
	pid, ok := player(w, r)
	var req dailyClaimReq
	if !ok || !decodeOptional(w, r, &req) {
		return
	}
	v, err := a.s().ClaimDaily(r.Context(), pid, req.Mend)
	a.answer(w, r, v, err)
}

// --- the week's quests ---

func (a *api) weekly(w http.ResponseWriter, r *http.Request) {
	if pid, ok := player(w, r); ok {
		v, err := a.s().GetWeekly(r.Context(), pid)
		a.answer(w, r, v, err)
	}
}

type weeklyClaimReq struct {
	Slot int `json:"slot"`
}

func (a *api) weeklyClaim(w http.ResponseWriter, r *http.Request) {
	pid, ok := player(w, r)
	var req weeklyClaimReq
	if !ok || !decode(w, r, &req) {
		return
	}
	v, err := a.s().ClaimWeeklyTask(r.Context(), pid, req.Slot)
	a.answer(w, r, v, err)
}

type weeklyChestReq struct {
	Tier int `json:"tier"`
}

func (a *api) weeklyChest(w http.ResponseWriter, r *http.Request) {
	pid, ok := player(w, r)
	var req weeklyChestReq
	if !ok || !decode(w, r, &req) {
		return
	}
	v, err := a.s().ClaimWeeklyChest(r.Context(), pid, req.Tier)
	a.answer(w, r, v, err)
}

// --- the Victory Road ---

func (a *api) road(w http.ResponseWriter, r *http.Request) {
	if pid, ok := player(w, r); ok {
		v, err := a.s().GetRoad(r.Context(), pid)
		a.answer(w, r, v, err)
	}
}

type roadClaimReq struct {
	// One milestone; absent claims every one waiting.
	Index *int `json:"index"`
}

func (a *api) roadClaim(w http.ResponseWriter, r *http.Request) {
	pid, ok := player(w, r)
	var req roadClaimReq
	if !ok || !decodeOptional(w, r, &req) {
		return
	}
	v, err := a.s().ClaimRoad(r.Context(), pid, req.Index)
	a.answer(w, r, v, err)
}

// --- the guide ---

type guideAdvanceReq struct {
	Step string `json:"step"`
}

func (a *api) guideAdvance(w http.ResponseWriter, r *http.Request) {
	pid, ok := player(w, r)
	var req guideAdvanceReq
	if !ok || !decode(w, r, &req) {
		return
	}
	v, err := a.s().AdvanceGuide(r.Context(), pid, req.Step)
	a.answer(w, r, v, err)
}

func (a *api) guideSkip(w http.ResponseWriter, r *http.Request) {
	pid, ok := player(w, r)
	var req struct{}
	if !ok || !decodeOptional(w, r, &req) {
		return
	}
	v, err := a.s().SkipGuide(r.Context(), pid)
	a.answer(w, r, v, err)
}

func (a *api) guideBandit(w http.ResponseWriter, r *http.Request) {
	pid, ok := player(w, r)
	var req struct{}
	if !ok || !decodeOptional(w, r, &req) {
		return
	}
	v, err := a.s().FightBandit(r.Context(), pid)
	a.answer(w, r, v, err)
}

// --- flasks ---

type useTokenReq struct {
	Token     string `json:"token"`
	ActionSeq int64  `json:"action_seq"`
}

func (a *api) useToken(w http.ResponseWriter, r *http.Request) {
	pid, ok := player(w, r)
	var req useTokenReq
	if !ok || !decode(w, r, &req) {
		return
	}
	v, err := a.s().UseToken(r.Context(), pid, req.Token, req.ActionSeq)
	a.answer(w, r, v, err)
}
