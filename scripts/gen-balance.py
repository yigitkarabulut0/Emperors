#!/usr/bin/env python3
"""Generate balance/*.json from the formulas in docs/design/economy.md.

Generated rather than hand-typed so the shipped numbers provably match the
design, and so retuning means editing one constant instead of 15 rows.
"""
import json, pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
# balance/ is the human-facing source of truth; the server embeds an identical
# copy so the binary can seed config version 1 with no filesystem dependency.
# CI asserts the two are byte-identical.
SEED = ROOT / "server/internal/gameconfig/seed"


def emit(name: str, text: str) -> None:
    (ROOT / "balance" / name).write_text(text)
    SEED.mkdir(parents=True, exist_ok=True)
    (SEED / name).write_text(text)

# --- collect ladder (economy.md 3.1-3.2) -------------------------------------
NAMES = ["Pick Grapes","Gather Strawberries","Harvest Wheat","Tend the Orchard",
         "Chop Timber","Fish the River","Quarry Stone","Mine Iron Ore",
         "Hunt the King's Wood","Escort a Trade Caravan","Smelt Silver",
         "Clear the Bandit Camp","Delve the Deep Mine","Collect the Crown Tithe",
         "Plunder the Dragon's Hoard"]
SLUGS = ["grapes","strawberries","wheat","orchard","timber","fish","stone","iron",
         "hunt","caravan","silver","bandits","deep_mine","tithe","dragon_hoard"]
ENERGY = [1,2,3,4,6,8,10,13,16,20,25,31,38,46,55]
UNLOCK = [1,3,5,8,11,14,18,22,26,30,35,40,45,52,60]
GPE_BASE, GPE_STEP = 2.00, 1.22

jobs = []
for i, (name, slug, e, u) in enumerate(zip(NAMES, SLUGS, ENERGY, UNLOCK), start=1):
    gpe = GPE_BASE * GPE_STEP ** max(0, i - 2)
    jobs.append({
        "id": slug, "order": i, "name": name,
        "unlock_level": u, "energy_cost": e,
        "base_gold": round(e * gpe),
        "base_xp": max(2, round(e * (1.40 + 0.02 * u))),
    })

# Milestones replace rather than stack: reaching 50 means +10% total, not +15%.
MILESTONES = [
    {"collects": 25,   "bonus_bp": 500},
    {"collects": 50,   "bonus_bp": 1000},
    {"collects": 100,  "bonus_bp": 1500},
    {"collects": 250,  "bonus_bp": 2000},
    {"collects": 500,  "bonus_bp": 2500},
    {"collects": 1000, "bonus_bp": 3000},
]

emit("jobs.json", json.dumps({
    "_comment": "Collect ladder. gold = round(energy * 2.00 * 1.22^max(0,n-2)); "
                "xp = max(2, round(energy * (1.40 + 0.02*unlock_level))). "
                "Gold-per-energy rises 13.3x across the ladder so the best affordable "
                "job is always correct, while leftover energy still earns something. "
                "Milestone bonuses REPLACE (max +30%), they do not stack.",
    "milestones": MILESTONES,
    "jobs": jobs,
}, indent=2) + "\n")

# --- energy / xp / levels (economy.md 1.1, 2.1) -------------------------------
LEVEL_CAP = 60
levels = []
cum = 0
for L in range(1, LEVEL_CAP + 1):
    need = int(1.7 * L ** 2.2 + 10 * L + 5)
    levels.append({"level": L, "xp_to_next": need, "cumulative_xp": cum})
    cum += need

emit("progression.json", json.dumps({
    "_comment": "xp_to_next(L) = floor(1.7*L^2.2 + 10L + 5). Energy regen is FLAT: "
                "Max Energy is a 'how long can I be away' stat, regen speed is a "
                "'how much do I earn per day' stat. Because regen does not scale with "
                "max, buying Max Energy cannot inflate daily income — this is what "
                "bounds the entire gold supply.",
    "level_cap": LEVEL_CAP,
    "energy": {
        "base_max": 60,
        "per_stat_point": 3,
        "regen_base_seconds": 60,
        "overflow": False,
        "levelup_refill": True,
        "regen_bonus_cap_bp": 6000,
    },
    "stat_points_per_level": 1,
    "levels": levels,
}, indent=2) + "\n")

