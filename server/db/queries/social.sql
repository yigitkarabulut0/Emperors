-- Sosyal (migration 00045): the kingdom's hall, the friends' roll and their
-- gift, the spyglass, the kingdom's aid and its shared goal.

-- ---------------------------------------------------------------------------
-- The hall
-- ---------------------------------------------------------------------------

-- The room as a lord arriving sees it: the newest lines first, a blocked lord's
-- lines left out, and a hidden line left out unless it was this lord's own (so
-- a lord whose line was hidden is not left wondering where it went).
-- name: ListChat :many
SELECT m.*, p.username, p.display_name, p.level, p.avatar, p.cos_frame, p.cos_title,
       p.cos_color, p.cos_crest, p.vip_points, p.kingdom_role
FROM app.chat_messages m
LEFT JOIN app.players p ON p.id = m.player_id
WHERE m.kingdom_id = sqlc.arg(kingdom_id)
  AND m.seq > sqlc.arg(after_seq)
  AND (m.hidden_at IS NULL OR m.player_id = sqlc.arg(me))
  AND (m.player_id IS NULL OR NOT EXISTS (
        SELECT 1 FROM app.blocks b
        WHERE b.player_id = sqlc.arg(me) AND b.blocked_id = m.player_id))
ORDER BY m.seq DESC
LIMIT sqlc.arg(lim);

-- One line said. The rate limit is not here: it is counted from the lord's own
-- rows in the window (CountChatSince), inside the same transaction.
-- name: InsertChat :one
INSERT INTO app.chat_messages (kingdom_id, player_id, kind, system_kind, body, shown, payload)
VALUES (sqlc.arg(kingdom_id), sqlc.narg(player_id), sqlc.arg(kind), sqlc.narg(system_kind),
        sqlc.arg(body), sqlc.arg(shown), sqlc.narg(payload))
RETURNING *;

-- What this lord has said in the window, which is the leash the balance calls
-- window_max. Counted from the rows themselves rather than from a counter, so
-- a restart never hands anybody a fresh bucket.
-- name: CountChatSince :one
SELECT count(*) FROM app.chat_messages
WHERE player_id = sqlc.arg(player_id) AND created_at >= sqlc.arg(since);

-- The last line this lord said, for the bucket's refill.
-- name: LastChatAt :one
SELECT created_at FROM app.chat_messages
WHERE player_id = sqlc.arg(player_id)
ORDER BY created_at DESC
LIMIT 1;

-- name: GetChatMessage :one
SELECT * FROM app.chat_messages WHERE id = sqlc.arg(id);

-- The room's clock, for a lord who has just arrived.
-- name: ChatHeadSeq :one
SELECT COALESCE(max(seq), 0)::bigint FROM app.chat_messages WHERE kingdom_id = sqlc.arg(kingdom_id);

-- How much a lord has not read: the tab's dot.
-- name: ChatUnread :one
SELECT count(*) FROM app.chat_messages m
WHERE m.kingdom_id = sqlc.arg(kingdom_id)
  AND m.seq > sqlc.arg(seen_seq)
  AND m.hidden_at IS NULL
  AND (m.player_id IS NULL OR m.player_id <> sqlc.arg(me))
  AND (m.player_id IS NULL OR NOT EXISTS (
        SELECT 1 FROM app.blocks b
        WHERE b.player_id = sqlc.arg(me) AND b.blocked_id = m.player_id));

-- name: MarkChatSeen :exec
UPDATE app.players SET chat_seen_seq = GREATEST(chat_seen_seq, sqlc.arg(seq))
WHERE id = sqlc.arg(player_id);

-- A report, once per lord per line. The count on the line is what hides it, and
-- the WHERE is the guard: a second report from the same lord does nothing.
-- name: ReportChat :one
INSERT INTO app.chat_reports (message_id, reporter_id, reason)
VALUES (sqlc.arg(message_id), sqlc.arg(reporter_id), sqlc.arg(reason))
ON CONFLICT DO NOTHING
RETURNING *;

