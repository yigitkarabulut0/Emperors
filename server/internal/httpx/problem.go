// Package httpx holds the HTTP transport layer: router, middleware and the
// error envelope. Handlers stay thin — decode, delegate to a service, encode.
package httpx

import (
	"encoding/json"
	"log/slog"
	"net/http"

	"github.com/yigitkarabulut0/emperors/server/internal/obs"
)

// Problem is the single error shape every endpoint returns. `Code` is a stable
// machine-readable token the client switches on; `Message` is for humans and
// may change freely.
type Problem struct {
	Code      string `json:"code"`
	Message   string `json:"message"`
	RequestID string `json:"request_id,omitempty"`
}

const (
	CodeInternal     = "internal_error"
	CodeBadRequest   = "bad_request"
	CodeUnauthorized = "unauthorized"
	CodeNotFound     = "not_found"
	CodeUnavailable  = "unavailable"
)

// WriteJSON encodes v as JSON with the given status.
func WriteJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	if v == nil {
		return
	}
	if err := json.NewEncoder(w).Encode(v); err != nil {
		slog.Error("encode response", "err", err)
	}
}

// WriteProblem writes an error envelope, attaching the request id so a user's
// screenshot is enough to find the log line.
func WriteProblem(w http.ResponseWriter, r *http.Request, status int, code, msg string) {
	WriteJSON(w, status, Problem{Code: code, Message: msg, RequestID: obs.RequestID(r.Context())})
}
