# Emperors — Economy Design

> Produced by an architecture pass on 2026-09-04 and adversarially reviewed.
> Owner decisions made *after* this document was written take precedence — see the build plan.

**Headline:** A level-60, ~90-day progression built on one flat energy budget (60/hr) whose value per point rises 13× across a 15-job collect ladder, a 7-tier ×7.6 stat ladder shared by items and soldiers, a Might score defined as 2·√(Σattack × ΣeffectiveHP) that feeds a seeded volley-based auto-battle calibrated so a +20% Might edge wins 75%, and a strictly source-bounded / sink-unbounded economy in which diamonds never buy gold or power.

---

# EMPERORS — Game Systems, Math & Economy Design

**Version:** 1.0 · **Status:** implementable spec · **Target:** Go 1.27 backend, server-authoritative
**Scope:** every formula the backend must implement. The Godot client renders these numbers and never computes them.

---

## 0. Ground rules that govern every other section

These five rules are load-bearing. Violating any of them breaks the economy.

### 0.1 The balance registry

Every constant in this document lives in **one versioned JSON blob**, not scattered across Go source.

```sql
CREATE TABLE balance_versions (
  id           int PRIMARY KEY,
  data         jsonb NOT NULL,
  activated_at timestamptz NOT NULL DEFAULT now(),
  note         text NOT NULL DEFAULT ''
);
```

The active version is loaded into memory at boot and on a `NOTIFY balance_reload`. **Every `gold_ledger` row and every `battles` row stamps `balance_version`**, so a retro-analysis can separate "players got richer" from "we changed the numbers." Ship a `GET /admin/balance/diff?from=3&to=4` endpoint in the Next.js admin panel.

### 0.2 Integer arithmetic only

No `float64` anywhere in a path that produces a persisted number.

| Quantity | Storage | Unit |
|---|---|---|
| Gold, XP, diamonds | `bigint` | whole units |
| Energy | `bigint` | **milli-energy** (1 energy = 1000) |
| Tax accrual | `bigint` | **milli-gold/second** |
| All percentages/multipliers | `int` | **basis points** (bp; 10000 = ×1.0) |
| Item stats, combat damage | `int` | whole units; intermediates in `int64` milli |

Rounding is always `floor` after the final basis-point multiply, except where a table below says `round`. Reason: Neon is a pooled connection and requests retry; float drift across retries produces off-by-one gold that players *will* report.

### 0.3 The additive-bucket rule (the anti-inflation invariant)

There are exactly **eight multiplier buckets**. Within a bucket, every source **adds**. Buckets **multiply** with each other only where the formula below says so, and **every bucket has a hard cap enforced at read time**.

| Bucket | Sources | Hard cap |
|---|---|---|
| `collect_income_bp` | Granary, Royal Granaries, job milestones | +15000 bp (+150%) |
| `tax_income_bp` | Tithe Barn, Royal Treasury, VIP | +30000 bp (+300%) |
| `xp_bp` | Scriptorium, Royal Archives, Fresh Start boost, Battle Pass | +20000 bp (+200%) |
| `energy_regen_bp` | Beacons, Royal Couriers | +6000 bp (+60%) |
| `soldier_atk_bp` | Armoury, Royal Armoury | +10000 bp (+100%) |
| `soldier_def_bp` | Bulwark, Royal Bulwark | +10000 bp (+100%) |
| `soldier_spd_bp` | Stables | +6000 bp (+60%) |
| `shop_discount_bp` | Merchant Ties | +3000 bp (+30%) |

**Implementation chokepoint.** Exactly one function may apply a bucket:

```go
// balance/buckets.go — the ONLY place a percentage bonus is applied.
func ApplyBucket(base int64, bucket Bucket, p *PlayerBonuses) int64 {
    bp := clampBP(p.Sum(bucket), 0, bucket.CapBP())
    return base * int64(10000+bp) / 10000
}
```
Add a `go vet`-style lint (or a simple `grep` in CI) that fails the build if `collect_income_bp` or friends appear outside `balance/buckets.go`. Five sources of +20% must give +100%, never ×2.49. This single rule is what keeps the economy from running away.

### 0.4 Determinism and seeding

All randomness derives from a named, portable PRNG — **splitmix64 for seeding, xoshiro256\*\* for the stream**. Never `math/rand`, never a float stream. ~35 lines of pure integer Go; identical results forever, across versions and languages.

```go
func seedFor(parts ...[]byte) uint64 {
    h := sha256.New()
    h.Write(serverSecret)          // prevents client-side prediction of shop/loot
    for _, p := range parts { h.Write(p) }
    return binary.BigEndian.Uint64(h.Sum(nil)[:8])
}
```

### 0.5 The gold ledger

**Every** gold mutation goes through one write path.

```sql
CREATE TABLE gold_ledger (
  id          bigserial,
  player_id   bigint NOT NULL,
  delta       bigint NOT NULL,
  reason      text   NOT NULL,   -- collect|tax|pvp_steal|pvp_loss|pvp_ransom|shop_buy|
                                 -- item_sell|slot_buy|recruit|train|reforge|family_upgrade|
                                 -- kingdom_donate|kingdom_found|quest|level_up|shop_refresh
  ref_id      bigint,
  balance_ver int    NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id, created_at)
) PARTITION BY RANGE (created_at);
```
A nightly job computes, per active player: total minted (positive deltas excluding `pvp_steal`), total burned (negative excluding `pvp_loss`), and M2 (`SUM(gold)` over active players). **Alert if M2 per active player grows more than 5% week-over-week.** This is the operational safeguard behind §14's proof.

---

## 1. Energy

### 1.1 Constants

| Constant | Value | Note |
|---|---|---|
| `ENERGY_BASE_MAX` | 60 | |
| `ENERGY_PER_STAT_POINT` | 3 | |
| `ENERGY_REGEN_BASE_SEC` | 60 | seconds per 1 energy |
| `ENERGY_OVERFLOW` | **false** | regen stops at max, hard |
| `LEVELUP_REFILL` | full | sets energy to the (new) max |
| `TAX_OFFLINE_CAP_SEC` | 28800 (8 h) | +720 s per Tithe Barn level → 12 h at max |

### 1.2 Formulas

```
max_energy       = ENERGY_BASE_MAX + 3*pts_energy + larder_flat        (larder_flat = 4 * Larder_level)
regen_sec_per_pt = ENERGY_REGEN_BASE_SEC * 10000 / (10000 + energy_regen_bp)
energy_per_hour  = 3600 / regen_sec_per_pt
```

Energy is stored as `energy_milli` + `energy_updated_at` and **lazily materialised** on read — no cron, no per-tick writes:

```go
func (p *Player) EnergyNow(t time.Time) int64 {
    elapsed := t.Sub(p.EnergyUpdatedAt).Milliseconds()
    gain := elapsed * 1000 / int64(p.RegenSecPerPoint()*1000) // milli-energy
    return min(p.EnergyMilli+gain, p.MaxEnergy()*1000)
}
```

### 1.3 The central design statement

> **Max Energy is a "how long can I be away" stat. Regen speed is a "how much do I earn per day" stat.**

Because regen is a flat rate, buying Max Energy does **not** increase daily throughput — it only lets you bank more while offline. Daily throughput is bought *only* through the `energy_regen_bp` bucket, which is capped at +60%. This is what bounds the entire gold supply (§14).

**No overflow.** A player who sleeps 8 hours with a 60 bar loses 7 hours of regen — that is the intended pressure driving 3-4 sessions/day, and it is the reason Max Energy stat points and the Larder upgrade have value. Level-up refills to full; refills and potions clamp at max.

### 1.4 Collects per hour (free player, no upgrades — pure 60 energy/hr)

| Level | Max energy | Best job | Energy/collect | **Collects/hr** | Gold/hr (base) |
|---|---|---|---|---|---|
| 1 | 60 | Pick Grapes | 1 | **60.0** | 120 |
| 10 | 60 | Tend the Orchard | 4 | **15.0** | 180 |
| 30 | 60 | Escort a Trade Caravan | 20 | **3.0** | 588 |
| 60 | 60 | Plunder the Dragon's Hoard | 55 | **1.09** | 1,591 |

With a realistic invested build (stat points + Larder + Beacons + Granary + Kingdom):

| Level | Max energy | Energy/hr | Collects/hr | Gold/hr |
|---|---|---|---|---|
| 10 | 96 | 62 | 15.6 | 191 |
| 30 | 190 | 72 | 3.6 | 1,023 |
| 60 | 310 | 84 | 1.53 | 4,788 |

**Consequence — you must ship this:** tap volume *falls* with level by design. Mitigations, in priority order:
1. **Hold-to-repeat** on the collect button (fires every 250 ms until energy runs out or release) — from level 1. This is what makes the tutorial's ~150 early taps painless.
2. **×5 / ×10 bulk collect** buttons from level 15.
3. **Auto-collect toggle** from level 25 for everyone (spends energy on the best affordable job while the app is foregrounded). VIP gets it at level 15 — a convenience unlock only, never a power unlock.

### 1.5 Diamond refill pricing

Full refill. Price escalates within a rolling 24 h window, resets at the player's local-midnight offset (`players.reset_offset_minutes`, seeded from the device TZ at signup).

| Refill # today | 1 | 2 | 3 | 4 | 5 | 6+ |
|---|---|---|---|---|---|---|
| Diamonds | 20 | 30 | 45 | 70 | 100 | **150 (capped)** |

Capping at 150 rather than continuing to escalate is a deliberate non-predatory choice: a whale can buy 10 refills/day for 745 diamonds (~$11), which is a bounded, honest offer rather than an exponential trap.

---

## 2. XP and levels

### 2.1 The curve

```
xp_to_next(L) = floor(1.7 * L^2.2 + 10*L + 5)
```

Chosen so that cumulative XP ≈ `0.53·L^3.2`, which — against a roughly flat energy budget and a slowly-rising XP-per-energy — produces the target pacing. The `+10L+5` term keeps levels 1-5 from being trivially tiny.

### 2.2 XP sources

| Source | Formula |
|---|---|
| Collect job *n* | `max(2, round(energy_n * (1.40 + 0.02 * unlock_level_n)))` |
| Attack (win) | `round((10 + 0.8*def_level) * gap_mult)` |
| Attack (loss) | 35% of the win value |
| Daily quest (tier 1/2/3) | `4 * level * tier` |
| `gap_mult` | `clamp(1 + 0.06*(def_level - att_level), 0.5, 1.8)` |

XP-per-energy: **collecting ≈ 1.4-2.6, attacking ≈ 3.1** (34 XP for 11 energy at L30).

> **Deliberate tension:** attacking is the XP-efficient path; collecting is the gold-efficient path. Every session the player chooses between levelling and banking. This is the main reason PvP stays populated.

### 2.3 Fresh Start boost

`xp_bp` receives **+10000 bp (×2.0) while level ≤ 10** and **+5000 bp (×1.5) at levels 11-15**, decaying to 0 at 16. This gets a day-1 player to level 14-15 (the "everything is unlocking" high) without distorting the long curve.

### 2.4 Stat points

**3 per level, +2 extra on every 10th level.** Total at level 60 = 3×59 + 2×6 = **189 points**, plus up to 10 from Squire's Training = **199**.

| Allocation | Effect |
|---|---|
| Max Energy | +3 max energy |
| Attack | +4 attack |
| Defense | +4 defense |

Free respec once, then 200 diamonds (or 50,000 gold) — respec is a *convenience*, never a required purchase.

### 2.5 Level table

Average player model: 70% energy capture (≈1,000-1,200 energy/day), 5 attacks/day, 3 quests, no VIP, kingdom joined ~day 5.

| Lv | XP to next | Cumulative | Day reached | Lv | XP to next | Cumulative | Day reached |
|---|---|---|---|---|---|---|---|
| 1 | 16 | 0 | 0.00 | 32 | 3,803 | 38,182 | 15.9 |
| 2 | 32 | 16 | 0.00 | 33 | 4,057 | 41,985 | 17.3 |
| 3 | 54 | 48 | 0.01 | 34 | 4,319 | 46,042 | 18.8 |
| 4 | 80 | 102 | 0.02 | 35 | 4,595 | 50,378 | 20.5 |
| 5 | 113 | 182 | 0.03 | 36 | 4,872 | 54,973 | 22.2 |
| 6 | 152 | 295 | 0.05 | 37 | 5,162 | 59,845 | 24.0 |
| 7 | 197 | 447 | 0.07 | 38 | 5,461 | 65,007 | 25.9 |
| 8 | 249 | 644 | 0.10 | 39 | 5,770 | 70,468 | 27.9 |
| 9 | 308 | 893 | 0.14 | 40 | 6,093 | 76,256 | 30.1 |
| 10 | 374 | 1,201 | 0.19 | 41 | 6,415 | 82,349 | 32.1 |
| 11 | 447 | 1,575 | 0.28 | 42 | 6,752 | 88,764 | 34.3 |
| 12 | 527 | 2,022 | 0.43 | 43 | 7,098 | 95,516 | 36.6 |
| 13 | 614 | 2,549 | 0.61 | 44 | 7,454 | 102,614 | 38.9 |
| 14 | 709 | 3,163 | 0.82 | 45 | 7,825 | 110,090 | 41.3 |
| 15 | 812 | 3,872 | **1.06** | 46 | 8,193 | 117,915 | 43.9 |
| 16 | 922 | 4,684 | 1.48 | 47 | 8,578 | 126,108 | 46.7 |
| 17 | 1,040 | 5,606 | 1.96 | 48 | 8,972 | 134,686 | 49.5 |
| 18 | 1,166 | 6,646 | 2.50 | 49 | 9,376 | 143,658 | 52.5 |
| 19 | 1,300 | 7,812 | 3.10 | 50 | 9,798 | 153,064 | **55.6** |
| 20 | 1,442 | 9,112 | **3.77** | 51 | 10,213 | 162,862 | 58.5 |
| 21 | 1,592 | 10,554 | 4.40 | 52 | 10,646 | 173,075 | 61.6 |
| 22 | 1,750 | 12,146 | 5.09 | 53 | 11,090 | 183,721 | 64.7 |
| 23 | 1,917 | 13,896 | 5.86 | 54 | 11,543 | 194,811 | 68.0 |
| 24 | 2,092 | 15,813 | 6.69 | 55 | 12,016 | 206,392 | **71.5** |
| 25 | 2,277 | 17,909 | **7.61** | 56 | 12,479 | 218,408 | 75.1 |
| 26 | 2,468 | 20,186 | 8.60 | 57 | 12,962 | 230,887 | 78.8 |
| 27 | 2,668 | 22,654 | 9.68 | 58 | 13,455 | 243,849 | 82.7 |
| 28 | 2,878 | 25,322 | 10.84 | 59 | 13,958 | 257,304 | 86.7 |
| 29 | 3,096 | 28,200 | 12.10 | 60 | 14,484 | 271,308 | **90.9** |
| 30 | 3,325 | 31,303 | **13.45** | (61) | — | 285,792 | — |
| 31 | 3,558 | 34,628 | 14.65 | | | | |

### 2.6 Pacing targets

| Metric | Target |
|---|---|
| Session length | **4-7 minutes** (bar of 60-310 empties in 3-10 collects + 2-3 attacks) |
| Sessions/day | **3-4**, ~20 min/day total |
| Level 15 | **end of day 1** |
| Level 30 | **day 13-14** average · day 9 committed · day 6 whale |
| Level 60 (cap) | **day 91** average · day ~64 committed (Scriptorium+Archives, ×1.45 XP) · day ~45 whale |

Level 60 is the launch cap. §14 explains what absorbs a capped player's income.

---

## 3. Collect jobs

### 3.1 Formula

```
energy_n = ENERGY_TABLE[n]                       # hand-tuned, ~×1.28/step
gpe_n    = 2.00 * 1.22^max(0, n-2)               # gold per energy
gold_n   = round(energy_n * gpe_n)
xp_n     = max(2, round(energy_n * (1.40 + 0.02 * unlock_n)))
```

The `max(0, n-2)` keeps jobs 1 and 2 at gpe 2.00, matching the owner's stated ladder (Grapes 1→2, Strawberries 2→4).

### 3.2 The ladder

| # | Job | Unlock Lv | Energy | Gold | XP | **Gold/energy** |
|---|---|---|---|---|---|---|
| 1 | Pick Grapes | 1 | 1 | 2 | 2 | 2.00 |
| 2 | Gather Strawberries | 3 | 2 | 4 | 3 | 2.00 |
| 3 | Harvest Wheat | 5 | 3 | 7 | 4 | 2.33 |
| 4 | Tend the Orchard | 8 | 4 | 12 | 6 | 3.00 |
| 5 | Chop Timber | 11 | 6 | 22 | 10 | 3.67 |
| 6 | Fish the River | 14 | 8 | 35 | 13 | 4.38 |
| 7 | Quarry Stone | 18 | 10 | 54 | 18 | 5.40 |
| 8 | Mine Iron Ore | 22 | 13 | 86 | 24 | 6.62 |
| 9 | Hunt the King's Wood | 26 | 16 | 129 | 31 | 8.06 |
| 10 | Escort a Trade Caravan | 30 | 20 | 196 | 40 | 9.80 |
| 11 | Smelt Silver | 35 | 25 | 299 | 52 | 11.96 |
| 12 | Clear the Bandit Camp | 40 | 31 | 453 | 68 | 14.61 |
| 13 | Delve the Deep Mine | 45 | 38 | 677 | 87 | 17.82 |
| 14 | Collect the Crown Tithe | 52 | 46 | 1,000 | 112 | 21.74 |
| 15 | Plunder the Dragon's Hoard | 60 | 55 | 1,459 | 143 | 26.53 |

**Why this shape works.** Gold/energy rises 13.3× across the ladder — steep enough that using the best job you can afford is always correct, shallow enough that a level-60 player with 3 leftover energy still earns 6 gold from Grapes instead of nothing. Because the step is a smooth ×1.22 and unlocks are 3-8 levels apart, each unlock is a visible ~+20-25% income jump — the pacing beat that carries the mid-game.

### 3.3 Milestones — extended past 100

Per-job cumulative collect counters. The bonus is a flat percentage added into the `collect_income_bp` bucket **for that job only**.

| Collects | Bonus | Cumulative | One-time gift |
|---|---|---|---|
| 25 | +5% | +5% | 1 item, ilvl = player level, tier rolled on the shop table |
| 50 | +5% | +10% | 1 item + 200 × level gold |
| 100 | +5% | +15% | 1 item (tier floor: **rare**) + 15 diamonds |
| **250** | +5% | **+20%** | 1 item (floor: **epic**) + 25 diamonds |
| **500** | +5% | **+25%** | 1 item (floor: **epic**) + 40 diamonds |
| **1000** | +5% | **+30% (hard cap)** | 1 item (floor: **legendary**) + 75 diamonds + "Master of \<job\>" title |

**Recommendation: yes, continue past 100, but stop at +30%.** Rationale: (a) the marginal +5% steps are worth chasing at 250/500/1000 counts because by then the job's base gold is large; (b) capping at +30% keeps the `collect_income_bp` bucket inside its +150% ceiling even with a maxed Granary (+60%) and Royal Granaries (+20%) — total +110%, headroom preserved; (c) the *real* reward past 100 is the guaranteed item floor, which is content, not inflation. Add a bronze/silver/gold/diamond mastery badge on the job row — pure UI, and it drives completion behaviour hard.

---

## 4. Tier system

### 4.1 Resolving the epic/mystic colour conflict

The owner specified epic = purple *and* mystic = purple. That is unshippable — at 44 px thumbnail size on a portrait phone, two purples are the same colour.

**Recommendation:**

| Tier | Colour | Hex | Frame |
|---|---|---|---|
| common | gray | `#9AA0A6` | plain |
| uncommon | green | `#3FA75A` | 1 gem |
| rare | blue | `#3B82F6` | 2 gems |
| epic | **violet** | `#A855F7` | 3 gems |
| legendary | gold | `#F5B301` | 4 gems |
| **mystic** | **magenta** | `#E040FB` + animated purple→cyan holographic sheen | 5 gems |
| special | red | `#E23B3B` | crown |

Mystic stays in the purple family (honouring the intent) but reads as unmistakably different from epic. If the owner rejects magenta, the fallback is epic = muted indigo `#6D5BD0` / mystic = bright `#E040FB`.

**Non-negotiable regardless:** rarity is **never** communicated by colour alone. Every item card carries the tier *name* and the *frame shape* (gem count / crown). This is both a readability and a deuteranopia-accessibility requirement.

### 4.2 Stat multiplier ladder

Implement as a lookup array, not a formula — designers need to hand-tune individual rungs.

| idx | Tier | `tier_mult` | Step vs previous |
|---|---|---|---|
| 0 | common | 1.00 | — |
| 1 | uncommon | 1.35 | ×1.35 |
| 2 | rare | 1.85 | ×1.37 |
| 3 | epic | 2.55 | ×1.38 |
| 4 | legendary | 3.60 | ×1.41 |
| 5 | mystic | 5.20 | ×1.44 |
| 6 | special | 7.60 | ×1.46 |

Smoothly accelerating (each rung feels like a bigger leap than the last), total spread **7.6×**.

### 4.3 Roll distribution model