-- Counts the report onto the line and hides it once enough lords have said so.
-- One statement: a line cannot be counted without being judged against the
-- threshold in the same breath.
-- name: BumpChatReports :one
UPDATE app.chat_messages
SET reports   = reports + 1,
    hidden_at = CASE WHEN hidden_at IS NULL AND reports + 1 >= sqlc.arg(to_hide)::int
                     THEN now() ELSE hidden_at END,
    hidden_by = CASE WHEN hidden_by IS NULL AND reports + 1 >= sqlc.arg(to_hide)::int
                     THEN 'reports' ELSE hidden_by END
WHERE id = sqlc.arg(id)
RETURNING *;

-- When this lord last reported anything, for the report cooldown.
-- name: LastReportAt :one
SELECT created_at FROM app.chat_reports
WHERE reporter_id = sqlc.arg(reporter_id)
ORDER BY created_at DESC
LIMIT 1;

-- The crown's hand: hide a line, or put it back.
-- name: SetChatHidden :one
UPDATE app.chat_messages
SET hidden_at = CASE WHEN sqlc.arg(hide)::bool THEN now() ELSE NULL END,
    hidden_by = CASE WHEN sqlc.arg(hide)::bool THEN sqlc.arg(by_whom)::text ELSE NULL END
WHERE id = sqlc.arg(id)
RETURNING *;

-- A silence, and the trail of it. Two statements, always written together:
-- the guard the hall reads is the column, and this is what the panel shows.
-- name: MutePlayer :one
UPDATE app.players
SET chat_muted_until = GREATEST(COALESCE(chat_muted_until, now()), sqlc.arg(until))
WHERE id = sqlc.arg(player_id)
RETURNING chat_muted_until;

-- name: RecordMute :one
INSERT INTO app.chat_mutes (player_id, until, reason, by_whom)
VALUES (sqlc.arg(player_id), sqlc.arg(until), sqlc.arg(reason), sqlc.arg(by_whom))
RETURNING *;

-- name: UnmutePlayer :exec
UPDATE app.players SET chat_muted_until = NULL, chat_strikes = 0 WHERE id = sqlc.arg(player_id);

-- A strike, counted inside the window and reset outside it, in one statement so
-- the count and the clock can never disagree.
-- name: StrikePlayer :one
UPDATE app.players
SET chat_strikes = CASE
        WHEN chat_strike_at IS NULL OR chat_strike_at < sqlc.arg(window_start)::timestamptz THEN 1
        ELSE chat_strikes + 1 END,
    chat_strike_at = now()
WHERE id = sqlc.arg(player_id)
RETURNING chat_strikes;

-- The lord agreed to the rules as they stand.
-- name: AcceptChatRules :one
UPDATE app.players SET chat_rules_version = sqlc.arg(version)
WHERE id = sqlc.arg(player_id)
RETURNING chat_rules_version;

-- The sweeper: the hall keeps what the balance says and no more.
-- name: SweepChat :execrows
DELETE FROM app.chat_messages WHERE created_at < sqlc.arg(before);

-- ---------------------------------------------------------------------------
-- Blocks
-- ---------------------------------------------------------------------------

-- name: BlockLord :exec
INSERT INTO app.blocks (player_id, blocked_id)
VALUES (sqlc.arg(player_id), sqlc.arg(blocked_id))
ON CONFLICT DO NOTHING;

-- name: UnblockLord :execrows
DELETE FROM app.blocks WHERE player_id = sqlc.arg(player_id) AND blocked_id = sqlc.arg(blocked_id);

-- name: ListBlocked :many
SELECT b.blocked_id, b.created_at, p.username, p.display_name, p.level, p.avatar
FROM app.blocks b
JOIN app.players p ON p.id = b.blocked_id
WHERE b.player_id = sqlc.arg(player_id)
ORDER BY b.created_at DESC;

-- name: CountBlocked :one
SELECT count(*) FROM app.blocks WHERE player_id = sqlc.arg(player_id);

-- Either way round: a block stops everything between the two lords, whoever
-- set it. Every social answer asks this one question.
-- name: BlockedBetween :one
SELECT EXISTS (
    SELECT 1 FROM app.blocks
    WHERE (player_id = sqlc.arg(a) AND blocked_id = sqlc.arg(b))
       OR (player_id = sqlc.arg(b) AND blocked_id = sqlc.arg(a))
);

-- ---------------------------------------------------------------------------
-- Friends
-- ---------------------------------------------------------------------------

