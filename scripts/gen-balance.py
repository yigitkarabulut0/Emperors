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
    "weapon": [
        ["Rusted Blade", "Farmhand's Cleaver", "Notched Shortsword"],
        ["Guard's Arming Sword", "Tempered Falchion", "Oathkeeper's Edge"],
        ["Riverbend Longsword", "Silvered Broadsword", "Warden's Claymore"],
        ["Duskfang", "Bastion Greatsword", "Kingsguard Sabre"],
        ["Ashfang, Blade of the Ninth Siege", "Dawnbreaker", "The Gilded Verdict"],
        ["Starfall Edge", "Wyrmtongue", "The Sundering"],
        ["Crown of Swords", "The Last Word", "Emperor's Mercy"],
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

item_defs = []
for slot, tiers in NAMES.items():
    for ti, names in enumerate(tiers):
        for n, name in enumerate(names, 1):
            item_defs.append({
                "id": f"{slot}_{TIER_IDS[ti]}_{n:02d}",
                "slot": slot,
                "tier": TIER_IDS[ti],
                "name": name,
                # Art is addressed by slot + design index; the tier is applied by
                # recolouring the line work, so one PNG serves all seven tiers.
                "art": f"{slot}_{n:02d}",
            })

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
