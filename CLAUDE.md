# Emperors — brief for anyone (or any agent) working in this repository

A 2D portrait mobile idle/RPG kingdom game. Godot 4.7 client, Go 1.27 server,
Postgres on Neon, Next.js live-ops panel. iPhone first.

**Read `docs/FRONTEND.md` before touching `client/`.** It is the screen-by-screen
reference. The client was rebuilt (September 2026) from seven reference
paintings: every icon, button, frame and portrait is a crop of `art/reference/`,
never redrawn; only live text is set in type. `art/SLICING_GUIDE.md` is the rule. This file is the short list of things that will silently break if you do
not know them.

---

## The five rules

**1. The client never computes a game number.**
The server sends resolved values — gold already multiplied by every bonus, XP
already through the bucket. The client renders them. There is no second
implementation of any formula, and adding one is how two screens start
disagreeing. Combat is the sharpest case: the client animates an event log the
server produced and never simulates a fight.

**2. A prediction is never written into the snapshot.**
`GameState.snapshot` holds only what the server confirmed. Optimistic taps go in
`_pending`, and what you see is `confirmed + replay(pending)`, computed on read
(`display_gold()`, `display_energy()`). Nothing needs rolling back because
nothing was written. If you find yourself editing `snapshot` directly, stop.

**3. Balance is data, and the generator owns it.**
`scripts/gen-balance.py` is the source of truth. `balance/*.json` are generated
from it and mirrored into `server/internal/gameconfig/seed/`. Editing the JSON
by hand gets overwritten on the next run.
And editing the JSON is not enough to change the game: the live rules come from
the newest published row in `admin.balance_versions`. See the deploy sequence.