-- The roll, with everything a row on the strip draws and the day's gift beside
-- it: whether I have sent to them today, and whether one of theirs is waiting.
-- name: ListFriends :many
SELECT p.id, p.username, p.display_name, p.level, p.avatar, p.might, p.last_seen_at,
       p.cos_frame, p.cos_title, p.cos_color, p.cos_crest, p.vip_points,
       p.privacy_online, k.name AS kingdom_name, f.since,
       EXISTS (SELECT 1 FROM app.gifts g
               WHERE g.from_id = sqlc.arg(me) AND g.to_id = p.id AND g.sent_on = sqlc.arg(today))
           AS gave_today,
       EXISTS (SELECT 1 FROM app.gifts g
               WHERE g.to_id = sqlc.arg(me) AND g.from_id = p.id AND g.taken_at IS NULL)
           AS gift_waiting
FROM app.friends f
JOIN app.players p ON p.id = CASE WHEN f.a = sqlc.arg(me) THEN f.b ELSE f.a END
LEFT JOIN app.kingdoms k ON k.id = p.kingdom_id
WHERE (f.a = sqlc.arg(me) OR f.b = sqlc.arg(me))
ORDER BY p.last_seen_at DESC
LIMIT sqlc.arg(lim);

-- name: CountFriends :one
SELECT count(*) FROM app.friends WHERE a = sqlc.arg(me) OR b = sqlc.arg(me);

-- name: AreFriends :one
SELECT EXISTS (
    SELECT 1 FROM app.friends
    WHERE a = LEAST(sqlc.arg(a)::uuid, sqlc.arg(b)::uuid)
      AND b = GREATEST(sqlc.arg(a)::uuid, sqlc.arg(b)::uuid)
);

-- name: FriendSince :one
SELECT since FROM app.friends
WHERE a = LEAST(sqlc.arg(a)::uuid, sqlc.arg(b)::uuid)
  AND b = GREATEST(sqlc.arg(a)::uuid, sqlc.arg(b)::uuid);

-- The pair is stored in id order, once. ON CONFLICT DO NOTHING makes accepting
-- twice cost nothing.
-- name: MakeFriends :execrows
INSERT INTO app.friends (a, b)
VALUES (LEAST(sqlc.arg(a)::uuid, sqlc.arg(b)::uuid), GREATEST(sqlc.arg(a)::uuid, sqlc.arg(b)::uuid))
ON CONFLICT DO NOTHING;

-- name: Unfriend :execrows
DELETE FROM app.friends
WHERE a = LEAST(sqlc.arg(a)::uuid, sqlc.arg(b)::uuid)
  AND b = GREATEST(sqlc.arg(a)::uuid, sqlc.arg(b)::uuid);

-- name: InsertFriendRequest :one
INSERT INTO app.friend_requests (from_id, to_id)
VALUES (sqlc.arg(from_id), sqlc.arg(to_id))
ON CONFLICT DO NOTHING
RETURNING *;

-- name: DeleteFriendRequest :execrows
DELETE FROM app.friend_requests WHERE from_id = sqlc.arg(from_id) AND to_id = sqlc.arg(to_id);

-- Both ways at once, which is what accepting does: if they asked me and I asked
-- them, one accept settles both.
-- name: DeleteFriendRequestsBetween :execrows
DELETE FROM app.friend_requests
WHERE (from_id = sqlc.arg(a) AND to_id = sqlc.arg(b))
   OR (from_id = sqlc.arg(b) AND to_id = sqlc.arg(a));

-- name: ListFriendRequests :many
SELECT r.from_id, r.created_at, p.username, p.display_name, p.level, p.avatar,
       p.might, p.cos_frame, p.cos_title, p.cos_color, p.cos_crest, p.vip_points,
       k.name AS kingdom_name
FROM app.friend_requests r
JOIN app.players p ON p.id = r.from_id
LEFT JOIN app.kingdoms k ON k.id = p.kingdom_id
WHERE r.to_id = sqlc.arg(me)
ORDER BY r.created_at DESC
LIMIT sqlc.arg(lim);

-- name: CountFriendRequestsTo :one
SELECT count(*) FROM app.friend_requests WHERE to_id = sqlc.arg(me);

-- name: HasFriendRequest :one
SELECT EXISTS (SELECT 1 FROM app.friend_requests
               WHERE from_id = sqlc.arg(from_id) AND to_id = sqlc.arg(to_id));

