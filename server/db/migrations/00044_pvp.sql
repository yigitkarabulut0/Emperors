-- +goose Up
-- +goose StatementBegin

-- Rekabet (pvp.json): the Honour Arena's ladder, the Bounty Board's escrow and
-- the Throne a week of war crowns. The rules are in the balance; this is where
-- each lord stands in them.
--
-- LOCKING ORDER, everywhere in this feature: app.players (ascending uuid), then
-- app.arena (ascending player_id), then app.bounties (by id), then
-- app.kingdoms. Two lords fighting each other at the same instant would
-- otherwise deadlock -- the reason LockTwoPlayers already orders by id.

-- ============================================================================
-- The Honour Arena
-- ============================================================================
-- One row per lord who has ever fought. Everything here belongs to a SEASON:
-- when a season turns the rating moves half the way back to the start and the
-- milestones paid are forgotten, so a climb is worth making again. The roll is
-- done both ways -- lazily by UpsertArena on the lord's next fight, and in bulk
-- by the arena_reset job -- and each is a no-op after the other.
--
-- The day's tickets are NOT here. They live on app.players beside refills_day
-- and shop_rerolls_day, because the guard must be read from the row the fight
-- has already locked, in the same statement that spends it.
CREATE TABLE app.arena (
    player_id  uuid        PRIMARY KEY REFERENCES app.players(id) ON DELETE CASCADE,
    season     integer     NOT NULL CHECK (season >= 1),
    rating     integer     NOT NULL,
    peak       integer     NOT NULL,
    wins       integer     NOT NULL DEFAULT 0 CHECK (wins >= 0),
    losses     integer     NOT NULL DEFAULT 0 CHECK (losses >= 0),
    -- Signed: +3 is three won running, -2 is two lost.
    streak     integer     NOT NULL DEFAULT 0,
    -- A bit per rating milestone paid this season. A bigint's 63 bits are room
    -- for any table a balance could publish.
    milestones bigint      NOT NULL DEFAULT 0 CHECK (milestones >= 0),
    -- The ladder's tie-break: level ratings are ordered by who got there first.
    last_at    timestamptz NOT NULL DEFAULT now(),
    -- This ceiling is the other half of validate_pvp's "unreachable league"
    -- check: a league above it could never be entered.
    CONSTRAINT arena_rating_range CHECK (rating BETWEEN 0 AND 5000),
    CONSTRAINT arena_peak_sane    CHECK (peak >= rating)
);
-- The ladder, the rank lookup and the matchmaking band all read this one index.
CREATE INDEX arena_ladder_idx ON app.arena (season, rating DESC, last_at, player_id);

-- ============================================================================
-- The Bounty Board
-- ============================================================================
-- A price on a head, placed for gold and standing forty-eight hours.
--
-- The escrow is held HERE, in `remaining`, and in nobody's purse: the placer's
-- gold left when they placed it, and a claim mints exactly what this row gives
-- up. The fee left the economy at the same moment and is never re-minted --
-- that burn is the whole reason a bounty is a sink rather than a pipe between
-- two accounts.
--
-- Never deleted: closed, so the board's history stays readable and a claim's
-- foreign key always names the bounty it drew on.
CREATE TABLE app.bounties (
    -- Minted in Go, like a battle's: the row is referenced before it is read
    -- back, and a database-defaulted id once left every replay link dead.
    id         uuid        PRIMARY KEY,
    target_id  uuid        NOT NULL REFERENCES app.players(id) ON DELETE CASCADE,
    placed_by  uuid        NOT NULL REFERENCES app.players(id) ON DELETE CASCADE,
    amount     bigint      NOT NULL CHECK (amount > 0),
    remaining  bigint      NOT NULL CHECK (remaining >= 0),
    fee_burned bigint      NOT NULL CHECK (fee_burned >= 0),
    -- The plate it was placed from (pvp.bounty.plates), never free text: the
    -- client names a plate and the server prices it.
    plate      text        NOT NULL,
    placed_at  timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL,
    closed_at  timestamptz,
    closed_as  text CHECK (closed_as IN ('claimed', 'expired', 'revoked')),
    CONSTRAINT bounties_window      CHECK (expires_at > placed_at),
    CONSTRAINT bounties_remaining   CHECK (remaining <= amount),
    -- Never on yourself, as a constraint rather than a check in Go: no code
    -- path can produce one.
    CONSTRAINT bounties_not_self    CHECK (target_id <> placed_by),
    CONSTRAINT bounties_closed_pair CHECK ((closed_at IS NULL) = (closed_as IS NULL))
);
-- The expiry sweep and the board's two reads. Partial: a closed bounty is never
-- looked up by expiry or by target again.
CREATE INDEX bounties_open_idx   ON app.bounties (expires_at)                WHERE closed_at IS NULL;
CREATE INDEX bounties_target_idx ON app.bounties (target_id, placed_at DESC) WHERE closed_at IS NULL;
CREATE INDEX bounties_placer_idx ON app.bounties (placed_by, placed_at DESC);

