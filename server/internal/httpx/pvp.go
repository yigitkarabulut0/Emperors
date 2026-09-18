package httpx

import (
	"net/http"

	"github.com/google/uuid"
)

// Rekabet (Wave 5): the Attack tab's other sub-tabs and the Throne.
//
// CAMPAIGN has no route: it opens in Wave 7, and a route that answers nothing
// is worse than no route at all.

// --- the Honour Arena ---

func (a *api) arena(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	v, err := a.s().GetArena(r.Context(), pid)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

func (a *api) arenaRefresh(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	var req seqReq
	if !decode(w, r, &req) {
		return
	}
	v, err := a.s().RefreshArena(r.Context(), pid, req.ActionSeq)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

type arenaFightReq struct {
	// An empty id names the hired champion, which has no row of its own.
	OpponentID string `json:"opponent_id"`
	ActionSeq  int64  `json:"action_seq"`
}

func (a *api) arenaFight(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	var req arenaFightReq
	if !decode(w, r, &req) {
		return
	}
	var oid uuid.UUID
	if req.OpponentID != "" {
		parsed, err := uuid.Parse(req.OpponentID)
		if err != nil {
			WriteProblem(w, r, http.StatusBadRequest, CodeBadRequest, "opponent_id must be a uuid, or empty for the hired champion")
			return
		}
		oid = parsed
	}
	res, err := a.s().ArenaFight(r.Context(), pid, oid, req.ActionSeq)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, res)
}

// --- the Bounty Board ---

func (a *api) bounties(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	v, err := a.s().GetBountyBoard(r.Context(), pid)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

// bountyPlaceReq names a PLATE, never an amount. The board's prices are the
// server's, and a body carrying "amount" is refused by strict decode -- which
// is exactly the guard we want.
type bountyPlaceReq struct {
	TargetID  string `json:"target_id"`
	Plate     string `json:"plate"`
	ActionSeq int64  `json:"action_seq"`
}

func (a *api) bountyPlace(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	var req bountyPlaceReq
	if !decode(w, r, &req) {
		return
	}
	tid, err := uuid.Parse(req.TargetID)
	if err != nil {
		WriteProblem(w, r, http.StatusBadRequest, CodeBadRequest, "target_id must be a uuid")
		return
	}
	res, err := a.s().PlaceBounty(r.Context(), pid, tid, req.Plate, req.ActionSeq)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, res)
}

type bountyClaimReq struct {
	BountyID  string `json:"bounty_id"`
	ActionSeq int64  `json:"action_seq"`
}

func (a *api) bountyClaim(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	var req bountyClaimReq
	if !decode(w, r, &req) {
		return
	}
	bid, err := uuid.Parse(req.BountyID)
	if err != nil {
		WriteProblem(w, r, http.StatusBadRequest, CodeBadRequest, "bounty_id must be a uuid")
		return
	}
	res, err := a.s().ClaimBounty(r.Context(), pid, bid, req.ActionSeq)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, res)
}

// --- the Throne ---

func (a *api) throne(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	v, err := a.s().GetThrone(r.Context(), pid)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

// throneDecreeReq carries NO action_seq. A decree writes nothing on the lord's
// own row, and moving the sequence would put the client's queued collects out
// of step for an edict that is not theirs at all.
type throneDecreeReq struct {
	Decree string `json:"decree"`
}

func (a *api) throneDecree(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	var req throneDecreeReq
	if !decode(w, r, &req) {
		return
	}
	v, err := a.s().DeclareDecree(r.Context(), pid, req.Decree)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}
