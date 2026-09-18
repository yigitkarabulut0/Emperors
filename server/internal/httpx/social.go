package httpx

import (
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"

	"github.com/yigitkarabulut0/emperors/server/internal/service"
)

// Sosyal (Wave 6): the kingdom's hall, the friends' roll, a rival's page and
// the spyglass, the kingdom's help, and the settings behind all of it.
//
// BOSS and WAR have no routes: they open in Wave 8, and a route that answers
// nothing is worse than no route at all.

// --- the hall ---

func (a *api) chat(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	after, _ := strconv.ParseInt(r.URL.Query().Get("after"), 10, 64)
	v, err := a.s().GetChat(r.Context(), pid, after)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

type chatSendReq struct {
	Body string `json:"body"`
}

func (a *api) chatSend(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	var req chatSendReq
	if !decode(w, r, &req) {
		return
	}
	v, err := a.s().SendChat(r.Context(), pid, req.Body)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

type chatReadReq struct {
	Seq int64 `json:"seq"`
}

func (a *api) chatRead(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	var req chatReadReq
	if !decode(w, r, &req) {
		return
	}
	if err := a.s().MarkChatRead(r.Context(), pid, req.Seq); err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, map[string]any{"seq": req.Seq})
}

type chatRulesReq struct {
	Version int `json:"version"`
}

func (a *api) chatAgree(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	var req chatRulesReq
	if !decode(w, r, &req) {
		return
	}
	v, err := a.s().AcceptChatRules(r.Context(), pid, req.Version)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, map[string]any{"version": v})
}

type chatReportReq struct {
	MessageID string `json:"message_id"`
	Reason    string `json:"reason"`
}

func (a *api) chatReport(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	var req chatReportReq
	if !decode(w, r, &req) {
		return
	}
	mid, err := uuid.Parse(req.MessageID)
	if err != nil {
		WriteProblem(w, r, http.StatusBadRequest, CodeBadRequest, "message_id must be a uuid")
		return
	}
	if err := a.s().ReportChat(r.Context(), pid, mid, req.Reason); err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, map[string]any{"reported": true})
}

// The Rules of the Hall as they stand, for a lord who has already agreed and
// wants to read them again (the settings' own row).
func (a *api) chatRulesRead(w http.ResponseWriter, r *http.Request) {
	if _, ok := PlayerID(r.Context()); !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	WriteJSON(w, http.StatusOK, map[string]any{"rules": a.s().TheRules(r.Context())})
}

// --- friends ---

func (a *api) friends(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	v, err := a.s().GetFriends(r.Context(), pid)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

type friendAskReq struct {
	Username string `json:"username"`
}

func (a *api) friendAsk(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	var req friendAskReq
	if !decode(w, r, &req) {
		return
	}
	v, err := a.s().RequestFriend(r.Context(), pid, req.Username)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

type friendAnswerReq struct {
	PlayerID string `json:"player_id"`
	Accept   bool   `json:"accept"`
}

func (a *api) friendAnswer(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	var req friendAnswerReq
	if !decode(w, r, &req) {
		return
	}
	other, err := uuid.Parse(req.PlayerID)
	if err != nil {
		WriteProblem(w, r, http.StatusBadRequest, CodeBadRequest, "player_id must be a uuid")
		return
	}
	if err := a.s().AnswerFriendRequest(r.Context(), pid, other, req.Accept); err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, map[string]any{"accepted": req.Accept})
}

type lordReq struct {
	PlayerID string `json:"player_id"`
}

func (a *api) friendRemove(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	var req lordReq
	if !decode(w, r, &req) {
		return
	}
	other, err := uuid.Parse(req.PlayerID)
	if err != nil {
		WriteProblem(w, r, http.StatusBadRequest, CodeBadRequest, "player_id must be a uuid")
		return
	}
	if err := a.s().Unfriend(r.Context(), pid, other); err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, map[string]any{"removed": true})
}

