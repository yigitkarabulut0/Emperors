-- Dev tools (service/dev.go): a server that is not production only. They move
-- a lord's clocks, never the server's, so what they show is what a lord away for
-- that long would come back to.

-- name: WarpPlayerClocks :exec
UPDATE app.players
SET energy_updated_at   = energy_updated_at - make_interval(hours => sqlc.arg(hours)::int),
    storehouse_at       = storehouse_at - make_interval(hours => sqlc.arg(hours)::int),
    shield_until        = shield_until - make_interval(hours => sqlc.arg(hours)::int),
    luck_expires_at     = luck_expires_at - make_interval(hours => sqlc.arg(hours)::int),
    xp_boost_expires_at = xp_boost_expires_at - make_interval(hours => sqlc.arg(hours)::int),
    boost_until         = boost_until - make_interval(hours => sqlc.arg(hours)::int),
    kingdom_left_at     = kingdom_left_at - make_interval(hours => sqlc.arg(hours)::int),
    -- The Tax Cart's clock and the Golden Hour's, and when the lord was last
    -- seen and last welcomed back: a warp is an absence, and the welcome-back
    -- job (run from the dev tools) sees it as one.
    cart_at             = cart_at - make_interval(hours => sqlc.arg(hours)::int),
    frenzy_last_at      = frenzy_last_at - make_interval(hours => sqlc.arg(hours)::int),
    frenzy_until        = frenzy_until - make_interval(hours => sqlc.arg(hours)::int),
    frenzy_ready_at     = frenzy_ready_at - make_interval(hours => sqlc.arg(hours)::int),
    last_seen_at        = last_seen_at - make_interval(hours => sqlc.arg(hours)::int),
    winback_at          = winback_at - make_interval(hours => sqlc.arg(hours)::int),
    -- Day markers move by whole days: the day's reward, refills, rerolls, the
    -- Stipend's share, Royal Favour's gift and the Golden Hour's count come
    -- round again.
    frenzy_day          = frenzy_day - (sqlc.arg(hours)::int / 24),
    daily_claimed_on    = daily_claimed_on - (sqlc.arg(hours)::int / 24),
    refills_day         = refills_day - (sqlc.arg(hours)::int / 24),
    shop_rerolls_day    = shop_rerolls_day - (sqlc.arg(hours)::int / 24),
    stipend_claimed     = stipend_claimed - (sqlc.arg(hours)::int / 24),
    stipend_until       = stipend_until - (sqlc.arg(hours)::int / 24),
    vip_gift_on         = vip_gift_on - (sqlc.arg(hours)::int / 24),
    -- Rekabet's days: the arena's fights and refreshes, the day its first win
    -- paid, and the day's bounties placed.
    arena_day           = arena_day - (sqlc.arg(hours)::int / 24),
    arena_first_win_on  = arena_first_win_on - (sqlc.arg(hours)::int / 24),
    bounty_day          = bounty_day - (sqlc.arg(hours)::int / 24)
WHERE id = sqlc.arg(id);

-- name: WarpArena :exec
UPDATE app.arena
SET last_at = last_at - make_interval(hours => sqlc.arg(hours)::int)
WHERE player_id = sqlc.arg(id);

-- name: WarpBounties :exec
UPDATE app.bounties
SET placed_at  = placed_at - make_interval(hours => sqlc.arg(hours)::int),
    expires_at = expires_at - make_interval(hours => sqlc.arg(hours)::int)
WHERE placed_by = sqlc.arg(id) OR target_id = sqlc.arg(id);

-- name: WarpBountyClaims :exec
UPDATE app.bounty_claims
SET created_at = created_at - make_interval(hours => sqlc.arg(hours)::int)
WHERE claimer_id = sqlc.arg(id);

-- name: WarpOffers :exec
UPDATE app.player_offers
SET fired_at = fired_at - make_interval(hours => sqlc.arg(hours)::int),
    expires_at = expires_at - make_interval(hours => sqlc.arg(hours)::int)
WHERE player_id = sqlc.arg(id);

-- name: WarpPlayerBoosts :exec
UPDATE app.player_boosts
SET starts_at = starts_at - make_interval(hours => sqlc.arg(hours)::int),
    expires_at = expires_at - make_interval(hours => sqlc.arg(hours)::int)
WHERE player_id = sqlc.arg(id);

-- name: WarpCosmetics :exec
UPDATE app.player_cosmetics
SET expires_at = expires_at - make_interval(hours => sqlc.arg(hours)::int)
WHERE player_id = sqlc.arg(id) AND expires_at IS NOT NULL;

-- name: WarpMail :exec
UPDATE app.mail
SET created_at = created_at - make_interval(hours => sqlc.arg(hours)::int),
    expires_at = expires_at - make_interval(hours => sqlc.arg(hours)::int)
WHERE player_id = sqlc.arg(id);

-- name: WarpCooldowns :exec
UPDATE app.attack_cooldowns
SET last_at = last_at - make_interval(hours => sqlc.arg(hours)::int)
WHERE attacker_id = sqlc.arg(id);

-- name: WarpRevenge :exec
UPDATE app.revenge_tokens
SET created_at = created_at - make_interval(hours => sqlc.arg(hours)::int),
    expires_at = expires_at - make_interval(hours => sqlc.arg(hours)::int)
WHERE player_id = sqlc.arg(id);

-- name: WarpDeals :exec
UPDATE app.player_deals
SET day = day - (sqlc.arg(hours)::int / 24)
WHERE player_id = sqlc.arg(id);

-- name: RestartGuide :execrows
UPDATE app.players SET guide_step = 0, guide_done_at = NULL, guide_skipped = false
WHERE id = sqlc.arg(id);