One model, four parameter sets. Weights grow geometrically with player level via a per-source luck coefficient:

```
w[t] = base_w[t] * (1 + luck_coef * min(level, 60))^t
P(t) = w[t] / Σw
```

Because the level factor is raised to the *tier index*, higher levels shift mass up the ladder without ever making commons impossible — exactly the curve you want.

| Source | base weights (common → special) | luck_coef |
|---|---|---|
| Shop | 100, 45, 16, 5, 1.2, 0.20, 0.02 | 0.014 |
| Peasant recruit | 100, 30, 7, 1.5, 0.25, 0.03, 0.002 | 0.010 |
| Mercenary recruit | 45, 55, 25, 8, 1.8, 0.25, 0.02 | 0.012 |
| Gladiator recruit | 10, 30, 40, 22, 8, 1.6, 0.18 | 0.014 |
| Attack loot | 100, 40, 12, 3, 0.6, 0.08, 0.006 | 0.013 |

#### Shop

| Lv | common | uncommon | rare | epic | legendary | mystic | special |
|---|---|---|---|---|---|---|---|
| 1 | 59.24% | 27.03% | 9.75% | 3.09% | 0.752% | 0.127% | 0.013% |
| 10 | 54.96% | 28.19% | 11.43% | 4.07% | 1.114% | 0.212% | 0.024% |
| 30 | 46.15% | 29.49% | 14.89% | 6.61% | 2.252% | 0.533% | 0.076% |
| 60 | 34.86% | 28.86% | 18.88% | 10.86% | 4.795% | 1.470% | 0.271% |

#### Peasant

| Lv | common | uncommon | rare | epic | legendary | mystic | special |
|---|---|---|---|---|---|---|---|
| 1 | 71.80% | 21.76% | 5.13% | 1.11% | 0.187% | 0.023% | 0.002% |
| 10 | 69.50% | 22.94% | 5.89% | 1.39% | 0.254% | 0.034% | 0.002% |
| 30 | 64.53% | 25.17% | 7.63% | 2.13% | 0.461% | 0.072% | 0.006% |
| 60 | 57.46% | 27.58% | 10.30% | 3.53% | 0.941% | 0.181% | 0.019% |

#### Mercenary

| Lv | common | uncommon | rare | epic | legendary | mystic | special |
|---|---|---|---|---|---|---|---|
| 1 | 32.91% | 40.71% | 18.73% | 6.06% | 1.381% | 0.194% | 0.016% |
| 10 | 29.51% | 40.39% | 20.56% | 7.37% | 1.857% | 0.289% | 0.026% |
| 30 | 23.24% | 38.63% | 23.88% | 10.39% | 3.181% | 0.601% | 0.065% |
| 60 | 16.41% | 34.49% | 26.96% | 14.84% | 5.743% | 1.372% | 0.189% |

#### Gladiator

| Lv | common | uncommon | rare | epic | legendary | mystic | special |
|---|---|---|---|---|---|---|---|
| 1 | 8.71% | 26.49% | 35.81% | 19.97% | 7.364% | 1.493% | 0.170% |
| 10 | 6.86% | 23.46% | 35.66% | 22.36% | 9.269% | 2.113% | 0.271% |
| 30 | 4.18% | 17.79% | 33.68% | 26.30% | 13.582% | 3.857% | 0.616% |
| 60 | 2.13% | 11.74% | 28.81% | 29.15% | 19.506% | 7.178% | 1.486% |

#### Attack loot

| Lv | common | uncommon | rare | epic | legendary | mystic | special |
|---|---|---|---|---|---|---|---|
| 1 | 63.83% | 25.86% | 7.86% | 1.99% | 0.403% | 0.054% | 0.004% |
| 10 | 60.25% | 27.23% | 9.23% | 2.61% | 0.589% | 0.089% | 0.008% |
| 30 | 52.76% | 29.33% | 12.23% | 4.25% | 1.182% | 0.219% | 0.023% |
| 60 | 42.78% | 30.46% | 16.26% | 7.24% | 2.576% | 0.611% | 0.082% |

For attack loot, use `q = 1 + 0.013 * max(att_level, def_level)` — **beating someone stronger than you rolls on their table.** Attacking up is the loot-efficient play, matching the rep formula in §9.

### 4.4 Pity

Per-player counters, one per source:
- **Shop:** 60 consecutive rolls with no epic+ → next roll is forced to epic or better (re-rolled on the epic+ sub-distribution). Counter resets on any epic+.
- **Gladiator:** 12 consecutive recruits with no legendary+ → forced legendary+.
- No pity on Peasant/Mercenary (they are the cheap options; pity there would trivialise Gladiators).

---

## 5. Items

### 5.1 Model

Three types (Weapon = swords, Armor, Horse), seven tiers, an **item level** (`ilvl`), a **quality** roll, and a rare **Masterwork** flag.

```
level_mult(ilvl) = 1 + 0.09 * ilvl
stat = round(base_slot_stat * tier_mult(t) * level_mult(ilvl) * quality * masterwork)
```

| Slot | base ATK | base DEF | base SPD |
|---|---|---|---|
| Weapon | 10 | 2 | 0 |
| Armor | 2 | 10 | 0 |
| Horse | 5 | 5 | 6 |

**ilvl assignment:** shop items = player level; attack loot = `max(att_level, def_level)`; milestone/quest items = player level. Shop stock is therefore always current-tier — old gear reliably ages out, which is the pressure that keeps the shop relevant for 90 days.

### 5.2 Roll variance — one quality roll, plus a Masterwork flag

**Recommendation: a single `quality` roll per item, uniform in [0.85, 1.15], applied to all stats identically**, stored as `quality_pct` (85-115) and displayed as a bar. Plus **Masterwork: 3% chance, ×1.15 to all stats, gold star badge**.

Rejected alternative: independent per-stat rolls. They produce more variety but a stat-soup that is unsortable and uncomparable on a 390 pt-wide portrait screen. One quality number lets the player sort, compare and chase perfect rolls in one glance; the Masterwork flag supplies the "wow" moment without the soup.

### 5.3 Stat tables (quality 1.00, no Masterwork)

**Weapon** (ATK / DEF)

| Tier | ilvl 1 | ilvl 30 | ilvl 60 |
|---|---|---|---|
| common | 11 / 2 | 37 / 7 | 64 / 13 |
| uncommon | 15 / 3 | 50 / 10 | 86 / 17 |
| rare | 20 / 4 | 68 / 14 | 118 / 24 |
| epic | 28 / 6 | 94 / 19 | 163 / 33 |
| legendary | 39 / 8 | 133 / 27 | 230 / 46 |
| mystic | 57 / 11 | 192 / 38 | 333 / 67 |
| special | 83 / 17 | 281 / 56 | 486 / 97 |

**Armor** (ATK / DEF) — exact mirror: common ilvl30 = 7/37, special ilvl60 = 97/486.

**Horse** (ATK / DEF / SPD)

| Tier | ilvl 1 | ilvl 30 | ilvl 60 |
|---|---|---|---|
| common | 5 / 5 / 7 | 19 / 19 / 22 | 32 / 32 / 38 |
| uncommon | 7 / 7 / 9 | 25 / 25 / 30 | 43 / 43 / 52 |
| rare | 10 / 10 / 12 | 34 / 34 / 41 | 59 / 59 / 71 |
| epic | 14 / 14 / 17 | 47 / 47 / 57 | 82 / 82 / 98 |
| legendary | 20 / 20 / 24 | 67 / 67 / 80 | 115 / 115 / 138 |
| mystic | 28 / 28 / 34 | 96 / 96 / 115 | 166 / 166 / 200 |
| special | 41 / 41 / 50 | 140 / 140 / 169 | 243 / 243 / 292 |

### 5.4 What a horse actually does — **recommendation**

A horse must not be "a worse weapon." It carries three distinct mechanical roles:

1. **Stats** — balanced ATK/DEF, lower raw total than weapon/armor.
2. **Initiative (SPD)** — the *only* source of Speed in the game. Speed determines:
   - **Side order**: the side with the higher `Σ SPD` fires its volley first each round.
   - **Crit chance**: `crit = clamp(0.05 + 0.30 * spd_att/(spd_att + spd_def + 1), 0.05, 0.45)`
   - **Dodge chance**: `dodge = clamp(0.20 * spd_def/(spd_def + spd_att + 1), 0.00, 0.15)`
3. **Charge** — the faster side deals **+12% damage on round 1 only**. Animated as a cavalry charge in the replay, with a dedicated SFX. This is the single most legible payoff for horse investment.

Power weighting: SPD counts at **0.5×** in the price and Might formulas, which is what makes the horse's lower raw stats fair. A player who stacks horses trades total HP for burst + crits — a real build decision, not a stat tax.

Rejected alternative: an army-wide "cavalry pool" that reduces enemy first-round damage. It reads well on paper but is invisible in the replay, and invisible mechanics do not motivate purchases.

### 5.5 Prices and the arbitrage proof

```
item_power = attack + defense + 0.5*speed
shop_price = round(1.6 * item_power^1.35 * tier_price_mult(t)) * (10000 - shop_discount_bp)/10000
sell_price = round(0.25 * shop_price_undiscounted(item))
```

| Tier | `tier_price_mult` |
|---|---|
| common | 1.0 |
| uncommon | 1.4 |
| rare | 2.2 |
| epic | 3.6 |
| legendary | 6.0 |
| mystic | 10.0 |
| special | 17.0 |

**Weapon buy / sell** (ilvl 30 and 60, quality 1.00):

| Tier | ilvl30 buy | ilvl30 sell | ilvl60 buy | ilvl60 sell |
|---|---|---|---|---|
| common | 265 | 66 | 563 | 141 |
| uncommon | 563 | 141 | 1,168 | 292 |
| rare | 1,350 | 338 | 2,832 | 708 |
| epic | 3,405 | 851 | 7,161 | 1,790 |
| legendary | 9,075 | 2,269 | 18,945 | 4,736 |
| mystic | 24,686 | 6,172 | 52,108 | 13,027 |
| special | 70,286 | 17,572 | 147,306 | 36,826 |

Reference: a level-30 player earns ~19k gold/day, a level-60 player ~90k/day. So an ilvl30 rare is ~7% of a day, a legendary ~half a day, a special ~3.7 days. Correct pressure.

**Arbitrage impossibility — proof.** Let `S(i)` be the shop price of item `i` and `V(i)` its sell price. Both are *pure functions of the same tuple* `(type, tier, ilvl, quality, masterwork)`, and `V(i) = floor(0.25 · S(i))`. Since:
1. **No in-game effect mutates an item's stats after acquisition** (there is no upgrading or enchanting in v1), the tuple is immutable, so `V` is fixed at acquisition time and equals `0.25·S`;
2. `0.25 · S(i) < S(i)` for all `S(i) > 0`;
3. `shop_discount_bp` reduces the *buy* price only and is explicitly excluded from the sell calculation (sell always uses the undiscounted price), so a maxed Merchant Ties gives buy = 0.70·S and sell = 0.25·S — still a 64% loss;

every buy→sell round trip loses ≥75% of the outlay. ∎

**Implementation rules that keep this true:**
- `sell_price` is **recomputed from the item's stats at sell time**. Never stored at purchase. Never derived from a second table.
- Discounts apply only to buy. Assert `sell_bp == 2500` in a unit test.
- **If item upgrading is ever added**, the invariant becomes: upgrade cost must be ≥ 0.75 × the resulting shop-price delta. Write this constraint into the balance registry as `ITEM_UPGRADE_MIN_COST_RATIO = 0.75` now, before anyone builds it.

**Loot as a gold faucet — quantified.** At level 30, attack loot has an expected **sell value of 198 gold per drop**; at a 20% drop rate that is **39.6 gold per win** — roughly 1/6 of the average gold steal. Loot is a *content* faucet (you might get a great item), not a gold faucet. No rate cap needed.

### 5.6 Reforge (recommended — the infinite sink)

`Reforge` re-rolls an item's `quality` (and re-rolls the Masterwork flag) for `0.60 × shop_price`. It creates **no** power inflation (quality is hard-capped at 115% and Masterwork at ×1.15) and absorbs unbounded gold. Cheap to build, zero balance risk, and it is the primary answer to "what does a level-60 player spend on?" (§14).

---

## 6. Soldiers

### 6.1 Slot cost curve

```
slot_cost(n) = round(500 * 2.05^(n-1))
slot_level_gate(n) = 4*(n-1) + 1
```

| n | Cost | Cumulative | Level gate |
|---|---|---|---|
| 1 | 500 | 500 | 1 |
| 2 | 1,025 | 1,525 | 5 |
| 3 | 2,101 | 3,626 | 9 |
| 4 | 4,308 | 7,934 | 13 |
| 5 | 8,831 | 16,765 | 17 |
| 6 | 18,103 | 34,868 | 21 |
| 7 | 37,110 | 71,978 | 25 |
| 8 | 76,076 | 148,054 | 29 |
| 9 | 155,956 | 304,010 | 33 |
| 10 | 319,709 | **623,719** | 37 |

**Cap at 10 slots for v1.** 10 soldiers × 3 slots = 30 equipment decisions, which is already the practical ceiling for a portrait phone UI. Slots 11 (655k) and 12 (1.34M) are pre-specified for a "Warlord" expansion.

### 6.2 Recruit prices

```
recruit_cost(type, level) = round(base[type] * (1 + 0.11 * level))
```

| Level | Peasant | Mercenary | Gladiator |
|---|---|---|---|
| 1 | 167 | 999 | 6,660 |
| 10 | 315 | 1,890 | 12,600 |
| 30 | 645 | 3,870 | 25,800 |
| 60 | 1,140 | 6,840 | 45,600 |

Recruiting into an occupied slot **replaces** the soldier (old one dismissed, no refund) — with a confirm dialog if the outgoing soldier is epic+.

> **Gladiator re-recruiting is the primary late-game gold sink.** At level 60, chasing a mystic Gladiator (7.18% per roll) takes ~14 rolls ≈ 638,000 gold ≈ 7 days of income. That is a well-priced, self-renewing chase.

### 6.3 Base stats

```
soldier_atk = round(type_atk * tier_mult(t) * (1 + 0.09*soldier_level) * (10000+soldier_atk_bp)/10000)
soldier_def = round(type_def * tier_mult(t) * (1 + 0.09*soldier_level) * (10000+soldier_def_bp)/10000)
soldier_hp  = round(type_hp  * tier_mult(t) * (1 + 0.09*soldier_level))
```

| Type | ATK | DEF | HP |
|---|---|---|---|
| Peasant | 8 | 8 | 40 |
| Mercenary | 14 | 12 | 55 |
| Gladiator | 22 | 18 | 75 |

**At soldier_level 30** (ATK / DEF / HP, before equipment):

| Tier | Peasant | Mercenary | Gladiator |
|---|---|---|---|
| common | 30 / 30 / 148 | 52 / 44 / 204 | 81 / 67 / 278 |
| uncommon | 40 / 40 / 200 | 70 / 60 / 275 | 110 / 90 / 375 |
| rare | 55 / 55 / 274 | 96 / 82 / 376 | 151 / 123 / 513 |
| epic | 75 / 75 / 377 | 132 / 113 / 519 | 208 / 170 / 707 |
| legendary | 107 / 107 / 533 | 187 / 160 / 733 | 293 / 240 / 999 |
| mystic | 154 / 154 / 770 | 269 / 231 / 1,058 | 423 / 346 / 1,443 |
| special | 225 / 225 / 1,125 | 394 / 337 / 1,547 | 619 / 506 / 2,109 |

Note that a **common Gladiator ≈ a rare Peasant** — the *type* matters beyond the tier roll. That is what justifies the 40× price gap between Peasant and Gladiator.

### 6.4 Soldier level and the staleness problem

A soldier's stats are frozen at its recruit level. Left alone, this creates a treadmill where every soldier must eventually be thrown away — a bad feeling.

**Recommendation: add a `Train` action.** Raises a soldier's effective level by 1, up to the player's current level.

```
train_cost(from_level, tier) = round(60 * 1.09^from_level * tier_mult(tier))
```
Training a legendary soldier from level 30 → 60 costs **~390,000 gold** in total. Substantial, incremental, priced, and it converts a "your guy is obsolete, delete him" moment into a "invest in your veteran" moment. It is also an effectively unbounded gold sink (`1.09^L` grows without limit).

If Train is cut from v1, staleness alone still works — it just forces re-recruits (a bigger sink, a worse feel). Flag for the owner.

The soldier card shows **"Recruited at Lv 12 · Train to Lv 30"** with a stale badge.

### 6.5 Realistic soldier counts

Gold binds before the level gate does at every stage:

| Player level | Slots affordable | Typical roster |
|---|---|---|
| 10 (day ~0.2) | **2** | 2 Peasants (uncommon/common) |
| 30 (day ~13) | **6-7** | 1 Gladiator, 2 Mercenaries, 3-4 Peasants; mostly rare gear |
| 60 (day ~91) | **10 (max)** | 3-4 Gladiators (legendary+), 4 Gladiators/Mercenaries, 2-3 Mercenaries; legendary/epic gear |

---

## 7. Player power — the Might formula

### 7.1 Player character

The player has the **same 3 equipment slots** as a soldier (weapon / armor / horse) and fights as unit #0.

```
player_atk = 10 + 2*level + 4*pts_attack  + Σ item.attack
player_def = 10 + 2*level + 4*pts_defense + Σ item.defense
player_spd = Σ item.speed
player_hp  = round((100 + 12*level + 3.0*player_def) * (1 + 0.02*level))
```

The `10 + 2*level` floor guarantees that a player with zero soldiers is never a zero — they can still win fights and progress, which is the owner's explicit requirement.

### 7.2 Per-unit derived values

```
unit_atk(u) = base_atk(u) + Σ equipped.attack
unit_def(u) = base_def(u) + Σ equipped.defense
unit_spd(u) = base_spd(u) + Σ equipped.speed
unit_hp(u)  = round((base_hp(u) + 3.0*unit_def(u)) * (1 + 0.02*owner_level))

DR(def, lvl) = min(0.60, def / (def + 40*lvl + 60))
EHP(u)       = unit_hp(u) / (1 - DR(unit_def(u), owner_level))
```

`HP_PER_DEF = 3.0` means Defense buys both damage reduction *and* HP — a deliberate double-dip that keeps Defense competitive with Attack, since Attack is doubly valuable in a volley system (§8).

### 7.3 Might

```
ArmyATK = Σ_u unit_atk(u)                    # over player + all soldiers
ArmyEHP = Σ_u EHP(u)
Might   = round(2 * sqrt(ArmyATK * ArmyEHP))
```

This is the geometric mean of offence and effective survivability, scaled ×2 so it reads as a big number. It is **monotone increasing in every single stat**, which is required for matchmaking and for the "you are stronger" UI to be honest. Critically, it is *exactly* the quantity the combat sim in §8 decides on — `ArmyATK` is additive because all living units contribute damage, and `ArmyEHP` is additive because only the front unit takes damage. The proxy and the simulation agree by construction.

**UI presentation:** show three numbers on the army card — **Attack Power** (`ArmyATK`), **Defence Power** (`ArmyEHP/10`), and **Might** (the single matchmaking/leaderboard number). Never show a win percentage.

### 7.4 Worked examples (machine-verified)

| Player | Roster | ArmyATK | ArmyEHP | **Might** |
|---|---|---|---|---|
| **Lv 10** — 29 pts (12E/10A/7D), uncommon gear ilvl10 | 2× uncommon Peasant, common gear | 221 | 1,476 | **1,142** |
| **Lv 30** — 91 pts (30E/35A/26D), rare gear ilvl30 | 1× legendary Gladiator, 2× epic Mercenary, 3× rare Peasant; all rare gear | 1,744 | 15,705 | **10,466** |
| **Lv 60** — 189 pts (50E/75A/64D), legendary gear ilvl60 | 3× mystic Gladiator, 4× legendary Gladiator, 3× epic Mercenary; legendary/epic gear | 9,301 | 126,397 | **68,576** |

**Might curve: 1.1k → 10.5k → 68.6k.** A 60× growth across the game — a satisfying "numbers go up" arc that still fits comfortably in an `int64` and displays without abbreviation until ~10k (then use `12.4k` formatting).

`players.might` is denormalised and recomputed on **any** army-affecting write (equip, recruit, train, stat point, upgrade purchase). It is indexed for matchmaking.

---

## 8. PvP combat resolution

### 8.1 The chosen model: volley auto-battle with a front line

Rejected: (a) pure power comparison with variance — no replay to animate, no reason to build the Attack tab's best screen; (b) simultaneous full melee — every unit takes damage, which makes the HP-bar UI unreadable at 10v10 on a phone; (c) one-hero duels as in Shakes & Fidget — cannot express an army.

**Chosen:** each side has an ordered line. Every living unit on a side contributes damage each round, and **all of it lands on the enemy's front unit**. When the front dies, the next steps up (excess damage is wasted). This gives:
- Additive `ΣATK` and additive `ΣEHP` → the Might formula is exactly right (§7.3).
- Back-line units matter from round 1 (no dead weight), so buying slots always feels good.
- A replay that animates beautifully in portrait: two rows of portraits, a volley of damage numbers, one HP bar dropping at a time.

### 8.2 Constants

