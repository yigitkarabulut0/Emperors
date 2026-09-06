package adminstream

import (
	"context"
	"errors"
	"net/http"
	"time"

	"github.com/coder/websocket"
)

const (
	// pingEvery keeps the connection alive through any proxy that would
	// otherwise close it as idle, and is how a half-open socket is discovered.
	pingEvery = 20 * time.Second
	// pingTimeout is how long a pong may take before the panel is considered
	// gone.
	pingTimeout = 10 * time.Second
	// writeTimeout bounds a single frame write. The subscriber's buffer is what
	// absorbs a slow reader; this catches one that has stopped entirely.
	writeTimeout = 10 * time.Second
	// helloTimeout bounds building the first snapshot, which hits the database.
	helloTimeout = 10 * time.Second
)

// Serve upgrades one request and pumps frames until the panel goes away.
//
// me is whatever identity the caller resolved (the admin's username and role);
// it is echoed in the hello frame so the panel can gate its own controls without
// a second request.
func (h *Hub) Serve(w http.ResponseWriter, r *http.Request, me any, origins []string) {
	// http.Server put read and write deadlines on this connection before the
	// handler ran -- 30s and 60s on the admin listener. They survive the hijack,
	// so without clearing them the socket would die mid-conversation exactly one
	// minute after connecting. Must happen before Accept, while the
	// ResponseWriter still reaches the underlying conn.
	rc := http.NewResponseController(w)
	_ = rc.SetReadDeadline(time.Time{})
	_ = rc.SetWriteDeadline(time.Time{})

	conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{
		// Websockets are not subject to CORS, so the origin check is the
		// server's job and nobody else's.
		OriginPatterns: origins,
		// The panel is on a loopback tunnel and frames are small; compression
		// would cost CPU on both ends to save nothing.
		CompressionMode: websocket.CompressionDisabled,
	})
	if err != nil {
		h.log.Warn("admin stream handshake refused", "err", err, "origin", r.Header.Get("Origin"))
		return
	}
	defer conn.CloseNow()

	ctx, cancel := context.WithCancel(context.WithoutCancel(r.Context()))
	defer cancel()

	helloCtx, helloCancel := context.WithTimeout(ctx, helloTimeout)
	frame, err := h.helloFrame(helloCtx, me)
	helloCancel()
	if err != nil {
		h.log.Error("could not build the stream snapshot", "err", err)
		_ = conn.Close(websocket.StatusInternalError, "snapshot failed")
		return
	}

	// Subscribe BEFORE sending hello, so an event that happens while the
	// snapshot is being built is queued rather than lost. The panel may see a
	// change it already had in the snapshot, which is harmless -- every event is
	// an idempotent statement of what a thing now is.
	s := h.subscribe()
	defer h.unsubscribe(s)

	if err := writeFrame(ctx, conn, frame); err != nil {
		return
	}

	// A reader is required even though the panel says nothing: it is what
	// delivers pongs and notices a close.
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

	for {
		select {
		case <-ctx.Done():
			return
		case <-s.done:
			// Dropped for not keeping up. Say so in the close code: the panel
			// reconnects and takes a fresh snapshot rather than carrying on with
			// a view that has a hole in it.
			_ = conn.Close(websocket.StatusPolicyViolation, "too slow")
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