print("jobs.json      :", len(jobs), "jobs")
for j in (jobs[0], jobs[2], jobs[9], jobs[14]):
    print(f"  {j['order']:>2}. {j['name']:<26} lv{j['unlock_level']:<3} {j['energy_cost']:>3}e "
          f"-> {j['base_gold']:>5}g {j['base_xp']:>4}xp  (gpe {j['base_gold']/j['energy_cost']:.2f})")
print("progression.json:", LEVEL_CAP, "levels, total xp to cap =", f"{cum:,}")


# --- items (economy.md 4.2, 4.3, 5.1-5.5) -------------------------------------
TIER_IDS = ["common", "uncommon", "rare", "epic", "legendary", "mystic", "special"]
TIER_MULT = [1.00, 1.35, 1.85, 2.55, 3.60, 5.20, 7.60]
TIER_PRICE_MULT = [1.0, 1.4, 2.2, 3.6, 6.0, 10.0, 17.0]

SLOT_BASE = {
    #            atk def spd
    "weapon": {"attack": 10, "defense": 2,  "speed": 0},
    "armor":  {"attack": 2,  "defense": 10, "speed": 0},
    "horse":  {"attack": 5,  "defense": 5,  "speed": 6},
}

# Three designs per (type, tier). Names are per-tier so a legendary reads as
# legendary before the player looks at the numbers.
NAMES = {
    # A name that says "Falchion" must be drawn as a falchion. The design pool
    # walks through the whole table (see ART_DESIGNS), so these are ordered to
    # match the shape each slot actually receives; SHAPE_WORDS enforces it below.
    "weapon": [
        ["Rusted Arming Sword", "Farmhand's Falchion", "Notched Broadsword"],
        ["Guard's Greatsword", "Tempered Flamberge", "Oathkeeper's Rapier"],
        ["Riverbend Leafblade", "Silvered Arming Sword", "Warden's Falchion"],
        ["Duskfang Broadsword", "Bastion Greatsword", "Kingsguard Flamberge"],
        ["Dawnbreaker Rapier", "Ashfang Leafblade", "The Gilded Verdict"],
        ["Starfall Falchion", "Wyrmtongue Broadsword", "The Sundering"],
        ["Crown of Flame", "Emperor's Mercy", "The Last Word"],
    ],
    "armor": [
        ["Padded Gambeson", "Patched Leathers", "Militia Jerkin"],
        ["Studded Brigandine", "Guard's Hauberk", "Ironweave Coat"],
        ["Chainmail of the Watch", "Riverbend Cuirass", "Warden's Plate"],
        ["Duskplate Harness", "Bastion Armour", "Kingsguard Mail"],
        ["Aegis of the Ninth Siege", "Dawnward Plate", "The Gilded Bulwark"],
        ["Starfall Carapace", "Wyrmscale Harness", "The Unbroken"],
        ["Crown of Iron", "The Last Wall", "Emperor's Aegis"],
    ],
    "horse": [
        ["Plough Horse", "Swaybacked Mare", "Village Pony"],
        ["Courser", "Guard's Rouncey", "Trail Palfrey"],
        ["Riverbend Destrier", "Silvermane", "Warden's Charger"],
        ["Duskmane Destrier", "Bastion Warhorse", "Kingsguard Steed"],
        ["Ninth Siege Charger", "Dawnrunner", "The Gilded Stallion"],
        ["Starfall Courser", "Wyrmborn Steed", "The Tempest"],
        ["Crown Destrier", "The Last Ride", "Emperor's Own"],
    ],
}

# How many distinct silhouettes exist per slot. Tier is applied by recolouring
# the line work, so one PNG serves all seven tiers of a design -- but with only
# three designs a slot, a legendary sword was the SAME SHAPE as the rusted blade
# you started with, in a different colour. Climbing has to look like something.
ART_DESIGNS = {"weapon": 7, "armor": 3, "horse": 3}

item_defs = []
for slot, tiers in NAMES.items():
    designs = ART_DESIGNS[slot]
    for ti, names in enumerate(tiers):
        for n, name in enumerate(names, 1):
            # Walk the design pool straight through the whole 21-item table rather
            # than restarting it each tier. Three items of one tier are therefore
            # always three different shapes, and the shapes keep turning over as
            # the player climbs, instead of the same three repeating seven times.
            art_index = (ti * len(names) + n - 1) % designs + 1
            item_defs.append({
                "id": f"{slot}_{TIER_IDS[ti]}_{n:02d}",
                "slot": slot,
                "tier": TIER_IDS[ti],
                "name": name,
                "art": f"{slot}_{art_index:02d}",
            })