**4. Every percentage bonus goes through `economy.ApplyBucket`.**
Bonuses are basis points, additive inside a bucket, and each bucket has a hard
cap applied exactly once. A second multiplication site anywhere and the caps stop
being caps. The one bucket that cannot use `ApplyBucket` — tax, because it scales
a stored rate rather than an amount — is clamped by hand in
`estates.TaxRate` against `gameconfig.MaxTaxIncomeBP`.
Gold and experience have two lanes, each with its own cap. What is earned for
good (upgrades, mastery, Legacy, the kingdom) goes in the permanent bucket;
whatever runs out (a server boost, an event, a draught, a letter's bonus) goes
in with `economy.AddTemp`, which files it in the timed lane (`...Temp`,
`bonus.go`). `ApplyBucket` still applies both, once. Never name a `Temp` bucket
directly — `lanes_test.go` fails the build if you do.

**5. `internal/game` stays pure.**
No `net/http`, no `database/sql`, no pgx, no `time.Now()`. Time arrives as a
parameter. `server/internal/game/purity_test.go` fails the build if you break
this. It is what makes the economy unit-testable with zero infrastructure.

---

## One way in for each kind of change

Each of these is the only path for what it does, and a test holds the line.
Adding a second path is how a number starts to lie.

| What | The one way | Held by |
|---|---|---|
| Diamonds move | a query in `diamond_sites_test.go`'s list, followed by `ledger.Diamonds` in the same function. Credits repay a refund debt first, in the same statement | `diamond_sites_test.go`; `itest` reconciles every balance against its ledger after each test |
| A reward is paid (letter, chest, event, purchase) | `service.grantBundle`, all or nothing, bag checked first. Money buys time, comfort and looks, never gold or power: `CheckReward(r, paid)` refuses the rest | `validate_rewards.go`, `rewards_test.go`, `mail_test.go` |
| An action is counted (quests, weekly tasks, boards, achievements) | `service.recordDeeds`, inside the action's transaction and inside a savepoint (`softStep`), so a counter that fails costs a tick, never the action | `softstep_test.go`, `deeds_test.go` |
| Work on a clock | a `Job` in `service/jobs_list.go`, claimed in `app.job_runs`, reading the live balance each run | `jobs_test.go` |
| The client reports what only it sees | `Api.track`, under a name `service/events.go` lists | `scripts/lint-client.py` |
| Energy comes from anything but the pool and a refill | a token with `energy_pct` (a flask), drunk through `service.UseToken`; money may never carry one, so bought energy stays the day's three refills. A friend's draught is that token (`flask_friend`) and nothing else: `SpendGiftTake` moves a COUNT, never energy | `validate_rewards.go` (`energy_pct` and `paid_ok` together are refused), `validate_social.go` (the gift token must be a flask, and never `paid_ok`) |
| A lord is given a timed bonus by another lord (the kingdom's aid) | an ordinary row in `app.player_boosts` with `source = 'aid'`, so it rides the timed lane every other boost rides and is capped where they are capped. There is no second cap and no second table | `validate_social.go` (aid that would eat the timed lane is refused), `itest` |
| The kingdom's shared goal moves | `service.recordDeeds`, the same savepoint every other counter rides: a goal that had its own reporting path would count what the deeds did not | `deeds_test.go`, `itest/social_test.go` |
| A lord talks to another lord | `service.SendChat`, which is where the filter, the burst, the window, the strikes and the transaction are. Nothing is said over the socket: `internal/realtime` carries statements about a room, never commands | `social_test.go`, `smoke-social.py` |
| A free daily source (cart, calendar, week, road) pays energy or experience | its grant in `retention.json`, measured by `scripts/pace.py` against casual level 60: each source prints its own pull, and the daily loop together is held to 5 % | `pace.py` exits 1 past it; `validate_retention.go` holds every grant to the reward rules |
| A server-wide timed bonus is felt (an operator's boost, the hour's event, a festival) | read off the boost poll (`service.Boosts`), never a query per request, and filed in `loadEffects` by `addLiveBonus`: gold and experience with `economy.AddTemp`, the rest into luck, renown or the market's discount, each bounded where it is spent. With no poll (a hand-built `Deps`: tests, tools) nothing is on | `itest/liveops_test.go`, `lanes_test.go` |
| A mile of the campaign is fought | `service.FightStage`, which sends `myArmy` (whoever is in the yard) against `campaign.Army` -- a garrison written down in campaign.json whose recorded Might `gameconfig.Validate` recomputes in Go. Its reward is a `RewardBundle` of WAGES through `grantBundle`; no battle row is kept, because `app.battles` is lords against lords | `validate_campaign.go`, `internal/game/campaign`'s own tests, `itest/depth_test.go` |
| A soldier is away | a row in `app.expeditions` with no `settled_at`: the row IS the absence. `service.mustBeHome` is the one question, asked by the reroll, the dismissal and a change of gear, and `myArmy` leaves them out of their lord's own battles while `theirArmy` keeps them on the walls | `itest/depth_test.go`, `hunt_roads.gd` |
| A blow lands on the kingdom's beast | `service.StrikeBoss`, which locks the lord and then the beast (`LockKingdomBoss`) and fights `boss.Blow` -- an ordinary `combat.SimulateWith` cut to the balance's rounds -- against the health the row holds at that instant. Nothing is paid at the blow: the chests go out by letter when the cycle closes, because what a lord earned depends on what the KINGDOM did | `internal/game/boss`'s tests and `calibration_test.go`, `itest/kingdom_war_test.go`, `scripts/smoke-boss.py` |
| A lord rides out in a kingdom war | `service.WarAttack`, which moves POINTS and nothing else: no gold, no energy, no shield applied or broken, no cooldown, no revenge, no renown, and not the lord's own `action_seq`. That list IS the feature, and `war_rules_test.go` reads the file and fails the build if it ever names one of them | `war_rules_test.go`, `itest/kingdom_war_test.go` |
| A fight's take is capped | `raidCap(attackerLevel)` in `service/attack.go`, its two numbers declared inside it. The raid's preview, the raid itself and the bounty board's payout all read that one function | `attack_test.go`'s `TestTheRaidCapIsWorkedOutInOnePlace` (reads the source) and `TestTheRaidCapIsTheNumberItWas` |
| A fight costs nothing but a rating (the Honour Arena) | `service/arena.go`, which names none of `ApplyBattleDefender`, `GrantRevenge`, `TouchCooldown`, `settleEnergy`, `raidTake`, `awardReputation` or `ShieldUntil`. A bounty hunt is the opposite: it is an ordinary raid through `service.raid`, with `raidOpts.Bounty` set | `arena_test.go` (reads the source), `itest/pvp_test.go` |
| A purchase is delivered | `service.deliverApple` (from the phone's verify and restore, and the App Store's notifications), once per transaction id, to the lord its `appAccountToken` names. Money is never refused: a paid product can hold nothing a full bag or an owned cosmetic could block, and a cosmetic already owned pays its `fallback_diamonds` | `validate_commerce.go`, `itest/purchases_test.go` |
| An advert pays | `service.CreditAdWatch`, from GOOGLE'S callback and nothing else. The tap (`StartAdWatch`) buys a TICKET -- a row in `app.ad_watches` -- and the client never says it watched one, because a client that could say that could say it a hundred times. The callback is trusted only by its ECDSA signature over its own RAW query (`internal/ads`), pays once per Google `transaction_id` (a unique index, not a check), and re-reads the day's allowance inside the lock. What it pays is `commerce.ads.grant`, through `CheckReward(r, paid=true)`: an advert buys what money buys, never gold or power | `validate_ads_test.go`, `internal/ads`'s tests, `itest/ads_test.go`, `scripts/smoke-ads.py` |

Wave 8's one sequenced action is the BLOW at the beast, because it spends
energy; the war attack is not, because nothing of the lord's own moves in one.
Neither is the advert's tap: it spends nothing of the lord's, and the diamonds
arrive by a callback the lord's session is not even part of.
Wave 6's two sequenced actions are the draught TAKEN (`/v1/friends/gift/take`) and
the spyglass (`/v1/lords/{id}/spy`): both spend something of the lord's own. The
gift SENT, a line said, an ask answered, a call for aid answered and every
settings change move nothing.

**No endpoint moves `action_seq` except the player's own sequenced action.** A
letter claimed, and later a purchase delivered, must not: the client's queued
collects are counting on the number. Such an answer's snapshot is taken with `GameState.adopt_async`.

---

## Deploying

Use the `deploy-hetzner` skill for the sequence. Two things that bite: skipping
`adminctl -cmd publish-balance` makes a changed number change nothing (the
database's active version beats the embedded seed), and `.env` /
`infra/secrets.env` are gitignored and must never enter git history.

The game API refuses JSON fields it does not know (strict decode). A client
that starts sending a new field needs the server that knows it deployed first:
on the VPS before the .ipa, and on any local API a capture runs against
(sign-in sending `device` stranded every capture on the boot screen once).

---

## Verifying

```sh
python3 scripts/gen-balance.py    # must be idempotent: run twice, no diff
python3 scripts/pace.py           # time-to-level under real session patterns
cd server && go build ./... && go vet ./... && go test -count=1 ./...
python3 scripts/lint-client.py     # compiles every script; layouts <-> assets <-> manifests
godot --path client -- --dev-login <user> <pw> --tab collect --capture shot.png --capture-after 6
```

`scripts/smoke-m*.py` drive the live HTTP API end to end. A capture run saves the
941x1672 design grid 1:1; put it beside `art/reference/<tab>.png` and look.

After a schema change: `cd server && sqlc generate`.

---

## Things that have already gone wrong here

Each of these shipped, and each was found late. They are the shape of mistake
this codebase invites.

- **A number that lies.** `tiers.json`'s `stat_mult` drifted to a completely
  different curve from the multiplier the game runs on. Nothing read it, so
  nothing caught it. Derived values are now generated, and `Validate` rejects a
  document where the readable number disagrees with the real one.
  The check written then covered only `stat_mult`; `pips`, `cumulative_xp`, a
  campaign captain's `gear`, and `energy.overflow` sat unguarded beside it until
  `dead_fields_test.go` went looking. **That test is the standing guard now:** a
  balance field no code outside `gameconfig` ever names fails the build, and the
  two ways out are to wire it up or to write down why it is inert. Before
  deploying a stricter validator, check the LIVE document against it
  (`EMPERORS_LIVE_DOC=<doc> go test -run TestTheLiveDocumentStillPasses ./internal/gameconfig/`)
  — a server that refuses to start is worse than the number it refused.
- **A field added to the generator, and the generator not re-run.** Reforging
  (since removed) shipped costing one gold, because a missing ratio reads as
  zero and zero prices the action at the floor rather than refusing to load.
  `Validate` now rejects zero where zero is meaningless.
- **A plate the painting shows EMPTY.** A mock-up's plate carries no words, so
  a rect measured off it can be wider than the plate, and a stamp drawn across
  it can be drawn across a name. Both shipped: the Throne's two ring plates were
  recorded 49 and 29 units too wide, and the war's ROUTED stamp sat over the
  lord's name and their Might. Measure the PLATE's own field, then set the
  longest real string in it and look.
- **A screen recomputing what the server already resolved.** The Estates tab
  called `estates.Derive` instead of `loadEffects`, so the rate it printed
  dropped kingdom upgrades, live events and the Legacy bonus. The purse was right
  and the screen was wrong, which is worse than the reverse.
- **A response field nothing read.** The server reported a crossed mastery
  milestone for months; the client never looked, so a permanent +20% payout
  arrived with no ceremony at all. Two more were found the same way in
  September 2026, each with a comment in the server stating the screen that
  would show it: `raid_cap` (the rules sheet printed the rate and not the
  ceiling, so nobody could see why 3% of a rich purse is not 3%) and
  `scouted_today` (sent so being looked over is felt where the raiding is, and
  said nowhere at all). Worse, six of `service/badges.go`'s own counters —
  `chat`, `friends`, `gifts`, `aid_calls`, `hunt`, `campaign`, and `decree` —
  reached the client and raised no bubble at all, so a lord was never told their
  hall had spoken, a friend had asked, a draught waited, aid was called for,
  their scout was home, or a chest was theirs. **`client/tests/badges_reach_the_rail.gd`
  is the standing guard:** it names every badge the server sends and the bubble
  it must move, so a new one cannot arrive unwired. When you add a field to a
  response, add the line that reads it in the same change — or do not add the
  field.
- **A page that would not scroll to its own body.** The Kingdom tab grows its
  page to the height its section reports. `help_section`'s two panels each
  answered with their own HEIGHT where the caller wanted the y they END at --
  the same number for a panel starting at zero, and not for the one after it --
  so the section reported the aid panel's height as the whole section's, the
  page never grew past the screen, and the calls for aid, every ANSWER and ASK
  FOR AID could not be reached at all. Nothing looked broken: the panel was
  drawn, just past a page that would not move. `client/tests/section_heights.gd`
  holds every section's reported height against what it actually drew.
- **A generated id that was never stored.** `InsertBattle` omitted the `id`
  column, so the database defaulted a different one and the `battle_id` handed to
  the client named no stored row. Only surfaced when something finally tried to
  read a battle back.

---

## The standard of work

The owner judges this game by how it looks and feels on the phone, and wants it
to look flawless. Every piece of work here meets that bar without being asked:

- **Spend what it takes.** Tokens, tool calls, renders, a second pass: never
  trade care for speed or brevity. A change is finished when it is right, not
  when it is plausible. Within the task, do what doing it properly obviously
  includes instead of asking whether to.
- **Look at it.** Nothing visible is done until it has been rendered and looked
  at beside its painting (`art/reference/<tab>.png`), zoomed in where it
  changed. "It compiles" and "the tests pass" are where checking starts. When a
  screen changes, redo its `art/qa/<screen>_sbs.png`.
- **Measure, don't eyeball.** Sizes, positions, weights and colours come off the
  painting: find the ink's extent and its pixel values (`art/tools/probe.py`,
  `zoom.py`), set the layout to them, render, and measure again until the two
  agree to a unit or two.
- **Fix the cause, at its source.** A flaw is usually a crop (an erase a few
  pixels short of the ink), a layout rect or a shared component. Fix the
  manifest, the layout or the component, never a patch on one screen that
  leaves the others wrong.
- **One object, one look.** A badge, plate, bar, empty slot or figure looks and
  behaves the same on every screen. When you fix one, find every other place
  the same flaw lives and fix those too.
- **Try the hard cases.** The longest real name (`balance/items.json`,
  `balance/jobs.json`), late-game numbers in the thousands, empty and zero
  states (a new player: no kingdom, no soldiers, 0 XP), both canvases (941×1672
  and 941×2040 with `--capture-size`), and the phone's top inset.
- **Prove it.** Each fix gets a test in `client/tests/` that fails on the old
  state (put the old asset or layout back and see it fail) and passes on the
  new. Then run every test and `scripts/lint-client.py`.
- **Stay inside the paintings' world.** New surfaces are built from the painted
  kit (`docs/FRONTEND.md`), in the paintings' type at their measured sizes;
  nothing flat, default or invented.
- **Say what you did.** Report what changed, what you checked, and what you
  decided not to do and why. A failure is reported as a failure.

---

## A document to read with care

`docs/design/economy.md` is the deepest document in the repo and parts of it are
now out of date; its header carries a table of exactly which parts and what
replaced them. Trust the table over the body.