-- The day's requests, counted on the lord's own row in the same statement that
-- spends one, so two taps cannot both be the twentieth.
-- name: SpendFriendRequest :one
UPDATE app.players
SET friend_req_day = sqlc.arg(today),
    friend_reqs    = CASE WHEN friend_req_day = sqlc.arg(today) THEN friend_reqs + 1 ELSE 1 END
WHERE id = sqlc.arg(player_id)
  AND (friend_req_day IS DISTINCT FROM sqlc.arg(today) OR friend_reqs < sqlc.arg(per_day)::int)
RETURNING friend_reqs;

-- ---------------------------------------------------------------------------
-- The gift
-- ---------------------------------------------------------------------------

-- One a day to each friend, in the SENDER's own day: the primary key is the
-- rule, so a second gift is a conflict rather than a count.
-- name: SendGift :one
INSERT INTO app.gifts (from_id, to_id, sent_on, token)
VALUES (sqlc.arg(from_id), sqlc.arg(to_id), sqlc.arg(sent_on), sqlc.arg(token))
ON CONFLICT DO NOTHING
RETURNING *;

-- What is waiting for me, with who sent it.
-- name: ListWaitingGifts :many
SELECT g.from_id, g.sent_on, g.token, g.sent_at,
       p.username, p.display_name, p.level, p.avatar
FROM app.gifts g
JOIN app.players p ON p.id = g.from_id
WHERE g.to_id = sqlc.arg(me) AND g.taken_at IS NULL
ORDER BY g.sent_at
LIMIT sqlc.arg(lim);

-- Takes one gift. The WHERE is the guard: a gift already taken returns no row,
-- so a double tap grants nothing.
-- name: TakeGift :one
UPDATE app.gifts SET taken_at = now()
WHERE from_id = sqlc.arg(from_id) AND to_id = sqlc.arg(to_id) AND sent_on = sqlc.arg(sent_on)
  AND taken_at IS NULL
RETURNING *;

-- The day's take, counted on the taker's own row in the same statement that
-- spends one. Returns no row when the day is full, which is the guard.
-- name: SpendGiftTake :one
UPDATE app.players
SET gift_day    = sqlc.arg(today),
    gifts_taken = CASE WHEN gift_day = sqlc.arg(today) THEN gifts_taken + 1 ELSE 1 END
WHERE id = sqlc.arg(player_id)
  AND (gift_day IS DISTINCT FROM sqlc.arg(today) OR gifts_taken < sqlc.arg(per_day)::int)
RETURNING gifts_taken;

-- ---------------------------------------------------------------------------
-- The spyglass
-- ---------------------------------------------------------------------------

-- Pays for a look. The WHERE is the guard -- a lord who cannot afford the
-- spyglass buys nothing -- and the day's count is spent in the same statement,
-- so two taps cannot both be the tenth.
-- name: PayForSpy :one
UPDATE app.players
SET gold       = gold - sqlc.arg(cost),
    action_seq = sqlc.arg(action_seq),
    spy_day    = sqlc.arg(today),
    spy_used   = CASE WHEN spy_day = sqlc.arg(today) THEN spy_used + 1 ELSE 1 END
WHERE id = sqlc.arg(id) AND gold >= sqlc.arg(cost)
  AND (spy_day IS DISTINCT FROM sqlc.arg(today) OR spy_used < sqlc.arg(per_day)::int)
RETURNING *;

-- name: InsertSpyReport :one
INSERT INTO app.spy_reports (viewer_id, target_id, cost, report, expires_at)
VALUES (sqlc.arg(viewer_id), sqlc.arg(target_id), sqlc.arg(cost), sqlc.arg(report), sqlc.arg(expires_at))
RETURNING *;

-- The live report this lord holds on that one, if any.
-- name: LiveSpyReport :one
SELECT * FROM app.spy_reports
WHERE viewer_id = sqlc.arg(viewer_id) AND target_id = sqlc.arg(target_id)
  AND expires_at > now()
ORDER BY created_at DESC
LIMIT 1;

-- How many lords have looked at me today: what the raid page tells a lord, so
-- being scouted is always felt.
-- name: CountScoutedSince :one
SELECT count(DISTINCT viewer_id) FROM app.spy_reports
WHERE target_id = sqlc.arg(target_id) AND created_at >= sqlc.arg(since);