# What each weapon design actually depicts. A name that promises a shape must be
# drawn as that shape: rotating the design pool through the table silently broke
# this once, and a "Tempered Falchion" rendered as a wavy flamberge.
SHAPE_WORDS = {
    "arming sword": 1, "falchion": 2, "broadsword": 3,
    "greatsword": 4, "flamberge": 5, "rapier": 6, "leafblade": 7,
}
for d in item_defs:
    if d["slot"] != "weapon":
        continue
    lowered = d["name"].lower()
    for word, design in SHAPE_WORDS.items():
        if word in lowered:
            got = int(d["art"].split("_")[1])
            assert got == design, (
                f"{d['id']} is named {d['name']!r} but is drawn as {d['art']} "
                f"(design {design} is the {word})")

emit("items.json", json.dumps({
    "_comment": "Items. stat = round(base_slot_stat * tier_mult * (1 + 0.09*ilvl) * quality * masterwork). "
                "One quality roll per item applies to every stat, so items stay sortable and comparable "
                "on a phone; per-stat rolls would produce unsortable stat-soup. "
                "shop_price = round(1.6 * item_power^1.35 * tier_price_mult), item_power = atk + def + 0.5*spd. "
                "sell_price = floor(0.25 * UNDISCOUNTED shop price), so every buy-sell round trip loses at "
                "least 75% and arbitrage is impossible even with a maxed shop discount.",
    # Basis points, not floats: stat maths must be integer-only so the server,
    # the admin simulator and the client all produce the identical number.
    # Python's round() is banker's rounding and Go's is half-away-from-zero, so
    # a float pipeline would disagree by one on exact .5 cases.
    "tier_mult_bp": {TIER_IDS[i]: int(round(TIER_MULT[i] * 10000)) for i in range(7)},
    "tier_price_mult_bp": {TIER_IDS[i]: int(round(TIER_PRICE_MULT[i] * 10000)) for i in range(7)},
    "slot_base": SLOT_BASE,
    "level_mult_per_ilvl_bp": 900,
    "quality": {"min_pct": 85, "max_pct": 115},
    "masterwork": {"chance_bp": 300, "mult_pct": 115},
    "price": {"coef": 1.6, "exponent": 1.35, "sell_ratio_bp": 2500},
    "speed_power_weight_bp": 5000,
    "shop": {
        "slots": 6,
        "window_seconds": 300,
        "base_weights": {"common": 100.0, "uncommon": 45.0, "rare": 16.0, "epic": 5.0,
                         "legendary": 1.2, "mystic": 0.20, "special": 0.02},
        "luck_coef": 0.014,
    },
    "definitions": item_defs,
}, indent=2) + "\n")


