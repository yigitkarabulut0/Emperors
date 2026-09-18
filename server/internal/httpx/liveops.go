package httpx

import "net/http"

// Live ops (liveops.json): the hourly event's gift, the festivals, the season's
// Royal Charter and the deeds. Every claim here is asynchronous, as a letter
// is: none moves action_seq, and the client adopts the snapshot with
// adopt_async.

// --- the hour ---

func (a *api) hourlyClaim(w http.ResponseWriter, r *http.Request) {
	pid, ok := player(w, r)
	var req struct{}
	if !ok || !decodeOptional(w, r, &req) {
		return
	}
	v, err := a.s().ClaimHourly(r.Context(), pid)
	a.answer(w, r, v, err)
}

// --- festivals ---

func (a *api) festivals(w http.ResponseWriter, r *http.Request) {
	if pid, ok := player(w, r); ok {
		v, err := a.s().GetEvents(r.Context(), pid)
		a.answer(w, r, v, err)
	}
}

type festivalClaimReq struct {
	// task | milestone, with its index; both absent claims everything done.
	Kind  string `json:"kind"`
	Index *int   `json:"index"`
}

func (a *api) festivalsClaim(w http.ResponseWriter, r *http.Request) {
	pid, ok := player(w, r)
	var req festivalClaimReq
	if !ok || !decodeOptional(w, r, &req) {
		return
	}
	v, err := a.s().ClaimFestival(r.Context(), pid, req.Kind, req.Index)
	a.answer(w, r, v, err)
}

// --- the season ---

func (a *api) season(w http.ResponseWriter, r *http.Request) {
	if pid, ok := player(w, r); ok {
		v, err := a.s().GetSeason(r.Context(), pid)
		a.answer(w, r, v, err)
	}
}

type seasonClaimReq struct {
	// One tier in one lane (free | royal); both absent claims every tier
	// reached in both.
	Tier *int   `json:"tier"`
	Lane string `json:"lane"`
}

func (a *api) seasonClaim(w http.ResponseWriter, r *http.Request) {
	pid, ok := player(w, r)
	var req seasonClaimReq
	if !ok || !decodeOptional(w, r, &req) {
		return
	}
	v, err := a.s().ClaimCharter(r.Context(), pid, req.Tier, req.Lane)
	a.answer(w, r, v, err)
}

func (a *api) seasonUnlock(w http.ResponseWriter, r *http.Request) {
	pid, ok := player(w, r)
	var req struct{}
	if !ok || !decodeOptional(w, r, &req) {
		return
	}
	v, err := a.s().OpenCharterWithDiamonds(r.Context(), pid)
	a.answer(w, r, v, err)
}

// --- the deeds ---

func (a *api) achievements(w http.ResponseWriter, r *http.Request) {
	if pid, ok := player(w, r); ok {
		v, err := a.s().GetAchievements(r.Context(), pid)
		a.answer(w, r, v, err)
	}
}

type achievementClaimReq struct {
	// One deed's tiers; absent claims every deed's.
	ID string `json:"id"`
}

func (a *api) achievementsClaim(w http.ResponseWriter, r *http.Request) {
	pid, ok := player(w, r)
	var req achievementClaimReq
	if !ok || !decodeOptional(w, r, &req) {
		return
	}
	v, err := a.s().ClaimAchievements(r.Context(), pid, req.ID)
	a.answer(w, r, v, err)
}
