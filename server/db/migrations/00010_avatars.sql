-- +goose Up
-- A player's portrait. Asynchronous PvP means you never meet an opponent, only
-- a row on a list, so a chosen face is most of the identity there is.
--
-- Stored as a plain slug rather than a foreign key: the set of portraits lives
-- in the balance document, which is versioned and hot-swappable, and a player
-- who picked a portrait that a later version drops should keep working. The
-- client falls back to the default when it cannot resolve one.
ALTER TABLE app.players ADD COLUMN avatar TEXT NOT NULL DEFAULT 'knight';

-- +goose Down
ALTER TABLE app.players DROP COLUMN avatar;