def stat(slot, tier_ix, ilvl, key):
    """Mirrors the Go implementation exactly: integer maths, half-up rounding."""
    base = SLOT_BASE[slot][key]
    num = base * int(round(TIER_MULT[tier_ix] * 10000)) * (10000 + 900 * ilvl)
    den = 10000 * 10000
    return (num + den // 2) // den


print(f"items.json     : {len(item_defs)} definitions ({len(NAMES)} slots x 7 tiers x 3 designs)")
for slot in ("weapon", "horse"):
    for ti in (0, 4, 6):
        a, d, s = (stat(slot, ti, 30, k) for k in ("attack", "defense", "speed"))
        power = a + d + 0.5 * s
        price = round(1.6 * power ** 1.35 * TIER_PRICE_MULT[ti])
        print(f"  {slot:<7} {TIER_IDS[ti]:<10} ilvl30  atk {a:>4} def {d:>4} spd {s:>4}"
              f"   buy {price:>7,}  sell {int(0.25 * price):>6,}")


# --- soldiers (economy.md 6.1-6.4, 7.1-7.3) -----------------------------------
def half_up(num, den):
    return (num + den // 2) // den


SOLDIER_TYPES = [
    # base cost is chosen so recruit_cost(1) matches the design table exactly
    {"id": "peasant",   "name": "Peasant",   "base_cost": 150,  "attack": 8,  "defense": 8,  "hp": 40,
     "weights": {"common": 100.0, "uncommon": 30.0, "rare": 7.0, "epic": 1.5,
                 "legendary": 0.25, "mystic": 0.03, "special": 0.002}, "luck_coef": 0.010},
    {"id": "mercenary", "name": "Mercenary", "base_cost": 900,  "attack": 14, "defense": 12, "hp": 55,
     "weights": {"common": 45.0, "uncommon": 55.0, "rare": 25.0, "epic": 8.0,
                 "legendary": 1.8, "mystic": 0.25, "special": 0.02}, "luck_coef": 0.012},
    {"id": "gladiator", "name": "Gladiator", "base_cost": 6000, "attack": 22, "defense": 18, "hp": 75,
     "weights": {"common": 10.0, "uncommon": 30.0, "rare": 40.0, "epic": 22.0,
                 "legendary": 8.0, "mystic": 1.6, "special": 0.18}, "luck_coef": 0.014},
]

MAX_SLOTS = 10
slots = [{
    "index": n,
    "cost": half_up(500 * round(2.05 ** (n - 1) * 10000), 10000),
    "level_gate": 4 * (n - 1) + 1,
} for n in range(1, MAX_SLOTS + 1)]

emit("soldiers.json", json.dumps({
    "_comment": "Soldiers. slot_cost(n) = 500 * 2.05^(n-1); recruit_cost = base * (1 + 0.11*level); "
                "stats = type_stat * tier_mult * (1 + 0.09*soldier_level). A common Gladiator is about "
                "as strong as a rare Peasant, which is what justifies the 40x price gap: the TYPE matters "
                "beyond the tier roll. Train raises a soldier's level toward the player's for "
                "60 * 1.09^level * tier_mult, turning 'your veteran is obsolete' into 'invest in your "
                "veteran' — and, because 1.09^L grows without limit, an unbounded late-game gold sink.",
    "max_slots": MAX_SLOTS,
    "slots": slots,
    "recruit_cost_per_level_bp": 1100,
    "level_mult_per_level_bp": 900,
    "train": {"base": 60, "growth_bp": 10900},
    # Onboarding grants (economy.md 16). Without these a new player grinds their
    # whole first session — through every level-up refill — and still finishes
    # about 180 gold short of their first barracks slot, so the tab unlocks
    # visibly unreachable. Measured, not guessed: a fresh account reaches ~322
    # gold at level 5 before energy runs dry.
    "onboarding": {
        "free_slot_at_level": 5,
        "free_first_recruit": True,
        "first_recruit_tier_floor": "uncommon",
    },
    "types": SOLDIER_TYPES,
    # economy.md 7.1-7.3
    "player": {
        "base_stat": 10,
        "per_level": 2,
        "per_stat_point": 4,
        "base_hp": 100,
        "hp_per_level": 12,
    },
    "combat": {
        "hp_per_defense_bp": 30000,      # 3.0x — Defense buys HP as well as mitigation
        "hp_level_bonus_bp": 200,        # +2% per owner level
        "dr_level_coef": 40,             # DR = def / (def + 40*level + 60)
        "dr_base": 60,
        "dr_cap_bp": 6000,               # hard 60% ceiling, or tanks become unkillable
        # Battle simulation (economy.md 8.2-8.6). A volley auto-battle over ~200
        # damage rolls per side is inherently near-deterministic: per-hit noise
        # averages out to a coefficient of variation under 0.04, so crit and dodge
        # cannot move the win curve at all. The ONLY knob that can is a per-side,
        # per-battle roll — Fortune of War. A per-unit roll fails too, because its
        # effect shrinks as 1/sqrt(N) and the curve would drift as players buy slots.
        "dmg_k_bp": 1600,
        # 0.25, not the design's 0.15. Measured on symmetric level-60 10v10
        # fights, 0.15 left 3.8% of battles hitting the round cap and resolving on
        # health fraction instead of a kill — which makes MAX_ROUNDS a design
        # element rather than the safety net it is meant to be. 0.25 drops that to
        # 0.5% and shortens the average fight from 39 to 32 rounds, while moving
        # the win rate at +20% Might by only 0.8 points.
        "rage_step_bp": 2500,            # per round, global to the battle
        "max_rounds": 60,                # safety net, not a design element
        "variance_min_bp": 8500,
        "variance_max_bp": 11500,
        "crit_mult_bp": 17500,
        "crit_base_bp": 500,
        "crit_speed_bp": 3000,
        "crit_cap_bp": 4500,
        "dodge_speed_bp": 2000,
        "dodge_cap_bp": 1500,
        "charge_bonus_bp": 1200,         # round 1, faster side only
        "home_ground_bp": 800,           # defender DEF x1.08
        # Target: a +20% Might advantage wins 75% of the time. Below ~70% the
        # damage swing exceeds +-55% and gear investment stops reading as
        # meaningful; above ~85% the replay becomes something you skip.
        #
        # The design derived 0.38 from a closed-form log-normal model. Measured
        # against the actual simulator that value gives 80.4%, because front-line
        # ordering, wasted excess damage and rage all sharpen the curve — which
        # the design itself warned would happen and told us to measure. Swept at
        # 6,000 battles per point, 0.50 reproduces the intended curve across its
        # whole range (0.80 -> 20%, 1.10 -> 65%, 1.20 -> 75%, 1.50 -> 92%).
        "fortune_sigma_bp": 5000,
        # Clamped at 1.5 sigma rather than 2. At sigma 0.50 a two-sigma tail displays
        # as "your levies fight at 272%, theirs at 37%", which reads as the game
        # being broken rather than as a die roll. 1.5 keeps the extremes inside
        # 2.1x/0.47x and barely touches the win curve, because the tails are rare.
        "fortune_clamp_sigmas_x10": 15,
    },
}, indent=2) + "\n")


def sold_stat(base, tier_ix, lvl):
    return half_up(base * int(round(TIER_MULT[tier_ix] * 10000)) * (10000 + 900 * lvl), 10000 * 10000)


print(f"soldiers.json  : {MAX_SLOTS} slots, {len(SOLDIER_TYPES)} types")
print(f"  slot costs   : {', '.join(f'{s['cost']:,}' for s in slots[:5])} ... {slots[-1]['cost']:,}")
print(f"  total for 10 : {sum(s['cost'] for s in slots):,} gold")
for t in SOLDIER_TYPES:
    r1 = half_up(t['base_cost'] * (10000 + 1100 * 1), 10000)
    print(f"  {t['name']:<10} recruit lv1 {r1:>6,}   "
          f"common@30 {sold_stat(t['attack'],0,30):>3}/{sold_stat(t['defense'],0,30):>3}/{sold_stat(t['hp'],0,30):>4}   "
          f"legendary@30 {sold_stat(t['attack'],4,30):>3}/{sold_stat(t['defense'],4,30):>3}/{sold_stat(t['hp'],4,30):>4}")


# --- family upgrades (economy.md 11.2) ----------------------------------------
UPGRADES = [
    # id, name, bucket, max_lv, per_level, base cost, growth, blurb
    ("granary",    "Granary",             "collect_income_bp", 20,  300, 400,   1.36, "Every collect pays more."),
    ("tithe_barn", "Tithe Barn",          "tax_income_bp",     20,  500, 500,   1.36, "Your estates earn more, and hold it longer while you are away."),
    ("scriptorium","Scriptorium",         "xp_bp",             15,  200, 900,   1.42, "Learn faster from everything you do."),
    ("beacons",    "Watchtower Beacons",  "energy_regen_bp",   10,  400, 4000,  1.55, "Energy returns faster."),
    ("larder",     "Larder",              "max_energy_flat",   25,    4, 300,   1.28, "Hold more energy, so a long absence wastes less."),
    ("armoury",    "Armoury",             "soldier_atk_bp",    20,  300, 500,   1.36, "Your soldiers strike harder."),
    ("bulwark",    "Bulwark",             "soldier_def_bp",    20,  300, 500,   1.36, "Your soldiers endure more."),
    ("stables",    "Stables",             "soldier_spd_bp",    12,  400, 2500,  1.48, "Your riders move first."),
    ("merchant",   "Merchant Ties",       "shop_discount_bp",  10,  200, 4000,  1.60, "The market asks less of you."),
    ("war_chest",  "War Chest",           "steal_cap_bp",       8,  800, 8000,  1.75, "Carry more away from a raid."),
    ("coffers",    "Ransom Coffers",      "ransom_bp",          8,  500, 6000,  1.72, "Losing a defence still pays."),
]

upgrades = []
for uid, name, bucket, maxlv, per, base, growth, blurb in UPGRADES:
    costs = [half_up(base * round(growth ** (lv - 1) * 10000), 10000) for lv in range(1, maxlv + 1)]
    upgrades.append({
        "id": uid, "name": name, "bucket": bucket, "max_level": maxlv,
        "per_level": per, "blurb": blurb, "costs": costs,
    })

# --- territory holdings -------------------------------------------------------
# The design put passive income on soldier slots; the owner chose Territory as
# its home, so holdings are the income engine and the Family tree multiplies it.
# A base rate from level remains, so a player with no holdings still has some
# idle income and the hybrid model is always on.
HOLDINGS = [
    ("wheat_farm",  "Wheat Farm",    1,  1),
    ("watermill",   "Watermill",     8,  2),
    ("quarry",      "Stone Quarry",  14, 3),
    ("vineyard",    "Vineyard",      20, 4),
    ("iron_mine",   "Iron Mine",     28, 5),
    ("market",      "Market Square", 36, 6),
    ("river_port",  "River Port",    45, 7),
    ("mint",        "Ducal Mint",    55, 8),
]
HOLDING_MAX_LEVEL = 10

holdings = []
for i, (hid, name, unlock, _tier) in enumerate(HOLDINGS):
    # Yield per level grows 1.5x per holding, so later estates matter without
    # making the first ones worthless.
    per_hour = round(1.0 * 1.5 ** i, 2)
    # Priced from PAYBACK, not from the Family tree. Yields are pinned by the
    # target that passive income stays around 20-50% of active collecting, so the
    # only lever is cost. At roughly 300 gold per gold-per-hour, a holding pays
    # for itself in about twelve days of real time — a real investment in an idle
    # game, where the first pass (a thousand-hour payback) made Territory
    # something no rational player would ever build.
    #
    # The Family tree remains the bottomless sink at 6.8M; Territory is the income
    # engine and is deliberately cheap by comparison.
    base_cost = half_up(round(85 * 1.72 ** i), 1)
    costs = [half_up(base_cost * round(1.25 ** (lv - 1) * 10000), 10000)
             for lv in range(1, HOLDING_MAX_LEVEL + 1)]
    holdings.append({
        "id": hid, "name": name, "unlock_level": unlock,
        "max_level": HOLDING_MAX_LEVEL,
        # milli-gold per hour per level, so the whole pipeline stays integer
        "tax_milli_per_hour_per_level": int(round(per_hour * 1000)),
        "costs": costs,
    })

emit("estates.json", json.dumps({
    "_comment": "Family upgrades and Territory holdings. Every percentage is ADDITIVE within its "
                "bucket and the bucket applies once, so there is no compounding between upgrades and "
                "every bucket stays hard-capped. The Family tree costs far more in total than a "
                "level-60 player will ever earn — that is deliberate, so there is never an 'I finished "
                "the upgrades' cliff and every node stays a live choice. "
                "Tax = base(level) + sum(holding yields), multiplied by tax_income_bp. Deliberately NOT "
                "a function of Might or gear, so PvP power cannot buy income which buys PvP power.",
    "upgrades": upgrades,
    "holdings": holdings,
    "tax": {
        "base_per_hour_milli": 24000,
        "growth_bp": 10450,              # 1.045^level
        "offline_cap_seconds": 28800,    # 8h, +720s per Tithe Barn level
        "offline_cap_per_tithe_level": 720,
    },
}, indent=2) + "\n")

print(f"estates.json   : {len(upgrades)} family upgrades, {len(holdings)} holdings")
print(f"  family tree total cost : {sum(sum(u['costs']) for u in upgrades):>12,} gold")
print(f"  holdings total cost    : {sum(sum(h['costs']) for h in holdings):>12,} gold")
tax60 = 24 * 1.045 ** 60
hold60 = sum(h["tax_milli_per_hour_per_level"] / 1000 * HOLDING_MAX_LEVEL for h in holdings)
print(f"  tax/hr at lv60         : base {tax60:>8.0f} + holdings {hold60:>7.0f} = {tax60 + hold60:>8.0f}")
print(f"  8h offline vs 8h active: {(tax60 + hold60) * 8 / 12725 * 100:>5.1f}%  (design target ~51% at max)")
print("  holding                 unlock   max yield/hr      total cost   payback")
for h in holdings:
    y = h["tax_milli_per_hour_per_level"] / 1000 * HOLDING_MAX_LEVEL
    c = sum(h["costs"])
    print(f"  {h['name']:<22} lv{h['unlock_level']:<4} {y:>10.1f} {c:>15,}   {c/max(y,0.01):>6.0f}h")


# --- kingdoms (economy.md 12) -------------------------------------------------
KINGDOM_UPGRADES = [
    ("royal_granaries", "Royal Granaries", "collect_income_bp", 10, 200,  50000,  1.55, "Every member collects more."),
    ("royal_archives",  "Royal Archives",  "xp_bp",             10, 150,  60000,  1.55, "Every member learns faster."),
    ("royal_treasury",  "Royal Treasury",  "tax_income_bp",     10, 400,  50000,  1.52, "Every member's estates earn more."),
    ("royal_armoury",   "Royal Armoury",   "soldier_atk_bp",     8, 200,  80000,  1.60, "Every member's soldiers strike harder."),
    ("royal_bulwark",   "Royal Bulwark",   "soldier_def_bp",     8, 200,  80000,  1.60, "Every member's soldiers endure more."),
    ("royal_couriers",  "Royal Couriers",  "energy_regen_bp",    6, 200, 150000,  1.70, "Every member's energy returns faster."),
    ("royal_banners",   "Royal Banners",   "reputation_bp",      6, 500, 120000,  1.65, "Raids earn the kingdom more renown."),
    ("royal_court",     "Royal Court",     "member_cap_flat",    5,   2, 200000,  1.80, "Room for more lords."),
]

k_upgrades = []
for uid, name, bucket, maxlv, per, base, growth, blurb in KINGDOM_UPGRADES:
    k_upgrades.append({
        "id": uid, "name": name, "bucket": bucket, "max_level": maxlv,
        "per_level": per, "blurb": blurb,
        "costs": [half_up(base * round(growth ** (lv - 1) * 10000), 10000) for lv in range(1, maxlv + 1)],
    })

KINGDOM_MAX_LEVEL = 8
k_levels = [{
    "level": L,
    # kingdom_xp(L) = 150000 * L^1.9 — the XP needed to REACH level L.
    "xp_required": 0 if L == 1 else half_up(round(150000 * L ** 1.9), 1),
    "member_cap": 5 + 5 * L,
} for L in range(1, KINGDOM_MAX_LEVEL + 1)]

emit("kingdoms.json", json.dumps({
    "_comment": "Kingdoms. Upgrades use the SAME additive buckets as Family upgrades, so a maxed "
                "Granary (+60%) plus maxed Royal Granaries (+20%) plus a fully mastered job (+30%) "
                "comes to +110%, inside the +150% bucket cap. Maxing the whole tree costs about 35M "
                "kingdom gold — a 30-member kingdom donating a tenth of its income needs roughly 230 "
                "days, so it is a long-horizon collective goal rather than a checklist. Reputation "
                "decays 2% a day, which is what stops a kingdom that quit in month one from squatting "
                "at rank 1 forever.",
    "found_cost": 250000,
    "found_level": 20,
    "max_level": KINGDOM_MAX_LEVEL,
    "levels": k_levels,
    "upgrades": k_upgrades,
    "donation": {
        "daily_cap_base": 20000,
        "daily_cap_per_level": 800,
        "xp_per_gold": 1,
        "xp_per_reputation": 100,
        "favour_per_gold": 100,
    },
    "reputation": {
        "daily_cap_per_member": 150,
        "decay_bp_per_day": 200,
    },
}, indent=2) + "\n")

print(f"kingdoms.json  : {len(k_upgrades)} upgrades, {KINGDOM_MAX_LEVEL} levels")
print(f"  found        : {250000:,} gold at level 20")
print(f"  tree total   : {sum(sum(u['costs']) for u in k_upgrades):>12,} kingdom gold")
print(f"  member cap   : {k_levels[0]['member_cap']} at Lv1 -> {k_levels[-1]['member_cap']} at Lv{KINGDOM_MAX_LEVEL}")
print(f"  xp to Lv8    : {k_levels[-1]['xp_required']:>12,}")