-- What one claim carried off. The pair cap -- the same placer and claimer at
-- most twice a week -- is counted from here.
--
-- The other leash, four claims on one target a day and then a two-hour wait, is
-- NOT counted here: app.attack_cooldowns already keeps count_24h and last_at
-- per (attacker, defender), and a second counter for the same question is how
-- two numbers start disagreeing.
CREATE TABLE app.bounty_claims (
    id         bigserial   PRIMARY KEY,
    bounty_id  uuid        NOT NULL REFERENCES app.bounties(id) ON DELETE CASCADE,
    -- One claim per fight: the fight is what proves it, and a battle cannot pay
    -- two bounties.
    battle_id  uuid        NOT NULL UNIQUE REFERENCES app.battles(id) ON DELETE CASCADE,
    claimer_id uuid        NOT NULL REFERENCES app.players(id) ON DELETE CASCADE,
    target_id  uuid        NOT NULL REFERENCES app.players(id) ON DELETE CASCADE,
    placer_id  uuid        NOT NULL REFERENCES app.players(id) ON DELETE CASCADE,
    paid       bigint      NOT NULL CHECK (paid > 0),
    -- The UTC week, as the boards keep it (game/deeds.UWeek): the pair's cap.
    uweek      bigint      NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX bounty_claims_pair_idx   ON app.bounty_claims (placer_id, claimer_id, uweek);
CREATE INDEX bounty_claims_bounty_idx ON app.bounty_claims (bounty_id, created_at DESC);

-- ============================================================================
-- The Throne
-- ============================================================================
-- One reign per UTC week, the week's Monday as its key. The primary key IS the
-- idempotence: a settlement that ran twice inserts nothing the second time, and
-- no job needs to remember it did.
--
-- In app rather than admin: every authenticated request reads the decree off
-- the boost poll, and the client draws its banner from the snapshot.
CREATE TABLE app.throne (
    uweek       bigint      PRIMARY KEY,
    kingdom_id  uuid        NOT NULL REFERENCES app.kingdoms(id) ON DELETE CASCADE,
    emperor_id  uuid        NOT NULL REFERENCES app.players(id) ON DELETE CASCADE,
    -- What won it, scaled x100 as kingdom reputation is stored.
    reputation  bigint      NOT NULL,
    members     integer     NOT NULL CHECK (members >= 1),
    crowned_at  timestamptz NOT NULL DEFAULT now(),
    reign_ends  timestamptz NOT NULL,
    -- The one decree of the reign. Null until it is declared; the WHERE on
    -- DeclareDecree is what makes it once.
    decree_id   text,
    decree_at   timestamptz,
    decree_ends timestamptz,
    CONSTRAINT throne_reign  CHECK (reign_ends > crowned_at),
    CONSTRAINT throne_decree CHECK (
        (decree_id IS NULL AND decree_at IS NULL AND decree_ends IS NULL)
     OR (decree_id IS NOT NULL AND decree_at IS NOT NULL AND decree_ends > decree_at))
);
-- The boost poll's one read: is a decree in force now.
CREATE INDEX throne_decree_idx ON app.throne (decree_ends) WHERE decree_id IS NOT NULL;

-- Kingdom renown, counted per UTC week.
--
-- app.kingdoms.reputation is CUMULATIVE and decays 2% a day, so the kingdom
-- with the most of it on any Monday is the kingdom with the most of it on every
-- Monday, and the Throne would be over after week one. This is the number the
-- Throne is decided on (pvp.throne.measure = "week_gain"); the cumulative one
-- is still there for the alternative.
--
-- Written by service.awardReputation, the ONE place kingdom renown is minted,
-- in the same transaction and under the same per-member daily cap.
CREATE TABLE app.kingdom_week (
    kingdom_id uuid   NOT NULL REFERENCES app.kingdoms(id) ON DELETE CASCADE,
    uweek      bigint NOT NULL,
    reputation bigint NOT NULL DEFAULT 0 CHECK (reputation >= 0), -- scaled x100
    PRIMARY KEY (kingdom_id, uweek)
);
CREATE INDEX kingdom_week_board_idx ON app.kingdom_week (uweek, reputation DESC);

-- ============================================================================
-- What the new fights do to what was already here
-- ============================================================================
-- An arena fight is stored, watched and listed exactly as a raid is, and it is
-- NOT one: no gold moves, no energy is spent, no shield is written and no
-- revenge token is granted. Without this column CountRaidsSince would count
-- arena defences as raids, and a lord would come back to "you were robbed three
-- times" having lost nothing at all.
ALTER TABLE app.battles ADD COLUMN kind text NOT NULL DEFAULT 'raid'
    CHECK (kind IN ('raid', 'arena', 'bounty'));
CREATE INDEX battles_arena_idx ON app.battles (attacker_id, created_at DESC)
    WHERE kind = 'arena';

-- The day's arena tickets and refreshes, the day the first win paid, and the
-- day's bounties placed -- counted on the LORD'S own day
-- (players.reset_offset_minutes) beside refills_day (00028) and
-- shop_rerolls_day (00038), for the same reason: the guard is read from the row
-- the action has already locked and written in the same statement, so two taps
-- cannot both be the fifth fight.
ALTER TABLE app.players
    ADD COLUMN arena_day          date,
    ADD COLUMN arena_fights_used  smallint NOT NULL DEFAULT 0 CHECK (arena_fights_used >= 0),
    ADD COLUMN arena_refresh_used smallint NOT NULL DEFAULT 0 CHECK (arena_refresh_used >= 0),
    ADD COLUMN arena_first_win_on date,
    ADD COLUMN bounty_day         date,
    ADD COLUMN bounty_placed      smallint NOT NULL DEFAULT 0 CHECK (bounty_placed >= 0);

-- Where a piece of gear came from, so the panel and the Collection wall can say
-- so. The arena's milestone chests are the only gear Rekabet grants.
ALTER TABLE app.player_items DROP CONSTRAINT IF EXISTS player_items_acquired_from_check;
ALTER TABLE app.player_items ADD CONSTRAINT player_items_acquired_from_check
    CHECK (acquired_from IN (
        'shop', 'milestone', 'loot', 'recruit', 'admin',
        'mail', 'reward', 'promo', 'event', 'season', 'chest',
        'forge', 'expedition', 'campaign', 'boss', 'war', 'tutorial', 'arena'
    ));

-- The Throne's letters, the bounty's and the arena's. This list and the switch
-- in service.checkDraft are the same list in two languages: a kind missing from
-- either makes a crowning that writes its row, holds its cosmetics and sends
-- nothing at all.
ALTER TABLE app.mail DROP CONSTRAINT IF EXISTS mail_kind_check;
ALTER TABLE app.mail ADD CONSTRAINT mail_kind_check CHECK (kind IN (
    'system', 'admin', 'compensation', 'gift', 'largesse', 'referral',
    'promo', 'purchase', 'kingdom', 'event', 'season', 'winback', 'board',
    'arena', 'bounty', 'throne'));

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
DELETE FROM app.mail WHERE kind IN ('arena', 'bounty', 'throne');
DELETE FROM app.player_items WHERE acquired_from = 'arena';
ALTER TABLE app.player_items DROP CONSTRAINT IF EXISTS player_items_acquired_from_check;
ALTER TABLE app.player_items ADD CONSTRAINT player_items_acquired_from_check
    CHECK (acquired_from IN (
        'shop', 'milestone', 'loot', 'recruit', 'admin',
        'mail', 'reward', 'promo', 'event', 'season', 'chest',
        'forge', 'expedition', 'campaign', 'boss', 'war', 'tutorial'
    ));
ALTER TABLE app.mail DROP CONSTRAINT IF EXISTS mail_kind_check;
ALTER TABLE app.mail ADD CONSTRAINT mail_kind_check CHECK (kind IN (
    'system', 'admin', 'compensation', 'gift', 'largesse', 'referral',
    'promo', 'purchase', 'kingdom', 'event', 'season', 'winback', 'board'));
ALTER TABLE app.players
    DROP COLUMN IF EXISTS bounty_placed,
    DROP COLUMN IF EXISTS bounty_day,
    DROP COLUMN IF EXISTS arena_first_win_on,
    DROP COLUMN IF EXISTS arena_refresh_used,
    DROP COLUMN IF EXISTS arena_fights_used,
    DROP COLUMN IF EXISTS arena_day;
DELETE FROM app.battles WHERE kind <> 'raid';
DROP INDEX IF EXISTS app.battles_arena_idx;
ALTER TABLE app.battles DROP COLUMN IF EXISTS kind;
DROP TABLE IF EXISTS app.kingdom_week;
DROP TABLE IF EXISTS app.throne;
DROP TABLE IF EXISTS app.bounty_claims;
DROP TABLE IF EXISTS app.bounties;
DROP TABLE IF EXISTS app.arena;
-- +goose StatementEnd