| Constant | Value | Role |
|---|---|---|
| `DMG_K` | 0.16 | global damage scalar |
| `RAGE_STEP` | 0.15 | damage growth per round (**global to the battle**, not per duel) |
| `MAX_ROUNDS` | 60 | hard cap |
| `VARIANCE` | uniform [0.85, 1.15] | per-unit, per-round |
| `CRIT_MULT` | 1.75 | |
| `DODGE_MAX` | 0.15 | |
| `CHARGE_BONUS` | 0.12 | round 1, faster side only |
| `HOME_GROUND_BP` | 800 | defender's DEF ×1.08 |
| **`FORTUNE_SIGMA`** | **0.38** | **the primary calibration knob (§8.6)** |

### 8.3 The algorithm

```
1. SNAPSHOT
   Freeze both armies (stats, gear, levels) into the battle record. Defender's DEF ×1.08 (Home Ground).
   Order each side's units by SPD desc, tie-break by unit_id asc.  # fully deterministic

2. SEED
   seed = sha256(server_secret || battle_id || att_snapshot_hash || def_snapshot_hash)[0:8]
   rng  = xoshiro256**(splitmix64(seed))

3. FORTUNE OF WAR  (rolled once per side, BEFORE the battle animates)
   f_A = clamp(normal(rng, 0, FORTUNE_SIGMA), -2σ, +2σ)
   f_D = clamp(normal(rng, 0, FORTUNE_SIGMA), -2σ, +2σ)
   fortune_A = exp(f_A)   # applied to side A's damage for the whole battle
   fortune_D = exp(f_D)
   -> emitted as the first replay event so the client shows it as a visible die roll

4. ORDER
   first = side with higher Σ SPD; tie -> attacker.

5. ROUNDS  (r = 1 .. MAX_ROUNDS)
   rage = 1 + RAGE_STEP*(r-1)
   for side in [first, other]:
       if side has no living units: continue
       target = opposing front unit
       total = 0
       for each living unit u on side:
           base   = unit_atk(u) * DMG_K * fortune_side * rage
           afterDR= base * (1 - DR(unit_def(target), target_owner_level))
           v      = uniform(rng, 0.85, 1.15)
           if uniform(rng) < dodge(target, u):  emit(dodge); continue
           crit   = uniform(rng) < crit(u, target)
           charge = (r == 1 && side == fastSide) ? 1.12 : 1.0
           dmg    = floor(afterDR * v * (crit ? CRIT_MULT : 1) * charge)
           total += dmg
           emit({r, src:u, dst:target, dmg, crit})
       target.hp -= total
       if target.hp <= 0: emit(death); advance that side's front
       if opposing side has no living units: -> WINNER = side; goto 6

6. TIMEOUT (r > MAX_ROUNDS)
   winner = side with the higher (Σ remaining hp / Σ max hp); exact tie -> DEFENDER.
```

**Termination is guaranteed** by rage: by round 30 damage is ×5.35, by round 60 it is ×9.85. In practice, symmetric level-30 armies resolve in **25-30 rounds**; a mismatched fight in 6-12. `MAX_ROUNDS = 60` is a safety net, not a design element.

*Worked termination check (7v7, level 30, symmetric):* `ΣATK = 1744`, front unit `DEF 356` → `DR = 0.220`, `HP 3,307`. Round-1 volley = `1744 × 0.16 × 0.78 = 218`. With rage, `0.075r² + 0.925r = 15.2` → the first duel takes **9.3 rounds**; each subsequent front falls faster as rage compounds. Total ≈ 28 rounds, ~56 volley events.

### 8.4 Damage sub-formulas

```
DR(def, lvl)     = min(0.60, def / (def + 40*lvl + 60))
crit(u, target)  = clamp(0.05 + 0.30 * spd_u/(spd_u + spd_t + 1), 0.05, 0.45)
dodge(target, u) = clamp(0.20 * spd_t/(spd_t + spd_u + 1), 0.00, 0.15)
```

`DR` scales the denominator by the *defender's level*, so raw defence numbers do not become percentage-immune at high ilvl. The 0.60 cap prevents a full-defence build from becoming unkillable.

### 8.5 Replay format and storage

The server simulates **once** and persists the event log. **The client never simulates** — it only animates. This removes cross-platform float-determinism from the correctness path entirely (integer math is still mandated for audit re-runs).

```json
{
  "v": 1,
  "seed": "9f3c1a2b7d4e0055",
  "balance_version": 4,
  "fortune": { "a": 1.164, "d": 0.913 },
  "order":   "a",
  "sides": {
    "a": { "name": "Aldric", "level": 30, "might": 10466,
           "units": [{ "id":"a0","name":"Aldric","atk":326,"def":290,"spd":41,"hp":2128,"portrait":"champ_m3" }, ...] },
    "d": { ... }
  },
  "events": [
    { "t":"fortune" },
    { "t":"hit",  "r":1, "s":"a0", "d":"d0", "dmg":142, "crit":false, "charge":true },
    { "t":"dodge","r":1, "s":"a3", "d":"d0" },
    { "t":"hp",   "r":1, "u":"d0", "hp":2691 },
    { "t":"death","r":9, "u":"d0" },
    { "t":"end",  "w":"a", "rounds":28 }
  ],
  "reward": { "gold":1240, "xp":38, "rep":12, "item_id":88213 }
}
```

- ~200 events at 10v10 → ~12 KB JSON → **~2 KB gzipped**. Store as `bytea` in `battle_replays`.
- **Hard cap `MAX_EVENTS = 2000`**; if exceeded, truncate to a summary (should be unreachable).
- **Retention: 30 days**, then drop the blob and keep the row (`winner`, `gold`, `might_a`, `might_d`) for analytics. Partition by month.

### 8.6 Calibration — the most important engineering task in this document

**A many-hit auto-battle is inherently near-deterministic.** With 7 units × ~28 rounds ≈ 200 independent damage rolls per side, per-hit noise averages out to a coefficient of variation under 0.04. Tuning crit and dodge cannot move the win curve — I checked; it does not matter what you set them to. The *only* mechanism that produces a controllable win curve at constant army size is a **per-side, per-battle roll**. That is what Fortune of War is for. (A per-*unit* roll does not work either: its effect shrinks as 1/√N, so the win curve would drift as players buy slots.)

Because `Might = 2√(ATK × EHP)`, the quantity the battle actually decides on is `ATK × EHP` = **Might²**. So a Might ratio of 1.2 is a *deciding-quantity* ratio of 1.44. Under a log-normal model:

```
P(attacker wins) = Φ( 2·ln(Might_A / Might_D) / σ_total )
σ_total          = sqrt( (FORTUNE_SIGMA·√2)² + 0.05² )
```

**The knob table** (machine-computed) — pick a row, set the constant:

| `FORTUNE_SIGMA` | σ_total | **Win % at +20% Might** | implied logistic exponent *k* | ±1σ damage swing |
|---|---|---|---|---|
| 0.20 | 0.287 | 89.8% | 11.92 | +22% / −18% |
| 0.30 | 0.427 | 80.3% | 7.72 | +35% / −26% |
| **0.38** | **0.540** | **75.0%** | **6.04** | **+46% / −32%** |
| 0.45 | 0.638 | 71.6% | 5.07 | +57% / −36% |
| 0.55 | 0.779 | 68.0% | 4.14 | +73% / −42% |
| 0.70 | 0.991 | 64.4% | 3.24 | +101% / −50% |

### **Recommendation: `FORTUNE_SIGMA = 0.38` → a 20% power advantage wins 75% of the time.**

Rationale for choosing 75% over the alternatives:
- **Below ~70%** (σ ≥ 0.45) the ±1σ damage swing exceeds ±55%, and gear investment stops reading as meaningful — a player who spent 50k on a legendary and still loses to a weaker opponent 3 times out of 10 will quit.
- **Above ~85%** (σ ≤ 0.25) the outcome is a foregone conclusion, the replay becomes something you skip, and the Attack tab degenerates into "read the number, tap the weakest."
- **75% is the sweet spot:** the favourite usually wins, the underdog wins often enough (25%) that attacking up for the bigger prize is a live strategy, and the Fortune roll is large enough to feel like a real die but small enough to be explainable.
- Crucially, **within the matchmaking band (0.85×-1.35× Might, §9.5) the realistic win-rate range is 25%-87%** — every target on the list is a genuine decision.

**Making the randomness feel fair rather than broken:** the Fortune roll is emitted as the *first* replay event and rendered as a visible pre-battle banner — *"Fortune of War: your levies fight at 116%, theirs at 91%."* A visible die roll that the player watches before the fight is dramatic; the identical maths applied silently reads as a bug report.

### Win-probability table at `FORTUNE_SIGMA = 0.38`

| Might ratio (A/D) | Attacker win % |
|---|---|
| 0.60 | 2.9% |
| 0.70 | 9.3% |
| 0.80 | 20.4% |
| 0.90 | 34.8% |
| 0.95 | 42.5% |
| **1.00** | **50.0%** |
| 1.05 | 57.2% |
| 1.10 | 63.8% |
| **1.20** | **75.0%** |
| 1.35 | 86.7% |
| 1.50 | 93.4% |
| 2.00 | 99.5% |

### The calibration harness — build this, gate CI on it

The table above is the *model*. The simulator must be measured against it, because front-line ordering, wasted excess damage, and rage all bias the result.

```go
// combat/calibration_test.go — MUST run in CI, MUST fail the build on drift.
func TestCombatCalibration(t *testing.T) {
    for _, ratio := range []float64{1.00, 1.05, 1.10, 1.20, 1.50, 2.00} {
        wins := 0
        const N = 50_000
        for i := 0; i < N; i++ {
            a := synthArmy(30, 7, 1.0)      // level 30, 7 units, Might multiplier 1.0
            d := synthArmy(30, 7, 1/ratio)
            if Simulate(a, d, uint64(i)).WinnerIsAttacker { wins++ }
        }
        p := float64(wins) / N
        require.InDelta(t, modelP(ratio), p, 0.03, "ratio %.2f", ratio)
    }
    // The two invariants that matter most:
    // 1. mirror match is a coin flip within the Home Ground bias
    require.InDelta(t, 0.48, measure(1.00), 0.02)
    // 2. the fitted exponent is in the design band
    require.InDelta(t, 6.0, fitK(), 1.5)
}
```

Also assert: **`k` must not drift with army size.** Run the fit at 3v3, 7v7 and 10v10 and require all three within ±1.0 of each other. If they drift, the noise is leaking from a per-unit source and Fortune needs to be the only knob.

### 8.7 Home Ground

The defender's DEF is multiplied by 1.08. This makes a mirror-match attack ≈ 48% rather than 50%, which (a) nudges players to attack slightly *down*, reducing total gold churned by PvP, (b) makes defensive investment visible, and (c) gives the defender something without giving them a win.

---

## 9. PvP rewards and risk

### 9.1 Cost of attacking

```
attack_energy(level) = 6 + floor(level/6)
```
Level 1 → 6 · Level 30 → 11 · Level 60 → 16. Roughly ¼ of a top-tier job.

### 9.2 The steal — **capped by attacker level**

```
base_rate  = 0.03 + war_chest_bonus            # War Chest maxes at 0.05
if revenge: base_rate += 0.01
if second_steal_from_same_target_in_24h: base_rate *= 0.5

STEAL_CAP(att_level) = round(250 * (1 + 0.35*att_level) * (10000 + war_chest_cap_bp)/10000)

stolen = clamp(floor(base_rate * defender_gold_on_hand), 10, STEAL_CAP(att_level))
```

| Attacker level | Base cap | Cap at max War Chest (+64%) |
|---|---|---|
| 1 | 337 | 553 |
| 10 | 1,125 | 1,845 |
| 30 | 3,025 | 4,961 |
| 60 | 5,500 | 9,020 |

**Why cap on the *attacker's* level, not a flat %:** it makes it structurally impossible for a low-level alt account to drain a rich player, and it caps the disaster case (a level-30 player's worst single loss is 3,025 = 16% of a day's income, not "I logged in and lost everything"). Uncollected tax is **not** stealable (§13), which gives players a discoverable, legitimate way to shelter income.

**No vault, no bank.** The correct counterplay to being robbed is **spending your gold**, which is precisely the behaviour the economy wants. A vault would be a trivially-abused safe and would remove the game's best sink accelerator. Say this out loud in the design; do not add a bank later.

### 9.3 What the attacker risks

On a loss the attacker forfeits **only the energy** — no gold. PvP must be strictly attractive or it dies. But a loss is not free:
- The re-attack cooldown on that target still applies (a wasted opportunity).
- W/L is public on the profile (social cost).
- The **defender** collects a ransom.

### 9.4 Rewards summary

| Event | Attacker | Defender |
|---|---|---|
| Attacker wins | +stolen gold, +XP (full), +rep, 20% item drop | −stolen gold, **30-min shield** |
| Attacker loses | +XP (35%), +2 rep | **+ransom**, +5 rep, no shield |
| Revenge win | +4% steal (same cap), ×1.5 rep, shield **not** broken | as above |

**Ransom (a small, deliberate faucet):**
```
ransom = floor(would_have_been_stolen * (0.40 + 0.05*ransom_coffers_level))
```
40% base, up to 80% at max Ransom Coffers. This makes "you were attacked" sometimes *good* news, and it is the only thing that makes Defense stat points and the Bulwark upgrade worth buying. Minted, not transferred — quantified in §14.

**XP:** `round((10 + 0.8*def_level) * gap_mult)`, ×0.35 on a loss.

**Kingdom reputation:**
```
rep = clamp(round(8 * (def_might / att_might)^0.6), 3, 40)     # on a win
rep = 2 (attacker loss) | 5 (successful defence)
daily cap per member = 150
```
Attacking *up* is the rep-efficient play by design.

### 9.5 Matchmaking

The Attack tab shows **5 candidates**, refreshed free every 10 minutes, after any attack, or instantly for 5 diamonds.

```sql
SELECT id, name, level, might, kingdom_id, gold
FROM players
WHERE id <> $me
  AND level BETWEEN $lvl - $band AND $lvl + $band       -- band = max(3, ceil(0.20*level))
  AND might BETWEEN $might*0.70 AND $might*1.60
  AND (shield_until IS NULL OR shield_until < now())
  AND (kingdom_id IS NULL OR kingdom_id <> $my_kingdom)
  AND last_seen_at > now() - interval '7 days'
  AND level >= 8 AND created_at < now() - interval '48 hours'
  AND id NOT IN (SELECT target_id FROM attack_cooldowns
                 WHERE player_id = $me AND expires_at > now())
ORDER BY random() LIMIT 5;
```

> **Postgres note:** you cannot put `now()` in a partial-index predicate (not `IMMUTABLE`). Use a plain composite index `(level, might) INCLUDE (shield_until, last_seen_at, kingdom_id)` and filter in the query. `ORDER BY random()` over a filtered set is fine up to ~100k rows; past that, switch to a `TABLESAMPLE SYSTEM_ROWS(200)` pre-filter.

If fewer than 5 candidates survive: widen the Might band in 0.1 steps to [0.55, 2.00], then the level band, then **fall back to bot targets**.

**Bots are mandatory at launch.** With a small population the query returns nothing and the Attack tab is dead on arrival. Generate "wandering warband" NPCs: `Might = player_might × uniform(0.80, 1.15)`, an army composition derived from that Might, a name from a medieval name table, and a gold purse from `bot_gold(level) = round(400 * 1.06^level)`. Bot gold is **minted** (count it in §14). Bots have no shield, no kingdom, cannot be revenged, and grant **half rep**. Recommendation: do **not** visibly label them as bots (it kills the fantasy), but do log them distinctly and phase them out as the real pool grows — set the bot ratio as a runtime config (`BOT_FILL_RATIO`, start at 1.0, target 0.0).

**Candidate card shows:** name, level, kingdom tag, Might, and a coarse strength badge — *Weaker / Even / Stronger / Much Stronger* derived from the Might ratio. **Never show the win percentage.**

### 9.6 Anti-farming

| Mechanic | Value |
|---|---|
| Re-attack cooldown on the same target | **6 hours** (revenge exempt) |
| Max attacks on one player per 24 h | **2** (including revenge) |
| Diminishing steal (2nd steal within 24 h) | **×0.5** |
| New-player protection | level < 8 **or** account < 48 h: cannot be attacked, cannot attack |
| Global budget | energy (no separate cap) |

### 9.7 Revenge

When attacked, the defender receives a **Revenge token** against that attacker, valid 24 h, one per incoming attack, shown as a red badge on the Attack tab.

A revenge attack: **half energy cost**, **ignores the target's shield** (essential — otherwise the person who just robbed you is untouchable), **+50% rep**, **4% steal** (same cap), and **does not break your own shield**.

This is the single highest-value retention mechanic in async PvP: it converts "I was robbed" from a churn event into a push notification the player *wants* to open.

### 9.8 What stops a whale farming beginners

Not a ban — an alignment of incentives that makes it pointless:

1. **Level band** `±max(3, 20%)` — a level-60 player cannot reach below level 48.
2. **Might floor 0.70×** — trivially weak targets are removed from the pool entirely.
3. **New-player protection** — level 8 / 48 h.
4. **3% of a poor player's gold is worthless.** A beginner holds ~500 gold; 15 gold is not worth 16 energy.
5. **Rep scales as `(def_might/att_might)^0.6`** — farming down earns the floor of 3 rep vs 40 for attacking up. Kingdom standing punishes bullying.
6. **Loot rolls on `max(att_level, def_level)`** — farming down gives the worst loot table.
7. **6-hour cooldown** caps the rate regardless.

Farming down is legal and strictly dominated in every currency the game tracks. That is a better answer than a prohibition, which players route around.

---

## 10. The 30-minute shield

### 10.1 Rules

| Situation | Shield? |
|---|---|
| Defender **loses** a defence | **Yes — 30 minutes** |
| Defender **wins** a defence | No (evidently fine) |
| Attacker loses an attack | No (you chose the fight) |
| Attacker wins | No |

`SHIELD_DEFEAT_MINUTES = 30`, stored as `players.shield_until timestamptz`.

While shielded:
- The player is excluded from every target list **and** any direct `POST /attack` is rejected server-side. Check in **both** places — defence in depth, because the list is cached client-side for up to 10 minutes.
- Collect, shop, upgrades, recruiting, training are all unaffected.

### 10.2 Does attacking break your own shield? — **Yes**

**Recommendation: attacking immediately cancels your shield.** Without this rule, the dominant strategy is "get beaten once, then raid freely for 30 minutes while untouchable" — an exploit that *rewards losing*. Show a confirmation: *"Attacking will end your protection (28m remaining). Continue?"*

**One exception: revenge attacks do not break the shield.** Retaliating against the person who just beat you must always be safe, or revenge — the best retention hook in the game — becomes a trap that costs you 28 minutes of safety.

### 10.3 Stacking and paid protection

Defeat shields cannot stack (you cannot be attacked while shielded, so a second defeat is impossible). Paid protection **extends**:

```
shield_until = min(max(now, shield_until) + purchased_duration, now + 24h)
```

| Paid protection | Diamonds |
|---|---|
| 2 hours | 25 |
| 8 hours | 70 |
| 24 hours | 150 |

Same cancel-on-attack rule. **No refund on cancellation** — state this in the purchase copy, in plain English, before the confirm. A player who is surprised by this will leave a 1-star review.

Two guards against turtling:
- Total shield duration capped at **24 h**.
- A player under **paid** protection is excluded from the "Most Gold" leaderboard.

Future: shields do not apply inside a scheduled kingdom war.

---

## 11. Family upgrades

### 11.1 Stacking rule — stated explicitly

**Every Family upgrade percentage is ADDITIVE within its bucket (§0.3).** Family + Kingdom + job milestones all add into the same bucket, and the bucket applies once, multiplicatively, to the base value. There is no compounding between upgrades. Every bucket is hard-capped.

Worked check: maxed Granary (+60%) + maxed Royal Granaries (+20%) + a fully-mastered job (+30%) = **+110%**, i.e. ×2.10 on base gold — comfortably inside the +150% cap, with headroom for future content.

### 11.2 The tree

```
cost(level) = round(base * growth^(level-1))
```

| # | Name | Bucket / Effect | Max Lv | Per level | At max | Base | Growth | Lv-max cost | **Total** |
|---|---|---|---|---|---|---|---|---|---|
| 1 | **Granary** | `collect_income_bp` | 20 | +3% | +60% | 400 | 1.36 | 137,816 | 519,526 |
| 2 | **Tithe Barn** | `tax_income_bp` +5%, offline cap +12 min | 20 | +5% / +12m | +100% / +4h | 500 | 1.36 | 172,270 | 649,410 |
| 3 | **Scriptorium** | `xp_bp` | 15 | +2% | +30% | 900 | 1.42 | 121,977 | 410,257 |
| 4 | **Watchtower Beacons** | `energy_regen_bp` | 10 | +4% | +40% | 4,000 | 1.55 | 206,560 | 574,850 |
| 5 | **Larder** | max energy (flat) | 25 | +4 | +100 | 300 | 1.28 | 112,243 | 512,040 |
| 6 | **Armoury** | `soldier_atk_bp` | 20 | +3% | +60% | 500 | 1.36 | 172,270 | 649,410 |
| 7 | **Bulwark** | `soldier_def_bp` | 20 | +3% | +60% | 500 | 1.36 | 172,270 | 649,410 |
| 8 | **Stables** | `soldier_spd_bp` | 12 | +4% | +48% | 2,500 | 1.48 | 186,560 | 570,018 |
| 9 | **Merchant Ties** | `shop_discount_bp` | 10 | +2% | +20% | 4,000 | 1.60 | 274,878 | 726,341 |
| 10 | **War Chest** | steal +0.25%, steal cap +8% | 8 | +0.25%/+8% | 5% / +64% | 8,000 | 1.75 | 402,121 | 927,615 |
| 11 | **Ransom Coffers** | defence ransom +5% | 8 | +5% | 80% | 6,000 | 1.72 | 267,209 | 629,999 |
| 12 | **Squire's Training** | +2 stat points (one-time each) | 5 | +2 pts | +10 pts | 15,000 | 2.10 | 291,722 | 543,287 |
| | | | | | | | | **TOTAL** | **7,362,163** |

