/** @type {import('next').NextConfig} */
const config = {
  // The panel never talks to the game's admin API from the browser. Every call
  // goes through this app's own route handlers, so the session cookie stays
  // httpOnly and same-origin and no admin token is ever exposed to page scripts.
  //
  // It also holds no database credentials at all: the Go /admin API is the only
  // thing that touches Postgres, so the game's rules and invariants have exactly
  // one implementation.
  reactStrictMode: true,
  // The repo holds several lockfiles (client, server tooling, this panel), so
  // Next cannot infer which directory is the project root and warns on build.
  outputFileTracingRoot: import.meta.dirname,
};
export default config;