-- ---------------------------------------------------------------------------
-- The kingdom's aid
-- ---------------------------------------------------------------------------

-- name: AskForAid :one
INSERT INTO app.kingdom_aid (kingdom_id, asker_id, expires_at)
VALUES (sqlc.arg(kingdom_id), sqlc.arg(asker_id), sqlc.arg(expires_at))
RETURNING *;

-- The calls still standing in this kingdom, with who asked and whether I have
-- answered this one already.
-- name: ListAidCalls :many
SELECT a.id, a.asker_id, a.created_at, a.expires_at, a.answers,
       p.username, p.display_name, p.level, p.avatar, p.cos_frame, p.cos_title,
       p.cos_color, p.cos_crest, p.vip_points,
       EXISTS (SELECT 1 FROM app.kingdom_aid_answers ans
               WHERE ans.aid_id = a.id AND ans.helper_id = sqlc.arg(me)) AS answered
FROM app.kingdom_aid a
JOIN app.players p ON p.id = a.asker_id
WHERE a.kingdom_id = sqlc.arg(kingdom_id) AND a.expires_at > now()
  AND a.asker_id <> sqlc.arg(me)
  AND NOT EXISTS (SELECT 1 FROM app.blocks b
                  WHERE (b.player_id = sqlc.arg(me) AND b.blocked_id = a.asker_id)
                     OR (b.player_id = a.asker_id AND b.blocked_id = sqlc.arg(me)))
ORDER BY a.created_at DESC
LIMIT sqlc.arg(lim);

-- name: GetAidCall :one
SELECT * FROM app.kingdom_aid WHERE id = sqlc.arg(id);

-- Answering, once per lord per call: the primary key is the rule.
-- name: AnswerAid :one
INSERT INTO app.kingdom_aid_answers (aid_id, helper_id)
VALUES (sqlc.arg(aid_id), sqlc.arg(helper_id))
ON CONFLICT DO NOTHING
RETURNING *;

-- name: BumpAidAnswers :one
UPDATE app.kingdom_aid SET answers = answers + 1 WHERE id = sqlc.arg(id) RETURNING *;

-- The day's aid given, spent on the helper's own row.
-- name: SpendAid :one
UPDATE app.players
SET aid_day   = sqlc.arg(today),
    aid_given = CASE WHEN aid_day = sqlc.arg(today) THEN aid_given + 1 ELSE 1 END
WHERE id = sqlc.arg(player_id)
  AND (aid_day IS DISTINCT FROM sqlc.arg(today) OR aid_given < sqlc.arg(per_day)::int)
RETURNING aid_given;

-- The lord asked; the cooldown is the column, written in the same statement
-- that reads it.
-- name: MarkAidAsked :one
UPDATE app.players SET aid_asked_at = now()
WHERE id = sqlc.arg(player_id)
  AND (aid_asked_at IS NULL OR aid_asked_at < sqlc.arg(not_since)::timestamptz)
RETURNING aid_asked_at;

-- How many stacks this lord is holding: the live aid rows in app.player_boosts,
-- counted as PAIRS (a stack is one gold row and one experience row).
-- name: CountAidStacks :one
SELECT count(*) FROM app.player_boosts
WHERE player_id = sqlc.arg(player_id) AND source = 'aid'
  AND bucket = 'collect_income_bp' AND expires_at > now();

-- ---------------------------------------------------------------------------
-- The shared goal
-- ---------------------------------------------------------------------------

-- The kingdom's goal for a day, made once. The unique key is the rule: two
-- lords arriving at the same instant make one goal between them.
-- name: UpsertKingdomGoal :one
INSERT INTO app.kingdom_goals (kingdom_id, day, kind, target, members, ends_at, claim_until)
VALUES (sqlc.arg(kingdom_id), sqlc.arg(day), sqlc.arg(kind), sqlc.arg(target),
        sqlc.arg(members), sqlc.arg(ends_at), sqlc.arg(claim_until))
ON CONFLICT (kingdom_id, day) DO UPDATE SET kingdom_id = EXCLUDED.kingdom_id
RETURNING *;