### 11.3 Why the total is deliberately unreachable

A player's lifetime gold at level 60 (~day 91) is roughly **3.5-4.5 M**. Maxing the entire tree costs **7.36 M** — about 1.7× that. This is intentional: the Family tree is the long-tail gold sink that absorbs post-cap income (§14). A level-60 player will have roughly **45-55%** of the tree, and every one of the 12 nodes remains a live choice. There is no "I finished the upgrades" cliff.

Ordering guidance surfaced in the UI (a "Recommended" chip): Granary → Larder → Tithe Barn → Armoury/Bulwark → Beacons → the rest.

---

## 12. Kingdom system

### 12.1 Founding and membership

| | |
|---|---|
| Founding cost | **250,000 gold** + **level 20** minimum |
| Founder role | King |
| Roles | King · Marshal (invite/kick) · Member |
| Joining | Invite-only in v1 (optionally "open to applications" later) |
| Member cap | `5 + 5 × kingdom_level` → 10 (Lv1) … 45 (Lv8), +10 more from Royal Court |
| Kingdom XP | 1 per gold donated + 100 per reputation earned by members |
| Level requirement | `kingdom_xp(L) = 150,000 × L^1.9` → Lv2 560k, Lv3 1.19M, Lv8 7.28M |

### 12.2 Donations

```
daily_donation_cap(player) = 20,000 + 800 * player_level
```
Level 30 → 44,000/day; level 60 → 68,000/day. This prevents one whale from instantly maxing a kingdom and blocks alt-account gold laundering.

**Donating must reward the donor personally, or nobody donates.** Each 100 gold donated grants **1 Kingdom Favour**, spendable in a small Kingdom Shop:

| Kingdom Shop item | Favour |
|---|---|
| Energy potion (+25 energy) | 40 |
| Shop instant refresh | 25 |
| Attack target refresh | 15 |
| Kingdom banner cosmetic | 800 |
| +10% XP for 2 hours (into `xp_bp`, capped) | 120 |

### 12.3 The kingdom upgrade tree

Funded from the treasury (donations only). Same additive-bucket rule.

| Name | Bucket | Max Lv | Per level | At max | Base cost | Growth |
|---|---|---|---|---|---|---|
| **Royal Granaries** | `collect_income_bp` | 10 | +2% | +20% | 50,000 | 1.55 |
| **Royal Archives** | `xp_bp` | 10 | +1.5% | +15% | 60,000 | 1.55 |
| **Royal Treasury** | `tax_income_bp` | 10 | +4% | +40% | 50,000 | 1.52 |
| **Royal Armoury** | `soldier_atk_bp` | 8 | +2% | +16% | 80,000 | 1.60 |
| **Royal Bulwark** | `soldier_def_bp` | 8 | +2% | +16% | 80,000 | 1.60 |
| **Royal Couriers** | `energy_regen_bp` | 6 | +2% | +12% | 150,000 | 1.70 |
| **Royal Banners** | rep gain +% | 6 | +5% | +30% | 120,000 | 1.65 |
| **Royal Court** | member cap +2 | 5 | +2 | +10 | 200,000 | 1.80 |

Maxing everything costs roughly **35 M** kingdom gold. A 30-member kingdom donating ~10% of income (≈150k/day) needs ~230 days — correctly a long-horizon collective goal, not a checklist.

### 12.4 Reputation and leaderboards

- Earned per attack (§9.4), capped at **150/member/day**.
- **Decays 2%/day**, applied by a nightly job. Decay is what keeps the leaderboard alive and stops a kingdom that quit in month 1 from squatting rank 1 forever.
- Rep converts to kingdom XP at 100:1 for levelling.

| Leaderboard | Scope | Refresh |
|---|---|---|
| Kingdom Reputation | weekly season, Mon 00:00 UTC, **25% carryover** | 5 min (materialised view) |
| Kingdom Might | `SUM(member.might)` | 5 min |
| Individual Might | global top 100 | 5 min |
| Weekly Gold Stolen | individual, top 100 | 5 min |

Weekly season rewards: top-10 kingdoms split diamonds among members (rank 1: 100 dia/member, scaling down to 20 at rank 10) + a seasonal banner.

### 12.5 What stops a dead kingdom from trapping members

Five mechanisms, in order of importance:

1. **Kingdom bonuses apply the instant you join — no ramp, no loyalty timer.** Switching to a better kingdom is never punished. This is the strongest anti-trap measure and it is purely a design restraint: *do not add a loyalty mechanic.*
2. **Leave freely at any time**, no cost. A 24 h re-join cooldown only (prevents hopping to farm join bonuses).
3. **Inactive-King succession.** If the King has not logged in for **7 days**, any Marshal may claim the throne immediately. If there is no active Marshal, the highest-Might member seen within 48 h may claim it after a **24 h notice** visible to all members.
4. **Auto-dissolve.** A kingdom with zero member logins for **30 days** is archived; members are freed and receive a pro-rata refund of **25% of their personal lifetime donations**.
5. **The treasury is never refundable on leaving** — otherwise donations become a savings account and the whole system is a laundering vector. State this in the donate confirm dialog.

---

## 13. Hybrid idle income (the tax)

### 13.1 What it is a function of

**Level, the Tithe Barn, the Royal Treasury, VIP, and the number of soldier slots owned.** Explicitly **not** Might or equipment — keeping gear out of the idle formula prevents a feedback loop where PvP power buys income which buys PvP power.

```
tax_gold_per_hour(L) = 24 * 1.045^L
tax_milli_per_sec    = floor( tax_gold_per_hour(L) * 1000 / 3600
                              * (10000 + tax_income_bp) / 10000
                              * (10000 + 300*soldier_slots_owned) / 10000 )
```

Display it as **gold/hour**, never gold/second (0.0067/s reads as nothing).

### 13.2 Offline accrual

```
elapsed_sec  = min(now - tax_updated_at, TAX_OFFLINE_CAP_SEC)
pending_milli= tax_milli_per_sec * elapsed_sec
```
`TAX_OFFLINE_CAP_SEC = 28800` (8 h), **+720 s per Tithe Barn level** → 12 h at max.

Tax accrues while **online too** (uncapped while the session is live) and auto-collects every 60 s or on tap. Do not write to the DB on every request — compute pending on read, credit atomically on the "Collect Taxes" tap and on login. Store `tax_milli_accrued` and `tax_updated_at`.

> **Uncollected tax is not stealable.** This is a discoverable, legitimate way for players to shelter income from raiders — and the 8-12 h cap is what stops it becoming an infinite bank. Good emergent depth from one line of design.

### 13.3 The math at levels 1, 20, 50

Target ratio: **offline tax over 8 h ≈ 22% of what 8 h of active collecting would earn**, rising to **~45%** with a maxed Tithe Barn + Royal Treasury.

| Level | Tax/hr (base) | 8 h base | 8 h active-collect equivalent | **Ratio (base)** | 8 h at max tax bonus (×2.4) | **Ratio (maxed)** |
|---|---|---|---|---|---|---|
| 1 | 25.1 | 201 | 960 | **21%** | 482 | 50% |
| 10 | 37.3 | 298 | 1,440 | 21% | 716 | 50% |
| 20 | 57.9 | 463 | 2,592 | **18%** | 1,111 | 43% |
| 30 | 89.9 | 719 | 4,704 | 15% | 1,726 | 37% |
| 50 | 216.8 | 1,734 | 8,549 | **20%** | 4,162 | 49% |
| 60 | 336.7 | 2,693 | 12,725 | 21% | 6,464 | 51% |

The dip around level 20-30 is where the job ladder unlocks fastest; it self-corrects. If the owner wants it flatter, raise the exponent from 1.045 to 1.048 (tuning knob `TAX_GROWTH`).

**Design consequence:** the Tithe Barn is the highest-value Family upgrade for a low-session-count player and near-worthless for a no-lifer. That is a genuine build choice — *idle player vs active player* — and it is why the hybrid model earns its complexity.

---

## 14. Gold sources vs sinks

### 14.1 Every source

| # | Source | Type | Magnitude at Lv 30 |
|---|---|---|---|
| 1 | Collect jobs | **Faucet** (primary) | 14,225/day |
| 2 | Tax income | **Faucet** | 1,887/day |
| 3 | PvP steal | **Transfer** (net zero population-wide) | +936 / −576 = +360/day |
| 4 | Defence ransom | **Faucet** (small) | 154/day |
| 5 | Item sales (loot) | **Faucet** (small) | 154/day |
| 6 | Item sales (bought) | Partial refund (25%) | player-driven |
| 7 | Daily quests | **Faucet** | 2,160/day |
| 8 | Level-up reward `250 × level` | **Faucet** (tiny) | ~560/day |
| 9 | Bot purses | **Faucet** — must be monitored | scales with `BOT_FILL_RATIO` |
| 10 | **Diamonds → gold** | **DOES NOT EXIST** | — |

> ### Rule: diamonds never buy gold, and never buy power.
> This single decision is the biggest structural protection the economy has. Diamonds buy *time* (energy refills, refreshes) and *safety* (protection) and *cosmetics*. If a future PM proposes a gold bundle, the correct answer is a gold *multiplier for a limited time* (which flows through the capped `collect_income_bp` bucket) — never a lump sum.

### 14.2 Every sink

