-- +goose Up
-- +goose StatementBegin

-- Legacy: the answer to what a level-60 player does next.
--
-- The design calls this "the actual terminal answer" and needs it by about day
-- 130: at the cap the job ladder stops, holdings stop, slots stopped at 37, and
-- the only remaining verb is raid-then-bank. Income growth can never outrun
-- sinks if the sink becomes the next run.
--
-- Reset the level, keep what gold bought. That is the whole trade, and the cost
-- is real because so much of this game is level-gated: the tax base collapses
-- from 993 gold an hour back to 42, the best job pays 2 instead of 1459, and
-- Fight, House and the upper holdings re-lock. What survives is everything the
-- player spent gold on -- gear, soldiers, estates, the family tree -- so the
-- climb back is fast, which is what makes doing it ten times plausible.
ALTER TABLE app.players
    ADD COLUMN legacy integer NOT NULL DEFAULT 0 CHECK (legacy >= 0);

-- +goose StatementEnd

-- +goose Down
ALTER TABLE app.players DROP COLUMN IF EXISTS legacy;
