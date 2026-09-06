/**
 * The panel talks to the Go admin API, and it does so in two different ways for
 * two different reasons.
 *
 * Ordinary reads and writes go through this app's own route handlers, which
 * attach the session token server-side. The browser never sees a credential it
 * could leak.
 *
 * The live stream cannot work that way: a Route Handler is request/response and
 * cannot serve a protocol upgrade -- Next's own docs say so outright. But the
 * Next server DOES proxy an upgrade to an external rewrite destination
 * (router-server.js hands an upgrade with no matched output to proxyRequest,
 * which runs httpxy with ws:true). So the socket is opened SAME ORIGIN against
 * this app and rewritten to Go, which means the httpOnly cookie rides along on
 * the handshake and there is no second credential to mint, expire or redact
 * from a log.
 */
const ADMIN = process.env.EMPERORS_ADMIN_API ?? "http://127.0.0.1:8081";

/** @type {import('next').NextConfig} */
export default {
  reactStrictMode: true,
  // Several lockfiles live in this repo (client, server, admin), so Next cannot
  // infer which directory is the root.
  outputFileTracingRoot: import.meta.dirname,
  async rewrites() {
    return {
      // beforeFiles, so an accidental app/api/stream/route.ts can never shadow
      // the upgrade and turn the socket into a silent 405.
      beforeFiles: [{ source: "/api/stream", destination: `${ADMIN}/stream` }],
      afterFiles: [],
      fallback: [],
    };
  },
};
