package realtime

import (
	"context"
	"errors"
	"net/http"
	"time"

	"github.com/coder/websocket"
	"github.com/google/uuid"
)

const (
	// pingEvery keeps the connection alive through any proxy that would
	// otherwise close it as idle, and is how a half-open socket is found.
	pingEvery = 20 * time.Second
	// pingTimeout is how long a pong may take before the lord is considered
	// gone.
	pingTimeout = 10 * time.Second
	// writeTimeout bounds a single frame write. The subscriber's buffer is what
	// absorbs a slow reader; this catches one that has stopped entirely.
	writeTimeout = 10 * time.Second
)

// StatusReauth is the close code that tells a client its token has run out and
// it should sign in again before reconnecting.
//
// 4001 is in the range reserved for the application, and it is deliberately NOT
// StatusPolicyViolation: a client that cannot tell "your token expired" from
// "you were dropped for being slow" either reconnects forever with a dead token
// or gives up on a socket it could have had back.
const StatusReauth websocket.StatusCode = 4001

// Serve upgrades one request and pumps frames until the lord goes away or their
// session runs out.
//
// room is the kingdom they are standing in, head the room's clock at the moment
// they arrived, and until when their token is good for. A lord with no kingdom
// never reaches here: there is no room to join, and the caller answers 409.
func (h *Hub) Serve(w http.ResponseWriter, r *http.Request, room uuid.UUID, head int64, until time.Time, origins []string) {
	// http.Server put read and write deadlines on this connection before the
	// handler ran. They survive the hijack, so without clearing them the socket
	// would die mid-conversation exactly one deadline after connecting. Must
	// happen before Accept, while the ResponseWriter still reaches the conn.
	rc := http.NewResponseController(w)
	_ = rc.SetReadDeadline(time.Time{})
	_ = rc.SetWriteDeadline(time.Time{})

	conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{
		// Websockets are not subject to CORS, so the origin check is the
		// server's job and nobody else's. The phone sends no Origin at all,
		// which is why an empty list is allowed through by the caller.
		OriginPatterns:  origins,
		CompressionMode: websocket.CompressionDisabled,
	})
	if err != nil {
		h.log.Warn("a hall handshake was refused", "err", err, "origin", r.Header.Get("Origin"))
		return
	}
	defer conn.CloseNow()

	ctx, cancel := context.WithCancel(context.WithoutCancel(r.Context()))
	defer cancel()

	// Subscribe BEFORE saying hello, so a line said while the hello is in
	// flight is queued rather than lost. The client may see a line it already
	// has, which is harmless: every frame carries the row's own id.
	s := h.subscribe(room)
	defer h.unsubscribe(s)

	frame, err := h.helloFrame(room, head)
	if err != nil {
		_ = conn.Close(websocket.StatusInternalError, "hello failed")
		return
	}
	if err := writeFrame(ctx, conn, frame); err != nil {
		return
	}

	// A reader is required even though the client says nothing: it is what
	// delivers pongs and notices a close. Anything a client sends is read and
	// thrown away -- a line is said over HTTP, where the rate limit, the filter
	// and the transaction are, and never over this socket.
	go func() {
		defer cancel()
		for {
			if _, _, err := conn.Read(ctx); err != nil {
				return
			}
		}
	}()

	ping := time.NewTicker(pingEvery)
	defer ping.Stop()

	var reauth <-chan time.Time
	if !until.IsZero() {
		t := time.NewTimer(time.Until(until))
		defer t.Stop()
		reauth = t.C
	}

	for {
		select {
		case <-ctx.Done():
			return
		case <-s.done:
			// Dropped for not keeping up. Say so in the close code: the client
			// reconnects and re-reads the room rather than carrying on with a
			// hall that has a hole in it.
			_ = conn.Close(websocket.StatusPolicyViolation, "too slow")
			return
		case <-reauth:
			_ = conn.Close(StatusReauth, "token expired")
			return
		case b := <-s.out:
			if err := writeFrame(ctx, conn, b); err != nil {
				return
			}
		case <-ping.C:
			pctx, pcancel := context.WithTimeout(ctx, pingTimeout)
			err := conn.Ping(pctx)
			pcancel()
			if err != nil {
				return
			}
		}
	}
}

func writeFrame(ctx context.Context, conn *websocket.Conn, b []byte) error {
	wctx, cancel := context.WithTimeout(ctx, writeTimeout)
	defer cancel()
	err := conn.Write(wctx, websocket.MessageText, b)
	if err != nil && !errors.Is(err, context.Canceled) {
		return err
	}
	return err
}