-- name: GetKingdomGoal :one
SELECT * FROM app.kingdom_goals
WHERE kingdom_id = sqlc.arg(kingdom_id) AND day = sqlc.arg(day);

-- The goal a lord may still claim from: today's, or yesterday's while its claim
-- window is open.
-- name: LatestClaimableGoal :one
SELECT * FROM app.kingdom_goals
WHERE kingdom_id = sqlc.arg(kingdom_id) AND claim_until > now()
ORDER BY day DESC
LIMIT 1;

-- A lord's share of the work, and the goal's own bar, in one statement: the
-- kingdom's progress and the lord's part can never disagree about a tick.
-- name: AddGoalProgress :one
WITH part AS (
    INSERT INTO app.kingdom_goal_parts (goal_id, player_id, amount)
    VALUES (sqlc.arg(goal_id), sqlc.arg(player_id), sqlc.arg(amount))
    ON CONFLICT (goal_id, player_id) DO UPDATE
    SET amount = app.kingdom_goal_parts.amount + EXCLUDED.amount
    RETURNING amount
)
UPDATE app.kingdom_goals g
SET progress = LEAST(g.target, g.progress + sqlc.arg(amount))
WHERE g.id = sqlc.arg(goal_id) AND g.ends_at > now()
RETURNING g.*, (SELECT amount FROM part) AS mine;

-- name: GetGoalPart :one
SELECT * FROM app.kingdom_goal_parts
WHERE goal_id = sqlc.arg(goal_id) AND player_id = sqlc.arg(player_id);

-- Takes one chest, once. The bit is the guard and the WHERE is where it is
-- checked, so a second tap on the same chest returns no row and pays nothing.
-- name: ClaimGoalTier :one
UPDATE app.kingdom_goal_parts
SET claimed = claimed | sqlc.arg(bit)::int
WHERE goal_id = sqlc.arg(goal_id) AND player_id = sqlc.arg(player_id)
  AND (claimed & sqlc.arg(bit)::int) = 0
RETURNING *;

-- Who has done what, for the hall's list.
-- name: ListGoalParts :many
SELECT gp.player_id, gp.amount, gp.claimed, p.username, p.display_name, p.level,
       p.avatar, p.cos_frame, p.cos_title, p.cos_color, p.cos_crest, p.vip_points
FROM app.kingdom_goal_parts gp
JOIN app.players p ON p.id = gp.player_id
WHERE gp.goal_id = sqlc.arg(goal_id)
ORDER BY gp.amount DESC
LIMIT sqlc.arg(lim);

-- ---------------------------------------------------------------------------
-- The settings
-- ---------------------------------------------------------------------------

-- name: SetNotifyPrefs :one
UPDATE app.players
SET notif_raid    = sqlc.arg(notif_raid),
    notif_chat    = sqlc.arg(notif_chat),
    notif_mail    = sqlc.arg(notif_mail),
    notif_events  = sqlc.arg(notif_events),
    notif_friends = sqlc.arg(notif_friends),
    quiet_from    = sqlc.arg(quiet_from),
    quiet_to      = sqlc.arg(quiet_to)
WHERE id = sqlc.arg(player_id)
RETURNING *;

-- name: SetPrivacyPrefs :one
UPDATE app.players
SET privacy_profile  = sqlc.arg(privacy_profile),
    privacy_online   = sqlc.arg(privacy_online),
    privacy_requests = sqlc.arg(privacy_requests)
WHERE id = sqlc.arg(player_id)
RETURNING *;

-- ---------------------------------------------------------------------------
-- The desk (admin)
-- ---------------------------------------------------------------------------

-- The moderation queue: every reported line not yet judged, oldest first,
-- because the SLA is measured from when it was said.
-- name: ListReportedChat :many
SELECT m.*, p.username, p.display_name, p.level, p.state, p.chat_muted_until,
       k.name AS kingdom_name,
       (SELECT count(*) FROM app.chat_reports r WHERE r.message_id = m.id) AS report_count,
       (SELECT min(r.created_at) FROM app.chat_reports r WHERE r.message_id = m.id) AS first_report_at,
       (SELECT string_agg(DISTINCT r.reason, ',') FROM app.chat_reports r WHERE r.message_id = m.id) AS reasons
