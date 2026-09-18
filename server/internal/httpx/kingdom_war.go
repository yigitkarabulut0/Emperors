package httpx

import (
	"net/http"

	"github.com/google/uuid"
)

// Krallik Boss ve Savaslari (Wave 8): the kingdom's beast and the kingdom's
// wars, both on the Kingdom tab.
//
// Four routes and no more. A blow at the beast is sequenced, because it spends
// energy; a war attack is not, because nothing of the lord's own moves in one
// (service/war.go says which and why) and the client's queued collects are
// counting on the number.

// --- the beast ---

func (a *api) boss(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	v, err := a.s().GetBoss(r.Context(), pid)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

func (a *api) bossHit(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	var req seqReq
	if !decode(w, r, &req) {
		return
	}
	v, err := a.s().StrikeBoss(r.Context(), pid, req.ActionSeq)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

// --- the wars ---

func (a *api) war(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	v, err := a.s().GetWar(r.Context(), pid)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

type warAttackReq struct {
	PlayerID string `json:"player_id"`
}

func (a *api) warAttack(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	var req warAttackReq
	if !decode(w, r, &req) {
		return
	}
	target, err := uuid.Parse(req.PlayerID)
	if err != nil {
		WriteProblem(w, r, http.StatusBadRequest, CodeBadRequest, "player_id is not an id")
		return
	}
	v, err := a.s().WarAttack(r.Context(), pid, target)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}
