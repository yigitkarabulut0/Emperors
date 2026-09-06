# Running the admin panel

The panel is a local tool. It is not deployed, and it does not need to be: it
runs on your laptop and watches whichever server you point it at.

**Point it at the right server.** Presence lives in the memory of the process
that serves the game's requests. Your phone talks to the Hetzner container, so a
panel pointed at a Go server running on your laptop will show an empty board
forever — and be correct to. Two ways to run:

## Against the deployed server (what you want to watch real players)

```sh
# One terminal: the tunnel. Leave it open.
ssh -N -L 8081:127.0.0.1:8081 -i ~/.ssh/emperors_deploy root@91.107.215.32

# Another: the panel.
cd admin
EMPERORS_ADMIN_API=http://127.0.0.1:8081 EMPERORS_ENV=prod npm run build
EMPERORS_ADMIN_API=http://127.0.0.1:8081 EMPERORS_ENV=prod npm run start
```

Open <http://localhost:3000>. The websocket rides the same tunnel, because the
browser opens it against the panel's own origin and Next rewrites it.

The tunnel is needed because `infra/compose.yml` publishes the admin listener on
loopback only. Nothing about the admin API is reachable from the internet, and
Caddy has no route to it.

## Against a local server (for development)

```sh
cd server && go run ./cmd/api        # both listeners, pointed at Neon
cd admin  && npm run build && npm run start
```

## Things worth knowing

- **Use `npm run start`, not `npm run dev`.** Client components do not hydrate
  under `next dev` on this machine: the HMR websocket fails
  `ERR_INVALID_HTTP_RESPONSE`. It was isolated with a trivial counter and a
  production build is unaffected. `dev` will look broken and is not.
- **`EMPERORS_ENV`** is what the badge in the top bar shows. Set it to `prod`
  when the tunnel is up, so you cannot forget which population you are looking at.
- **`EMPERORS_ADMIN_ORIGINS`** on the server is the websocket handshake
  allowlist, defaulting to `localhost:3000,127.0.0.1:3000`. Websockets are exempt
  from CORS, so this check is the only thing between a page on the internet and a
  live feed of who is playing.