FROM app.chat_messages m
LEFT JOIN app.players p ON p.id = m.player_id
LEFT JOIN app.kingdoms k ON k.id = m.kingdom_id
WHERE m.reports > 0
ORDER BY m.created_at
LIMIT sqlc.arg(lim);

-- The lines around a reported one, so a moderator reads the room and not a
-- sentence on its own.
-- name: ChatContext :many
SELECT m.*, p.username, p.display_name
FROM app.chat_messages m
LEFT JOIN app.players p ON p.id = m.player_id
WHERE m.kingdom_id = sqlc.arg(kingdom_id)
  AND m.seq BETWEEN sqlc.arg(from_seq) AND sqlc.arg(to_seq)
ORDER BY m.seq;

-- Clears the reports on a line once the crown has judged it, so it leaves the
-- queue whichever way the judgement went.
-- name: ResolveChatReports :execrows
DELETE FROM app.chat_reports WHERE message_id = sqlc.arg(message_id);

-- name: ClearChatReportCount :one
UPDATE app.chat_messages SET reports = 0 WHERE id = sqlc.arg(id) RETURNING *;

-- name: ListMutes :many
SELECT m.*, p.username, p.display_name
FROM app.chat_mutes m
JOIN app.players p ON p.id = m.player_id
ORDER BY m.created_at DESC
LIMIT sqlc.arg(lim);

-- What the desk shows of the hall at a glance.
-- name: ChatStats :one
SELECT
    (SELECT count(*) FROM app.chat_messages cm WHERE cm.created_at >= sqlc.arg(since))::bigint AS said,
    (SELECT count(*) FROM app.chat_messages WHERE reports > 0)::bigint AS reported,
    (SELECT count(*) FROM app.chat_messages WHERE hidden_at IS NOT NULL)::bigint AS hidden,
    (SELECT count(*) FROM app.players WHERE chat_muted_until > now())::bigint AS muted,
    (SELECT count(*) FROM app.friends)::bigint AS friendships,
    (SELECT count(*) FROM app.gifts g WHERE g.sent_at >= sqlc.arg(since))::bigint AS gifts;

-- ============================================================================
-- A lord reported (app.lord_reports, migration 46)
-- ============================================================================

-- One lord saying another should not be here. Reporting the same lord for the
-- same thing twice while the first is still open changes nothing.
-- name: ReportLord :one
INSERT INTO app.lord_reports (target_id, reporter_id, reason)
VALUES (sqlc.arg(target_id), sqlc.arg(reporter_id), sqlc.arg(reason))
ON CONFLICT DO NOTHING
RETURNING *;

-- When this lord last reported anybody, line or lord: one cooldown covers
-- both, so a flood is a flood whichever button it comes through. No rows means
-- they have never reported -- read as such, not as a NULL time.
-- name: LastLordReportAt :one
SELECT created_at FROM app.lord_reports
WHERE reporter_id = sqlc.arg(reporter_id)
ORDER BY created_at DESC
LIMIT 1;

-- The desk's second queue: every lord with an open report, the oldest first,
-- with what is known of them and what they were reported for.
-- name: ListReportedLords :many
SELECT r.target_id,
       count(*)::bigint                       AS reports,
       min(r.created_at)::timestamptz         AS first_at,
       max(r.created_at)::timestamptz         AS last_at,
       string_agg(DISTINCT r.reason, ',')     AS reasons,
       p.username, p.display_name, p.level, p.state, p.avatar, p.chat_muted_until,
       k.name AS kingdom_name
FROM app.lord_reports r
JOIN app.players p ON p.id = r.target_id
LEFT JOIN app.kingdoms k ON k.id = p.kingdom_id
WHERE r.resolved_at IS NULL
GROUP BY r.target_id, p.username, p.display_name, p.level, p.state, p.avatar,
         p.chat_muted_until, k.name
ORDER BY min(r.created_at)
LIMIT sqlc.arg(lim);

-- The crown has judged this lord: every open report against them is answered,
-- whichever way it went.
-- name: ResolveLordReports :execrows
UPDATE app.lord_reports
SET resolved_at = now(), resolved_by = sqlc.arg(by)
WHERE target_id = sqlc.arg(target_id) AND resolved_at IS NULL;

-- name: CountReportedLords :one
SELECT count(DISTINCT target_id)::bigint FROM app.lord_reports WHERE resolved_at IS NULL;
