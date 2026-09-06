-- +goose Up
-- +goose StatementBegin

-- The daily login calendar.
--
-- Diamonds have exactly one source today — five per level, 295 across a whole
-- 82-day climb to the cap — against three things to spend them on. The design
-- put more than half the intended free supply in this calendar and it was never
-- built, so the premium currency has been a number that goes up and stays up.
--
-- Stored as the local DAY the player last claimed, not a timestamp. "Have they
-- claimed today" is a question about a calendar square, and comparing dates in
-- the player's own timezone (reset_offset_minutes, captured at signup) is what
-- makes midnight mean midnight where they actually are.
ALTER TABLE app.players
    ADD COLUMN daily_streak     integer NOT NULL DEFAULT 0
                                CHECK (daily_streak >= 0),
    -- NULL means they have never claimed. Deliberately a date and not a
    -- timestamp: there is no meaningful sub-day precision here, and a date
    -- cannot drift by a second and skip somebody's Tuesday.
    ADD COLUMN daily_claimed_on date;

-- +goose StatementEnd

-- +goose Down
ALTER TABLE app.players
    DROP COLUMN IF EXISTS daily_streak,
    DROP COLUMN IF EXISTS daily_claimed_on;
