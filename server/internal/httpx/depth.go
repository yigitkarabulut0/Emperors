package httpx

import (
	"net/http"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"
)

// PvE ve derinlik (Wave 7): the Conquest Campaign, the expeditions, the forge
// and the talent tree. The kingdom's beast and its wars are Wave 8's, and live
// in kingdom_war.go.

// --- the campaign ---

func (a *api) campaign(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	v, err := a.s().GetCampaign(r.Context(), pid)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

func (a *api) campaignChapter(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	v, err := a.s().GetChapter(r.Context(), pid, chi.URLParam(r, "id"))
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

type stageReq struct {
	ChapterID string `json:"chapter_id"`
	Stage     int    `json:"stage"`
	ActionSeq int64  `json:"action_seq"`
}

func (a *api) campaignFight(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	var req stageReq
	if !decode(w, r, &req) {
		return
	}
	v, err := a.s().FightStage(r.Context(), pid, req.ChapterID, req.Stage, req.ActionSeq)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

type chapterChestReq struct {
	ChapterID string `json:"chapter_id"`
	Index     int    `json:"index"`
	ActionSeq int64  `json:"action_seq"`
}

func (a *api) campaignChest(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	var req chapterChestReq
	if !decode(w, r, &req) {
		return
	}
	v, err := a.s().ClaimChapterChest(r.Context(), pid, req.ChapterID, req.Index, req.ActionSeq)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

// --- the expeditions ---

func (a *api) hunt(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	// A soldier may be named, and then every range on the page is quoted at
	// that soldier's rank.
	var soldier *uuid.UUID
	if s := r.URL.Query().Get("soldier"); s != "" {
		id, err := uuid.Parse(s)
		if err != nil {
			WriteProblem(w, r, http.StatusBadRequest, CodeBadRequest, "soldier is not an id")
			return
		}
		soldier = &id
	}
	v, err := a.s().GetHunt(r.Context(), pid, soldier)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

type huntSendReq struct {
	SoldierID string `json:"soldier_id"`
	FieldID   string `json:"field_id"`
}

func (a *api) huntSend(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	var req huntSendReq
	if !decode(w, r, &req) {
		return
	}
	sid, err := uuid.Parse(req.SoldierID)
	if err != nil {
		WriteProblem(w, r, http.StatusBadRequest, CodeBadRequest, "soldier_id is not an id")
		return
	}
	v, err := a.s().SendHunt(r.Context(), pid, sid, req.FieldID)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

type huntIDReq struct {
	ID        string `json:"id"`
	ActionSeq int64  `json:"action_seq"`
}

func (a *api) huntCollect(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	var req huntIDReq
	if !decode(w, r, &req) {
		return
	}
	id, err := uuid.Parse(req.ID)
	if err != nil {
		WriteProblem(w, r, http.StatusBadRequest, CodeBadRequest, "id is not an id")
		return
	}
	v, err := a.s().CollectHunt(r.Context(), pid, id, req.ActionSeq)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

func (a *api) huntRecall(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	var req huntIDReq
	if !decode(w, r, &req) {
		return
	}
	id, err := uuid.Parse(req.ID)
	if err != nil {
		WriteProblem(w, r, http.StatusBadRequest, CodeBadRequest, "id is not an id")
		return
	}
	v, err := a.s().RecallHunt(r.Context(), pid, id)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

// --- the forge ---

type forgeReq struct {
	ItemIDs   []string `json:"item_ids"`
	ActionSeq int64    `json:"action_seq"`
}

func (a *api) forge(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	var req forgeReq
	if !decode(w, r, &req) {
		return
	}
	ids := make([]uuid.UUID, 0, len(req.ItemIDs))
	for _, s := range req.ItemIDs {
		id, err := uuid.Parse(s)
		if err != nil {
			WriteProblem(w, r, http.StatusBadRequest, CodeBadRequest, "item_ids holds something that is not an id")
			return
		}
		ids = append(ids, id)
	}
	v, err := a.s().Forge(r.Context(), pid, ids, req.ActionSeq)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

// --- the talent tree ---

func (a *api) talents(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	v, err := a.s().GetTalents(r.Context(), pid)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

type talentBuyReq struct {
	TalentID  string `json:"talent_id"`
	ActionSeq int64  `json:"action_seq"`
}

func (a *api) talentBuy(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	var req talentBuyReq
	if !decode(w, r, &req) {
		return
	}
	v, err := a.s().BuyTalent(r.Context(), pid, req.TalentID, req.ActionSeq)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

func (a *api) talentRespec(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	var req seqReq
	if !decode(w, r, &req) {
		return
	}
	v, err := a.s().RespecTalents(r.Context(), pid, req.ActionSeq)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}
