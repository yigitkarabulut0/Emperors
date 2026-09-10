-- +goose Up
-- +goose StatementBegin

-- Joining a kingdom without being asked.
--
-- Kingdoms were invitation-only, and an invitation needs a king who already
-- knows your name: a new player had no way in, and a new king no way to be
-- found. A player can now search the kingdoms and join one, and each king
-- decides how: 'open' seats anyone while there is room, 'request' lets them ask
-- and the king or a captain answers.
ALTER TABLE app.kingdoms
    ADD COLUMN join_policy text NOT NULL DEFAULT 'open'
                           CHECK (join_policy IN ('open', 'request'));

-- A request is an invitation travelling the other way, so it lives in the same
-- table and under the same key: one row per (kingdom, player), whichever of the
-- two asked first. That is what makes "a king invites someone who has already
-- asked" a join rather than two rows that disagree.
ALTER TABLE app.kingdom_invites
    ADD COLUMN direction text NOT NULL DEFAULT 'invite'
                         CHECK (direction IN ('invite', 'request'));

-- "Who has asked to join us" -- the Lords tab's question.
CREATE INDEX kingdom_invites_kingdom_direction_idx
    ON app.kingdom_invites (kingdom_id, direction);

-- When the player last left or was removed from a kingdom. Open joining makes a
-- kingdom a shield -- join your attacker's kingdom and they cannot raid you --
-- and a removal meaningless, unless leaving costs a short wait.
ALTER TABLE app.players
    ADD COLUMN kingdom_left_at timestamptz;

-- Handing over the crown never moved leader_id, which is the column a rename is
-- permitted by. Every kingdom that changed kings kept its old one on paper.
UPDATE app.kingdoms k
SET leader_id = p.id
FROM app.players p
WHERE p.kingdom_id = k.id
  AND p.kingdom_role = 'king'
  AND k.leader_id IS DISTINCT FROM p.id;

-- +goose StatementEnd

-- +goose Down
DROP INDEX IF EXISTS app.kingdom_invites_kingdom_direction_idx;
DELETE FROM app.kingdom_invites WHERE direction = 'request';
ALTER TABLE app.kingdom_invites DROP COLUMN IF EXISTS direction;
ALTER TABLE app.kingdoms DROP COLUMN IF EXISTS join_policy;
ALTER TABLE app.players DROP COLUMN IF EXISTS kingdom_left_at;
