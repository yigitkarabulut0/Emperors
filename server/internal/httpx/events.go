package httpx

import (
	"net/http"

	"github.com/yigitkarabulut0/emperors/server/internal/service"
)

type eventsReq struct {
	Events []service.ClientEvent `json:"events"`
}

// events keeps what the phone saw that the server could not. Only the names
// and properties service/events.go lists are kept; the rest are counted as
// dropped, never refused, so an old build loses a measurement and not a batch.
func (a *api) events(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	var req eventsReq
	if !decode(w, r, &req) {
		return
	}
	res, err := a.s().RecordEvents(r.Context(), pid, req.Events)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, res)
}
