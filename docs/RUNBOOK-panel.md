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

## Live ops (the ☀ page)

- **The hour.** Every hour rolls one event from `balance/liveops.json`'s hourly
  table and is written down the minute it begins (and the hour after, so the
  game can announce it). The page lists the day ahead and the day behind: an
  hour marked *predicted* has not been written yet and shows what the roll
  will say. Set an hour that has not begun, up to 24 hours ahead: force an
  event, make it a quiet hour, or give it back to the roll. The hour running
  cannot be changed, and the hour after a forced one still never repeats it.
- **Festivals.** Schedule one off its template, to start in so many hours or
  at a UTC time. It is frozen as the balance stands at that moment, runs its
  days, and no two may overlap (the server refuses; the form warns first). The
  game announces it 72 hours ahead. *End now* stops a running festival without
  paying anything more; one that ends by itself is closed within five minutes
  by the `festivals_close` job, which sends every place its prize and every lord
  what they left unclaimed, by letter. *Board* shows the standings.
- **The season.** Read-only: the running season's day, how many lords hold a
  Charter and a royal lane (and how many bought it with money), how they spread
  over the tiers, the renown top ten, and every close the `boards_close` job has
  written (the week's boards on Mondays, and a season's boards, nobility and
  leftover Charters when it ends).

## Rekabet (the ⚑ page)

Three panels, and two numbers on them are the ones worth watching.

**The Honour Arena.** The ladder as it stands, the census by league, and the
day's fights. The number to watch is **against a hired champion**: when a band
holds nobody the arena offers a champion built from the asker's own army
instead, and that champion never joins the ladder. High here is a population
problem, not a balance one — widen `pvp.arena.band_rating` or wait for lords,
do not touch K.

**The Bounty Board.** **Gold held on heads** is what is escrowed right now;
**gold burned this week** is what the crier's twenty per cent took out of the
economy. The board is a SINK, and those two together say whether it is working.
Under them, any placer-and-claimer pair who met more than once this week is
listed: that is the shape collusion takes, and `pair_claims_per_week` is what
bounds it. **withdraw** (designer) closes a price and gives the whole remainder
back to the lord who set it — the fee stays burned, because it left the economy
when the price was set.

**The Throne.** The reign, the week's race, and the reigns before it. It says
which measure it is crowned on (`week_gain` — renown gained in the week — or
`total`) and who a decree reaches (`realm` by default: every lord in the game).
**settle the closed week** (designer) runs the Monday settlement by hand, for
when the job was down; it crowns nobody twice, because the week is claimed in
`admin.period_closes` and the reign's own primary key refuses a second row.

What the page cannot do, deliberately: it cannot set a lord's rating, and it
cannot place a bounty. A ladder an operator can write into is a ladder that
measures nothing.

## Salonlar (the ⚖ page)

The halls, and the crown's two answers. Reading it is an **analyst's**; hiding a
line or silencing a tongue is a **moderator's**, and every one is audited with
the line's own id — a silence with no name against it is how a hall becomes a
rumour about the crown.

**The queue is oldest first.** The clock a moderator is judged by starts when
the line was said, not when somebody got round to it, so the oldest thing
waiting is always the next thing to do; the chip beside each row is that clock,
and it turns amber past an hour.

Two things are shown for every line: **what was typed** and **what the hall
showed**. The filter stars words out, and a moderator who only ever reads the
starred version cannot tell a slip from a campaign. **read the room** opens the
lines either side of it, because a sentence judged on its own is judged wrong.

`reports_to_hide` (3, from `social.json`) lines hide themselves from the room
before anybody is awake; what is left here is whether a line stays hidden and
whether the tongue behind it is silenced. **A silence is TIME** — an hour by the
hall's own rule, or a day — and never a fine. Lifting one forgets the strikes
behind it: a lord let back in starts again.

**Reported lords** is the second queue (`app.lord_reports`): a lord reported
from their own page — their name, their look, their play — where there is no
line to point at. Nothing hides itself here; a name is judged by a person. The
answers are the ones the desk already has (a silence, a letter, nothing), and
then **looked at**, which clears every open report against that lord so the same
name is not read again every morning.

What the page cannot do, deliberately: it cannot write a line into a hall, and
it cannot read a lord's letters. A crown that can speak as a lord is a crown
nobody can be told apart from.

## Boss & savaş (the 🐉 page)

The kingdoms' two shared fights: the beast standing against each of them, and
the week's wars. An **analyst's** read, and only a read — there is no lever on
the page at all, because every number on it is decided in the balance and the
Balance page is where a designer moves one.

**The kill rate is what this page exists for.** `boss.json`'s
`hp_per_might_bp` is calibrated against reference kingdoms so that a level-one
beast falls in **65–80 %** of cycles (`internal/game/boss/calibration_test.go`
fights whole cycles to prove it), and the figure on this page is the same
measurement taken in the wild. Over the band the beast is a formality; under it
the raid is a wall and kingdoms stop turning up. Either way the number to move
is the share, not the chests.

A beast's health is the **kingdom's own Might**, times the blows the kingdom
has, times that share — so a hall of five and a hall of twenty meet the same
siege. A kingdom whose bar barely moves is a kingdom whose lords are not
swinging, not one whose beast is too big: read *fighters* against *members*
before reading anything else.

**Byes** are the war's own warning. A bye is a kingdom nobody within one and a
half times its strength could be found for; a realm with many of them has a
spread `max_ratio_bp` cannot bridge, and the fix is that number or the number of
kingdoms, not the purse.

**Attacks on routed lords** is the other one. Beating a lord who has lost every
banner pays a quarter, so a large count is a kingdom farming the one lord who
cannot answer rather than fighting the ones who can — worth a look at the
kingdom, not a change to the rule, which is already a quarter.

Nothing here can be paid out by hand: the chests and the purse go by letter from
`boss_settle` and `war_settle`, and both are idempotent — the Jobs page is where
a run is watched, and running one twice pays nobody twice.

## Herald's Tidings (on the Billing page)

The rewarded advert's own panel sits under the takings, over the same window,
and appears **only on a realm that has adverts** — a server started without
`EMPERORS_ADMOB_UNIT` has an empty table and no panel, which is the state the
game ships in.

Four figures, and one of them is the one to watch:

- **adverts watched** — watches Google's signed callback actually paid, with
  how many were *started* beside them. A tap is a ticket; a started watch owes
  nobody anything.
- **came back** — paid over started. **This is the alarm.** It is normally
  high; when it collapses, the cause is one of three, in rising order of
  urgency: the SDK could not fill (AdMob's own dashboard says so), lords are
  closing the advert early, or **this server was unreachable when Google
  called** — check that `/v1/ads/admob/ssv` answers 200 from the open internet.
- **diamonds paid** — what the herald cost, and the average an advert paid.
  It should equal `commerce.ads.grant.diamonds` exactly; a drifting average
  means the balance moved mid-window, not that a lord was overpaid.
- **earned** — deliberately not a number. What the adverts *earned* is AdMob's
  report; this server never sees it, and a figure invented here would be
  invented money.

There is no lever: the allowance, the cooldown, the level and what one pays are
all `commerce.ads` in the balance, and the Balance page is where they move.
Turning adverts **on or off is not a panel action either** — it is
`EMPERORS_ADMOB_UNIT` in `infra/secrets.env` and a restart (`docs/RUNBOOK.md`).
