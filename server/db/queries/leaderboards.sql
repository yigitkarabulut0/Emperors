-- name: SetMight :exec
UPDATE app.players SET might = $2 WHERE id = $1;

-- Rebuilds one board. Called inside a transaction with the delete below, so
-- readers never see a half-filled board.
-- name: ClearBoard :exec
DELETE FROM app.leaderboard_entries WHERE board = $1;

-- The ranking itself, done in the database rather than in Go: sorting every
-- player in application memory is the thing this table exists to avoid.
-- Bots are excluded — a board topped by the filler opponents would be a lie.
-- name: FillBoardMight :exec
INSERT INTO app.leaderboard_entries (board, rank, place, player_id, value)
SELECT 'might', row_number() OVER w, row_number() OVER w, id, might
FROM app.players
WHERE state = 'active' AND NOT is_bot AND might > 0
WINDOW w AS (ORDER BY might DESC, id)
ORDER BY might DESC, id
LIMIT sqlc.arg(lim);

-- name: FillBoardLevel :exec
INSERT INTO app.leaderboard_entries (board, rank, place, player_id, value)
SELECT 'level', row_number() OVER w, row_number() OVER w, id, level
FROM app.players
WHERE state = 'active' AND NOT is_bot
WINDOW w AS (ORDER BY level DESC, xp DESC, id)
ORDER BY level DESC, xp DESC, id
LIMIT sqlc.arg(lim);

-- Net worth: what they are carrying plus what they have banked. Treasury alone
-- would reward hoarding and purse alone would reward being about to be robbed.
-- name: FillBoardWealth :exec
INSERT INTO app.leaderboard_entries (board, rank, place, player_id, value)
SELECT 'wealth', row_number() OVER w, row_number() OVER w, id, gold + treasury_gold
FROM app.players
WHERE state = 'active' AND NOT is_bot
WINDOW w AS (ORDER BY (gold + treasury_gold) DESC, id)
ORDER BY (gold + treasury_gold) DESC, id
LIMIT sqlc.arg(lim);

-- name: ReadBoard :many
SELECT e.rank, e.place, e.value, p.display_name, p.avatar, p.level, p.kingdom_id,
       p.cos_frame, p.cos_title, p.cos_color, p.cos_crest, p.vip_points
FROM app.leaderboard_entries e
JOIN app.players p ON p.id = e.player_id
WHERE e.board = sqlc.arg(board)
ORDER BY e.rank
LIMIT sqlc.arg(lim);

-- name: MyRank :one
SELECT rank, place, value FROM app.leaderboard_entries
WHERE board = $1 AND player_id = $2;