| # | Sink | Type | Magnitude at Lv 30 |
|---|---|---|---|
| 1 | Shop item purchases | **Burn** (75% burned, 25% recoverable) | 2,500/day |
| 2 | Soldier slot purchases | **Burn** (100%) | 3,700/day amortised |
| 3 | Soldier recruits / re-recruits | **Burn** (100%) | 8,600/day |
| 4 | Soldier training | **Burn**, unbounded in level | player-driven |
| 5 | Item reforge | **Burn**, unbounded | player-driven |
| 6 | Family upgrades | **Burn** (100%) | 4,000/day |
| 7 | Kingdom donations | Removed from the individual | 2,000/day |
| 8 | Kingdom upgrades | **Burn** (100%) | collective |
| 9 | Kingdom founding | **Burn** — 250,000 | one-time |
| 10 | Manual shop refresh `200 + 60×level` | **Burn** (3/hr free-with-gold, then diamonds) | ~1,000/day |
| 11 | PvP losses | Transfer | (see #3) |

### 14.3 Steady-state balance at level 30

| Sources | /day | | Sinks | /day |
|---|---|---|---|---|
| Collect | 14,225 | | Shop items | 2,500 |
| Tax | 1,887 | | Recruits | 8,600 |
| PvP net | 360 | | Slots (amortised) | 3,700 |
| Ransom | 154 | | Family upgrades | 4,000 |
| Loot sales | 154 | | Kingdom donation | 2,000 |
| Quests | 2,160 | | | |
| **Total** | **18,940** | | **Total** | **20,800** |

**Sinks exceed sources by ~9%.** That is the correct shape: an engaged player is *always slightly gold-hungry*, which keeps every purchase a real decision. It is also a thin margin — see §Risks.

### 14.4 The non-inflation proof

**Claim: total gold income per player per day is bounded above by a computable constant; total sink capacity is unbounded. Therefore the economy cannot inflate.**

*Sources are bounded:*
- Collect income = `energy_per_day × gold_per_energy × (1 + collect_income_bp)`. Each factor is capped:
  - `energy_per_day ≤ 86400/60 × 1.60 = 2,304` (regen bucket capped at +60%)
  - `gold_per_energy ≤ 26.53` (job 15, the last job, and level is capped at 60)
  - `collect_income_bp ≤ 15000` (+150%)
  - → **≤ 152,800 gold/day**
- Tax = `24 × 1.045^60 × 24h × 4.0` (tax bucket capped at +300%) → **≤ 32,300/day**
- PvP steal is a *transfer* — it moves gold, it does not create it.
- Ransom, loot sales, quests and level-ups are all bounded by level 60 and by daily caps.
- → **Hard ceiling ≈ 190,000 gold/day for a theoretical no-lifer at max level with every bucket maxed.**

*Sinks are unbounded:*
- **Soldier training** costs `60 × 1.09^L × tier_mult` per level and there is no cap on repeated re-recruit-then-train cycles.
- **Item reforge** costs `0.60 × shop_price` per attempt, unlimited, and produces zero power inflation (quality caps at 115%).
- **Gladiator re-recruiting** is a probability chase with no terminal state.
- The **Family tree** (7.36 M) and **Kingdom tree** (~35 M) exceed lifetime income by design.

∎ **Source-bounded, sink-unbounded is the only structurally safe configuration.** Write this as an invariant that must never be broken by future content: *any new faucet must be inside a capped bucket; any new sink may be uncapped.*

### 14.5 When does a player have more gold than they can spend?

The danger zone is **post-level-60 with a mostly-maxed Family tree and 10 slots** (~day 130+). Income ~90k/day; remaining sinks are recruits and items. Two Gladiator rerolls/day absorbs 91,200 — it holds, but only just, and only while the tier chase stays motivating.

**Three answers, in build order:**
1. **Reforge (v1)** — infinite, zero balance risk. Build it.
2. **Soldier Training (v1)** — `1.09^L` scaling makes it effectively unbounded.
3. **Legacy / prestige (v1.1)** — reset level to 1, keep items and soldiers, gain a permanent **+5% to all income** (a "Legacy stack," max 10 = +50%, flowing through the *capped* buckets). This is the standard idle-game terminal sink: income growth can never outrun sinks because the sink becomes "the next Legacy run." Mark it as the planned answer for month 4+.

---

## 15. Monetization

### 15.1 Principles

- **No diamond → gold.**
- **No diamond → power.** No paid slots, no paid recruits, no paid stats.
- **No paid loot boxes.** Every diamond purchase states exactly what it gives.
- **No unbounded escalating timers.** Energy refills cap at 150 diamonds.
- **No interrupting ads.** Rewarded video only, opt-in.

The product is: **diamonds buy time and safety.**

### 15.2 What diamonds buy

| Item | Diamonds | Notes |
|---|---|---|
| Energy refill (full) | 20 / 30 / 45 / 70 / 100 / **150 cap** | 1st-5th of the day, then flat |
| Shop instant refresh | 8 | unlimited |
| Attack target refresh | 5 | unlimited |
| Protection 2 h | 25 | cancelled by attacking, no refund |
| Protection 8 h | 70 | |
| Protection 24 h | 150 | total shield capped at 24 h |
| Stat respec | 200 | first one free |
| Name change | 100 | first one free |
| Cosmetic portrait / frame / kingdom banner | 150 - 600 | pure cosmetic |
| **Royal Charter** (30-day battle pass) | 900 (~$8) | 30-tier track: energy potions, gold, cosmetics, **1 guaranteed epic+ item at tier 30** |
| **Crown Patronage** (VIP subscription) | **$6.99/mo** | +25% `tax_income_bp`, +1 free refill/day, 2 free shop refreshes/hour, auto-collect taxes, auto-collect unlocked at Lv 15 instead of 25, ad-free. **Zero combat power.** |

Explicitly **not** sold: soldier slots, recruits, item upgrades, kingdom founding, stat points, XP boosts that exceed the `xp_bp` cap.

### 15.3 Diamond packages

| Pack | Diamonds | USD | $ per 100 | Bonus vs base |
|---|---|---|---|---|
| Handful | 100 | $1.99 | $1.99 | — |
| Pouch | 550 | $9.99 | $1.82 | +10% |
| Chest | 1,200 | $19.99 | $1.67 | +20% |
| Hoard | 3,300 | $49.99 | $1.51 | +32% |
| Treasury | 7,000 | $99.99 | $1.43 | +40% |

### 15.4 Free diamond faucet

| Source | Amount |
|---|---|
| Daily login (7-day cycle) | 5 / 5 / 10 / 10 / 15 / 15 / 25 |
| Level-up | 10 (50 every 10th level) |
| Job milestone (100 / 250 / 500 / 1000) | 15 / 25 / 40 / 75 |
| Weekly kingdom rep top-10 | 20-100 per member |
| Rewarded video (later) | 3/day × 10 |
| Starting grant | **50** |

A free player earns **~30-50 diamonds/day → roughly one free energy refill per day.** That is the explicit design intent: **the free player gets one bonus session daily.** Over 90 days a free player accumulates ~2,800-3,500 diamonds ≈ 30-37 refills, plus a cosmetic or two.

### 15.5 Conversion points

| # | Moment | Offer | Framing |
|---|---|---|---|
| 1 | Minute 8-12 of session 1 | First refill at a discounted **10 diamonds** (they hold 50 free) | Teaches the mechanic at zero cost. Non-modal banner. |
| 2 | **Level 8-10** | **Starter Chest, $2.99**: 300 diamonds + 5,000 gold + 1 guaranteed rare item. One-time, 48 h window. | Historically the highest-converting SKU in this genre. |
| 3 | First PvP defeat with real gold lost | 2 h protection | **Not** on the defeat screen — that reads as predatory. Offer on the *next* Attack tab visit. |
| 4 | Level 20 / kingdom founding | Royal Charter (battle pass) | "Your kingdom needs a treasury." |
| 5 | Level 30+ | Crown Patronage (VIP) | Framed entirely around offline tax, for the player who logs in twice a day. |

**Targets to validate:** ARPDAU **$0.06-0.10**, payer conversion **2.5-4%**, D1 40% / D7 18% / D30 8%.

---

## 16. The first 10 minutes

New player state at 0:00 — level 1, 60/60 energy, 0 gold, **50 diamonds**, Collect tab only.

| Time | What happens | What it teaches |
|---|---|---|
| **0:00-0:30** | No account wall — auto-create a device-bound guest account. Name pre-filled with a random medieval name ("change later"). One skippable 4-panel card: *"Your father the Baron is dead. The estate is yours. Rebuild the family."* | Zero friction to first tap. |
| **0:30-1:30** | Collect tab, **one job**: *Pick Grapes* (1 energy → 2 gold, 2 XP). Pulsing tap target, **hold-to-repeat enabled**. Tutorial forces 5 collects. At 16 XP → **Level 2**: full energy refill with a celebration, +3 stat points. | Tap = gold + XP. **Level-up = free energy.** |
| **1:30-2:30** | Forced stat-allocation modal (first time only). Three buttons with one-line explanations. Tutorial *suggests* Max Energy, does not force it. → **Family tab unlocks** with a bottom-bar badge animation. | Stat points are a choice you own. |
| **2:30-3:30** | Level 3 (48 XP) → ***Gather Strawberries*** unlocks (2 → 4). Tutorial highlights the **gold-per-energy** column: *"Bigger jobs pay more per energy. Always use the best one you can afford."* | The single most important economic literacy in the game. |
| **3:30-4:30** | ~250-350 gold. **Shop tab unlocks at Level 4** (6 slots, 2 weapons / 2 armor / 2 horses). Tutorial forces the purchase of a scripted common **Rusty Falchion at 120 gold**. **Inventory tab unlocks** in the same beat. Equip flow: Inventory → tap → Equip to Champion. | Buy → equip → your Attack number goes up. |
| **4:30-5:30** | **Level 5 → Family upgrades unlock.** *Granary Lv1* costs **400 gold** — priced so the player is ~200 short, creating a clear 60-second goal. They collect, buy it, and **watch every job's gold number tick up 3%**. | **Permanent upgrades compound.** This is the most important teaching moment in the entire game. |
| **5:30-6:30** | **Soldiers tab unlocks at Level 5.** First slot granted **free** (normally 500). First **Peasant recruit free**, with a **guaranteed uncommon floor** for a good first impression. Its 3 empty gear slots pulse; a second free common item is granted to equip on it. | Slot → recruit → tier. **Soldiers wear gear too.** |
| **6:30-7:30** | **Attack tab unlocks at Level 6.** First target is a **guaranteed bot** ("Bandit Karel", Might = 0.75× the player's) so the first PvP experience is a win. Replay plays in full; **Skip is disabled on this first battle only**. Rewards: gold steal, XP, and a **forced item drop (guaranteed rare)**. | PvP → replay → loot. The hook. |
| **7:30-8:30** | Energy at ~15/60. Tutorial points at the energy bar and the regen timer. **First monetization touch:** a soft, dismissible, non-modal banner — *"Out of energy? A refill costs 20 diamonds — you have 50."* No countdown, no modal, no hard sell. | Energy is the real currency. |
| **8:30-9:30** | With a refill (or with regen), a mixed burst: a few Strawberries + one more attack. Hits **Level 7-8**. **Daily Quests panel unlocks** ("Collect 20 times", "Win 2 attacks", "Buy 1 item") + the **7-day login calendar**. | Come back tomorrow. |
| **9:30-10:00** | Energy runs dry. "Come back in" screen shows: (a) the regen countdown, (b) the **tax bar** on the Family tab — *"Your estate earns 25 gold/hour while you're away, up to 8 hours"*, (c) a **push-notification opt-in** framed as *"We'll tell you when your energy is full."* | Offline income exists. Notifications are useful, not spam. |

**State at the 10-minute mark:** level 7-8, all six tabs unlocked, 1 soldier, 3-4 items, 1 family upgrade bought, 1 PvP win, offline income ticking, push opt-in prompted, a reason to return in ~1 hour and again tomorrow.

### Tab unlock schedule

| Feature | Unlocks |
|---|---|
| Collect | 0:00 |
| Family | Level 2 |
| Shop + Inventory | Level 4 |
| Soldiers | Level 5 |
| Attack | Level 6 (and you cannot *be* attacked until Level 8 / 48 h) |
| Daily quests + login calendar | Level 7 |
| Kingdom (join) | Level 12 |
| Bulk collect ×5/×10 | Level 15 |
| Kingdom (found) | Level 20 + 250,000 gold |
| Auto-collect | Level 25 (Level 15 with VIP) |

---

## 17. Data model (balance-relevant DDL)

```sql
CREATE TABLE players (
  id                  bigserial PRIMARY KEY,
  name                citext UNIQUE NOT NULL,
  level               int    NOT NULL DEFAULT 1,
  xp                  bigint NOT NULL DEFAULT 0,
  gold                bigint NOT NULL DEFAULT 0,       -- on hand; stealable
  diamonds            int    NOT NULL DEFAULT 50,
  energy_milli        bigint NOT NULL DEFAULT 60000,
  energy_updated_at   timestamptz NOT NULL DEFAULT now(),
  pts_energy          int NOT NULL DEFAULT 0,
  pts_attack          int NOT NULL DEFAULT 0,
  pts_defense         int NOT NULL DEFAULT 0,
  pts_unspent         int NOT NULL DEFAULT 0,
  tax_milli_accrued   bigint NOT NULL DEFAULT 0,
  tax_updated_at      timestamptz NOT NULL DEFAULT now(),
  might               bigint NOT NULL DEFAULT 0,        -- denormalised
  shield_until        timestamptz,
  kingdom_id          bigint,
  soldier_slots       int NOT NULL DEFAULT 0,
  reset_offset_min    int NOT NULL DEFAULT 0,           -- for daily resets
  refills_today       int NOT NULL DEFAULT 0,
  shop_refresh_nonce  int NOT NULL DEFAULT 0,
  pity_shop           int NOT NULL DEFAULT 0,
  pity_gladiator      int NOT NULL DEFAULT 0,
  last_seen_at        timestamptz NOT NULL DEFAULT now(),
  created_at          timestamptz NOT NULL DEFAULT now(),
  balance_version     int NOT NULL
);
-- NOTE: now() is not IMMUTABLE, so no partial index. Plain composite + query-side filter.
CREATE INDEX players_matchmaking ON players (level, might)
  INCLUDE (shield_until, last_seen_at, kingdom_id, gold);

CREATE TABLE items (
  id          bigserial PRIMARY KEY,
  owner_id    bigint NOT NULL REFERENCES players(id),
  kind        smallint NOT NULL,        -- 0 weapon, 1 armor, 2 horse
  tier        smallint NOT NULL,        -- 0..6
  ilvl        smallint NOT NULL,
  quality_pct smallint NOT NULL,        -- 85..115
  masterwork  boolean  NOT NULL DEFAULT false,
  attack      int NOT NULL,             -- denormalised, computed once at creation
  defense     int NOT NULL,
  speed       int NOT NULL,
  equipped_on bigint,                   -- NULL | soldiers.id | -1 for the player
  source      text NOT NULL,            -- shop|loot|milestone|quest|tutorial
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX items_owner ON items (owner_id) INCLUDE (equipped_on);
CREATE UNIQUE INDEX items_one_per_slot
  ON items (equipped_on, kind) WHERE equipped_on IS NOT NULL;

CREATE TABLE soldiers (
  id            bigserial PRIMARY KEY,
  owner_id      bigint NOT NULL REFERENCES players(id),
  slot_index    smallint NOT NULL,
  type          smallint NOT NULL,      -- 0 peasant, 1 mercenary, 2 gladiator
  tier          smallint NOT NULL,
  soldier_level smallint NOT NULL,      -- recruit level, raised by Train
  recruited_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (owner_id, slot_index)
);

CREATE TABLE job_progress (
  player_id  bigint NOT NULL REFERENCES players(id),
  job_index  smallint NOT NULL,
  collects   int NOT NULL DEFAULT 0,
  PRIMARY KEY (player_id, job_index)
);

CREATE TABLE family_upgrades (
  player_id     bigint NOT NULL REFERENCES players(id),
  upgrade_index smallint NOT NULL,
  level         smallint NOT NULL DEFAULT 0,
  PRIMARY KEY (player_id, upgrade_index)
);

CREATE TABLE battles (
  id           bigserial,
  attacker_id  bigint NOT NULL,
  defender_id  bigint NOT NULL,
  is_bot       boolean NOT NULL DEFAULT false,
  is_revenge   boolean NOT NULL DEFAULT false,
  winner_att   boolean NOT NULL,
  might_att    bigint NOT NULL,
  might_def    bigint NOT NULL,
  gold_moved   bigint NOT NULL,
  rounds       smallint NOT NULL,
  seed         bytea NOT NULL,
  balance_ver  int NOT NULL,
  created_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id, created_at)
) PARTITION BY RANGE (created_at);

CREATE TABLE battle_replays (
  battle_id  bigint NOT NULL,
  created_at timestamptz NOT NULL,
  blob       bytea NOT NULL,          -- gzipped JSON, ~2 KB
  PRIMARY KEY (battle_id, created_at)
) PARTITION BY RANGE (created_at);    -- drop partitions after 30 days

CREATE TABLE attack_cooldowns (
  player_id  bigint NOT NULL,
  target_id  bigint NOT NULL,
  count_24h  smallint NOT NULL DEFAULT 1,
  expires_at timestamptz NOT NULL,
  PRIMARY KEY (player_id, target_id)
);

CREATE TABLE revenge_tokens (
  id         bigserial PRIMARY KEY,
  player_id  bigint NOT NULL,
  target_id  bigint NOT NULL,
  battle_id  bigint NOT NULL,
  expires_at timestamptz NOT NULL,
  used       boolean NOT NULL DEFAULT false
);

CREATE TABLE kingdoms (
  id             bigserial PRIMARY KEY,
  name           citext UNIQUE NOT NULL,
  tag            varchar(5) UNIQUE NOT NULL,
  king_id        bigint NOT NULL,
  level          smallint NOT NULL DEFAULT 1,
  kingdom_xp     bigint NOT NULL DEFAULT 0,
  treasury       bigint NOT NULL DEFAULT 0,
  reputation     bigint NOT NULL DEFAULT 0,
  rep_season     bigint NOT NULL DEFAULT 0,
  created_at     timestamptz NOT NULL DEFAULT now()
);
```

**The shop needs no table and no cron.** It is a pure function of `(player_id, time_window, refresh_nonce, level, balance_version)`:

```go
func ShopFor(p *Player, now time.Time) [6]Item {
    window := now.Unix() / 300                       // 5-minute window
    seed := seedFor(u64(p.ID), u64(window), u64(p.ShopRefreshNonce),
                    u64(p.Level), u64(p.BalanceVersion))
    rng := NewXoshiro(seed)
    var out [6]Item
    kinds := [6]Kind{Weapon, Weapon, Armor, Armor, Horse, Horse}
    for i := range out {
        out[i] = RollItem(rng, kinds[i], ShopWeights, p.Level, p.Level)
    }
    if p.Level >= 10 { forceAtLeastOne(&out, rng, TierRare) }
    applyPity(&out, rng, p)
    return out
}
```
Zero writes, identical across devices and reconnects, survives an app kill. Purchases are recorded in a small `shop_purchases(player_id, window_id, slot_idx)` table so a bought slot shows as SOLD for the rest of the window.

---

## 18. Go constants (representative extract)

```go
package balance

// ---- Energy ----
const (
    EnergyBaseMax        = 60
    EnergyPerStatPoint   = 3
    EnergyRegenBaseSec   = 60
    EnergyOverflow       = false
    TaxOfflineCapSec     = 28800
    TaxOfflineCapPerBarn = 720
)
var DiamondRefillPrices = [...]int{20, 30, 45, 70, 100} // then RefillPriceCap
const RefillPriceCap = 150

// ---- XP ----
func XPToNext(l int) int64 { return int64(1.7*math.Pow(float64(l),2.2) + 10*float64(l) + 5) }
const (
    StatPointsPerLevel   = 3
    StatPointsPerDecade  = 2
    PlayerAtkPerPoint    = 4
    PlayerDefPerPoint    = 4
    FreshStartBP1to10    = 10000 // +100% xp
    FreshStartBP11to15   =  5000
)

// ---- Tiers ----
var TierMult      = [7]float64{1.00, 1.35, 1.85, 2.55, 3.60, 5.20, 7.60}
var TierPriceMult = [7]float64{1.00, 1.40, 2.20, 3.60, 6.00, 10.0, 17.0}

// ---- Items ----
const (
    ItemLevelGrowth = 0.09
    QualityMin, QualityMax = 85, 115
    MasterworkChance = 0.03
    MasterworkMult   = 1.15
    ShopPriceK       = 1.6
    ShopPriceExp     = 1.35
    SellRate         = 0.25    // asserted in a unit test; never configurable at runtime
    ItemUpgradeMinCostRatio = 0.75 // reserved: enforce if upgrading is ever added
)
var ItemBase = map[Kind][3]float64{ // atk, def, spd
    Weapon: {10, 2, 0}, Armor: {2, 10, 0}, Horse: {5, 5, 6},
}

// ---- Combat ----
const (
    DmgK          = 0.16
    RageStep      = 0.15
    MaxRounds     = 60
    MaxEvents     = 2000
    VarianceLow   = 0.85
    VarianceHigh  = 1.15
    CritMult      = 1.75
    CritBase      = 0.05
    CritScale     = 0.30
    CritCap       = 0.45
    DodgeScale    = 0.20
    DodgeCap      = 0.15
    ChargeBonus   = 0.12
    HomeGroundBP  = 800
    HPPerDef      = 3.0
    DRCap         = 0.60
    DRLevelK      = 40
    DRFlat        = 60

    // THE calibration knob. See §8.6. Changing this changes PvP feel more
    // than every other constant in this file combined.
    FortuneSigma  = 0.38
)

// ---- PvP ----
const (
    StealRateBase   = 0.03
    StealRateRevenge= 0.04
    StealCapBase    = 250.0
    StealCapPerLvl  = 0.35
    StealMin        = 10
    ShieldMinutes   = 30
    ReattackHours   = 6
    MaxAttacksPerTarget24h = 2
    RansomBase      = 0.40
    LootDropChance  = 0.20
    RepDailyCap     = 150
    RepDecayPerDay  = 0.02
)
```

---

## 19. Tuning-knob index

Numbers marked **KNOB** are the ones I would expect to move in playtest. Everything else should stay put unless the whole model is re-derived.

| Knob | Current | Moves what | Sensitivity |
|---|---|---|---|
| **`FortuneSigma`** | 0.38 | PvP determinism (§8.6 table) | **Extreme** — the single highest-leverage constant |
| `gpe_growth` | 1.22 | Late-game gold magnitude | High — raise to 1.24 for bigger numbers |
| `EnergyRegenBaseSec` | 60 | Total daily throughput for everyone | **Extreme** |
| XP curve exponent | 2.2 | Days-to-level-60 | High |
| `TAX_GROWTH` | 1.045 | Active vs idle ratio | Medium |
| `slot_cost` growth | 2.05 | How many soldiers a player has | High |
| `recruit_cost` slope | 0.11/level | Late-game sink depth | Medium |
| Family upgrade growth rates | 1.28-2.10 | Long-tail sink depth | Medium |
| `StealCapPerLvl` | 0.35 | PvP stakes | Medium |
| `LootDropChance` | 0.20 | Gear acquisition rate | Medium |
| Milestone cap | +30% | Job specialisation depth | Low |
| `RansomBase` | 0.40 | Whether Defense is worth buying | Medium |
| `DailyDonationCap` | 20k + 800×lvl | Kingdom progression speed | Low |
| `BOT_FILL_RATIO` | 1.0 → 0.0 | Attack tab liveness at launch | High early, zero later |


---

## Key decisions

- **Energy regen is a FLAT rate (1 per 60 s, capped at +60% by upgrades); Max Energy only increases offline banking, never daily throughput.**
  - Rejected: Max Energy scaling daily throughput (e.g. regen proportional to max, or a percentage-per-minute regen).
  - Why: This is what makes the total gold supply provably bounded (§14.4). If Max Energy raised throughput, income would compound with stat points and every faucet cap in the document would be meaningless. It also creates a clean, teachable split: Max Energy = 'how long can I be away', regen = 'how much do I earn per day'.
- **PvP is a volley auto-battle: every living unit on a side contributes damage each round, and all of it lands on the enemy's single front unit.**
  - Rejected: Shakes & Fidget style 1v1 hero duels; or full simultaneous melee where every unit takes damage.
  - Why: Volley-with-front-line makes Sum(ATK) and Sum(EHP) exactly additive, which means Might = 2*sqrt(SumATK * SumEHP) is precisely the quantity the simulator decides on — the displayed power number and the battle agree by construction. It also renders well in portrait (one HP bar dropping at a time, a volley of damage numbers) and back-line soldiers matter from round 1, so buying slots always feels good. Duels cannot express an army; full melee is unreadable at 10v10 on a phone.
- **Combat randomness comes from a per-SIDE 'Fortune of War' roll (lognormal, sigma = 0.38), surfaced in the UI as a visible pre-battle die roll, targeting a 75% win rate at +20% Might.**
  - Rejected: Tuning per-hit crit/dodge/damage variance to control the win curve; or a per-unit morale roll.
  - Why: Per-hit noise provably cannot control the win curve — with ~200 damage rolls per side the CV falls under 0.04 and any 20% advantage wins ~100% of the time. A per-unit roll shrinks as 1/sqrt(N), so the win curve would silently drift as players buy soldier slots. Only a per-side, per-battle roll gives a constant, tunable exponent. Showing the roll before the fight converts a large multiplier from 'feels like a bug' into 'I watched the dice'.
- **Diamonds never buy gold and never buy power. No paid soldier slots, recruits, stat points or item upgrades.**
  - Rejected: Gold bundles and paid soldier slots — the standard idle-game monetization.
  - Why: A gold bundle is an uncapped faucet that instantly invalidates the §14.4 non-inflation proof and destroys the 9% sink-over-source margin the whole economy rests on. Paid power poisons PvP, which is the retention engine. Diamonds selling time (refills, refreshes) and safety (protection) is both defensible and, per the §15 model, viable at $0.06-0.10 ARPDAU. If a gold offer is ever needed, it must be a time-limited multiplier flowing through the capped collect_income bucket, never a lump sum.
- **All percentage bonuses are ADDITIVE within one of eight hard-capped buckets, applied by a single function ApplyBucket() that CI enforces as the only call site.**
  - Rejected: Multiplicative stacking of upgrade bonuses (the more common and more 'satisfying' idle-game convention).
  - Why: Five sources of +20% must give +100%, not x2.49. Multiplicative stacking is exactly how idle economies inflate past the point where any sink can absorb income. The single-chokepoint rule matters as much as the math: this invariant is trivially broken by a well-meaning feature PR six months from now, so it needs a lint, not a comment.
- **The steal is capped by the ATTACKER's level (250 * (1 + 0.35*level)), not by a flat percentage, and there is no vault or bank.**
  - Rejected: Uncapped 3%; or adding a gold vault that shelters a deposited balance.
  - Why: The attacker-level cap makes it structurally impossible for a low-level alt to drain a rich player, and it bounds the worst-case single loss at ~16% of a day's income rather than an account-wiping event. Refusing a vault is deliberate: the correct counterplay to being robbed is SPENDING your gold, which is precisely the behaviour the sink-heavy economy wants. Uncollected tax (capped at 8-12 h) already provides a legitimate, discoverable shelter.
- **Attacking cancels your own 30-minute defeat shield — except for revenge attacks, which do not.**
  - Rejected: Shield persists regardless of what you do while under it.
  - Why: Without the cancel rule, the dominant strategy becomes 'lose once on purpose, then raid freely for 30 minutes while untouchable' — an exploit that rewards losing. The revenge exception is equally necessary: retaliating against the person who just robbed you must always be safe, or revenge (the strongest retention hook in async PvP) becomes a trap that costs 28 minutes of protection.
- **Mystic resolves to magenta (#E040FB) with a holographic sheen; epic keeps standard violet (#A855F7). Rarity is never communicated by colour alone — every card also shows the tier name and a gem-count/crown frame.**
  - Rejected: Honouring the owner's spec literally with two purples.
  - Why: At 44 px thumbnail size two purples are the same colour, which makes the shop unreadable and the whole tier ladder illegible at a glance. Magenta stays inside the purple family so the owner's intent survives. The name+frame redundancy is separately required for deuteranopia accessibility and is worth having regardless of which hues are chosen.
- **Soldiers freeze their stats at recruit level, but a paid 'Train' action (60 * 1.09^L * tier_mult per level) raises them toward the player's current level.**
  - Rejected: Soldiers auto-scale with the player's current level; or pure staleness forcing re-recruitment.
  - Why: Auto-scaling removes the game's deepest late-game sink. Pure staleness creates a 'throw your veteran away' moment that feels bad. Train converts obsolescence into an explicit, priced, incremental investment — and because it scales as 1.09^L it is an effectively unbounded gold sink, which §14.4 needs to hold post-cap.
- **Bot 'wandering warband' opponents fill the Attack target list at launch, with a runtime BOT_FILL_RATIO that decays to 0 as the real population grows.**
  - Rejected: Real players only.
  - Why: The matchmaking query (level band AND Might band AND not-shielded AND not-on-cooldown AND active within 7 days) returns zero rows on a small population. Without bots the Attack tab — which owns the replay, the loot faucet and the revenge retention loop — is dead on arrival at launch. Bot purses are minted gold and must be counted in the faucet audit.
- **The shop is a pure deterministic function of (player_id, 5-minute window, refresh nonce, level, balance_version) rather than a stored table refreshed by a cron.**
  - Rejected: A shop_slots table repopulated every 5 minutes by a scheduled job.
  - Why: Zero writes, no cron, no per-player timer state, and the stock is byte-identical across devices, reconnects and app kills. On a pooled Neon connection with a per-request cost model this removes an entire class of write load and an entire class of desync bug. Only purchases need persistence (a tiny shop_purchases row per bought slot).

## Risks flagged

- The PvP win curve is UNVERIFIED until the calibration harness runs. The FortuneSigma = 0.38 -> 75%-at-+20% mapping comes from a lognormal model, not from the simulator. Front-line ordering, wasted excess damage on overkill, and rage compounding will all bias the real result — most likely toward MORE determinism than the model predicts. If TestCombatCalibration is not built and gated in CI before PvP ships, the game's core loop will have unknown feel. Also assert that the fitted exponent k does not drift between 3v3, 7v7 and 10v10; if it does, noise is leaking from a per-unit source and Fortune is no longer the only knob.
- The sink-over-source margin at level 30 is only ~9% (20,800 vs 18,940 gold/day). A single mis-tuned faucet flips the economy inflationary. The most fragile numbers are daily quest gold (12 * level * tier — currently 11% of daily income), bot purses (minted, scales with BOT_FILL_RATIO which starts at 1.0), and the defence ransom (40-80% of the would-be steal). All three must be in the nightly M2 audit from day one, not added later.
- Tap volume collapses with level by design: 60 collects/hour at level 1 down to ~1.1/hour at level 60. If hold-to-repeat (level 1), bulk x5/x10 (level 15) and auto-collect (level 25) are not all shipped, the mid-game reads as 'there is nothing to do' and D30 retention will crater. Hold-to-repeat in particular is required for the tutorial to work at all — day 1 involves ~400 energy of 1-4 energy collects.
- The additive-bucket rule is trivially broken by a well-meaning future PR that writes `gold * (1 + granary) * (1 + kingdom)`. There is no type-system defence; it needs the ApplyBucket chokepoint plus a CI grep. One violation in one endpoint silently makes the §14.4 non-inflation proof false, and it will not be noticed until M2 has already run away.
- Item ilvl is pinned to the player's level at acquisition, so ALL pre-cap gear is disposable. A player who spends 24,686 gold on a mystic weapon at level 30 finds it worth a fraction of a level-60 common by day 90. This is economically correct but emotionally bad. Mitigations exist (Reforge, the Train mechanic's precedent) but the UI must communicate ilvl prominently from day 1 or this generates support tickets and refund requests.
- PvP population density at launch. The matchmaking query has five simultaneous filters; below roughly 2,000 daily-active players in a level band it returns nothing and BOT_FILL_RATIO stays pinned at 1.0 — meaning 'async PvP against real players', the game's headline feature, is not actually happening. Plan for a single global shard, and treat 'when can we turn bots off' as a launch KPI.
- Replay storage growth. At 2 KB gzipped per battle and 6 attacks/day/player, 10,000 DAU produces ~120 MB/day, ~3.6 GB/month. The 30-day partition-drop policy is mandatory, not optional, on Neon pricing. The MAX_EVENTS = 2000 cap must be enforced or a pathological army composition can blow the row size.
- Neon is a POOLED connection and the gold_ledger writes on every collect. At 60 collects/hour/player during early levels this is a meaningful write rate. Batch collects (hold-to-repeat, bulk x10) must produce ONE ledger row with a count, not N rows, or the ledger becomes the throughput bottleneck and the nightly audit query becomes unrunnable.
- Maxing the Family tree costs 7.36M gold against ~4M lifetime income at level 60 — deliberately unreachable. If playtesters read this as 'the upgrades are impossibly expensive' rather than 'there is always something to buy', the framing has failed. The UI must show a recommended purchase order and never show a global completion percentage.
- The 'Fortune of War' roll at sigma = 0.38 produces a +46%/-32% damage swing. Min-maxers will compute it, and some will read it as the game cheating. The mitigation (showing it as a visible pre-battle roll) is a UI dependency on a combat constant — if the client ships without the Fortune banner, the same maths reads as broken.
- Legacy/prestige is deferred to v1.1 but is the actual terminal answer to 'what absorbs a capped player's gold'. Reforge and Train hold the line to roughly day 130. If Legacy slips past that, the most engaged cohort — the one that reached the cap — hits a wall with millions of unspendable gold, which is the single most reliable way to lose a whale.

## Questions raised for the owner

- Is level 60 the launch cap, and is Legacy/prestige in scope for v1.1? The entire §14 sink analysis holds to about day 130; if the cap is meant to be higher (80? 100?) the XP curve exponent (2.2), the collect ladder (15 jobs), and the item ilvl growth (0.09) all need re-deriving together, not individually.
- Do you accept magenta (#E040FB) for mystic, keeping epic as standard violet? If both tiers must read as literally purple, the fallback is epic = muted indigo #6D5BD0 / mystic = bright #E040FB — but I need this settled before any item art is generated, because tier framing is baked into the sprite sheets.
- Is the soldier 'Train' action in v1? Without it, soldiers go permanently stale at their recruit level and the only recourse is re-recruiting (a bigger gold sink but a much worse feel — you throw away a soldier you got attached to). With it, there is one more system to build and one more screen. This decision changes the late-game sink math in §14.5.
- Are bot opponents acceptable in the Attack tab at launch, and should they be visibly labelled as bots? Without them the tab is empty on day 1. Labelling them is honest but breaks the fantasy and tells players the population is small. My recommendation is unlabelled-but-logged with a BOT_FILL_RATIO that decays, but this is a product-integrity call that is yours, not mine.
- Is a VIP subscription ($6.99/mo, tax + convenience only, zero combat power) something you want? It roughly doubles projected LTV in this genre but adds subscription lifecycle handling (App Store receipts, grace periods, restore) that is real backend work, and it changes the §15 conversion funnel.
- 10 soldier slots or 12? I specced 10 for v1 (30 equipment decisions is already the practical ceiling for portrait UI) with 11-12 pre-priced for a later expansion. If you want 12 at launch, the slot cost curve holds but the Soldiers tab needs a different layout than a simple list.
- Should attack loot exist at all? I recommend yes (20% drop, EV of only ~40 gold per win, so it is a content faucet not a gold faucet, and it is the main non-gold reason to attack). But it is the single biggest source of items outside the shop, and if you want the shop to be the definitive gearing path, cutting it simplifies the tier-distribution surface from five tables to four.
- Single global player pool, or regional shards? This is the highest-leverage infrastructure question in the document: it determines whether the §9.5 matchmaking bands can ever be satisfied, how long bots are needed, and whether the kingdom leaderboard is one board or many. Neon is in eu-west-2 (London), which argues for a single global pool at launch.
- What is your tolerance for PvP randomness, concretely? I recommend a 20% Might advantage winning 75% of the time. If you would rather it be 80% (gear matters more, replays matter less) or 68% (upsets are common, min-maxers complain), that is one constant — FortuneSigma — but I need the answer before the calibration test is written, because the test asserts the target.
- Should there be a hard cap on how much gold a single player can hold? There is none in this design. It is not needed for the inflation proof (§14.4 bounds income, not stock), but an uncapped bigint balance combined with the 3% steal means a hoarder can present an enormous single target. I lean toward no cap plus a 'you are carrying a lot of gold' nudge, but it is worth an explicit decision.

---

# Adversarial review — verdict: needs-revision


## BLOCKER (5)

### §2.5's "70% energy capture (≈1,000–1,200 energy/day)" is arithmetically impossible under §1.1's ENERGY_OVERFLOW=false plus §2.6's "3–4 sessions/day". With no overflow, daily captured energy is hard-bounded by sessions × max_energy. At L30 (§1.4 max=190) that ceiling is 4×190 = 760 = 44% of the 1,728 generated — not 70%. The document contains three mutually incompatible capture rates: 70% (§2.5), 58% (implied by §14.3's 14,225 collect line ÷ §1.4's 1,023 gold/hr = 13.9 h/day), and the physically-implied 44%.

**Breaks because:** Every downstream number is derived from this one assumption: the §2.5 level table, the §2.6 day-91 cap target, the §14.3 economy balance, the §5.5 price-pressure argument ("a L30 player earns ~19k/day") and the §15.5 ARPDAU targets. A L30 player actually collects ~10,800 gold/day, not 14,225 — 24% below the modelled figure — so the design ships with an unfalsifiable economy model. It is also self-inflicted: §1.3 explicitly designs FOR the overflow loss ("loses 7 hours of regen — that is the intended pressure") and then models as if the loss did not happen.

**Fix:** Change ENERGY_BASE_MAX from 60 to 120 (single constant). max_energy = 120 + 3·pts_energy + 4·Larder_level then gives L30 = 250 → 4×250 = 1,000/day = 58%, which makes §14.3's collect line exactly self-consistent, and L60 = 370 → 1,480/day = 73%, matching §2.5. This does not touch §14.4's supply ceiling (that bound uses regen × the capped regen bucket, which is unchanged), it doubles the L1 bar to 2 h-to-full which strengthens the idle promise, and it leaves the §1.3 "Max Energy = how long can I be away" teaching intact. Then re-derive §2.5's day-reached column and §14.3 from capture = min(sessions × max_energy, regen × 24) and publish the sessions/day assumption as an explicit named constant MODEL_SESSIONS_PER_DAY = 4 in the balance registry, so playtest can refit it.

### The level-up gold faucet is understated by ~11× and is omitted entirely from the §14.3 balance table. §14.1 books "Level-up reward 250 × level" as "Faucet (tiny), ~560/day". At L30 the reward is 250×30 = 7,500 and §2.5's own table gives 1.20 days per level (day 13.45 → 14.65), so the real rate is 6,250 gold/day. §14.3's source column (Collect 14,225 + Tax 1,887 + PvP 360 + Ransom 154 + Loot 154 + Quests 2,160 = 18,940) contains no level-up line at all.

**Breaks because:** This single line inverts the document's headline economic claim. As written §14.3 shows sinks exceeding sources by 9.8% ("an engaged player is always slightly gold-hungry"). Correcting the level-up faucet gives sources 25,190 vs sinks 20,800 — sources exceed sinks by 21.1%. Even after also correcting the energy-capture error above (which pushes the other way), sources still exceed sinks by 4.6%. The economy as specified is inflationary, and §14.4's "source-bounded, sink-unbounded" conclusion rests on a table that omits its second-largest faucet.

**Fix:** Two changes. (1) Reduce the reward to LEVEL_UP_GOLD = 60 × level (1,800 at L30 ≈ 1,500/day ≈ 7% of income; 3,600 at L60) and move the formula out of the §14.1 table into §2 alongside the other level-up effects (full energy refill, stat points, 10 diamonds), because it is currently specified nowhere in the body. (2) Add an explicit "Level-up" row to §14.3 computed as LEVEL_UP_GOLD(L) ÷ days_per_level(L) taken from the §2.5 table, and add a CI test that recomputes the whole §14.3 table from the balance registry and fails if |sources − sinks| ÷ sources falls outside [−15%, −5%].

### Speed does not appear in the Might formula at all, yet it decisively determines combat outcomes. §7.3 defines Might = 2√(ArmyATK × ArmyEHP) where ArmyATK = Σ unit_atk and ArmyEHP = Σ EHP — neither contains a SPD term. But §5.4 states "SPD counts at 0.5× in the price and Might formulas" and §7.3 claims Might "is monotone increasing in every single stat". Both statements are false. I simulated the §8.3 algorithm against the §7.4 L30 archetype: two armies with byte-identical Might (10,469), one with SPD 41/unit and one with SPD 0, and the fast army wins 75.8% of the time (76.4% at SPD 138). Decomposition shows the bulk is the initiative rule (§8.3 step 4: side with higher ΣSPD volleys first) — flipping the SPD tie-break alone moves a mirror match from 52.0% to 44.4%.

**Breaks because:** Matchmaking (§9.5), the leaderboards (§12.4) and the Weaker/Even/Stronger badge (§9.5) are all Might-based. A player who stacks horses therefore obtains a combat advantage equivalent to +20% Might that is completely invisible to the matchmaker, the opponent and the UI. That is the dominant strategy from the moment a player owns three horses, and it silently invalidates §8.6's entire calibration (which assumes Might is the deciding quantity). Simultaneously, §5.5's price formula DOES charge 0.5×spd, so horses cost 27% more Might-per-gold than weapons at every tier (legendary ilvl60: 38.5 vs 53.0 Might per 1,000 gold) — so the item that is secretly overpowered also reads as overpriced on the only stat the UI shows. The price/Might/combat triangle is incoherent in both directions.

**Fix:** Three coordinated changes. (1) Replace the binary initiative rule with simultaneous volleys: both sides compute their volley against the pre-round state, then both are applied. This removes the ~7.5 pp first-strike asymmetry, which is a step function on "do you own any horse at all" rather than a smooth stat, and it also removes the CHARGE special case's dependence on the tie-break. (2) Keep crit/dodge as SPD's only combat effects and fold their expected value into Might: ArmyATK_eff = ArmyATK × (1 + 0.75 × crit(s, s_ref)), ArmyEHP_eff = ArmyEHP ÷ (1 − dodge(s, s_ref)), Might = 2√(ArmyATK_eff × ArmyEHP_eff), where s = ArmySPD ÷ unit_count and s_ref is a REF_SPD_BY_LEVEL[1..60] lookup in the balance registry seeded from the median SPD-per-unit of the §7.4 archetype at that level. (3) Add a hard CI gate to the §8.6 harness: sim(A_fast, B_slow) at equal Might must return 50% ± 3 pp for s ∈ {0, 41, 98, 138}. Finally, delete the false claim in §5.4 and restate §7.3's monotonicity claim as monotone in ATK, DEF and SPD under the corrected formula.

### Diamond energy refills are an uncapped gold faucet, which breaks both §15.1's stated principle ("No diamond → gold. No diamond → power.") and §14.4's non-inflation proof. §1.5 sells a full refill for 20/30/45/70/100/150 diamonds with no daily count limit ("6+ = 150 capped"). At L60 a full refill is 310 energy; energy converts to gold at a fixed, published rate of 26.53 gpe × the collect bucket. §14.4's ceiling derivation enumerates only regen-generated energy and never mentions refills.

**Breaks because:** At L60, ten refills/day (745 diamonds ≈ $11) yields 3,100 extra energy = 172,710 gold/day — on top of the 190,000/day figure §14.4 calls a "hard ceiling", so the true ceiling is ~339,000/day, 1.8× the proven bound. Over 90 days that is 67,050 diamonds ≈ $958 for +18.5 M gold against a stated 3.5–4.5 M lifetime income — a 5× progression multiplier. That destroys the §5.5 price-pressure argument, the §11.3 "deliberately unreachable 7.36 M tree", the §14.5 post-cap analysis, and the §9.8 anti-whale argument (a whale reaches the Might band ceiling in weeks). Energy is gold at a known exchange rate, so §15.1's principle is violated by §1.5 in the same document.

**Fix:** Cap daily refills at 3 (prices 20/30/45, total 95 diamonds), delete the 4th/5th/6th+ rows, and add REFILL_MAX_PER_DAY = 3 to §18. Then add refills to §14.4's derivation explicitly: energy_per_day ≤ 86400/60 × 1.60 + 3 × max_energy, which at L60 gives 2,304 + 1,110 = 3,414 → ceiling ≈ 190,000 gold/day, restoring the stated number as an actual bound. Rewrite §15.1's first bullet honestly as "Diamonds buy at most +48% daily throughput, hard-capped at 3 refills/day and counted in the §14.4 ceiling" rather than the unsupportable "never buy gold". Separately, remove "gold" from the Royal Charter battle-pass track in §15.2 or specify its exact amount and book it in §14.4 — as written it is a second unquantified diamond→gold path.

### The §17 unique index on items is globally scoped and will reject almost every equip. CREATE UNIQUE INDEX items_one_per_slot ON items (equipped_on, kind) WHERE equipped_on IS NOT NULL, combined with the stated encoding "equipped_on bigint -- NULL | soldiers.id | -1 for the player", means the tuple (-1, 0) can exist at most once in the entire table.

**Breaks because:** Soldier ids are globally unique bigserials so the constraint is correct for soldiers, but −1 is a shared sentinel across all players. The first player in the database to equip a weapon on their own character takes (-1, 0); every subsequent player's equip returns 23505 unique_violation. The tutorial at 3:30–4:30 forces the player to equip the Rusty Falchion, so registration-to-tutorial-completion breaks for player #2 onward. There is also no FK on equipped_on, so dismissing a soldier (§6.2 "replaces the soldier, old one dismissed") silently orphans its three items with no specified disposition.

**Fix:** Replace the sentinel with two columns: equipped_soldier_id bigint REFERENCES soldiers(id) ON DELETE SET NULL, equipped_by_player boolean NOT NULL DEFAULT false, plus CHECK (NOT (equipped_by_player AND equipped_soldier_id IS NOT NULL)). Then two partial unique indexes: CREATE UNIQUE INDEX items_soldier_slot ON items (equipped_soldier_id, kind) WHERE equipped_soldier_id IS NOT NULL; and CREATE UNIQUE INDEX items_player_slot ON items (owner_id, kind) WHERE equipped_by_player. The ON DELETE SET NULL also resolves the dismissal case by returning the items to the inventory — state that explicitly in §6.2.


## MAJOR (10)

### §8.7's Home Ground does not achieve its stated effect, and the document's own CI gate will fail against its own constants. §8.7 claims the defender's DEF ×1.08 "makes a mirror-match attack ≈ 48% rather than 50%" and §8.6's harness asserts require.InDelta(t, 0.48, measure(1.00), 0.02). I implemented §8.3 exactly as specified and measured the attacker winning 52.0% (3v3), 51.9% (7v7), 51.8% (10v10) — outside the asserted 46–50% band in the wrong direction.

**Breaks because:** Home Ground at 1.08 is worth only ~1.3 pp (53.2% → 51.9%) and CHARGE ~0.5 pp, but the SPD tie-break in §8.3 step 4 ("tie → attacker") is worth ~7.5 pp and swamps both. The stated design goal — "nudges players to attack slightly down, reducing total gold churned by PvP" — is inverted: the attacker has a +2 pp edge, which increases PvP volume and gold churn, compounding the uncapped-attack and ransom-faucet problems below. And because the CI test hard-codes 0.48, the build fails on day one with a number that cannot be reached by tuning HOME_GROUND_BP alone.

**Fix:** Adopt the simultaneous-volley change above, which brings the raw mirror match to 50%. Then set HOME_GROUND_BP = 1300 (defender DEF ×1.13) — extrapolating the measured 1.3 pp per 8% DEF, 13% yields ≈ 2 pp — and re-fit in the harness. Change the CI assertion from a hard-coded 0.48 to require.InDelta(t, MirrorTargetWinRate, measure(1.00), 0.02) with MirrorTargetWinRate = 0.48 read from the balance registry, so the constant and the assertion move together. Keep the rest of §8.6's harness exactly as written — see the note in corrected_recommendations, it validates.

### The defence ransom is an unbounded minted faucet. §9.4 defines ransom = floor(would_have_been_stolen × (0.40 + 0.05·ransom_coffers_level)), explicitly "minted, not transferred", with no per-day limit anywhere in the document. Its size scales with the DEFENDER's own gold-on-hand (via would_have_been_stolen = 3% of defender gold) and its rate scales linearly with incoming attack volume, which the defender does not control. §14.4 nevertheless asserts "Ransom, loot sales, quests and level-ups are all bounded by level 60 and by daily caps."

**Breaks because:** §14.3 books ransom at 154 gold/day from an assumed 5 incoming attacks. A visible, gold-rich L30 defender receiving 20 incoming attacks/day at a 50% defence win rate and 100k on hand mints 12,000 gold/day — 63% of the modelled total daily income — from nothing. At 50 incoming attacks it is 30,000/day. It also creates a straightforward collusion path: an accomplice deliberately throws attacks (§9.3: an attacking loss costs only energy) to mint ransom into a target account. §14.4's stated invariant "any new faucet must be inside a capped bucket" is violated by a faucet already in the document.

**Fix:** Add players.ransom_today bigint NOT NULL DEFAULT 0 and a hard cap RANSOM_DAILY_CAP(level) = 3 × STEAL_CAP(level), reset on the same daily_reset_at as refills and quests. At L30 that caps minted ransom at 9,075/day and at the modelled 5 incoming attacks it is not binding, so the intended feel is preserved. Add ransom_today to the nightly M2 audit as its own series (the §14.4 risk list already names it as one of the three fragile faucets — it needs a mechanism, not just monitoring). Additionally require the attacker to have completed a real battle with Might within the §9.5 band to make throw-farming as expensive as legitimate attacking.

### There is no daily attack cap, so §14's "5 attacks/day" model has no enforcing mechanism, and PvP either dominates or collapses depending on an unmodelled quantity. §9.1 sets attack_energy(30) = 11 against a daily energy budget of 760, allowing up to 69 attacks/day. §9.6's "Global budget: energy (no separate cap)" states this explicitly as a design choice. Meanwhile §2.2 claims a "deliberate tension" where "attacking is the XP-efficient path; collecting is the gold-efficient path" — but at L30 attacking is 3.1 XP/energy vs collecting's 2.0, and it also beats collecting on gold (16.4 vs 14.2 gold/energy) as soon as defenders hold ≳8,000 gold.

**Breaks because:** The claimed tension does not exist at any gold-on-hand level: below ~8k, attacking is worse on gold and better on XP; above ~8k it is strictly better on both. Worse, the design is self-defeating. §9.2 explicitly instructs players that "the correct counterplay to being robbed is spending your gold" and refuses a vault on that basis. If players comply — and the sink-heavy economy compels them to — then 3% of gold-on-hand collapses toward the StealMin floor of 10 gold, PvP's entire gold reward evaporates, and with it the ransom faucet, the revenge retention hook, and the §14.3 "PvP net +360/day" line. The document never models the steady-state gold-on-hand distribution, yet §9.2, §9.4, §9.8 and §14.3 all depend on it.

**Fix:** Two changes. (1) Add ATTACKS_PER_DAY = 10 + floor(level/10) (16 at L60) tracked against daily_reset_at, and restate §14.3's PvP lines against that cap rather than an unenforced assumption. (2) Decouple the steal from the hoard with a minted floor that tracks the collect ladder: stolen = clamp(floor(base_rate × defender_gold) + STEAL_FLOOR(def_level), STEAL_MIN, STEAL_CAP(att_level)) with STEAL_FLOOR(L) = round(1.4 × attack_energy(L) × gpe_best_job(L)) — 151 at L30, 594 at L60. At a 60% win rate this pays ~0.85× what the same energy earns from collecting, so PvP stays worth doing against a broke defender without dominating. STEAL_FLOOR is minted, so book it in §14.4 bounded by ATTACKS_PER_DAY × STEAL_FLOOR (2,265/day at L30) and add it to the M2 audit. Then delete or rewrite §2.2's "deliberate tension" paragraph, which the numbers do not support.

### §0.2's "Integer arithmetic only — no float64 anywhere in a path that produces a persisted number" is contradicted by essentially every other section, and its stated justification is technically wrong. §18's constant block is entirely float64 (TierMult, TierPriceMult, ItemBase, DmgK, HPPerDef, FortuneSigma, XPToNext via math.Pow). §7.2 defines EHP = unit_hp / (1 − DR) — float division. §8.3 uses normal(rng, 0, FORTUNE_SIGMA), exp(), and uniform(rng, 0.85, 1.15). All of these feed persisted gold, XP and battle rows. The stated reason — "Neon is a pooled connection and requests retry; float drift across retries produces off-by-one gold" — is not a real mechanism: IEEE-754 float64 evaluation of the same expression on the same binary is bit-deterministic, so retries cannot drift.

**Breaks because:** The rule is the document's §0 ground rule and is described as load-bearing, but no other section obeys it, so an implementer has no way to know which numbers are actually integer-mandated. The genuine risks it is reaching for are different ones: math.Pow/math.Exp implementations can change across Go releases, which breaks §8.5's audit re-runs, and accumulating a running balance in float64 loses precision. Neither is addressed. Meanwhile the mandate is also over-engineering in one place — §8.5 already persists the replay and states "the client never simulates", so cross-platform float determinism is not on the correctness path at all.

**Fix:** Split the rule into two scoped rules with correct rationales. (1) STORAGE AND LEDGER: gold, XP, diamonds, energy_milli and all bucket applications are int64/bp end-to-end, because a running balance must not accumulate error and because §0.5's audit must reconcile exactly. Keep ApplyBucket's integer form as written. (2) COMBAT: float64 is permitted inside Simulate() because the output is a persisted replay, not a recomputed balance; instead pin reproducibility by storing the seed, the balance_version AND a sim_version int in the battles row, and require an audit re-run to use the archived binary for that sim_version. Then convert §18's TierMult/TierPriceMult/ItemBase to integer bp tables (135, 185, 255, 360, 520, 760 / 100, 140, 220, 360, 600, 1000, 1700) since those feed item stats and prices, which ARE persisted. Also replace XPToNext's math.Pow with a precomputed [61]int64 lookup, which is what the §2.5 table already is.

### §0.1's balance hot-reload mechanism does not work on the project's stated database connection. The design loads the active balance version "into memory at boot and on a NOTIFY balance_reload". The project's DATABASE_URL is Neon's pooled connection string; Neon's pooler runs PgBouncer in transaction pooling mode, which does not support LISTEN/NOTIFY — Neon's own documentation directs users to a direct (unpooled) connection for "queries that depend on SET, LISTEN/NOTIFY, or session-level state".

**Breaks because:** The LISTEN will either error or silently never deliver, so a balance change applied via the Next.js admin panel appears to succeed in Postgres and never reaches the running Go process. Because §0.5 stamps balance_version on every gold_ledger and battles row, the symptom is subtle: rows keep getting stamped with the stale version and the retro-analysis §0.1 exists to enable quietly reports the wrong thing.

**Fix:** Drop LISTEN/NOTIFY. The backend is a single Docker container on a single VPS, so the simplest correct mechanism is a 30-second poller: SELECT id FROM balance_versions ORDER BY activated_at DESC LIMIT 1, and on change load the row and swap an atomic.Pointer[Balance]. That is a handful of lines, needs no second connection, and is p99-fast on a pooled endpoint. If sub-second propagation is ever required, add a DIRECT_DATABASE_URL (Neon's unpooled endpoint) used by exactly one long-lived pgx connection dedicated to LISTEN, and document why two URLs exist. Note in §0.1 that the pooled endpoint is also unsuitable for the goose/migrate step for the same session-state reason.

### Job milestone rewards create a farm that is cheapest on the worst job and directly contradicts the tutorial's core economic lesson. §3.3 grants, per job, cumulative rewards at 25/50/100/250/500/1000 collects including 15+25+40+75 = 155 diamonds, 200×level gold, and six items with tier floors rising to a guaranteed legendary at 1000, all at ilvl = player level. Job 1 (Pick Grapes) costs 1 energy per collect, so 1,000 collects costs 1,000 energy regardless of player level.

**Breaks because:** A L60 player can spend 1,000 energy (about 12 hours of regen) on Pick Grapes to receive a guaranteed ilvl-60 legendary (18,945 gold to buy), five more floor-guaranteed items, 12,000 gold, and 155 diamonds — which is 7.3 days of the entire free diamond faucet, and 2,325 diamonds across all 15 jobs, roughly $33 of IAP value. The tutorial at 2:30–3:30 teaches "Always use the best job you can afford" and calls it "the single most important economic literacy in the game"; the milestone table pays players to ignore it. Separately, the +5% bonus tiers at 250/500/1000 are dead content for jobs 3–12, which a player only uses for the 5–8 levels they are best (roughly 250–450 collects) before abandoning them — so the reward structure is upside down: trivially grindable on jobs whose base gold is worthless, unreachable on the jobs that matter.

**Fix:** Gate milestone counters on relevance: a collect only advances job n's counter when unlock_level(n) ≥ player_level − 10. That makes farming Pick Grapes at L60 award nothing, preserves the tutorial's lesson, and keeps milestones as a natural byproduct of correct play. Additionally, scale the diamond rewards by job index (diamonds = round(base × (1 + 0.1 × n))) so the late jobs are the valuable ones, and move the 250/500/1000 +5% bonus tiers to 150/300/600 so jobs 3–12 can realistically reach at least the first extended tier during the 5–8 levels they are current. Add job_progress.milestones_claimed smallint so a failed grant is retryable without double-awarding.

### Both pity systems in §4.4 essentially never fire. I evaluated them against §4.3's own weight model. Shop pity (60 consecutive rolls with no epic+): P(epic+) is 3.98% at L1 rising to 17.39% at L60, so P(60 consecutive misses) is 8.75e-2 at L1, 2.56e-3 at L30 and 1.05e-5 at L60. Gladiator pity (12 consecutive recruits with no legendary+): P(legendary+) is 28.17% at L60, so the pity fires 1.9% of the time at L60 and 9.2% at L30.

**Breaks because:** The pity mechanic is dead content precisely where §6.2 says the chase matters most — "chasing a mystic Gladiator at level 60 takes ~14 rolls ≈ 638,000 gold" is described as "the primary late-game gold sink", and the floor meant to bound that variance triggers for 1 player in 53. A player who rolls 25 Gladiators without a mystic (12% chance) has burned 1.14 M gold, 12 days of income, with no protection at all. The thresholds appear to have been set against the intuition that legendary+ is rare, but §4.3's luck_coef pushes it to 28% by L60.

**Fix:** Retarget the Gladiator pity at the tier players actually chase and set the threshold from the distribution: 10 consecutive recruits with no mystic+ (P(mystic+) = 8.66% at L60 → the pity carries 40% of players, a real floor) forces mystic+. For the shop, replace the epic+ counter with a level-scaled rarity target: forced legendary+ after SHOP_PITY_N rolls with no legendary+, where SHOP_PITY_N = 40 (P(legendary+) at L60 = 6.5% → 0.935^40 = 7%, fires meaningfully). Compute both thresholds in the balance registry from the live weight tables rather than hard-coding them, and add a unit test asserting each pity fires for between 5% and 40% of simulated players at L1/L30/L60.

### The shop is described as a pure function but depends on mutable state, so its central claimed property is false. §17 states the shop is "a pure function of (player_id, time_window, refresh_nonce, level, balance_version)" with "zero writes, identical across devices and reconnects, survives an app kill" — but ShopFor() calls applyPity(&out, rng, p), and §4.4's pity is "per-player counters" that must be incremented as rolls are consumed.

**Breaks because:** If the pity counter advances per window, the shop contents of window W depend on how many previous windows the player happened to open, so two devices that opened different numbers of windows compute different stock for the same window — exactly the desync bug the pure-function design was chosen to eliminate. If the counter advances only on view, it requires a write per view, defeating "zero writes". If it never advances, pity does nothing.

**Fix:** Make pity deterministic in the window index rather than in a counter: derive the pity state as pity_window = floor(window_id / SHOP_PITY_N) and force the rare-tier floor on the last window of each block, seeded from the same tuple. That preserves purity, needs no writes, is identical across devices, and gives the same expected floor rate. Add shop_refresh_nonce to the block computation so a paid refresh does not reset the pity block. Also add the shop_purchases(player_id, window_id, slot_idx) table to the §17 DDL — it is referenced only in prose — with a retention job dropping rows older than 1 hour, since at 288 windows/day it otherwise grows unboundedly.

### §17's attack_cooldowns table cannot represent the two different windows §9.6 requires. The table is PRIMARY KEY (player_id, target_id) with a single count_24h smallint and a single expires_at timestamptz, while §9.6 specifies both a 6-hour re-attack cooldown on the same target AND a maximum of 2 attacks on one player per 24 hours.

**Breaks because:** With expires_at = now + 6h, the row expires (or is swept) at 6 hours and count_24h resets with it, so a player can attack the same target at t=0, 6h, 12h and 18h — 4 attacks per 24 h, double the stated cap, and a straight bypass of §9.8's anti-farming argument point 7 ("6-hour cooldown caps the rate regardless"). With expires_at = now + 24h the 6-hour cooldown cannot be expressed at all. There is no schema state that satisfies both.

**Fix:** Replace the table with an append-only log: CREATE TABLE attack_log (player_id bigint NOT NULL, target_id bigint NOT NULL, attacked_at timestamptz NOT NULL, is_revenge boolean NOT NULL DEFAULT false, PRIMARY KEY (player_id, target_id, attacked_at)) with an index on (player_id, attacked_at DESC). The 6-hour rule becomes NOT EXISTS (SELECT 1 FROM attack_log WHERE player_id=$me AND target_id=$t AND NOT is_revenge AND attacked_at > now() - interval '6 hours'); the 24-hour cap becomes (SELECT count(*) FROM attack_log WHERE player_id=$me AND target_id=$t AND attacked_at > now() - interval '24 hours') < 2. Sweep rows older than 24 h in the nightly job. The same table then also serves the new ATTACKS_PER_DAY cap without a second structure.

### §8.6's stated matchmaking win-rate range does not match §9.5's SQL, and neither section's numbers agree with the model. §8.6 claims "within the matchmaking band (0.85×–1.35× Might, §9.5) the realistic win-rate range is 25%–87%". §9.5's actual query filters might BETWEEN $might*0.70 AND $might*1.60. Under §8.6's own P(win) = Φ(2·ln(M_A/M_D)/σ_total) with σ_total = 0.540, the SQL band [0.70, 1.60] yields attacker Might ratios [0.625, 1.429] and win rates 4.1%–90.7%. The quoted band [0.85, 1.35] would yield 13.3%–72.6%. Neither produces 25%–87%.

**Breaks because:** A target sitting at the top of the band (1.60× your Might) offers a 4% win chance for 11–16 energy. The §9.5 candidate card shows only "Much Stronger" and §9.5 explicitly says "Never show the win percentage", so the player has no way to tell a 4% trap from a 25% gamble. §8.6's central design argument — "every target on the list is a genuine decision" — is the justification for choosing FORTUNE_SIGMA = 0.38 over the alternatives, and it rests on a band the query does not implement.

**Fix:** Tighten the SQL to might BETWEEN $might*0.78 AND $might*1.28, which yields 22%–80% under the σ_total = 0.540 model — a real range where every listed target is a live decision — and correct §8.6's prose to quote that band and those numbers. Keep the §9.5 widening ladder but bound it at [0.60, 1.70] rather than [0.55, 2.00], and when the band has been widened, badge the out-of-band candidates distinctly ("Overwhelming") so the player can tell a desperate fallback from a normal target. Add a unit test asserting the SQL band constants and the §8.6 quoted win-rate range are computed from the same two numbers in the balance registry.


## MINOR (7)

### The replay event count and storage estimates are 2.4× low. §8.5 states "~200 events at 10v10 → ~12 KB JSON → ~2 KB gzipped", and §8.3's worked check says "Total ≈ 28 rounds, ~56 volley events". But §8.3's emit({r, src:u, dst:target, dmg, crit}) sits inside the per-unit loop, so a volley emits one event per living unit, not one event. Running the specified algorithm I measured 342 mean / 635 max events at 7v7 and 479 mean / 840 max at 10v10.

**Breaks because:** §8.3 conflates volleys (56) with events (~342). The 30-day retention risk in the risk list is sized off the wrong number: 10,000 DAU × 6 attacks/day at ~5 KB gzipped is ~290 MB/day and ~8.7 GB/month, not the stated 120 MB/day and 3.6 GB/month — a material difference on Neon storage pricing, and it changes whether 30-day retention is sufficient or needs to be 14. On the other hand MAX_EVENTS = 2000 is comfortably out of reach (840 observed max at 10v10), so that half of the risk is overstated.

**Fix:** Correct §8.5 to ~480 events / ~29 KB JSON / ~5 KB gzipped at 10v10 and restate the retention arithmetic. Then halve it back with two cheap changes: (a) drop the per-volley hp event, since the client can derive the target's HP by summing the volley's dmg fields; (b) collapse each volley into one event {t:"volley", r, s:side, d:target, hits:[[src,dmg,flags],...]} rather than N top-level objects, which removes the repeated "r" and "d" keys — that alone is roughly a 55% JSON size reduction before gzip. Keep MAX_EVENTS but raise the label from "should be unreachable" to a measured headroom of 2.4×, and note it must be re-measured if the Warlord 12-slot expansion ships.

### The free diamond faucet in §15.4 is overstated by 40–75%. Summing the specified sources: daily login (5+5+10+10+15+15+25 = 85/week) = 12.1/day; level-ups (53 × 10 + 6 × 50 = 830 over 91 days) = 9.1/day. Total 21.3/day and 1,985 including the 50-diamond starting grant over 90 days. §15.4 claims "~30–50 diamonds/day" and "~2,800–3,500 over 90 days ≈ 30–37 refills".

**Breaks because:** The gap is filled only by rewarded video (explicitly marked "later"), weekly kingdom rep top-10 (only for members of top-10 kingdoms), and job milestones — which is the exploit above. So at launch, without video and without a top-10 kingdom, the honest figure is 21/day, which buys exactly one 20-diamond first-of-day refill and nothing else. §15.4's stated design intent ("the free player gets one bonus session daily") happens to survive, but §15.5's ARPDAU and conversion targets are modelled against a free player who has 40% more diamonds than they will actually have — and the shortfall lands on the discretionary purchases (cosmetics, protection) that the conversion funnel depends on.

**Fix:** Restate §15.4 as ~21/day pre-video and ~51/day post-video, and make rewarded video a launch feature rather than "(later)" if the 30–50/day figure is load-bearing for §15.5's targets. Alternatively raise the daily login cycle to 10/10/15/15/20/20/40 (18.6/day) which reaches ~28/day at launch. Either way, publish the arithmetic in the section so the number is checkable, and remove job milestones from the free-diamond accounting once the relevance gate above is added.

### All eight bucket caps in §0.3 are unreachable, so the mechanism §14.4's proof leans on is decorative in v1 and the derived ceiling is ~40% looser than the real one. Maximum achievable sums: collect_income +110% against a +150% cap; tax +165% (100 Tithe Barn + 40 Royal Treasury + 25 VIP) against +300%; energy_regen +52% (40 Beacons + 12 Royal Couriers) against +60%; soldier_atk +76% against +100%; soldier_spd +48% against +60%; shop_discount +20% against +30%.

**Breaks because:** Not an error, but §14.4 derives its "hard ceiling ≈ 190,000 gold/day" from the caps rather than the achievable maxima. The real L60 ceiling from regen alone is 2,016 energy × 26.53 gpe × 2.10 = 112,300/day. Presenting the loose bound as "the" ceiling makes the §14.5 danger-zone analysis ("income ~90k/day") look consistent with it when the two are computed on different bases, and it obscures that the caps provide zero constraint on v1 content. Relatedly, §5.5's arbitrage proof uses "a maxed Merchant Ties gives buy = 0.70·S" (the 30% cap) when Merchant Ties maxes at 20%.

**Fix:** State both numbers in §14.4: the achievable ceiling (112,300/day at L60 today) and the cap-derived ceiling (190,000/day, which is headroom for future content), and label the caps as forward-looking insurance rather than active constraints. Correct §5.5's 0.70·S to 0.80·S. Separately, move the ninth multiplier hiding in §13.1 — the (10000 + 300 × soldier_slots_owned)/10000 tax term, worth +30% at 10 slots — into the tax_income_bp bucket so §0.3's "there are exactly eight multiplier buckets" is true and the term is covered by the cap and by ApplyBucket.

### §5.5's arbitrage proof is invalidated by §5.6 in the same document, and §12.5's dead-kingdom rules contradict each other. The proof's premise 1 is "No in-game effect mutates an item's stats after acquisition (there is no upgrading or enchanting in v1), the tuple is immutable" — but §5.6 introduces Reforge, which re-rolls quality and the Masterwork flag, i.e. mutates the stats after acquisition. Separately, §12.5 point 4 refunds "25% of their personal lifetime donations" on auto-dissolve while §12.5 point 5 states "the treasury is never refundable on leaving — otherwise donations become a savings account".

**Breaks because:** The arbitrage conclusion survives numerically (worst case: buy at S, reforge to max quality 115 and Masterwork, sell at 0.25 × 1.81 × S = 0.45 S < S), but the proof as written is false, and a proof that is false for a reason present in the document is worse than no proof — the next person to add an item-mutating feature will check premise 1, find it already violated, and conclude the constraint does not apply. The kingdom refund is a minted faucet (the treasury has already been spent on upgrades) that is absent from §14.4 and creates exactly the savings-account vector point 5 forbids.

**Fix:** Rewrite the proof premise as: "V(i) = floor(0.25 · S(i)) is recomputed from the item's current stats at sell time, and every stat-mutating operation M has cost(M) ≥ 0.60 × S(i_before) while S(i_after) ≤ 1.81 × S(i_before) (quality ∈ [85,115] and masterwork ×1.15 are the only mutations, both hard-capped), so 0.25 · S(i_after) ≤ 0.45 · S(i_before) < cost(M)." Then generalise ITEM_UPGRADE_MIN_COST_RATIO into a registry-level invariant checked by a property test over all (tier, ilvl, quality, masterwork) tuples. For the kingdom, delete the 25% dissolve refund and instead free the members and grant a cosmetic banner — or, if a refund is required for goodwill, pay it in diamonds from the publisher budget rather than minting gold, and book it in §14.4.

### The published tables were generated with Python's banker's rounding but the spec says round() and the target language is Go, whose math.Round is half-away-from-zero. In §3.2's XP column, job 3 (3 × 1.50 = 4.50) is tabulated as 4 and job 11 (25 × 2.10 = 52.50) as 52; a Go implementation of the stated formula produces 5 and 53. Relatedly, §2.5's L59 row is internally inconsistent: xp_to_next(59) = 13,970 not the tabulated 13,958, and cumulative(59) should be 257,338 not 257,304 (cumulative(60) = 271,308 is correct).

**Breaks because:** §0.2 warns specifically about "off-by-one gold that players will report" and mandates a rounding discipline, then ships tables that a faithful Go implementation will not reproduce. The two XP cells are trivial in isolation, but they mean the published tables cannot be used as golden-test fixtures — the first CI run comparing Go output to the document fails on two rows for a reason that looks like a formula error rather than a rounding-mode error, which is an hour of confusion per implementer.

**Fix:** Add to §0.2: "round() means round-half-away-from-zero, matching Go's math.Round; the reference tables in this document are regenerated with that mode." Then regenerate §3.2's XP column (job 3 → 5, job 11 → 53) and correct §2.5's L59 row to 13,970 / 257,338. Ship all reference tables (§2.5, §3.2, §4.3, §5.3, §5.5, §6.1, §6.3, §11.2, §13.3) as a golden-file fixture in the repo and add a CI test that regenerates them from the balance registry and diffs — that turns the document from prose into an executable spec and catches this class permanently.

### The CI lint proposed in §0.3 does not detect the failure mode the document's own risk list identifies. §0.3 says to "add a go vet-style lint (or a simple grep in CI) that fails the build if collect_income_bp or friends appear outside balance/buckets.go", and the risk list says the invariant "is trivially broken by a well-meaning future PR that writes gold * (1 + granary) * (1 + kingdom)".

**Breaks because:** That expression contains no bucket identifier, so the grep cannot see it. Conversely the identifiers must legitimately appear in the balance-JSON unmarshalling, in the per-player bonus aggregation that sums Granary + Royal Granaries + milestones into the bucket, in the admin panel's diff endpoint, and in tests — so a grep narrow enough to pass CI is narrow enough to catch nothing. The proposed control provides false assurance for the invariant the document calls the single most important one.

**Fix:** Replace the grep with three real controls. (1) Move buckets into internal/balance with the PlayerBonuses fields unexported and no exported accessor other than ApplyBucket, so the multiply cannot be written outside the package at all — Go's internal/ and unexported-field rules enforce this at compile time, no lint required. (2) Add a golden unit test: ApplyBucket(1000, CollectIncome, bonusesFrom(20%, 20%, 20%, 20%, 20%)) == 2000, explicitly asserting the 2.49× multiplicative result is not produced. (3) Add an end-to-end test that constructs a synthetic player with every bonus source at max, calls the real POST /collect handler, and asserts the returned gold equals base × (1 + Σbp/10000) computed independently from the balance JSON — that catches a compounding bug anywhere in the request path, including one written with no bucket identifiers.

### Bot opponents are underspecified in the two ways that determine whether they work, and their purses are too small to make bot PvP worth the energy. §9.5 specifies bots as "Might = player_might × uniform(0.80, 1.15), an army composition derived from that Might" with bot_gold(level) = round(400 × 1.06^level). Deriving a composition from a target Might is an inverse problem with infinitely many solutions, and the chosen solution fixes the bot's unit count, SPD, front-line order and DEF distribution — all of which move the real win rate away from the Might-implied one.

**Breaks because:** At L30, bot_gold = 2,297, so a 3% steal is 69 gold for 11 energy against a ~50%-win opponent — an expected 3.1 gold/energy against 14.2 gold/energy from collecting. Since §9.5 makes bots mandatory at launch ("without bots the Attack tab is dead on arrival") and BOT_FILL_RATIO starts at 1.0, the launch experience of the headline feature is a mode that is 4.5× worse than tapping a button. Meanwhile the unspecified composition means bot win rates will not match §8.6's calibration, so the first thing every player learns about PvP is wrong — and after the SPD fix above, a bot generated with zero SPD would lose 76% of the time regardless of its Might.

**Fix:** Specify bot generation as: take the §7.4 archetype for the bot's level (which fixes unit count, type mix and SPD-per-unit), then scale every unit's atk/def/hp by a single k solved so Might(scaled) equals the target — this preserves the archetype's ATK:EHP:SPD ratios so the Might-implied win rate holds. Add a harness assertion that bot-vs-player at Might ratio 1.00 returns 50% ± 3 pp. For purses, peg bot gold to what the steal formula should pay rather than an arbitrary exponential: bot_gold(L) = round(STEAL_FLOOR(L) / 0.03) so the standard 3% steal lands exactly on the collect-parity floor, i.e. 5,033 at L30 and 19,800 at L60. Bot gold is minted, so cap it with the ATTACKS_PER_DAY limit and put bot_purse_minted in the nightly M2 audit as its own series, which the risk list already asks for.


## Missing coverage

- Daily quests are entirely unspecified despite being 11% of modelled daily income. §2.2 gives only the XP formula (4 × level × tier); the gold formula (12 × level × tier) appears ONLY in the risk list, never in the body. There is no quest list, no reset time, no reroll rule, no claim idempotency, and no schema. The brief asked for every formula the backend must implement.
- The level-up gold reward formula (250 × level) appears only as a row in §14.1's source enumeration. §2 covers XP, stat points and the energy refill on level-up but never mentions gold, so an implementer reading §2 in isolation ships no level-up gold at all.
- There is no model of the steady-state gold-on-hand distribution, yet §9.2's 3% steal, §9.4's ransom, §9.8's six anti-farming arguments (notably #4, "3% of a poor player's gold is worthless") and §14.3's PvP lines all depend on it. §9.2 simultaneously instructs players to hold as little gold as possible, which drives the quantity toward zero.
- Inventory has no cap, no bulk sell, no auto-sell and no sort/filter spec, on a portrait phone. At 20% loot drop plus shop purchases plus up to 90 milestone gift items, a 90-day player accumulates several hundred rows. §17's items table has no cap and §5.5 specifies only a single-item sell.
- Equipment disposition on soldier replacement is unspecified. §6.2 says recruiting into an occupied slot dismisses the old soldier with no refund, but never says what happens to its three equipped items — returned to inventory, destroyed, or (per the current schema, which has no FK) silently orphaned.
- Daily-reset bookkeeping is incomplete. §1.5 names players.reset_offset_minutes but §17 declares reset_offset_min (a naming mismatch in a document claiming to be an implementable spec), and there is no daily_reset_at column, so refills_today, quest completion, the kingdom donation cap, the 150 rep/day cap and the proposed ransom/attack counters have no way to know whether they are stale. Timezone changes and DST after signup are also unhandled.
- Batched collect has no contract. The risk list correctly demands that hold-to-repeat and ×5/×10 produce ONE ledger row with a count, but gold_ledger has no count column and no batch endpoint is specified. Related: hold-to-repeat at 250 ms implies up to 4 requests/second per active player against a single VPS and a pooled Neon endpoint, with no client-side batching contract and no rate limit specified anywhere.
- gold_ledger has no index supporting its own audit query. The PK is (id, created_at) and there is no index on (player_id, created_at), so the §0.5 nightly per-player M2 aggregation sequentially scans every partition — the exact query the design's central economic safeguard depends on.
- The DDL omits CREATE EXTENSION citext (used by players.name and kingdoms.name) and any partition creation/rotation strategy for the four PARTITION BY RANGE tables. Both citext and tsm_system_rows are available on Neon, but neither is created, and §8.5's mandatory 30-day partition drop has no scheduler.
- Kingdom levelling has two unresolved interactions. Rep converts to kingdom XP at 100:1 while rep decays 2%/day — the document never says whether the conversion happens on earn or on the decaying stock, so kingdom level may be able to regress. And at 100:1, rep contributes roughly 4× more kingdom XP than donations do, which contradicts §12.2's framing of donations as the driver; §12.3's "30-member kingdom" also requires kingdom level 5, which the §12.1 member-cap formula puts months away.
- The 'kingdom members cannot attack each other' rule appears only inside the §9.5 matchmaking SELECT. §10.1 mandates defence-in-depth for shields (list filter plus server-side rejection) but no equivalent server-side guard is specified for the kingdom rule — and §9.7's revenge attacks explicitly bypass the target list entirely, so an attacker who joins the defender's kingdom before spending a revenge token has an unhandled path.
- Nothing enforces the §0.5 single-write-path invariant in the schema. There is no CHECK (gold >= 0) on players.gold, no FK from gold_ledger to players, and no reconciliation job asserting players.gold == SUM(gold_ledger.delta). The invariant is stated as load-bearing and is entirely convention.

## Corrected recommendations

## What survives, and it is more than you would expect

Before the corrections: I re-derived this document's tables independently and most of them are exactly right. Every entry in §5.3 (item stats), §6.3 (soldier stats), §5.5 (prices), §4.3 (all five roll distributions, to 2 decimal places), §11.2 (family costs — the 7,362,163 total reproduces to the gold), §3.2's gold column, §13.3 (tax), §12.1 (kingdom XP) and §2.1/§2.5 (XP curve, 271,308 cumulative) reproduce. All three §7.4 Might worked examples reproduce **exactly** — the L30 example's ArmyATK 1744, ArmyEHP 15,705 and Might 10,466 fall out of the stated formulas, and the replay JSON's a0 unit (atk 326, def 290, spd 41, hp 2128) is consistent with them. That is rare.

More importantly, **§8.6 — the section the author flags as the document's #1 risk — validates.** I implemented §8.3 verbatim and ran 4,000 battles per cell:

| units | ratio | model P | simulated P | mean rounds | timeout % |
|---|---|---|---|---|---|
| 3 | 1.20 | 75.0% | 76.8% | 23.3 | 0.0% |
| 7 | 1.20 | 75.0% | 76.7% | 25.5 | 0.0% |
| 10 | 1.20 | 75.0% | 76.3% | 26.8 | 0.0% |
| 7 | 1.50 | 93.4% | 94.4% | 22.0 | 0.0% |
| 7 | 2.00 | 99.5% | 99.9% | 17.8 | 0.0% |

The lognormal Fortune model matches the simulator within ~3 pp everywhere, **k does not drift with army size** (the specific thing the risk list warns about), rounds land in the predicted 17–28 band, and timeouts are 0.0% — so `MAX_ROUNDS = 60` is genuinely a safety net and `MAX_EVENTS = 2000` is unreachable (840 observed max at 10v10). The Lanchester-square insight underpinning §7.3 — that a volley/front-line model decides on ATK × EHP = Might² — is correct and is the best idea in the document. Keep §8.1–§8.6 essentially as written. **Build the harness anyway**, gated in CI, exactly as §8.6 specifies — but change one assertion (below).

---

## The corrections, in build order

### 1. Fix the energy model first — everything else is derived from it

```
ENERGY_BASE_MAX: 60 -> 120        // single constant change
```

With `ENERGY_OVERFLOW = false`, daily captured energy is hard-bounded by `sessions × max_energy`, not by regen. At the current constants:

| | max_energy | regen/day | 4-session ceiling | capture |
|---|---|---|---|---|
| L10 | 96 | 1,488 | 384 | **26%** |
| L30 | 190 | 1,728 | 760 | **44%** |
| L60 | 310 | 2,016 | 1,240 | **62%** |

§2.5 asserts 70% and 1,000–1,200 energy/day; §14.3 implies 58%. Neither is reachable at L30. With base 120: L30 max = 250 → 1,000/day = 58% (making §14.3 exactly self-consistent), L60 max = 370 → 1,480/day = 73% (matching §2.5). §14.4's supply bound is untouched because it derives from regen × the capped regen bucket.

Then regenerate §2.5's day-reached column and §14.3 from `capture = min(MODEL_SESSIONS_PER_DAY × max_energy, regen × 24)` with `MODEL_SESSIONS_PER_DAY = 4` as a named registry constant, so playtest can refit it in one place.

### 2. Fix the level-up faucet and re-derive §14.3

```
LEVEL_UP_GOLD = 60 * level        // was 250 * level
```

§14.1 books `250 × level` at "~560/day". §2.5's own pacing gives 1.20 days/level at L30, so the real rate is **6,250/day** — and §14.3's source column omits the line entirely. Corrected:

| | as written | + level-up faucet | + corrected capture |
|---|---|---|---|
| sources | 18,940 | 25,190 | 21,764 |
| sinks | 20,800 | 20,800 | 20,800 |
| margin | **−9.8%** (claimed) | **+21.1%** | **+4.6%** |

Add an explicit `Level-up` row to §14.3 and a CI test that recomputes the whole table from the registry, failing if the margin leaves `[−15%, −5%]`.

### 3. Fix the SPD/Might blind spot — this is the biggest game-design hole

Measured, at **byte-identical Might** (10,469 both sides), 6,000 battles:

| attacker SPD | defender SPD | attacker win % |
|---|---|---|
| 41 | 0 | **75.8%** |
| 98 | 0 | 77.9% |
| 138 | 0 | 76.4% |

Owning any horses is worth the same as a +20% Might advantage, and Might — the matchmaking, leaderboard and strength-badge number — cannot see it. Decomposition of a mirror match at 7v7:

| variant | attacker win % |
|---|---|
| full spec | **52.0%** |
| no Home Ground | 53.2% |
| no Charge | 51.4% |
| SPD tie → defender first | **44.4%** |

The initiative rule is worth ~7.5 pp; Home Ground is worth ~1.3 pp. Three changes:

**(a) Simultaneous volleys.** Both sides compute their volley against the pre-round state, then both are applied. Removes the step-function first-strike advantage and the tie-break's outsized effect. Keep the front-line targeting and overkill-wastage rules — those are what make ATK and EHP additive.

**(b) Fold SPD into Might.**
```
s            = ArmySPD / unit_count
ArmyATK_eff  = ArmyATK * (1 + 0.75 * crit(s, REF_SPD[level]))
ArmyEHP_eff  = ArmyEHP / (1 - dodge(s, REF_SPD[level]))
Might        = round(2 * sqrt(ArmyATK_eff * ArmyEHP_eff))
```
`REF_SPD[1..60]` is a registry lookup seeded from the median SPD-per-unit of the §7.4 archetype at that level. Then §5.4's claim that "SPD counts at 0.5× in the Might formula" becomes true, and §7.3's monotonicity claim becomes true.

**(c) `HOME_GROUND_BP: 800 -> 1300`**, and change the CI assertion from a hard-coded `0.48` to `require.InDelta(t, cfg.MirrorTargetWinRate, measure(1.00), 0.02)` so constant and assertion move together. As written, the document's own gate fails against the document's own constants.

Add a fourth harness gate: `sim(A_fast, B_slow)` at equal Might must return 50% ± 3 pp for `s ∈ {0, 41, 98, 138}`.

Note the pricing side is already half-right — §5.5's `item_power = attack + defense + 0.5*speed` charges for SPD, which is why horses currently cost 27% more Might-per-gold than weapons (legendary ilvl60: 38.5 vs 53.0 per 1,000 gold). Once (b) lands, that premium becomes correct rather than a tax.

### 4. Close the diamond→gold path

```
REFILL_MAX_PER_DAY = 3            // prices 20/30/45; delete rows 4,5,6+
```

At L60 today, 10 refills/day = 3,100 energy = **172,710 gold/day** on top of the 190,000/day §14.4 calls a hard ceiling. $958 over 90 days buys +18.5 M gold against a 3.5–4.5 M lifetime income. With the cap, §14.4's bound becomes honest:
```
energy_per_day <= 86400/60 * 1.60 + 3 * max_energy   // 2,304 + 1,110 = 3,414 at L60
```
Rewrite §15.1's first bullet as *"Diamonds buy at most +48% daily throughput, hard-capped and counted in the §14.4 ceiling."* Remove `gold` from the Royal Charter track, or specify the amount and book it.

### 5. Bound the PvP faucets and give the model a mechanism

```
ATTACKS_PER_DAY        = 10 + floor(level/10)
RANSOM_DAILY_CAP(L)    = 3 * STEAL_CAP(L)
STEAL_FLOOR(L)         = round(1.4 * attack_energy(L) * gpe_best_job(L))   // 151 @L30, 594 @L60
stolen = clamp(floor(base_rate*def_gold) + STEAL_FLOOR(def_level), STEAL_MIN, STEAL_CAP(att_level))
```

Today nothing enforces the "5 attacks/day" the economy assumes — the L30 energy budget allows 69. And §9.2 tells players to spend their gold as counterplay, which drives the 3% steal toward the 10-gold floor and kills PvP's reward. `STEAL_FLOOR` pegs a win at ~0.85× what the same energy earns from collecting, so PvP is worth doing against a broke defender without dominating. All three are minted, so all three go into the nightly M2 audit as separate series — the risk list already asks for this, it just needs the mechanisms to exist.

### 6. Schema corrections

```sql
-- items: the -1 sentinel makes (equipped_on, kind) globally unique, so exactly ONE
-- player in the database can equip a weapon. Replace it.
ALTER ... equipped_soldier_id bigint REFERENCES soldiers(id) ON DELETE SET NULL,
          equipped_by_player  boolean NOT NULL DEFAULT false,
          CHECK (NOT (equipped_by_player AND equipped_soldier_id IS NOT NULL));
CREATE UNIQUE INDEX items_soldier_slot ON items (equipped_soldier_id, kind)
  WHERE equipped_soldier_id IS NOT NULL;
CREATE UNIQUE INDEX items_player_slot  ON items (owner_id, kind) WHERE equipped_by_player;

-- attack_cooldowns cannot hold two windows (6h cooldown + 2/24h). Append-only log:
CREATE TABLE attack_log (
  player_id bigint NOT NULL, target_id bigint NOT NULL,
  attacked_at timestamptz NOT NULL, is_revenge boolean NOT NULL DEFAULT false,
  PRIMARY KEY (player_id, target_id, attacked_at));
CREATE INDEX attack_log_rate ON attack_log (player_id, attacked_at DESC);

-- the audit query the whole economy depends on has no index:
CREATE INDEX gold_ledger_player ON gold_ledger (player_id, created_at DESC);
ALTER TABLE gold_ledger ADD COLUMN count int NOT NULL DEFAULT 1;  -- batched collects
ALTER TABLE players ADD COLUMN daily_reset_at timestamptz NOT NULL DEFAULT now(),
                    ADD COLUMN ransom_today bigint NOT NULL DEFAULT 0,
                    ADD COLUMN attacks_today int NOT NULL DEFAULT 0,
                    ADD CONSTRAINT gold_nonneg CHECK (gold >= 0);
CREATE EXTENSION IF NOT EXISTS citext;
CREATE TABLE shop_purchases (player_id bigint, window_id bigint, slot_idx smallint,
  PRIMARY KEY (player_id, window_id, slot_idx));   -- referenced in §17 prose, absent from DDL
```

Also: `players.reset_offset_minutes` (§1.5) vs `reset_offset_min` (§17) — pick one.

### 7. Replace the balance-reload mechanism

`NOTIFY balance_reload` will not fire on this project's DATABASE_URL. Neon's pooled endpoint runs PgBouncer in transaction pooling mode, which does not support LISTEN/NOTIFY; Neon's docs direct you to a direct connection for anything depending on session state. The backend is one container on one VPS, so a 30-second poller (`SELECT id FROM balance_versions ORDER BY activated_at DESC LIMIT 1` → swap an `atomic.Pointer[Balance]`) is simpler and strictly correct. Same reason applies to your goose/migrate step — run migrations against the unpooled endpoint.

### 8. Scope §0.2's integer rule to where it is true

Split it: **storage/ledger is integer end-to-end** (gold, XP, diamonds, `energy_milli`, all bp) because a running balance must not accumulate error; **combat may use float64** because §8.5 persists the replay and the client never simulates, so cross-platform determinism is not on the correctness path. Pin audit reproducibility with a `sim_version int` on `battles` instead. Convert `TierMult`/`TierPriceMult`/`ItemBase` in §18 to integer bp (they feed persisted item stats), and replace `XPToNext`'s `math.Pow` with a `[61]int64` lookup — which is what §2.5's table already is. Delete the "Neon pooling + retries cause float drift" rationale; IEEE-754 evaluation is bit-deterministic on a fixed binary, and stating a false reason invites someone to relax the real rule.

### 9. Replace the bucket lint with controls that work

The proposed grep cannot see `gold * (1 + granary) * (1 + kingdom)` — the exact expression the risk list names. Instead: (a) put buckets in `internal/balance` with `PlayerBonuses` fields unexported, so the multiply is a compile error outside the package — no lint needed; (b) golden test `ApplyBucket(1000, CollectIncome, five×20%) == 2000`; (c) an end-to-end test that hits the real `POST /collect` with a max-bonus synthetic player and asserts the gold equals `base × (1 + Σbp/10000)` computed independently from the balance JSON.

### 10. Smaller retunes

| Change | From | To | Why |
|---|---|---|---|
| Milestone counter gate | any job | `unlock_level(n) >= player_level - 10` | 1,000 Pick Grapes = 1,000 energy → 155 diamonds (7.3 days of the entire free faucet) + a guaranteed ilvl-60 legendary; contradicts the tutorial's core lesson |
| Extended milestone tiers | 250/500/1000 | 150/300/600 | jobs 3–12 are best for only 5–8 levels (~250–450 collects); the +25%/+30% tiers are unreachable for 10 of 15 jobs |
| Gladiator pity | 12 without legendary+ | **10 without mystic+** | fires 1.9% of the time at L60 (P(legendary+) = 28%); mystic+ is 8.7%, so 10 misses carries ~40% of players |
| Shop pity | 60 without epic+ | **40 without legendary+**, computed from live weights | fires 1.05e-5 at L60 |
| Shop pity state | per-player counter | `floor(window_id / N)` block | the counter breaks §17's purity claim; the block form keeps zero writes |
| Matchmaking band | `[0.70, 1.60]` | `[0.78, 1.28]` | current band gives 4.1%–90.7% win rates, not the 25%–87% §8.6 claims; §8.6 also quotes a third band, `[0.85, 1.35]` |
| `bot_gold(L)` | `400 * 1.06^L` | `STEAL_FLOOR(L) / 0.03` | 69-gold steals at L30 make launch-day PvP 4.5× worse than tapping collect |
| Bot composition | "derived from Might" | archetype at level, scaled by one `k` solved for Might | preserves ATK:EHP:SPD ratios so the Might-implied win rate holds |
| Kingdom dissolve refund | 25% of donations (minted) | cosmetic banner only | contradicts §12.5's own point 5 and is an unbooked faucet |
| §15.4 free diamonds | "30–50/day, 2,800–3,500/90d" | **21/day, 1,985/90d** pre-video | login 12.1 + level-ups 9.1; the gap is rewarded video (marked "later") plus the milestone exploit |
| §8.5 replay size | ~200 events, 2 KB gz | **~480 events, ~5 KB gz** | emit is inside the per-unit loop; §8.3 conflates 56 *volleys* with events. Storage is 8.7 GB/month, not 3.6 |
| `round()` semantics | unspecified | half-away-from-zero (Go `math.Round`) | tables were generated with Python banker's rounding; §3.2 job 3 → 5 and job 11 → 53 in Go |
| §2.5 L59 row | 13,958 / 257,304 | **13,970 / 257,338** | arithmetic slip; cum(60) = 271,308 is correct |

### 11. One thing to say out loud that the document does not

Every one of the eight bucket caps in §0.3 is unreachable from v1 content (collect +110% vs a +150% cap, regen +52% vs +60%, tax +165% vs +300%, and so on). That is fine as forward-looking insurance, but §14.4 derives its "hard ceiling ≈ 190,000 gold/day" from the caps while §14.5 reasons about "~90k/day" from achievable play. State both bases: the achievable L60 ceiling today is **112,300 gold/day**, and 190,000 is headroom. Otherwise the two sections read as consistent when they are computed differently. Also correct §5.5's arbitrage proof to use 0.80·S (Merchant Ties maxes at +20%, not the +30% cap), and move §13.1's ninth multiplier — the `+3% tax per soldier slot` term, worth +30% at 10 slots — into `tax_income_bp` so "there are exactly eight multiplier buckets" is actually true.

Sources: [Neon connection pooling](https://neon.com/docs/connect/connection-pooling), [pgbouncer LISTEN/NOTIFY with transaction pooling](https://github.com/pgbouncer/pgbouncer/issues/655), [Neon supported extensions](https://neon.com/docs/extensions/pg-extensions), [Neon citext](https://neon.com/docs/extensions/citext)