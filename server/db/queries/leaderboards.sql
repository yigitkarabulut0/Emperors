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
INSERT INTO app.leaderboard_entries (board, rank, player_id, value)
SELECT 'might', row_number() OVER (ORDER BY might DESC, id), id, might
FROM app.players
WHERE state = 'active' AND NOT is_bot AND might > 0
LIMIT sqlc.arg(lim);

-- name: FillBoardLevel :exec
INSERT INTO app.leaderboard_entries (board, rank, player_id, value)
SELECT 'level', row_number() OVER (ORDER BY level DESC, xp DESC, id), id, level
FROM app.players
WHERE state = 'active' AND NOT is_bot
LIMIT sqlc.arg(lim);

-- Net worth: what they are carrying plus what they have banked. Treasury alone
-- would reward hoarding and purse alone would reward being about to be robbed.
-- name: FillBoardWealth :exec
INSERT INTO app.leaderboard_entries (board, rank, player_id, value)
SELECT 'wealth', row_number() OVER (ORDER BY (gold + treasury_gold) DESC, id),
       id, gold + treasury_gold
FROM app.players
WHERE state = 'active' AND NOT is_bot
LIMIT sqlc.arg(lim);

-- name: ReadBoard :many
SELECT e.rank, e.value, p.display_name, p.avatar, p.level, p.kingdom_id
FROM app.leaderboard_entries e
JOIN app.players p ON p.id = e.player_id
WHERE e.board = sqlc.arg(board)
ORDER BY e.rank
LIMIT sqlc.arg(lim);

-- name: MyRank :one
SELECT rank, value FROM app.leaderboard_entries
WHERE board = $1 AND player_id = $2;
