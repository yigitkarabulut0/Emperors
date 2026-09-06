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
# Experience per energy ramps the way gold does, one step per rung, but far more
# gently: 2.1x across the ladder against gold's 13.3x.
#
# The step is what sets the length of the game, and it is easy to get wrong in
# both directions. At (1.40 + 0.02 * unlock_level) it rose 1.3x while a level's
# cost rises about 400x, so the curve flattened into a wall. The correction
# overshot to 1.14 -- a 5.5x rise -- which, landing on top of a doubled energy
# budget, put level 60 at 22 days for a five-sessions-a-day player against a
# design target of 91. At 1.06 the same player reaches the cap around day 49 and
# a three-a-day player around day 82; measure it with scripts/pace.py before
# touching this number.
#
# It must stay shallower than gold's ladder, or "use the best job you can
# afford" stops being a gold decision and becomes an experience one.
XPE_BASE, XPE_STEP = 2.00, 1.06

jobs = []
for i, (name, slug, e, u) in enumerate(zip(NAMES, SLUGS, ENERGY, UNLOCK), start=1):
    gpe = GPE_BASE * GPE_STEP ** max(0, i - 2)
    jobs.append({
        "id": slug, "order": i, "name": name,
        "unlock_level": u, "energy_cost": e,
        "base_gold": round(e * gpe),
        "base_xp": max(2, round(e * XPE_BASE * XPE_STEP ** max(0, i - 2))),
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
                "xp = max(2, round(energy * 2.00 * 1.06^max(0,n-2))). "
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

# Pickable player portraits. Asynchronous PvP means an opponent is a row on a
# list, never a person you meet, so the chosen face carries most of the identity.
# Kept in balance rather than in code so the set can grow without a deploy.
AVATARS = ["knight", "king", "queen", "archer", "monk", "berserk",
           "knave", "herald", "templar", "witch", "captain", "princess"]

# Named rather than inlined below, because the estates self-check has to compute
# what active collecting earns per day, and it must do that from the same numbers
# the server will run. Hardcoding a second copy is how the old check came to be
# dividing by a figure four rebalances out of date.
ENERGY = {
    "base_max": 120,
    # The ceiling grows on its own, no stat point required. Without this the
    # pool fills during any gap longer than it takes to fill, and every
    # further minute of regeneration is thrown away -- which made the regen
    # rate a number that only mattered to somebody checking in every half
    # hour. See scripts/pace.py for the measurement.
    "per_level": 4,
    "per_stat_point": 5,
    "regen_base_seconds": 30,
    "overflow": False,
    "levelup_refill": True,
    "regen_bonus_cap_bp": 6000,
}

emit("progression.json", json.dumps({
    "_comment": "xp_to_next(L) = floor(1.7*L^2.2 + 10L + 5). Energy regen is FLAT: "
                "Max Energy is a 'how long can I be away' stat, regen speed is a "
                "'how much do I earn per day' stat. Because regen does not scale with "
                "max, buying Max Energy cannot inflate daily income — this is what "
                "bounds the entire gold supply.",
    "level_cap": LEVEL_CAP,
    "energy": ENERGY,
    # The design specifies 3. It shipped as 1, so every level-up delivered a
    # third of the intended reward.
    "stat_points_per_level": 3,
    # The Treasury is the game's largest gold sink and its only real risk
    # decision: banked gold cannot be stolen, but banking it costs. The fee is
    # what stops "deposit everything, always" from being free safety.
    "treasury": {"deposit_fee_bp": 1000},
    # Diamonds have to come from somewhere before purchasing exists, or the
    # counter sits at zero forever and reads as broken. Levelling is the source:
    # it is the one reward that cannot be farmed faster by playing more, since
    # the XP curve already bounds it.
    "levelup_diamonds": 5,
    # Daily quests: three a day, drawn from this list.
    #
    # The design specified the REWARD formula and nothing else — its own review
    # says "entirely unspecified: no quest list, no reset time, no reroll rule,
    # no claim idempotency, no schema". This is that list.
    #
    # Every kind watches an action the player already takes, and the targets are
    # sized so all three fall out of one ordinary session rather than demanding
    # an extra one. A daily that cannot be finished on a normal day is a daily
    # that teaches players to ignore dailies.
    #
    # tier is the reward multiplier: reward = 4*level*tier xp, 12*level*tier gold.
    "quests": {
        "per_day": 3,
        "xp_per_level_per_tier": 4,
        "gold_per_level_per_tier": 12,
        "pool": [
            {"id": "collect_20", "kind": "collects", "target": 20, "tier": 1,
             "name": "An Honest Day", "blurb": "Work twenty jobs."},
            {"id": "collect_60", "kind": "collects", "target": 60, "tier": 2,
             "name": "The Long Shift", "blurb": "Work sixty jobs."},
            {"id": "energy_150", "kind": "energy", "target": 150, "tier": 2,
             "name": "Nothing Wasted", "blurb": "Spend 150 energy."},
            {"id": "energy_300", "kind": "energy", "target": 300, "tier": 3,
             "name": "To the Last Drop", "blurb": "Spend 300 energy."},
            # Gated behind the Fight tab's own unlock level, so it is never
            # offered to somebody who cannot open the screen.
            {"id": "win_1", "kind": "wins", "target": 1, "tier": 1,
             "name": "First Blood", "blurb": "Win a raid.", "min_level": 10},
            {"id": "win_3", "kind": "wins", "target": 3, "tier": 3,
             "name": "A Good Week's Work", "blurb": "Win three raids.", "min_level": 10},
            {"id": "buy_1", "kind": "buys", "target": 1, "tier": 1,
             "name": "Well Equipped", "blurb": "Buy something from the market.",
             "min_level": 2},
            {"id": "buy_3", "kind": "buys", "target": 3, "tier": 2,
             "name": "The Armourer's Friend", "blurb": "Buy three things.",
             "min_level": 2},
        ],
    },
    # The daily login calendar: seven squares, then it starts again.
    #
    # Levelling was the only diamond faucet — 295 across the whole climb to the
    # cap — which is roughly nine a day at the start and nothing at all once a
    # player slows down. This is the other half the design always specified, and
    # it is the half that pays a player for COMING BACK rather than for grinding.
    #
    # Rising within the week, and the seventh square worth as much as the first
    # three together, because the point is the return trip on day six, not the
    # reward on day one.
    "daily_login": {
        "rewards": [5, 5, 10, 10, 15, 15, 25],
        # Miss a day and the calendar starts over. Without this the streak is
        # just a counter and the seventh square arrives whenever it arrives.
        "reset_on_miss": True,
    },
    # What diamonds buy.
    #
    # Never gold and never power -- that rule is what keeps the premium currency
    # from being a shortcut past the game. These are the two things a player
    # actually wants and cannot otherwise have: the pool back before it refills
    # on its own, and a night where nobody can raid you.
    "store": {
        "energy_refill_diamonds": 12,
        "shield_diamonds": 20,
        "shield_hours": 8,
    },
    # Which sections a player can reach, and when.
    #
    # A new player meeting nine tabs at once cannot tell which one matters, and
    # most of them do nothing yet: there is no gold to spend, no army to gear, no
    # kingdom to join. Handing them Jobs and Hero and revealing the rest as each
    # becomes useful is the single biggest thing that makes the reference game
    # legible. Locked sections stay VISIBLE but dimmed with their level, because
    # seeing what is coming is most of what makes levelling feel like progress.
    #
    # Levels are chosen to land just before the thing behind them turns on:
    # the Shop matters once a job pays enough to buy from it, Army at 5 is when
    # the first slot becomes free, House at 20 is when founding unlocks.
    "sections": [
        {"id": "jobs", "level": 1},
        {"id": "hero", "level": 1},
        {"id": "shop", "level": 2},
        {"id": "items", "level": 3},
        {"id": "estates", "level": 4},
        {"id": "army", "level": 5},
        {"id": "bank", "level": 8},
        {"id": "fight", "level": 10},
        {"id": "house", "level": 20},
    ],
    "avatars": AVATARS,
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

# The roll band, and why it is this narrow.
#
# A tier has to MEAN something: a legendary must beat an epic, every time, or the
# ladder the whole game is sorted by is decoration. That is a constraint between
# two numbers, and it was violated. The widest a roll could swing was
# 1.15 quality x 1.15 masterwork / 0.85 = 1.556, while the CLOSEST two tiers sit
# is 1.35 (common to uncommon) -- so every adjacent pair could invert, and a
# masterwork epic really did out-hit a poorly rolled legendary.
#
# 1.05 x 1.08 / 0.95 = 1.194, comfortably inside 1.35 with room for integer
# rounding at small base stats. Validate enforces the relationship, so widening
# the band or narrowing the ladder fails the publish rather than the player.
QUALITY_MIN_PCT, QUALITY_MAX_PCT = 95, 105
MASTERWORK_MULT_PCT = 108

# The rarity ladder, emitted rather than hand-kept.
#
# stat_mult used to live only in a hand-edited tiers.json and had drifted to a
# completely different curve from the one the game runs on -- it said a special
# was 13.86x a common while the actual multiplier, tier_mult_bp, said 7.60x.
# Nothing read it, so nothing caught it, and anyone reasoning about power from
# that file was reasoning about a ladder that does not exist. It is derived from
# TIER_MULT here so the two cannot disagree again.
#
# Colours stay in balance rather than client code so they can be retuned from
# the panel. Tier is never signalled by colour ALONE: every card also carries the
# tier name and a 1-7 pip count, because a gray/green/blue/violet/gold/magenta/
# red ladder is not reliably separable under deuteranopia.
TIER_NAMES = ["Common", "Uncommon", "Rare", "Epic", "Legendary", "Mystic", "Special"]
TIER_COLORS = ["#9BA1A6", "#4ADE80", "#38BDF8", "#A855F7", "#F5C518", "#E040FB", "#EF4444"]

emit("tiers.json", json.dumps({
    "_comment": "The rarity ladder. stat_mult is DERIVED from the same TIER_MULT that items.json's "
                "tier_mult_bp comes from, so the two can never drift apart again. The ladder is "
                "strictly ordered in power and the roll band is narrower than the closest two rungs, "
                "so a higher tier always out-hits a lower one. Tier is NEVER signalled by colour alone: "
                "every card also shows the tier name and a 1-7 pip count.",
    "tiers": [
        {"id": TIER_IDS[i], "rank": i + 1, "name": TIER_NAMES[i],
         "color": TIER_COLORS[i], "pips": i + 1, "stat_mult": TIER_MULT[i]}
        for i in range(7)
    ],
}, indent=2) + "\n")

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
    # Ordered to match the design walk: item i is drawn as design (i % 7) + 1,
    # so each tier's three names must name designs (1,2,3), (4,5,6), (7,1,2) and
    # so on. SHAPE_WORDS below refuses to generate if they ever drift apart.
    "armor": [
        ["Padded Gambeson", "Militia Jerkin", "Rusted Hauberk"],
        ["Guard's Breastplate", "Tempered Cuirass", "Ironweave Harness"],
        ["Riverbend Aegis", "Warden's Gambeson", "Silvered Jerkin"],
        ["Duskmail Hauberk", "Bastion Breastplate", "Kingsguard Cuirass"],
        ["Dawnward Harness", "The Gilded Aegis", "Ashen Gambeson"],
        ["Starfall Jerkin", "Wyrmscale Hauberk", "The Unbroken Breastplate"],
        ["Crown Cuirass", "The Last Harness", "Emperor's Aegis"],
    ],
    "horse": [
        ["Plough Horse", "Village Pony", "Guard's Rouncey"],
        ["Trail Courser", "Riverbend Destrier", "Bastion Warhorse"],
        ["Warden's Charger", "Swaybacked Plough Horse", "Silvermane Pony"],
        ["Duskmane Rouncey", "Kingsguard Courser", "Dawnward Destrier"],
        ["The Ninth Siege Warhorse", "The Gilded Charger", "Starfall Plough Horse"],
        ["Wyrmborn Pony", "The Tempest Rouncey", "Crown Courser"],
        ["The Last Destrier", "Emperor's Warhorse", "Sunrise Charger"],
    ],
}

# How many distinct silhouettes exist per slot. Tier is applied by recolouring
# the line work, so one PNG serves all seven tiers of a design -- but with only
# three designs a slot, a legendary sword was the SAME SHAPE as the rusted blade
# you started with, in a different colour. Climbing has to look like something.
ART_DESIGNS = {"weapon": 7, "armor": 7, "horse": 7}

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
    "weapon": {"arming sword": 1, "falchion": 2, "broadsword": 3,
               "greatsword": 4, "flamberge": 5, "rapier": 6, "leafblade": 7},
    "armor": {"gambeson": 1, "jerkin": 2, "hauberk": 3,
              "breastplate": 4, "cuirass": 5, "harness": 6, "aegis": 7},
    "horse": {"plough horse": 1, "pony": 2, "rouncey": 3,
              "courser": 4, "destrier": 5, "warhorse": 6, "charger": 7},
}
for d in item_defs:
    words = SHAPE_WORDS.get(d["slot"], {})
    lowered = d["name"].lower()
    for word, design in words.items():
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
    "quality": {"min_pct": QUALITY_MIN_PCT, "max_pct": QUALITY_MAX_PCT},
    "masterwork": {"chance_bp": 300, "mult_pct": MASTERWORK_MULT_PCT},
    # reforge_ratio_bp is what re-rolling an item's quality costs, as a share of
    # its own undiscounted shop price.
    #
    # The design flagged this as invalidating its arbitrage proof, because that
    # proof assumed an item's stats never change after acquisition. It no longer
    # does, and the reason is the narrowed quality band: the best possible roll
    # is 1.194x the worst, which at the 1.35 price exponent is 1.270x the price,
    # so the most a reforge can ever add to the SELL value is 0.25 x 1.270 =
    # 0.317 of the original price -- against a 0.60 cost. Reforging to sell loses
    # money by construction, at every tier and every level.
    "price": {"coef": 1.6, "exponent": 1.35, "sell_ratio_bp": 2500,
              "reforge_ratio_bp": 6000},
    "speed_power_weight_bp": 5000,
    # The Collection: what donating a piece of gear is worth.
    #
    # It pays in LUCK, which is the one bucket that makes the reward loop back
    # into the thing being rewarded — a broader collection tilts future rolls,
    # which produces more things to collect. Luck is capped in code
    # (ClampLuckBP), so the whole board can never push past the ceiling the
    # game's own upgrades could already reach.
    #
    # 63 definitions: 3 slots x 7 tiers x 3 designs. At 60 bp each a complete
    # collection is +3780 bp before the set bonuses, which sits under the 10000
    # cap with room for the luck nodes a player may also own.
    "collection": {
        "luck_bp_per_piece": 60,
        # Completing every design of one slot at one tier. Nine of these exist
        # per slot, and they are what turn "sell the spares" into "hold the
        # third falchion".
        "luck_bp_per_set": 200,
    },
    "shop": {
        "slots": 6,
        "window_seconds": 300,
        "base_weights": {"common": 100.0, "uncommon": 45.0, "rare": 16.0, "epic": 5.0,
                         "legendary": 1.2, "mystic": 0.20, "special": 0.02},
        "luck_coef": 0.014,
        # Rerolling costs diamonds, never gold. A gold reroll would be a way to
        # convert income straight into rarity, which is the one thing the premium
        # currency is not allowed to do either -- so the price escalates within a
        # window and resets when the window turns.
        "reroll_base_diamonds": 8,
        "reroll_step_diamonds": 6,
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
                "stats = type_stat * tier_mult. A soldier has NO level: its tier is its rank, it is "
                "fixed at recruitment and it never grows. A common Gladiator is about as strong as a "
                "rare Peasant, which is what justifies the 40x price gap: the TYPE matters beyond the "
                "tier roll. Because nothing but the tier scales a soldier, the tier ladder is strictly "
                "ordered in power: a legendary always beats an epic.",
    "max_slots": MAX_SLOTS,
    "slots": slots,
    "recruit_cost_per_level_bp": 1100,
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
    #
    # The player is the ONLY thing in the game that grows with level, and it
    # grows in steps rather than continuously: a flat per-level trickle made the
    # number go up without a decision attached to it. Every fifth level hands
    # over a visible lump of attack and defense; everything beyond that comes
    # from spending stat points, which is a choice.
    "player": {
        "base_stat": 10,
        "levels_per_stat_step": 5,
        "stat_step": 5,
        "per_stat_point": 4,
        "base_hp": 100,
        # The player's HP grows through DEFENSE, not through a per-level
        # trickle: defense buys HP at 3.0x below, and defense comes from the
        # every-fifth-level step and from spent stat points. A flat per-level
        # term on top of that was power handed over for nothing.
        "hp_per_level": 0,
    },
    "combat": {
        "hp_per_defense_bp": 30000,      # 3.0x — Defense buys HP as well as mitigation
        # Was +2% per owner level, applied to soldiers as well as the player.
        # That is army power bought with nothing but time, which is exactly what
        # a fixed roster is not allowed to have -- and with attack no longer
        # scaling, HP outrunning it dragged fights into the round cap.
        "hp_level_bonus_bp": 0,
        "dr_level_coef": 40,             # DR = def / (def + 40*level + 60)
        "dr_base": 60,
        "dr_cap_bp": 6000,               # hard 60% ceiling, or tanks become unkillable
        # Battle simulation (economy.md 8.2-8.6). A volley auto-battle over ~200
        # damage rolls per side is inherently near-deterministic: per-hit noise
        # averages out to a coefficient of variation under 0.04, so crit and dodge
        # cannot move the win curve at all. The ONLY knob that can is a per-side,
        # per-battle roll — Fortune of War. A per-unit roll fails too, because its
        # effect shrinks as 1/sqrt(N) and the curve would drift as players buy slots.
        # Damage per point of attack. Raised from 0.16 because removing the
        # soldier level term changed what this is measured against: attack, HP
        # and defense used to scale together, so the ratio held at every level
        # by construction. With soldiers fixed, the ratio is whatever the base
        # numbers say, and at 0.16 that was ~30-round fights with one in ten
        # hitting the 60-round cap and being decided on health fraction.
        # Measured with TestRoundCountByLevel; 0.20 is the gentlest value that
        # clears the cap entirely.
        "dmg_k_bp": 2000,
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
    ("tithe_barn", "Tithe Barn",          "tax_income_bp",     20,  150, 500,   1.36, "Your estates earn more."),
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
# Five levels, not ten. The totals below are unchanged by this -- each level is
# simply twice as thick -- but a purchase you can SEE is the whole point of the
# tab. At ten levels the first one bought a tenth of the smallest estate: +1
# gold/hour against a base of 28, a 3% move that read as nothing happening, and
# players correctly left every holding at 0.
HOLDING_MAX_LEVEL = 5

holdings = []
for i, (hid, name, unlock, _tier) in enumerate(HOLDINGS):
    # Yield per level grows 1.65x per holding, so later estates are the ones
    # worth chasing, and the first ones still carry the early game.
    #
    # The coefficient is 2.4x what it was. At the old value a fully built estate
    # took four to ten days of its own income to pay for itself, which is a long
    # time to wait for a building in an idle game; it is now two to four, and
    # estates are the gold engine rather than a rounding error next to tapping.
    per_hour = round(4.08 * 1.65 ** i, 2)
    # Priced from PAYBACK, and the growth rate here is the load-bearing part:
    # cost must grow SLOWER than yield (1.51 against 1.65) so that payback
    # SHORTENS as you climb, 254 hours down to 137.
    #
    # It used to be the other way around -- cost 1.72 against yield 1.5 -- which
    # meant the Ducal Mint, the estate a level-55 player finally unlocks, took
    # 737 hours to pay for itself against the Wheat Farm's 283. The capstone was
    # the worst investment on the board, which is exactly backwards.
    #
    # The Family tree remains the bottomless sink at 6.8M; Territory is the income
    # engine and is deliberately cheap by comparison.
    base_cost = half_up(round(263 * 1.51 ** i), 1)
    costs = [half_up(base_cost * round(1.25 ** (lv - 1) * 10000), 10000)
             for lv in range(1, HOLDING_MAX_LEVEL + 1)]
    holdings.append({
        "id": hid, "name": name, "unlock_level": unlock,
        "max_level": HOLDING_MAX_LEVEL,
        # milli-gold per hour per level, so the whole pipeline stays integer
        "tax_milli_per_hour_per_level": int(round(per_hour * 1000)),
        "costs": costs,
    })

TAX = {
    # Idle income, and why both of these moved a long way.
    #
    # The rate is a function of LEVEL, and the level curve was slowed by
    # about 4x when the xp ramp came down to 1.06. Nothing else changed, but
    # a player at day 21 went from level 59 to level 42 — and their passive
    # income fell 61% with them, because it was pegged to a level they now
    # reach months later. Idle income has to be paced against the CLOCK, not
    # against a curve that moved underneath it.
    #
    # 40 x 1.055^L rather than 24 x 1.045^L, and holding yields 2.4x on top.
    # That is a deliberate change of what the game IS: estates are the gold
    # engine now and collecting is what buys levels. Tapping stays compulsory
    # because it is the only meaningful source of XP, and XP gates sections,
    # slots and every holding unlock -- but a player who has built their estates
    # out-earns one who only taps, at every archetype. See the self-check below.
    "base_per_hour_milli": 40000,
    "growth_bp": 10550,              # 1.055^level
    # DEAD, both of them. Estate income is credited by middleware on every
    # request and is deliberately uncapped; nothing on that path reads these.
    # Emitted so an older published balance document still parses.
    "offline_cap_seconds": 28800,
    "offline_cap_per_tithe_level": 720,
}

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
    "tax": TAX,
}, indent=2) + "\n")

print(f"estates.json   : {len(upgrades)} family upgrades, {len(holdings)} holdings")
print(f"  family tree total cost : {sum(sum(u['costs']) for u in upgrades):>12,} gold")
print(f"  holdings total cost    : {sum(sum(h['costs']) for h in holdings):>12,} gold")
# What passive income is actually WORTH, measured against what the same player
# earns by playing. Compared per DAY, not per hour: estate income accrues
# continuously and uncapped (see service/tax.go), while collecting is bounded by
# how often somebody opens the app and how much pool they have when they do.
#
# The old line divided by a hardcoded 12725 -- the active income of a build four
# rebalances ago -- so it went on printing a passing number while the real ratio
# halved underneath it. Anything derived from the balance has to be COMPUTED from
# the balance.
def _active_gold_per_day(level, gaps):
    pool_cap = ENERGY["base_max"] + ENERGY["per_level"] * (level - 1)
    energy = sum(min(pool_cap, int(g * 3600 / ENERGY["regen_base_seconds"])) for g in gaps)
    job = [j for j in jobs if j["unlock_level"] <= level][-1]
    return energy * job["base_gold"] / job["energy_cost"]


def _tax_base_per_hour(level):
    """The level term of the tax, from the config rather than a copy of it."""
    milli = TAX["base_per_hour_milli"]
    for _ in range(level):
        milli = milli * TAX["growth_bp"] // 10000
    return milli / 1000


def _passive_gold_per_day(level, bucket_mult):
    per_hour = _tax_base_per_hour(level)
    per_hour += sum(h["tax_milli_per_hour_per_level"] / 1000 * HOLDING_MAX_LEVEL
                    for h in holdings if h["unlock_level"] <= level)
    return per_hour * 24 * bucket_mult


# Tithe Barn at max (+30%) plus a maxed Royal Treasury (+10%). Both feed the one
# additive tax_income_bp bucket, so this is its real ceiling.
TAX_BUCKET_MAX = 1.40
SESSIONS = {"casual 3/day": [5, 8, 11], "regular 5/day": [3, 3, 4, 6, 8],
            "committed 8/day": [1, 1, 2, 2, 2, 3, 5, 8]}

tax60 = _tax_base_per_hour(60)
hold60 = sum(h["tax_milli_per_hour_per_level"] / 1000 * HOLDING_MAX_LEVEL for h in holdings)
print(f"  tax/hr at lv60         : base {tax60:>8.0f} + holdings {hold60:>7.0f} = {tax60 + hold60:>8.0f}")
print("  passive vs active gold per day, holdings maxed, tax bucket at its ceiling:")
print("    %-18s %s" % ("", "".join("%9s" % f"L{L}" for L in (10, 20, 30, 40, 50, 60))))
for who, gaps in SESSIONS.items():
    cells = "".join("%8.0f%%" % (100 * _passive_gold_per_day(L, TAX_BUCKET_MAX)
                                 / _active_gold_per_day(L, gaps))
                    for L in (10, 20, 30, 40, 50, 60))
    print(f"    {who:<18}{cells}")
print("    Estates are the GOLD engine and collecting is the XP engine, so these")
print("    are meant to exceed 100%: a player who builds out-earns one who only")
print("    taps. Tapping stays compulsory anyway -- it is the only real source of")
print("    XP, and XP gates sections, barracks slots and every holding unlock.")
print("    What to watch: if the committed row climbs far past the casual one,")
print("    the idle build has stopped being a CHOICE and just become correct.")
print("  holding                 unlock   max yield/hr      total cost   payback")
for h in holdings:
    y = h["tax_milli_per_hour_per_level"] / 1000 * HOLDING_MAX_LEVEL
    c = sum(h["costs"])
    print(f"  {h['name']:<22} lv{h['unlock_level']:<4} {y:>10.1f} {c:>15,}   {c/max(y,0.01):>6.0f}h")


# --- kingdoms (economy.md 12) -------------------------------------------------
KINGDOM_UPGRADES = [
    ("royal_granaries", "Royal Granaries", "collect_income_bp", 10, 200,  50000,  1.55, "Every member collects more."),
    ("royal_archives",  "Royal Archives",  "xp_bp",             10, 150,  60000,  1.55, "Every member learns faster."),
    ("royal_treasury",  "Royal Treasury",  "tax_income_bp",     10, 100,  50000,  1.52, "Every member's estates earn more."),
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
    # What Favour is actually for.
    #
    # It has been granted on every donation since kingdoms shipped, shown on the
    # Realm card, and been spendable on nothing — so donating cost the donor gold
    # and gave them back a number. The design's own line on this: "Donating must
    # reward the donor personally, or nobody donates."
    #
    # Priced against the daily donation cap rather than against gold directly: a
    # level-1 kingdom's cap is 20,800 gold a day, which is 208 favour, so the
    # energy potion is roughly a fifth of a day's donating and the XP boost about
    # half of one.
    "favour_shop": [
        {"id": "energy_potion", "name": "Energy Potion", "cost": 40,
         "blurb": "Fills your energy to the brim."},
        {"id": "shop_refresh", "name": "Fresh Wares", "cost": 25,
         "blurb": "The market restocks at once."},
        # Feeds the same xp_bp bucket as the Scriptorium and any server event,
        # so it shares that bucket's cap and cannot stack past it.
        {"id": "xp_boost", "name": "Scholar's Draught", "cost": 120,
         "bp": 1000, "hours": 2,
         "blurb": "+10% experience for two hours."},
    ],
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