func (a *api) giftSend(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	var req lordReq
	if !decode(w, r, &req) {
		return
	}
	other, err := uuid.Parse(req.PlayerID)
	if err != nil {
		WriteProblem(w, r, http.StatusBadRequest, CodeBadRequest, "player_id must be a uuid")
		return
	}
	v, err := a.s().SendGift(r.Context(), pid, other)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

type giftTakeReq struct {
	PlayerID  string `json:"player_id"`
	ActionSeq int64  `json:"action_seq"`
}

func (a *api) giftTake(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	var req giftTakeReq
	if !decode(w, r, &req) {
		return
	}
	other, err := uuid.Parse(req.PlayerID)
	if err != nil {
		WriteProblem(w, r, http.StatusBadRequest, CodeBadRequest, "player_id must be a uuid")
		return
	}
	v, err := a.s().TakeGift(r.Context(), pid, other, req.ActionSeq)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

// --- a rival's page, and the spyglass ---

func (a *api) lord(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	target, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		WriteProblem(w, r, http.StatusBadRequest, CodeBadRequest, "id must be a uuid")
		return
	}
	v, err := a.s().GetRival(r.Context(), pid, target)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

func (a *api) lordSpy(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	target, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		WriteProblem(w, r, http.StatusBadRequest, CodeBadRequest, "id must be a uuid")
		return
	}
	var req seqReq
	if !decode(w, r, &req) {
		return
	}
	v, err := a.s().Spy(r.Context(), pid, target, req.ActionSeq)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

type lordReportReq struct {
	Reason string `json:"reason"`
}

// A lord reported as a lord (App Review 1.2's other half): their name, their
// look, their play. The hall's own rows carry a reported LINE.
func (a *api) lordReport(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	target, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		WriteProblem(w, r, http.StatusBadRequest, CodeBadRequest, "id must be a uuid")
		return
	}
	var req lordReportReq
	if !decode(w, r, &req) {
		return
	}
	if err := a.s().ReportLord(r.Context(), pid, target, req.Reason); err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, map[string]any{"reported": true})
}

// --- the kingdom's help ---

func (a *api) help(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	v, err := a.s().GetHelp(r.Context(), pid)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

func (a *api) helpAsk(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	v, err := a.s().AskAid(r.Context(), pid)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

type aidReq struct {
	AidID string `json:"aid_id"`
}

func (a *api) helpAnswer(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	var req aidReq
	if !decode(w, r, &req) {
		return
	}
	aid, err := uuid.Parse(req.AidID)
	if err != nil {
		WriteProblem(w, r, http.StatusBadRequest, CodeBadRequest, "aid_id must be a uuid")
		return
	}
	v, err := a.s().AnswerAid(r.Context(), pid, aid)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

type goalClaimReq struct {
	Index int `json:"index"`
}

func (a *api) helpClaim(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	var req goalClaimReq
	if !decode(w, r, &req) {
		return
	}
	v, err := a.s().ClaimGoalChest(r.Context(), pid, req.Index)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

// --- settings and blocks ---

func (a *api) settings(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	v, err := a.s().GetSettings(r.Context(), pid)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

func (a *api) settingsNotify(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	var req service.NotifyPrefs
	if !decode(w, r, &req) {
		return
	}
	v, err := a.s().SetNotifyPrefs(r.Context(), pid, req)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

func (a *api) settingsPrivacy(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	var req service.PrivacyPrefs
	if !decode(w, r, &req) {
		return
	}
	v, err := a.s().SetPrivacyPrefs(r.Context(), pid, req)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

func (a *api) blockAdd(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	var req lordReq
	if !decode(w, r, &req) {
		return
	}
	other, err := uuid.Parse(req.PlayerID)
	if err != nil {
		WriteProblem(w, r, http.StatusBadRequest, CodeBadRequest, "player_id must be a uuid")
		return
	}
	if err := a.s().BlockLord(r.Context(), pid, other); err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, map[string]any{"blocked": true})
}

func (a *api) blockRemove(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	var req lordReq
	if !decode(w, r, &req) {
		return
	}
	other, err := uuid.Parse(req.PlayerID)
	if err != nil {
		WriteProblem(w, r, http.StatusBadRequest, CodeBadRequest, "player_id must be a uuid")
		return
	}
	if err := a.s().UnblockLord(r.Context(), pid, other); err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, map[string]any{"blocked": false})
}

// --- the hall's socket ---

// realtime upgrades to a websocket and puts the lord in their kingdom's room.
//
// The token is in the HEADER, like every other call: a token in a query string
// is a token in a proxy log. Godot's WebSocketPeer sends handshake headers, so
// there is no reason to make an exception for this one route.
//
// A lord with no kingdom has no room to join and is answered 409 rather than
// being left holding a socket that will never carry anything.
func (a *api) realtime(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	hub := a.s().Hall
	if hub == nil {
		WriteProblem(w, r, http.StatusServiceUnavailable, "no_realtime", "the hall is not listening on this server")
		return
	}
	room, head, err := a.s().HallRoom(r.Context(), pid)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	// When the token runs out the socket closes with 4001 and the client signs
	// in again -- rather than holding a connection authorised by a token that
	// expired an hour ago.
	var until time.Time
	if raw, found := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer "); found {
		if e, okExp := a.verifier.(interface{ Expiry(string) time.Time }); okExp {
			until = e.Expiry(raw)
		}
	}
	hub.Serve(w, r, room, head, until, a.wsOrigins)
}
