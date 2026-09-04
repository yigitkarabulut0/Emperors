package main

import (
	"fmt"
	"net"
	"net/http"
	"os"
	"time"
)

// probeSelf is the container healthcheck. It deliberately hits /healthz, not
// /readyz: readiness goes 503 during a deploy drain on purpose, and a
// healthcheck that fails then would kill the container mid-drain.
func probeSelf() int {
	addr := os.Getenv("EMPERORS_ADDR")
	if addr == "" {
		addr = ":8080"
	}
	_, port, err := net.SplitHostPort(addr)
	if err != nil {
		fmt.Fprintf(os.Stderr, "healthcheck: bad EMPERORS_ADDR %q: %v\n", addr, err)
		return 2
	}

	client := &http.Client{Timeout: 3 * time.Second}
	resp, err := client.Get("http://127.0.0.1:" + port + "/healthz")
	if err != nil {
		fmt.Fprintf(os.Stderr, "healthcheck: %v\n", err)
		return 1
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		fmt.Fprintf(os.Stderr, "healthcheck: status %d\n", resp.StatusCode)
		return 1
	}
	return 0
}
