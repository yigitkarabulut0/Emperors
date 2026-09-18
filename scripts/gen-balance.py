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
# What a lord who reaches the cap may do again, and what each pass is worth. The
# talents read max_stacks too: a Legacy is a talent point as well as income.
LEGACY = {
    "max_stacks": 10,
    "income_bp_per_stack": 500,
}
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

# The navigation sections and the level that opens each. Written ONCE: this is
# what progression.sections is generated from, and everything else that needs a
# gate's level -- a daily task, a page's blurb -- reads SECTION_LEVEL rather
# than repeating the number.
SECTIONS = [
    {"id": "jobs", "level": 1},
    {"id": "hero", "level": 1},
    {"id": "shop", "level": 2},
    {"id": "items", "level": 3},
    {"id": "estates", "level": 4},
    {"id": "army", "level": 5},
    {"id": "bank", "level": 8},
    {"id": "fight", "level": 10},
    # Rekabet (Wave 5). The one place these levels are written: pvp.json names
    # the gate, it never repeats the number.
    {"id": "arena", "level": 12},
    {"id": "bounty", "level": 15},
    # Sosyal (Wave 6). Friends is a level; the hall and its aid are a KINGDOM,
    # which is not a level and so is not a row here.
    {"id": "friends", "level": 3},
    {"id": "house", "level": 20},
    # PvE ve derinlik (Wave 7). The campaign opens BEFORE raiding, which is the
    # point of it: a lord learns what a battle is against the realm's own
    # garrisons before another lord can answer back.
    {"id": "campaign", "level": 6},
    {"id": "talents", "level": 10},
    {"id": "hunt", "level": 8},
    {"id": "forge", "level": 12},
    # Krallik Boss ve Savaslari (Wave 8). What really opens both is having a
    # KINGDOM, which is not a level; the gate is the one raiding stands behind,
    # because a lord who cannot raid cannot hold a banner either.
    {"id": "boss", "level": 10},
    {"id": "war", "level": 10},
]
SECTION_LEVEL = {s["id"]: s["level"] for s in SECTIONS}

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
    # Legacy: what starting over is worth.
    #
    # Reset to level 1 keeping gold, gear, soldiers and estates, and carry a
    # permanent bonus into the collect and tax buckets — both capped, so ten
    # stacks lift a player toward a ceiling the game's own upgrades could already
    # reach rather than past it.
    #
    # Only at the cap, because the point is that the cap stops being the end.
    "legacy": LEGACY,
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
            # PvE ve derinlik (Wave 7). Each is gated behind its own section's
            # level, so a task is never offered to a lord who cannot open the
            # screen it asks about -- and each watches a tap the lord was
            # taking anyway rather than asking for an extra session.
            {"id": "campaign_2", "kind": "stages", "target": 2, "tier": 1,
             "name": "Down the Road", "blurb": "Walk two miles of the campaign.",
             "min_level": SECTION_LEVEL["campaign"]},
            {"id": "campaign_5", "kind": "stages", "target": 5, "tier": 2,
             "name": "The Long March", "blurb": "Walk five miles of the campaign.",
             "min_level": SECTION_LEVEL["campaign"]},
            {"id": "hunt_1", "kind": "hunts", "target": 1, "tier": 1,
             "name": "Out of the Gate", "blurb": "Send a soldier to the fields.",
             "min_level": SECTION_LEVEL["hunt"]},
            # Two, not three: a lord has ONE expedition slot until level 20,
            # so three would ask them to wait out three roads in a day.
            {"id": "hunt_2", "kind": "hunts", "target": 2, "tier": 2,
             "name": "Every Road Walked", "blurb": "Send two soldiers out.",
             "min_level": SECTION_LEVEL["hunt"]},
            {"id": "aid_2", "kind": "aids", "target": 2, "tier": 1,
             "name": "A Hand Offered", "blurb": "Answer two calls for aid.",
             "needs": "kingdom"},
            # Krallik Boss (Wave 8). Two of the six blows, and only for a lord
            # who has a kingdom: a task nobody without one could ever finish
            # would be a wasted slot on their board, which is what `needs` is
            # for. Two rather than six, because a beast is not always standing.
            {"id": "boss_2", "kind": "blows", "target": 2, "tier": 2,
             "name": "Into the Beast", "blurb": "Strike your kingdom's beast twice.",
             "needs": "kingdom", "min_level": SECTION_LEVEL["boss"]},
        ],
    },
    # The daily login calendar is retention.json's `calendar` now: 28 squares,
    # not seven (see the retention section below).
    #
    # What diamonds buy.
    #
    # Never gold and never power -- that rule is what keeps the premium currency
    # from being a shortcut past the game. These are the two things a player
    # actually wants and cannot otherwise have: the pool back before it refills
    # on its own, and a night where nobody can raid you.
    "store": {
        # A full refill: three a day, each dearer than the last (economy.md
        # §15.1). Unlimited at a flat 12 was harmless while diamonds could only
        # be earned; the moment they can be bought it is unlimited gold and XP
        # for money, the one thing the premium currency must never buy. Three a
        # day caps what money can add to a day's energy; the rising price makes
        # the third a decision. The count resets at the player's own midnight.
        "energy_refill_prices": [20, 30, 45],
        "shield_diamonds": 20,
        "shield_hours": 8,
        # A new name for the hero. Vanity, not power, so it belongs in this list;
        # priced by hand for now and to be revisited with the rest of the store.
        "rename_diamonds": 100,
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
    "sections": SECTIONS,
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

# What an item level is worth: +9% of the base stat per level of the item.
LEVEL_MULT_PER_ILVL_BP = 900

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
        ["Rusted Arming Sword", "Farmhand's Falchion", "Notched Spear"],
        ["Guard's Greatsword", "Tempered Flamberge", "Oathkeeper's Rapier"],
        ["Riverbend Leafblade", "Silvered Arming Sword", "Warden's Falchion"],
        ["Duskfang Spear", "Bastion Greatsword", "Kingsguard Flamberge"],
        ["Dawnbreaker Rapier", "Ashfang Leafblade", "The Gilded Verdict"],
        ["Starfall Falchion", "Wyrmtongue Spear", "The Sundering"],
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

# How many distinct designs exist per slot. With only three a slot, a legendary
# sword was the SAME SHAPE as the rusted blade you started with, in a different
# colour; with seven, three tiers shared each. Every slot now has one painted
# design per definition: the seven cut from the references, then the fourteen
# painted by name on their own sheets (art/reference/items_weapons.png,
# items_armor.png and items_horses.png, scripts/cut-item-paintings.py), so the
# design walk below gives item i design i + 1.
ART_DESIGNS = {"weapon": 21, "armor": 21, "horse": 21}

# Designs two definitions share, and why: none now. The Village Pony wore the
# Plough Horse's plain brown head until its own pony was painted
# (art/reference/items_horses_2.png, horse_02). A share belongs here only while a
# definition waits for its painting; client/tests/item_designs.gd holds this
# list to be the only shares there are.
ART_SHARED = {}

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
            def_id = f"{slot}_{TIER_IDS[ti]}_{n:02d}"
            item_defs.append({
                "id": def_id,
                "slot": slot,
                "tier": TIER_IDS[ti],
                "name": name,
                "art": ART_SHARED.get(def_id, f"{slot}_{art_index:02d}"),
            })

# What each weapon design actually depicts. A name that promises a shape must be
# drawn as that shape: rotating the design pool through the table silently broke
# this once, and a "Tempered Falchion" rendered as a wavy flamberge. The numbers
# are the shape families of the first seven designs; the sheets paint designs
# 8 to 21 in the same family order (design d is family (d - 1) % 7 + 1: the
# Silvered Arming Sword is design 8, the Warden's Falchion 9, and so on), so one
# table checks all twenty-one.
SHAPE_WORDS = {
    "weapon": {"arming sword": 1, "falchion": 2, "spear": 3,
               "greatsword": 4, "flamberge": 5, "rapier": 6, "leafblade": 7},
    "armor": {"gambeson": 1, "jerkin": 2, "hauberk": 3,
              "breastplate": 4, "cuirass": 5, "harness": 6, "aegis": 7},
    "horse": {"plough horse": 1, "pony": 2, "rouncey": 3,
              "courser": 4, "destrier": 5, "warhorse": 6, "charger": 7},
}
for d in item_defs:
    if d["id"] in ART_SHARED:
        continue  # borrowing another's design, by the note on ART_SHARED
    words = SHAPE_WORDS.get(d["slot"], {})
    lowered = d["name"].lower()
    for word, design in words.items():
        if word in lowered:
            got = (int(d["art"].split("_")[1]) - 1) % 7 + 1
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
    "level_mult_per_ilvl_bp": LEVEL_MULT_PER_ILVL_BP,
    "quality": {"min_pct": QUALITY_MIN_PCT, "max_pct": QUALITY_MAX_PCT},
    "masterwork": {"chance_bp": 300, "mult_pct": MASTERWORK_MULT_PCT},
    # An item's stats never change after it is acquired, which is what the
    # design's arbitrage proof rests on. Reforging re-rolled them for gold and
    # so had to carry its own proof that re-rolling to sell always lost money;
    # it has been removed, and the simpler invariant is back.
    "price": {"coef": 1.6, "exponent": 1.35, "sell_ratio_bp": 2500},
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
        # And at most this many a day, on the lord's own day. Diamonds are sold,
        # and rerolls are the one place diamonds reach rarity: a cap keeps a
        # purse from turning into gear (plan: "market reroll at most 20 a day").
        "rerolls_per_day": 20,
    },
    # How many items one armory holds. A limit and a design knob: forcing a
    # choice about what to keep is what makes selling and the Collection matter.
    "inventory_cap": 150,
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
    {"id": "peasant",   "name": "Villager",   "base_cost": 150,  "attack": 8,  "defense": 8,  "hp": 40,
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

SOLDIERS_DOC = {
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
}
emit("soldiers.json", json.dumps(SOLDIERS_DOC, indent=2) + "\n")
# The two blocks a later wave mirrors: the campaign builds its garrisons out
# of the same player and combat numbers the server fights with, so a stage's
# recorded Might cannot drift from what the game works out.
SOLDIER_PLAYER = SOLDIERS_DOC["player"]
SOLDIER_COMBAT = SOLDIERS_DOC["combat"]


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
    ("coffers",    "Ransom Coffers",      "ransom_bp",          8,  500, 6000,  1.72, "Holding off a raid pays more."),
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
    # The storehouse (Wave 2): estate income fills it at the hourly rate for
    # this long, 12 minutes more per Tithe Barn level (12 h at its top), and
    # stops; the lord carries it to the purse or the vault.
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
# earns by playing. Compared per DAY, not per hour: estate income fills the
# storehouse (Wave 2, service/storehouse.go) up to its capacity -- 8 hours, 12
# minutes more per Tithe Barn level -- and is carried in at each session, so a
# gap longer than the capacity loses its excess; collecting is bounded by how
# often somebody opens the app and how much pool they have when they do.
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


def _storehouse_hours(tithe_level):
    return (TAX["offline_cap_seconds"] + TAX["offline_cap_per_tithe_level"] * tithe_level) / 3600


def _passive_gold_per_day(level, bucket_mult, gaps, tithe_level):
    """A day's estate income as a lord with these session gaps carries it in:
    each gap fills the storehouse for at most its capacity's hours."""
    per_hour = _tax_base_per_hour(level)
    per_hour += sum(h["tax_milli_per_hour_per_level"] / 1000 * HOLDING_MAX_LEVEL
                    for h in holdings if h["unlock_level"] <= level)
    cap = _storehouse_hours(tithe_level)
    kept = sum(min(g, cap) for g in gaps) * 24 / sum(gaps)
    return per_hour * kept * bucket_mult


# Tithe Barn at max (+30%) plus a maxed Royal Treasury (+10%). Both feed the one
# additive tax_income_bp bucket, so this is its real ceiling.
TAX_BUCKET_MAX = 1.40
SESSIONS = {"casual 3/day": [5, 8, 11], "regular 5/day": [3, 3, 4, 6, 8],
            "committed 8/day": [1, 1, 2, 2, 2, 3, 5, 8]}

tax60 = _tax_base_per_hour(60)
hold60 = sum(h["tax_milli_per_hour_per_level"] / 1000 * HOLDING_MAX_LEVEL for h in holdings)
print(f"  tax/hr at lv60         : base {tax60:>8.0f} + holdings {hold60:>7.0f} = {tax60 + hold60:>8.0f}")
TITHE_MAX = next(u["max_level"] for u in upgrades if u["id"] == "tithe_barn")
print("  passive vs active gold per day, holdings maxed, tax bucket at its ceiling,")
print(f"  carried in from a {_storehouse_hours(TITHE_MAX):.0f}h storehouse at every session:")
print("    %-18s %s" % ("", "".join("%9s" % f"L{L}" for L in (10, 20, 30, 40, 50, 60))))
for who, gaps in SESSIONS.items():
    cells = "".join("%8.0f%%" % (100 * _passive_gold_per_day(L, TAX_BUCKET_MAX, gaps, TITHE_MAX)
                                 / _active_gold_per_day(L, gaps))
                    for L in (10, 20, 30, 40, 50, 60))
    print(f"    {who:<18}{cells}")
print("  a day's estate income the storehouse keeps, by Tithe Barn level:")
for who, gaps in SESSIONS.items():
    cells = "".join("%7.0f%%" % (100 * sum(min(g, _storehouse_hours(t)) for g in gaps) / sum(gaps))
                    for t in (0, 10, TITHE_MAX))
    print(f"    {who:<18}{cells}   (Tithe Barn 0 / 10 / {TITHE_MAX})")
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
    # No daily cap. There was one -- 20,000 gold plus 800 a level -- to stop a
    # whale maxing a kingdom overnight and to make alt-account laundering slow.
    # The owner asked for it gone: a player may give the treasury whatever they
    # have.
    "donation": {
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
    # Priced in favour, which is a hundredth of the gold given: the energy potion
    # is 4,000 gold of donation, the market refresh 2,500 and the XP boost
    # 12,000. These were set against a daily cap of about 20,800 gold, which is
    # gone; the prices stand because they are what the goods are worth.
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
    # Joining without an invitation. A king chooses 'open' (anyone joins while
    # there is room) or 'request' (a king or captain answers each one).
    #
    # The cooldown is what keeps that honest. Kingdom-mates cannot raid each
    # other, so without a wait a lord under attack could join the attacker's
    # kingdom for the length of the raid and leave again -- and a king removing
    # someone from an open kingdom would watch them walk straight back in. An
    # hour is long enough to spoil both and short enough that a lord who simply
    # chose badly is not punished for it. economy.md 12.5 suggests 24 h, which
    # was for a game where joining granted a bonus; this one grants none.
    "rejoin_cooldown_minutes": 60,
    # Requests a player may have out at once. Enough to ask the three or four
    # kingdoms that look right; not enough to knock on every door in the realm.
    "max_join_requests": 5,
}, indent=2) + "\n")

print(f"kingdoms.json  : {len(k_upgrades)} upgrades, {KINGDOM_MAX_LEVEL} levels")
print(f"  found        : {250000:,} gold at level 20")
print(f"  tree total   : {sum(sum(u['costs']) for u in k_upgrades):>12,} kingdom gold")
print(f"  member cap   : {k_levels[0]['member_cap']} at Lv1 -> {k_levels[-1]['member_cap']} at Lv{KINGDOM_MAX_LEVEL}")
print(f"  xp to Lv8    : {k_levels[-1]['xp_required']:>12,}")


# --- rewards: tokens, the Royal Mail, and the bounds on any reward -------------
#
# A flask restores this share of the lord's own pool, so one is worth the same
# at every level. Kept small: each free source of energy moves the climb, and
# scripts/pace.py prints what each one moves it by (the plan allows 5 % a source).
FLASK_SMALL_PCT = 10
# A friend's draught: two parts of a hundred, and three a day. Six parts of a
# pool is what scripts/pace.py leaves the hall beside the kingdom's aid (2.8%
# of casual level 60 at nine parts, 1.8% at six, against a budget of 3%).
FLASK_FRIEND_PCT = 2
FLASK_LARGE_PCT = 25
#
# Every system that pays a player -- a letter, a login square, a chest, a
# purchase -- pays through one function on the server (grantBundle), and these
# are its data. A token is a consumable held in a count; paid_ok marks the ones
# money may carry. Anything whose use rolls for loot is never paid_ok: sold, it
# would be a loot box, which this game never has.
emit("rewards.json", json.dumps({
    "_comment": "Reward machinery. Tokens are consumables held in a count; paid_ok marks those money "
                "may carry. mail is the Royal Mail's housekeeping. limits bound a single reward, so a "
                "typo in a letter or a balance field is refused rather than delivered.",
    "tokens": [
        # A full refill in a bottle. Using one counts as one of the day's
        # refills, so however refills are paid for -- diamonds or potions --
        # the day's bought energy stays inside the same limit.
        {"id": "energy_potion", "name": "Energy Potion",
         "blurb": "Refills your energy. Counts as one of the day's refills.",
         "icon": "energy_potion", "paid_ok": True},
        # Eight hours of protection, the store's shield, held for later.
        {"id": "shield_8h", "name": "Protection Charter",
         "blurb": "Eight hours in which nobody can raid you. Raiding someone yourself ends it.",
         "icon": "city_shield", "paid_ok": True},
        # Part of a pool, in a bottle: the free rewards' energy (the Tax Cart,
        # the calendar, the week's chests). Never sold: money buys at most the
        # day's three refills, and a flask is not one of them.
        {"id": "flask_small", "name": "Small Flask",
         "blurb": "Restores a tenth of your energy. It is not a refill: the day's refills are untouched.",
         "icon": "flask_small", "paid_ok": False, "energy_pct": FLASK_SMALL_PCT},
        {"id": "flask_large", "name": "Great Flask",
         "blurb": "Restores a quarter of your energy. It is not a refill: the day's refills are untouched.",
         "icon": "flask_large", "paid_ok": False, "energy_pct": FLASK_LARGE_PCT},
        # What one friend sends another (social.friends). A SHARE of the taker's
        # own pool, like every other flask -- a flat gift would be a second way
        # energy enters the game, and a level-60 friend would be handing a new
        # lord half a day. Never sold, like the other two.
        {"id": "flask_friend", "name": "A Friend's Draught",
         "blurb": "A friend's gift: a fiftieth of your energy back. It is not a refill.",
         "icon": "flask_small", "paid_ok": False, "energy_pct": FLASK_FRIEND_PCT},
        # Mends a broken run of daily rewards (retention.calendar): time, not
        # power, so money may carry it.
        {"id": "pardon", "name": "Royal Pardon",
         "blurb": "Mends a broken run of daily rewards, as if the missed days had been kept.",
         "icon": "pardon", "paid_ok": True},
        # One more Tax Cart. A cart's prize is drawn at random, so a writ is a
        # loot draw and money never carries one.
        {"id": "cart", "name": "Cart Writ",
         "blurb": "Calls one more Tax Cart, opened after the carts already waiting.",
         "icon": "cart", "paid_ok": False},
        # One more fight in the Honour Arena, from Honour Hour. NEVER paid: the
        # arena's five fights a day are what keep the ladder a measure of play
        # rather than of a purse, and a ticket on sale would undo that in one
        # product. It is the only way past the day's five.
        {"id": "arena_ticket", "name": "Arena Token",
         "blurb": "One more fight in the Honour Arena, held until you spend it.",
         "icon": "arena_ticket", "paid_ok": False},
    ],
    "mail": {
        "default_expiry_days": 30,
        "purge_after_days": 30,
        "inbox_limit": 100,
        "claim_all_max": 50,
    },
    # Promo codes, made in the panel and redeemed in the game, delivered by the
    # Royal Mail. A code gives only what play gives too -- App Review 3.1.1
    # forbids a code that unlocks what is sold -- so no cosmetics, and a small
    # handful of diamonds at most. Once per lord, once per phone; wrong guesses
    # are throttled so codes cannot be found by trying.
    "promo": {
        "max_diamonds": 100,
        "failures_per_hour": 8,
        "expiry_days": 14,
    },
    # A lord brings a friend: the friend enters the lord's code within their
    # first week, and when they reach the level both are paid, by letter. The
    # caps and the account age keep it from being farmed with fresh accounts;
    # a friend on the lord's own phone is refused.
    "referral": {
        "reward_level": 10,
        "invitee_diamonds": 100,
        "inviter_diamonds": 100,
        "claim_days": 7,
        "inviter_min_hours": 72,
        "links_per_day": 5,
        "rewards_total": 20,
    },
    "limits": {
        "max_diamonds": 100000,
        "max_gold": 1000000000,
        "max_xp": 2000000,
        "max_wages_energy": 10000,
        "max_favour": 100000,
        "max_items": 10,
        "max_tokens": 50,
        "max_boost_hours": 72,
    },
}, indent=2) + "\n")

# --- cosmetics -------------------------------------------------------------------
#
# Portrait frames, titles, name colours and crests: how a lord looks to everyone
# else, never how they fight. The four crests the game has always drawn on rival
# cards are owned by everyone; the rest arrive with the systems that grant them.
# What a cosmetic costs in the Splendour shop, by kind. Frames and crests are
# the ones others see most; a colour is a single line of type.
SHOP_DIAMONDS = {"frame": 250, "crest": 150, "name_color": 120}
# What a duplicate pays: a cosmetic granted to someone who already owns it is
# never worth nothing.
DUPE_DIAMONDS = 25


def cos(id, kind, name, source, price=0, **extra):
    """One cosmetic. price 0 is not for sale: it comes from `source`."""
    c = {"id": id, "kind": kind, "name": name, "dupe_diamonds": DUPE_DIAMONDS, "source_hint": source}
    if price:
        c["shop_diamonds"] = price
    c.update(extra)
    return c


COSMETICS = [
    # The four crests the game always drew on rival cards: everyone's.
    {"id": "crest_lion", "kind": "crest", "name": "Lion Rampant", "art": "icons/crest_lion",
     "dupe_diamonds": 0, "default_owned": True},
    {"id": "crest_wolf", "kind": "crest", "name": "Silver Wolf", "art": "icons/crest_wolf",
     "dupe_diamonds": 0, "default_owned": True},
    {"id": "crest_stag", "kind": "crest", "name": "Forest Stag", "art": "icons/crest_stag",
     "dupe_diamonds": 0, "default_owned": True},
    {"id": "crest_eagle", "kind": "crest", "name": "Black Eagle", "art": "icons/crest_eagle",
     "dupe_diamonds": 0, "default_owned": True},
    # crests_sheet.png's other eight, for the Splendour shop and the deals.
    cos("crest_bear", "crest", "Brown Bear", "The Splendour shop", SHOP_DIAMONDS["crest"], art="icons/crest_bear"),
    cos("crest_dragon", "crest", "Red Dragon", "The Splendour shop", SHOP_DIAMONDS["crest"], art="icons/crest_dragon"),
    cos("crest_boar", "crest", "Black Boar", "The Splendour shop", SHOP_DIAMONDS["crest"], art="icons/crest_boar"),
    cos("crest_falcon", "crest", "White Falcon", "The Splendour shop", SHOP_DIAMONDS["crest"], art="icons/crest_falcon"),
    cos("crest_tower", "crest", "Stone Tower", "The Splendour shop", SHOP_DIAMONDS["crest"], art="icons/crest_tower"),
    cos("crest_rose", "crest", "Red Rose", "The Splendour shop", SHOP_DIAMONDS["crest"], art="icons/crest_rose"),
    cos("crest_sun", "crest", "Golden Sun", "Victory Road, level 60", art="icons/crest_sun"),
    # The day-28 square's crest, cropped from calendar.png's crown square.
    cos("crest_constancy", "crest", "Crown of Constancy", "The daily rewards, day 28", art="icons/crest_constancy"),
    cos("crest_raven", "crest", "Grey Raven", "The Splendour shop", SHOP_DIAMONDS["crest"], art="icons/crest_raven"),
    # frames_cosmetic_a/b.png: a square frame for cards and a ring for the rail.
    cos("frame_oak", "frame", "Oak Wreath", "The Splendour shop", 120, art="frames/oak"),
    cos("frame_laurel", "frame", "Laurel", "The Splendour shop", SHOP_DIAMONDS["frame"], art="frames/laurel"),
    cos("frame_laurel_gilded", "frame", "Gilded Laurel", "Royal Favour V", art="frames/laurel_gilded"),
    cos("frame_founder", "frame", "Founder's Frame", "The Founder's Crate", art="frames/founder"),
    cos("frame_patron", "frame", "Patron's Frame", "Crown Patronage", art="frames/patron"),
    cos("frame_aureole", "frame", "Aureole", "Royal Favour X", art="frames/aureole"),
    # frames_cosmetic_b.png: the frames play gives (retention.json).
    cos("frame_loyal_vassal", "frame", "Loyal Vassal", "The daily rewards, day 14", art="frames/loyal_vassal"),
    cos("frame_rising_lord", "frame", "Rising Lord", "Victory Road, level 20", art="frames/rising_lord"),
    cos("frame_heir", "frame", "Heir", "The steward's guide, finished", art="frames/heir"),
    # Titles, under the name.
    cos("title_founder", "title", "The Founder", "The Founder's Crate", text="the Founder"),
    cos("title_generous", "title", "The Generous", "Royal Largesse", text="the Generous"),
    cos("title_steadfast", "title", "The Steadfast", "The daily rewards, day 7", text="the Steadfast"),
    cos("title_wayfarer", "title", "The Wayfarer", "Victory Road, level 40", text="the Wayfarer"),
    # Name colours. Each reaches 4.5:1 on the card plate and the navy page.
    cos("color_patron", "name_color", "Patron's Gold", "Crown Patronage", color="#E8C46A"),
    cos("color_emerald", "name_color", "Emerald", "The Splendour shop", SHOP_DIAMONDS["name_color"], color="#6FD28A"),
    cos("color_rose", "name_color", "Rose", "The Splendour shop", SHOP_DIAMONDS["name_color"], color="#F08A8E"),
    cos("color_azure", "name_color", "Azure", "Royal Favour III", color="#8FB8FF"),
]

# --- live ops cosmetics (Wave 4) ----------------------------------------------
#
# What the live-ops systems give (liveops.json, below): the calendar events'
# frames and their winners' titles, the Royal Charter's cosmetics, the season's
# nobility, and each achievement's fourth-tier title. They go in the catalogue
# here so the reward rules can check every grant names a cosmetic that exists.
EVENT_COSMETICS = [
    # frames_events.png rows 3-5: a festival's own frame, earned on its points.
    cos("frame_event_harvest", "frame", "Harvest Festival", "The Harvest Festival's points", art="frames/event_harvest"),
    cos("frame_event_blood_moon", "frame", "Blood Moon", "The Blood Moon's points", art="frames/event_blood_moon"),
    cos("frame_event_caravan", "frame", "Merchant Caravan", "The Merchant Caravan's points", art="frames/event_caravan"),
    cos("title_bountiful", "title", "The Bountiful", "First at a Harvest Festival", text="the Bountiful"),
    cos("title_crimson", "title", "The Crimson", "First under a Blood Moon", text="the Crimson"),
    cos("title_caravaneer", "title", "The Caravaneer", "First at a Merchant Caravan", text="the Caravaneer"),
    # The Royal Charter's royal lane (a paid lane: looks only).
    cos("color_charter", "name_color", "Charter Copper", "The Royal Charter, tier 10", color="#F0A868"),
    cos("title_chartered", "title", "The Chartered", "The Royal Charter, tier 25", text="the Chartered"),
    cos("frame_charter", "frame", "Royal Charter", "The Royal Charter, tier 50", art="frames/charter"),
]
# The season's nobility, worn through the next season (frames_noble.png; the
# titles are the ranks' own names, set in type on titles_sheet's ribbons).
NOBILITY = [
    ("emperor", "Emperor", "The season's renown, 1st"),
    ("prince", "Prince", "The season's renown, 2nd to 5th"),
    ("duke", "Duke", "The season's renown, 6th to 25th"),
    ("count", "Count", "The season's renown, top 5%"),
    ("baron", "Baron", "The season's renown, top 20%"),
    ("knight", "Knight", "The Royal Charter, tier 25"),
]
for nid, name, how in NOBILITY:
    EVENT_COSMETICS.append(cos(f"frame_noble_{nid}", "frame", name, how, art=f"frames/noble_{nid}"))
    EVENT_COSMETICS.append(cos(f"title_noble_{nid}", "title", name, how, text=name))


def ach(id, name, category, icon, tiers, title, deed="", stat="", blurb=""):
    a = {"id": id, "name": name, "category": category, "icon": icon, "tiers": tiers,
         "title": f"title_ach_{id}", "blurb": blurb}
    if deed:
        a["deed"] = deed
    if stat:
        a["stat"] = stat
    EVENT_COSMETICS.append(cos(f"title_ach_{id}", "title", "The " + title[4:] if title.startswith("the ") else title,
                               f"{name}, fourth tier", text=title))
    return a


# The deeds (achievements): 24, each in four tiers, counted from the game's own
# counters (a deed, in a lifetime) or read off the lord's state (a stat). Seven
# kinds, as deeds.png's seven medallions show them. The fourth tier of each
# gives its title. A stat is retroactive by nature; a deed counts from the day
# the counters began (Wave 0).
ACHIEVEMENTS = [
    ach("honest_labour", "Honest Labour", "work", "work", [100, 1000, 10000, 100000], "the Tireless",
        deed="collects", blurb="Work the jobs of the realm."),
    ach("spent_in_service", "Spent in Service", "work", "work", [1000, 10000, 100000, 1000000], "the Unwearied",
        deed="energy", blurb="Spend energy in honest work."),
    ach("master_of_trades", "Master of Trades", "work", "work", [1, 3, 7, 15], "the Master",
        stat="masteries", blurb="Master a job to its last milestone."),
    ach("raider", "Raider", "war", "war", [10, 100, 500, 2000], "the Reaver",
        deed="raid_wins", blurb="Win raids on your rivals."),
    ach("iron_wall", "Iron Wall", "war", "war", [10, 100, 500, 2000], "the Unbroken",
        deed="defenses_held", blurb="Hold your walls against a raid."),
    ach("paid_in_kind", "Paid in Kind", "war", "war", [5, 50, 200, 1000], "the Avenger",
        deed="revenge_wins", blurb="Win a revenge strike."),
    ach("plunderer", "Plunderer", "war", "war", [100000, 10000000, 1000000000, 100000000000], "the Plunderer",
        deed="gold_stolen", blurb="Carry off gold in your raids."),
    ach("faithful_vassal", "Faithful Vassal", "kingdom", "kingdom", [10000, 1000000, 100000000, 10000000000],
        "the Loyal", deed="donated_gold", blurb="Give gold to your kingdom."),
    ach("recruiter", "Recruiter", "kingdom", "kingdom", [1, 10, 50, 200], "the Captain",
        deed="recruits", blurb="Raise soldiers for your army."),
    ach("drill_master", "Drill Master", "kingdom", "kingdom", [5, 50, 250, 1000], "the Drillmaster",
        deed="rerolls", blurb="Reroll your soldiers' ranks."),
    ach("rising_star", "Rising Star", "crown", "crown", [10, 25, 40, 60], "the Ascendant",
        stat="level", blurb="Reach a level."),
    ach("might_of_arms", "Might of Arms", "crown", "crown", [1000, 10000, 100000, 1000000], "the Mighty",
        stat="might", blurb="Grow the might of your army."),
    ach("builder", "Builder of Estates", "crown", "crown", [5, 25, 100, 300], "the Builder",
        deed="upgrades", blurb="Build your family's upgrades."),
    ach("lord_of_the_land", "Lord of the Land", "crown", "crown", [3, 15, 60, 150], "the Landed",
        deed="holdings", blurb="Buy and raise estate holdings."),
    ach("duty_bound", "Duty Bound", "scroll", "scroll", [10, 100, 500, 2000], "the Dutiful",
        deed="daily_quests", blurb="Finish the day's quests."),
    ach("week_by_week", "Week by Week", "scroll", "scroll", [6, 60, 300, 1000], "the Diligent",
        deed="weekly_quests", blurb="Finish the week's quests."),
    ach("faithful_attendance", "Faithful Attendance", "scroll", "scroll", [7, 28, 100, 365], "the Constant",
        deed="daily_claims", blurb="Claim the day's reward."),
    ach("well_read", "Letters from the Crown", "scroll", "scroll", [5, 50, 250, 1000], "the Well-Read",
        deed="mail_claims", blurb="Open the crown's letters."),
    ach("golden_touch", "Golden Touch", "laurel", "laurel", [1, 25, 150, 600], "the Golden",
        deed="golden_hours", blurb="Light the Golden Hour."),
    ach("tollkeeper", "Tollkeeper", "laurel", "laurel", [10, 100, 500, 2000], "the Tollkeeper",
        deed="carts_opened", blurb="Open the Tax Cart."),
    ach("outfitted", "The Armourer's Friend", "chest", "chest", [5, 50, 250, 1000], "the Outfitted",
        deed="buys", blurb="Buy gear at the market."),
    ach("prosperous", "Merchant", "chest", "chest", [10000, 1000000, 100000000, 10000000000], "the Prosperous",
        deed="shop_gold", blurb="Spend gold at the market."),
    ach("trader", "Trader", "chest", "chest", [10, 100, 500, 2000], "the Trader",
        deed="sells", blurb="Sell gear you have outgrown."),
    ach("curator", "Curator", "chest", "chest", [5, 20, 40, 63], "the Curator",
        stat="collection", blurb="Give pieces to the Collection wall."),
    # Rekabet (Wave 5). Both count a deed, so both start from the day the wave
    # lands -- there is no arena history to backfill.
    ach("champion", "Champion", "war", "war", [5, 50, 250, 1000], "the Champion",
        deed="arena_wins", blurb="Win fights in the Honour Arena."),
    ach("headhunter", "Headhunter", "war", "war", [1, 10, 50, 200], "the Headhunter",
        deed="bounties_claimed", blurb="Collect prices set on other lords' heads."),
    # Sosyal (Wave 6). Both count what a lord did FOR somebody else, which is
    # the only kind of deed this wave adds: nothing here counts words said.
    ach("open_handed", "Open-Handed", "kingdom", "kingdom", [10, 50, 250, 1000], "the Generous",
        deed="gifts_given", blurb="Send friends the day's energy."),
    ach("shoulder_to_shoulder", "Shoulder to Shoulder", "kingdom", "kingdom", [10, 100, 500, 2000], "the Stalwart",
        deed="aid_given", blurb="Answer your kingdom's calls for aid."),
]
assert len(ACHIEVEMENTS) == 28
# --- rekabet cosmetics (Wave 5) -----------------------------------------------
#
# The Throne's regalia and the arena's two top-league frames. Appended HERE, not
# beside the PvP section at the foot of this file, because cosmetics.json is
# emitted a few lines below and anything added after it is a grant naming a
# cosmetic that does not exist -- which Validate refuses at LOAD time, so the
# server would not boot on the new seed at all.
PVP_COSMETICS = [
    # Krallik Boss ve Savaslari (Wave 8): the two a lord can only be GIVEN by
    # their kingdom -- the most damage done to a boss, and the most points in a
    # war. Added here with the other earned looks, above cosmetics.json's own
    # emit, because a grant naming a cosmetic that does not exist is refused at
    # LOAD time and the server would not boot on the new seed at all.
    cos("title_slayer", "title", "Slayer", "Most damage to a kingdom boss", text="the Slayer"),
    cos("title_warlord", "title", "Warlord of the Week", "Most points in a Kingdom War",
        text="the Warlord"),
    cos("frame_arena_platinum", "frame", "Platinum Lists", "Hold the Platinum league",
        art="frames/arena_platinum"),
    cos("frame_arena_sapphire", "frame", "Sapphire Lists", "Hold the Sapphire league",
        art="frames/arena_sapphire"),
    cos("frame_imperial", "frame", "Imperial", "Emperor of the Week", art="frames/imperial"),
    cos("title_crowned_emperor", "title", "Crowned Emperor", "Emperor of the Week",
        text="the Crowned"),
    cos("title_imperial_court", "title", "Imperial Court", "The Emperor's kingdom, for the reign",
        text="the Imperial"),
]
EVENT_COSMETICS.extend(PVP_COSMETICS)

COSMETICS.extend(EVENT_COSMETICS)

emit("cosmetics.json", json.dumps({
    "_comment": "Cosmetics. kind is frame | title | name_color | crest. dupe_diamonds is paid when a "
                "cosmetic is granted to someone who already owns it; shop_diamonds, when present, is its "
                "price in the Splendour shop. A name colour must reach 4.5:1 contrast on both the card "
                "plate and the navy page.",
    "items": COSMETICS,
}, indent=2) + "\n")

print("rewards.json   : 6 tokens, mail 30-day letters, reward limits")
print(f"cosmetics.json : {len(COSMETICS)} cosmetics, {sum(1 for c in COSMETICS if c.get('shop_diamonds'))} for sale")


# --- commerce: what money buys -----------------------------------------------------
#
# The owner's rule is FAIR: money buys time (diamonds, energy potions), comfort
# (the Steward, a bigger bag) and looks (cosmetics) -- never gold, never power,
# never a loot box. The server enforces it product by product
# (gameconfig.validateCommerce -> CheckReward(paid)), not just here.
#
# usd_cents is the product's price tier in US dollars, the same the world over:
# it is what Royal Favour (VIP) counts and what revenue is reported in. What a
# player actually paid, in their own currency, is on the App Store's transaction.
STORE = "com.emperors.game."


def gems(n, cents, badge=""):
    p = {"id": f"gems_{n}", "store_id": f"{STORE}gems.{n}", "kind": "consumable",
         "usd_cents": cents, "shelf": "diamonds", "title": f"{n:,} Diamonds",
         "grant": {"diamonds": n},
         # Each tier's first purchase pays double, once per account.
         "first_bonus_bp": 10000}
    if badge:
        p["badge"] = badge
    return p


PRODUCTS = [
    gems(60, 99),
    gems(330, 499),
    gems(700, 999, "most_popular"),
    gems(1500, 1999),
    gems(4000, 4999),
    gems(8500, 9999, "best_value"),
    {"id": "starter", "store_id": f"{STORE}starter.299", "kind": "consumable", "usd_cents": 299,
     "shelf": "offers", "title": "The Founder's Crate",
     "grant": {"diamonds": 300, "tokens": {"energy_potion": 3},
               "cosmetics": ["frame_founder", "title_founder"]},
     "limit": 1, "fallback_diamonds": 100,
     "offer": {"trigger": "level", "min_level": 8, "hours": 48, "slot": "starter"}},
    # The Founder's Crate's other arm (EXPERIMENTS): dearer, and more in it.
    # Only ever shown to lords its test puts in that arm, and only while the
    # test runs -- which needs the product in App Store Connect first.
    {"id": "starter_499", "store_id": f"{STORE}starter.499", "kind": "consumable", "usd_cents": 499,
     "shelf": "offers", "title": "The Founder's Crate",
     "grant": {"diamonds": 600, "tokens": {"energy_potion": 5},
               "cosmetics": ["frame_founder", "title_founder"]},
     "limit": 1, "fallback_diamonds": 100,
     "offer": {"trigger": "level", "min_level": 8, "hours": 48, "slot": "starter"}},
    {"id": "stipend", "store_id": f"{STORE}stipend.30", "kind": "consumable", "usd_cents": 499,
     "shelf": "passes", "title": "Royal Stipend",
     "grant": {"diamonds": 300},
     "stipend": {"days": 30, "daily_diamonds": 60, "renew_within_days": 5}},
    {"id": "patronage", "store_id": f"{STORE}patronage.month", "kind": "subscription", "usd_cents": 699,
     "shelf": "passes", "title": "Crown Patronage",
     "patronage": {"period_diamonds": 60, "free_refills_per_day": 1, "bag_bonus": 25,
                   "steward": True, "skip_ads": True,
                   "cosmetics": ["frame_patron", "color_patron"]}},
    {"id": "steward", "store_id": f"{STORE}comfort.steward", "kind": "non_consumable", "usd_cents": 499,
     "shelf": "comfort", "title": "The Steward", "entitlement": "steward"},
    {"id": "quartermaster", "store_id": f"{STORE}comfort.quartermaster", "kind": "non_consumable",
     "usd_cents": 499, "shelf": "comfort", "title": "The Quartermaster",
     "entitlement": "quartermaster", "bag_bonus": 50},
    {"id": "largesse", "store_id": f"{STORE}largesse", "kind": "consumable", "usd_cents": 999,
     "shelf": "kingdom", "title": "Royal Largesse",
     "grant": {"diamonds": 600, "cosmetics": ["title_generous"]}, "fallback_diamonds": 50,
     "largesse": {"member_grant": {"diamonds": 20, "tokens": {"energy_potion": 1}},
                  "per_member_per_day": 5, "min_member_hours": 24}},
    # The Royal Charter's royal lane for the season it is bought in (liveops.json
    # season.royal_product): sold on the Season Pass page, not the store's shelves.
    # Bought again in a season already unlocked, it pays the lane's diamond price.
    {"id": "season_pass", "store_id": f"{STORE}season.pass", "kind": "consumable", "usd_cents": 799,
     "shelf": "charter", "title": "Royal Charter", "grant": {}, "season_pass": True, "fallback_diamonds": 900},
    # Offers: shown once, when their moment comes, for a day.
    {"id": "offer_empty", "store_id": f"{STORE}offer.empty", "kind": "consumable", "usd_cents": 199,
     "shelf": "offers", "title": "A Second Wind",
     "grant": {"diamonds": 150, "tokens": {"energy_potion": 2}},
     "limit": 1, "offer": {"trigger": "energy_empty", "min_level": 5, "hours": 24}},
    {"id": "offer_l10", "store_id": f"{STORE}offer.l10", "kind": "consumable", "usd_cents": 499,
     "shelf": "offers", "title": "The Squire's Purse",
     "grant": {"diamonds": 650, "tokens": {"energy_potion": 3}, "cosmetics": ["frame_oak"]},
     "limit": 1, "fallback_diamonds": 60, "offer": {"trigger": "level", "min_level": 10, "hours": 24}},
    {"id": "offer_l20", "store_id": f"{STORE}offer.l20", "kind": "consumable", "usd_cents": 999,
     "shelf": "offers", "title": "The Knight's Coffer",
     "grant": {"diamonds": 1350, "tokens": {"energy_potion": 5}, "cosmetics": ["crest_dragon"]},
     "limit": 1, "fallback_diamonds": 75, "offer": {"trigger": "level", "min_level": 20, "hours": 24}},
    {"id": "offer_l30", "store_id": f"{STORE}offer.l30", "kind": "consumable", "usd_cents": 1999,
     "shelf": "offers", "title": "The Baron's Treasury",
     "grant": {"diamonds": 2800, "tokens": {"energy_potion": 8}, "cosmetics": ["frame_laurel"]},
     "limit": 1, "fallback_diamonds": 125, "offer": {"trigger": "level", "min_level": 30, "hours": 24}},
    {"id": "offer_defeat", "store_id": f"{STORE}offer.defeat", "kind": "consumable", "usd_cents": 199,
     "shelf": "offers", "title": "Walls and Watchmen",
     "grant": {"diamonds": 100, "tokens": {"shield_8h": 2}},
     "limit": 1, "offer": {"trigger": "raided", "min_level": 12, "hours": 24}},
]

# The Royal Store's daily deals, one lord at a time, fixed at the day's first
# look (service/deals.go). Four slots, as store_2.png paints them: a gift box,
# free; energy potions; a Protection Charter; a frame. Each slot keeps its
# picture and what is in it rotates: the gift's contents, how many potions or
# charters, which Splendour cosmetic. A deal is bought with diamonds, and
# diamonds are sold, so its goods keep the paid rules (FAIR): tokens and looks,
# never gold or power. The free gift is the one place wages may appear.
#
# `was` is what the same goods cost at the store's own prices -- the day's first
# refill, the store's shield -- so the plate can say what the deal saves.
_REFILL = 20   # progression.store.energy_refill_prices[0]
_SHIELD = 20   # progression.store.shield_diamonds
DEALS = {
    # A potion is a whole pool of energy, so it is the rare gift: at one day in
    # five it brought casual level 60 forward 6.5 %, past the 5 % a new source
    # may move it (scripts/pace.py prints the gift's own table); at one in ten
    # it is 3.7 %.
    "gift": [
        {"id": "gift_wages", "title": "A Day's Wages", "grant": {"gold_wages": 40}, "weight": 40},
        {"id": "gift_diamonds", "title": "A Handful of Diamonds", "grant": {"diamonds": 5}, "weight": 36},
        {"id": "gift_potion", "title": "An Energy Potion", "grant": {"tokens": {"energy_potion": 1}}, "weight": 10},
        {"id": "gift_scholar", "title": "A Scholar's Purse", "grant": {"xp_wages": 40}, "weight": 14},
    ],
    "potions": [
        {"id": "potions_1", "title": "An Energy Potion", "grant": {"tokens": {"energy_potion": 1}},
         "diamonds": 15, "was": _REFILL, "weight": 40},
        {"id": "potions_2", "title": "Two Energy Potions", "grant": {"tokens": {"energy_potion": 2}},
         "diamonds": 28, "was": 2 * _REFILL, "weight": 40},
        {"id": "potions_3", "title": "Three Energy Potions", "grant": {"tokens": {"energy_potion": 3}},
         "diamonds": 39, "was": 3 * _REFILL, "weight": 20},
    ],
    "charters": [
        {"id": "charter_1", "title": "A Protection Charter", "grant": {"tokens": {"shield_8h": 1}},
         "diamonds": 14, "was": _SHIELD, "weight": 60},
        {"id": "charter_2", "title": "Two Protection Charters", "grant": {"tokens": {"shield_8h": 2}},
         "diamonds": 26, "was": 2 * _SHIELD, "weight": 40},
    ],
    # The frame slot: a cosmetic the Splendour shop sells that the lord does
    # not own, this much off its shop price.
    "cosmetic_off_bp": 3000,
}

# Royal Favour: counted in US cents spent, lost again with a refund. The seal is
# seen by everyone; the level number is the player's own.
VIP_POINTS = [99, 499, 999, 1999, 4999, 9999, 19999, 49999, 99999, 199999]
VIP = [{"level": i + 1, "points": pts,
        # A gift to claim each day, in diamonds, and a little more room.
        "daily_diamonds": [2, 3, 4, 5, 6, 8, 10, 12, 15, 20][i],
        "bag_bonus": [0, 5, 5, 10, 10, 15, 15, 20, 25, 30][i]}
       for i, pts in enumerate(VIP_POINTS)]
for v in VIP:
    v["cosmetics"] = {3: ["color_azure"], 5: ["frame_laurel_gilded"], 10: ["frame_aureole"]}.get(v["level"], [])

# HERALD'S TIDINGS -- the rewarded advert (store.png's herald, the plan's
# "odullu reklam").
#
# An advert is MONEY: the house is paid by the advertiser for the lord's
# attention, so what it may pay is exactly what a purchase may pay --
# validate_commerce runs CheckReward(grant, paid=True) over this grant, which
# refuses gold, experience, favour, gear and timed bonuses. Diamonds are what is
# left, and diamonds are what the painting's two plates have room for.
#
# WHAT ONE IS WORTH. A rewarded advert on iOS earns the house somewhere near
# $0.015 a view, and the Royal Store sells diamonds at 60-85 to the dollar: one
# view is worth about one diamond of what we sell. Two is therefore a little
# more than the advert earns -- deliberately, because a lord who opens the store
# every day is the lord who might one day buy something -- and five a day caps
# the whole thing at ten, which is under the calendar's twelve. It is a small
# steady kindness, not a second economy.
#
# The herald is SHUT until the server is given an AdMob unit id
# (EMPERORS_ADMOB_UNIT). A WATCH plate over a placement with no advert to play
# is a button that does nothing, so the store hides the whole section.
ADS = {
    "per_day": 5,
    # Five moments in a day rather than a thirty-second grind.
    "cooldown_minutes": 5,
    # A brand-new account farming adverts is the oldest fraud there is.
    "min_level": 3,
    # How long a started watch may take to come back from Google.
    "ticket_minutes": 30,
    "grant": {"diamonds": 2},
}

emit("commerce.json", json.dumps({
    "_comment": "What money buys. FAIR: time, comfort and looks, never gold, power or a loot box. "
                "usd_cents is the price tier in US dollars (what Royal Favour counts); the player's own "
                "price is on the App Store transaction. kind is consumable | non_consumable | subscription.",
    "store_prefix": STORE,
    "products": PRODUCTS,
    "deals": DEALS,
    # A/B tests on what an offer sells. A lord is in one arm for good (a keyed
    # hash of the lord and the test, game/experiments); while a test is off,
    # its first arm is what everyone sees. The panel's Experiments page
    # compares the arms. Switch one on only when every arm's product is live in
    # App Store Connect.
    "experiments": [
        {"id": "starter_price", "active": False,
         "note": "the Founder's Crate at 2.99, or at 4.99 with more in it",
         "arms": [{"id": "control", "weight": 50, "product": "starter"},
                  {"id": "richer", "weight": 50, "product": "starter_499"}]},
    ],
    "vip": VIP,
    "ads": ADS,
    # A refund can come weeks after a purchase; money granted is never refused at
    # the moment of grant -- a reward that cannot be delivered (a cosmetic already
    # owned, a bag with no room) pays its fallback_diamonds instead.
    "refund_flag_count": 2,
    "refund_flag_days": 90,
}, indent=2) + "\n")

per_dollar = [p["grant"]["diamonds"] * 100 / p["usd_cents"] for p in PRODUCTS if p["shelf"] == "diamonds"]
print(f"commerce.json  : {len(PRODUCTS)} products; diamonds per dollar {per_dollar[0]:.1f} -> {per_dollar[-1]:.1f}; "
      f"the herald pays {ADS['grant']['diamonds']} x {ADS['per_day']} = {ADS['grant']['diamonds'] * ADS['per_day']} a day "
      f"({ADS['grant']['diamonds'] * ADS['per_day'] * 7} a week) when the realm has adverts")

# --- retention: the daily loop (Wave 3) ----------------------------------------
#
# What brings a lord back each day and each week, all of it free: the Tax Cart,
# the 28-day calendar, the week's quests, the Golden Hour, the Victory Road, the
# steward's guide through the first ten minutes, and a welcome back. Every grant
# goes through the one reward path (service.grantBundle), so the reward rules
# hold here as everywhere: rewards.limits, and tokens and cosmetics that exist.
#
# Energy and experience are what move the climb, so each source is kept small
# in them and pays mostly in gold, diamonds, gear and looks; scripts/pace.py
# prints what each one moves casual level 60 by.

# The Tax Cart (COURT > CHESTS): one arrives every four hours, three can wait,
# and each opens to one prize drawn from these published odds (in basis points,
# 10000 in all). A cart's prize is fixed by the lord and the cart's number, so
# it cannot be drawn again. Free only: a paid draw would be a loot box.
CART_ODDS = [
    {"id": "purse", "name": "Purse of Gold", "bp": 4800, "grant": {"gold_wages": 20}},
    {"id": "heavy_purse", "name": "Heavy Purse", "bp": 1500, "grant": {"gold_wages": 60}},
    {"id": "flask", "name": "Small Flask", "bp": 800, "grant": {"tokens": {"flask_small": 1}}},
    {"id": "scroll", "name": "Scholar's Scroll", "bp": 1000, "grant": {"xp_wages": 12}},
    {"id": "charm", "name": "Lucky Charm", "bp": 800,
     "grant": {"boosts": [{"bucket": "luck_bp", "bp": 2500, "hours": 1}]}},
    {"id": "diamonds_3", "name": "Three Diamonds", "bp": 500, "grant": {"diamonds": 3}},
    {"id": "gear", "name": "A Piece of Gear", "bp": 500, "grant": {"items": [{"tier": "uncommon", "count": 1}]}},
    {"id": "diamonds_10", "name": "Ten Diamonds", "bp": 100, "grant": {"diamonds": 10}},
]
CART = {"unlock_level": 2, "interval_seconds": 4 * 3600, "cap": 3, "odds": CART_ODDS}


def square(kind, grant, crown=False):
    s = {"kind": kind, "grant": grant}
    if crown:
        s["crown"] = True
    return s


def dia(n, crown=False, **more):
    return square("crown" if crown else "diamonds", dict({"diamonds": n}, **more), crown)


# The 28-day calendar, as calendar.png paints it: four weeks of seven, the
# seventh square of each a crown. 340 diamonds in all -- the old seven-square
# week's 85 a week -- weighted toward the end, because the point is the return
# trip on day 27, not the reward on day one. Days 7/14/21/28 are the crowns: a
# title, a frame, a rare piece of gear, a crest and 100 diamonds.
PURSE = [30, 45, 60, 80]     # gold wages, by week
SCROLL = [8, 10, 12, 15]     # experience wages, by week
CALENDAR_SQUARES = [
    # week 1
    dia(10), square("purse", {"gold_wages": PURSE[0]}), square("flask", {"tokens": {"flask_small": 1}}),
    square("scroll", {"xp_wages": SCROLL[0]}), square("cart", {"tokens": {"cart": 1}}), dia(20),
    dia(25, crown=True, cosmetics=["title_steadfast"]),
    # week 2
    dia(15), square("purse", {"gold_wages": PURSE[1]}), square("flask", {"tokens": {"flask_small": 1}}),
    square("scroll", {"xp_wages": SCROLL[1]}), square("cart", {"tokens": {"cart": 1}}), dia(25),
    dia(30, crown=True, cosmetics=["frame_loyal_vassal"]),
    # week 3
    square("purse", {"gold_wages": PURSE[2]}), square("flask", {"tokens": {"flask_large": 1}}),
    square("scroll", {"xp_wages": SCROLL[2]}), square("cart", {"tokens": {"cart": 2}}), dia(30),
    square("purse", {"gold_wages": PURSE[2]}),
    dia(35, crown=True, items=[{"tier": "rare", "count": 1}]),
    # week 4
    square("flask", {"tokens": {"flask_large": 1}}), square("scroll", {"xp_wages": SCROLL[3]}),
    square("cart", {"tokens": {"cart": 2}}), dia(50), square("purse", {"gold_wages": PURSE[3]}),
    square("flask", {"tokens": {"flask_large": 1}}),
    dia(100, crown=True, cosmetics=["crest_constancy"]),
]
assert len(CALENDAR_SQUARES) == 28
CALENDAR = {
    "squares": CALENDAR_SQUARES,
    # Miss one or two days and the run is broken, not lost: mend it with
    # diamonds (the price rises with the days missed) or a Royal Pardon, or
    # start anew. Miss more and the next claim starts anew by itself.
    "grace_days": 2,
    "restore_diamonds": [20, 50],
    # A pardon comes with the first square of each cycle; a lord holds two at most.
    "pardons_per_cycle": 1,
    "pardons_max": 2,
}

# The week's quests: six a week, reset at the lord's own Monday midnight. The
# two diamond ones are on every board; four more are drawn from the pool by a
# pure function of the lord and the week, and frozen at the week's first look.
# Each is worth 40 points toward three chests at 80 / 160 / 240. A task is
# offered only when the lord can do it in the first sitting: anything up to
# level 5 is (the guide gets a new lord there in ten minutes).
def wtask(id, name, short, blurb, icon, deed, target, grant, min_level=1, points=40):
    # `short` is the task as an instruction, for the tile's one-line plate.
    assert len(short) <= 24, short
    t = {"id": id, "name": name, "short": short, "blurb": blurb, "icon": icon, "deed": deed,
         "target": target, "points": points, "grant": grant}
    if min_level > 1:
        t["min_level"] = min_level
    return t


WEEKLY = {
    "fixed": [
        wtask("w_days", "Faithful Attendance", "Claim 5 daily rewards", "Claim the day's reward on five days.", "quest_scroll",
              "daily_claims", 5, {"diamonds": 15}),
        wtask("w_dailies", "Duty Done", "Finish 12 daily quests", "Finish twelve of the day's quests.", "quest_scroll",
              "daily_quests", 12, {"diamonds": 15}),
    ],
    "draw": 4,
    "eligible_level_floor": 5,
    "pool": [
        wtask("w_collects", "The Busy Week", "Collect 600 times", "Work six hundred jobs.", "quest_bolt",
              "collects", 600, {"gold_wages": 60}),
        wtask("w_hard_work", "Hands Never Idle", "Collect 1,500 times", "Work fifteen hundred jobs.", "quest_bolt",
              "collects", 1500, {"gold_wages": 120}),
        wtask("w_carts", "The Cart Returns", "Open 8 Tax Carts", "Open eight Tax Carts.", "quest_scroll",
              "carts_opened", 8, {"tokens": {"cart": 2}}, min_level=2),
        wtask("w_buys", "A Good Customer", "Buy 5 market items", "Buy five things at the market.", "quest_scroll",
              "buys", 5, {"gold_wages": 40}, min_level=2),
        wtask("w_stats", "Train the Hero", "Spend 10 stat points", "Spend ten stat points.", "quest_swords",
              "stat_spends", 10, {"gold_wages": 40}),
        wtask("w_upgrades", "The Builder", "Build 3 upgrades", "Build three family upgrades.", "quest_scroll",
              "upgrades", 3, {"gold_wages": 50}, min_level=4),
        wtask("w_rerolls", "Drill Sergeant", "Reroll soldiers 5 times", "Reroll soldiers five times.", "quest_swords",
              "rerolls", 5, {"items": [{"tier": "uncommon", "count": 1}]}, min_level=5),
        wtask("w_golden", "Golden Hours", "Light 3 Golden Hours", "Light the Golden Hour three times.", "quest_bolt",
              "golden_hours", 3, {"gold_wages": 60}, min_level=5),
        wtask("w_raids", "The Raider", "Win 10 raids", "Win ten raids.", "quest_swords",
              "raid_wins", 10, {"gold_wages": 80}, min_level=10),
        wtask("w_revenge", "Paid in Kind", "Win 2 revenge strikes", "Win two revenge strikes.", "quest_swords",
              "revenge_wins", 2, {"tokens": {"shield_8h": 1}}, min_level=10),
    ],
    "chests": [
        {"at": 80, "grant": {"gold_wages": 60, "tokens": {"flask_small": 1}}},
        {"at": 160, "grant": {"gold_wages": 80, "tokens": {"cart": 2}}},
        {"at": 240, "grant": {"diamonds": 20, "items": [{"tier": "rare", "count": 1}]}},
    ],
}

# The Golden Hour, on Collect: keep collecting -- no gap longer than `window`
# seconds -- until the run has spent `fill_pct` of your pool, and it lights for
# `duration` seconds: collects pay `bonus_bp` more gold (the timed lane, capped
# there) on up to `cover_pct` of your pool's energy. Three a day, half an hour
# apart. Gold only: it never moves the climb.
FRENZY = {"unlock_level": 5, "window_seconds": 20, "fill_pct": 40, "duration_seconds": 60,
          "bonus_bp": 10000, "cover_pct": 30, "per_day": 3, "cooldown_seconds": 1800}


def mile(level, grant, crown=False):
    m = {"level": level, "grant": grant}
    if crown:
        m["crown"] = True
    return m


# The Victory Road (Family > ROAD): fifteen milestones on the way to level 60,
# each claimed once, and claimable any time after -- a lord already past a
# milestone when the road opened claims it the same. 435 diamonds in all, the
# three crowns a frame, a title and a crest.
ROAD = {"milestones": [
    mile(3, {"diamonds": 10, "tokens": {"flask_small": 1}}),
    mile(5, {"diamonds": 15, "tokens": {"cart": 1}}),
    mile(8, {"diamonds": 20, "items": [{"tier": "uncommon", "count": 1}]}),
    mile(10, {"diamonds": 25, "tokens": {"flask_large": 1}}),
    mile(12, {"diamonds": 20, "tokens": {"flask_large": 1}}),
    mile(15, {"diamonds": 30, "items": [{"tier": "rare", "count": 1}]}),
    mile(18, {"diamonds": 25, "tokens": {"cart": 2}}),
    mile(20, {"diamonds": 30, "cosmetics": ["frame_rising_lord"]}, crown=True),
    mile(25, {"diamonds": 30, "items": [{"tier": "rare", "count": 1}]}),
    mile(30, {"diamonds": 35, "tokens": {"flask_large": 1}}),
    mile(35, {"diamonds": 30, "items": [{"tier": "epic", "count": 1}]}),
    mile(40, {"diamonds": 35, "cosmetics": ["title_wayfarer"]}, crown=True),
    mile(45, {"diamonds": 35, "tokens": {"cart": 3}}),
    mile(50, {"diamonds": 40, "items": [{"tier": "epic", "count": 1}]}),
    mile(60, {"diamonds": 55, "cosmetics": ["crest_sun"], "items": [{"tier": "legendary", "count": 1}]},
         crown=True),
]}
assert sum(m["grant"].get("diamonds", 0) for m in ROAD["milestones"]) == 435


def step(id, kind, title, text, done, tab="", target="", **more):
    s = {"id": id, "kind": kind, "title": title, "text": text, "done": done}
    if tab:
        s["tab"] = tab
    if target:
        s["target"] = target
    s.update(more)
    return s


# The steward's guide through the first ten minutes: twelve steps, each done
# by doing it -- the server counts the deed -- and SKIP always there. Finishing
# pays 20 diamonds and the Heir's frame. Where a step needs gold a new lord
# may not have (the first purchase, the first upgrade), the steward pays the
# shortfall, up to purse_max, when the step begins.
GUIDE = {
    "steps": [
        step("welcome", "tap", "WELCOME, MY LORD",
             "I am your steward. Your family's name is small and its purse is thin, but that is "
             "a thing we can mend together. Let me show you the realm.",
             "Then let us begin.", tab="collect"),
        step("first_collect", "deed", "HONEST WORK",
             "Every lord begins in the fields. Tap COLLECT to work the vineyard: it costs energy, "
             "and pays gold and experience.",
             "Well struck, my lord. The first grapes are in.",
             tab="collect", target="collect.job0", deed="collects", count=1),
        step("reach_2", "level", "A NAME TO GROW",
             "Keep working. Experience brings new levels, and each new level fills your energy "
             "at once.",
             "Level two! The market will trade with you now.",
             tab="collect", target="collect.job0", level=2),
        step("daily", "deed", "THE CROWN REMEMBERS",
             "Each day you come back, the crown sends a gift, and the gifts grow the longer you "
             "keep coming. Claim today's.",
             "Come back tomorrow, and the next day: the crown's gifts grow.",
             tab="collect", target="daily.claim", deed="daily_claims", count=1),
        step("cart", "deed", "THE TAX CART",
             "Every four hours a tax cart comes to your gate with the crown's share of the "
             "road. Open it in the Court.",
             "Three carts can wait for you. Never let a fourth be turned away.",
             tab="court", target="court.chests", deed="carts_opened", count=1, min_level=2),
        step("buy_gear", "deed", "THE MARKET",
             "A lord needs a blade. Buy something from the market: here is a little silver "
             "from the family chest if yours is short.",
             "A fine choice, my lord.",
             tab="shop", target="shop.offer", deed="buys", count=1, min_level=2, purse=True),
        step("wear_gear", "worn", "DRESSED FOR IT",
             "Gear does nothing in a chest. Open your family and put it on.",
             "Now you look the part.",
             tab="family", target="family.gear"),
        step("stats", "deed", "YOUR OWN STRENGTH",
             "Each level gives you stat points. Spend them: energy for more work, attack and "
             "defence for the fights to come.",
             "Stronger already.",
             tab="family", target="family.stats", deed="stat_spends", count=1),
        step("upgrade", "deed", "THE ESTATES",
             "At level four your estates open. Build the family's first upgrade: estates earn "
             "while you are away.",
             "It will pay for itself, my lord, and then some.",
             tab="family", target="family.estates", deed="upgrades", count=1, min_level=4, purse=True),
        step("recruit", "deed", "A SWORD AT YOUR SIDE",
             "At level five you may raise soldiers. The first one serves you for nothing: "
             "recruit them.",
             "Every army starts with one.",
             tab="army", target="army.recruit", deed="recruits", count=1, min_level=5),
        step("bandit", "bandit", "KAREL THE BANDIT",
             "A bandit has been robbing your road. Take your soldier and teach Karel a lesson.",
             "The road is safe again, and Karel's purse is yours.",
             tab="attack", target="attack.bandit"),
        step("farewell", "tap", "THE REALM AWAITS",
             "You know the realm now. From level ten you may raid your rivals; at twenty, join a "
             "kingdom. I will be here whenever you need me.",
             "Go well, my lord.", tab="collect"),
    ],
    "finish": {"diamonds": 20, "cosmetics": ["frame_heir"]},
    "purse_max": 300,
    # A real fight against a bot that is not a lord: the first of `seeds` draws
    # the new lord wins. Nobody is robbed; his purse is `grant`.
    "bandit": {"name": "Karel the Bandit", "avatar": "bandit", "level": 1, "seeds": 16,
               "attack": 6, "defense": 4, "speed": 4, "hp": 60,
               "grant": {"gold_wages": 40}},
}
assert len(GUIDE["steps"]) == 12

# Welcome back: a lord away three days or more finds a letter when they return
# (sent by an hourly job); away fourteen, a second with diamonds too. The boost
# runs for a day from the moment the letter is opened. Once in `cooldown_days`.
WINBACK = {
    "away_days": 3,
    "long_away_days": 14,
    "cooldown_days": 14,
    "grant": {"gold_wages": 120, "tokens": {"flask_large": 1, "cart": 1},
              "boosts": [{"bucket": "collect_income_bp", "bp": 5000, "hours": 24},
                         {"bucket": "xp_bp", "bp": 5000, "hours": 24}]},
    "long_grant": {"diamonds": 20},
    "title": "Welcome back, my lord",
    "body": "The realm kept your seat warm. Take these from the crown's own stores, and for a day "
            "your work pays half again as much.",
    "long_title": "The crown has missed you",
    "long_body": "Fourteen days and more! The treasurer insisted on this as well.",
}

emit("retention.json", json.dumps({
    "_comment": "The daily loop, all free. cart: the Tax Cart's clock and published odds (bp, 10000 in all). "
                "calendar: 28 squares, days 7/14/21/28 crowns. weekly: two fixed tasks and four drawn, "
                "40 points each, chests at 80/160/240. frenzy: the Golden Hour. road: the Victory Road's "
                "15 milestones. guide: the first ten minutes. winback: the welcome-back letters.",
    "cart": CART,
    "calendar": CALENDAR,
    "weekly": WEEKLY,
    "frenzy": FRENZY,
    "road": ROAD,
    "guide": GUIDE,
    "winback": WINBACK,
}, indent=2) + "\n")

_cal_diamonds = sum(s["grant"].get("diamonds", 0) for s in CALENDAR_SQUARES)
_week_diamonds = (sum(t["grant"].get("diamonds", 0) for t in WEEKLY["fixed"])
                  + sum(c["grant"].get("diamonds", 0) for c in WEEKLY["chests"]))
_cart_diamonds = sum(o["grant"].get("diamonds", 0) * o["bp"] for o in CART_ODDS) / 10000
print(f"retention.json : cart every {CART['interval_seconds'] // 3600}h (cap {CART['cap']}), "
      f"calendar {_cal_diamonds} diamonds / 28 days, weekly {_week_diamonds} diamonds, "
      f"road {sum(m['grant'].get('diamonds', 0) for m in ROAD['milestones'])} diamonds, "
      f"guide {len(GUIDE['steps'])} steps")

# What a lord who never pays earns in diamonds, read back from what was just
# written so it cannot drift from it. A deal priced near a week of this is a
# real decision; one priced far above it is only for payers.
_prog = json.loads((ROOT / "balance" / "progression.json").read_text())
_gift = DEALS["gift"]
_gift_day = sum(g["grant"].get("diamonds", 0) * g["weight"] for g in _gift) / sum(g["weight"] for g in _gift)
print(f"f2p diamonds   : {_cal_diamonds * 7 / 28:.0f}/week calendar + {_week_diamonds}/week weekly quests "
      f"+ {_cart_diamonds * 6 * 7:.1f}/week Tax Cart (6 a day, expected) + {_gift_day * 7:.1f}/week daily gift "
      f"(expected) + {_prog['levelup_diamonds']} a level + {sum(m['grant'].get('diamonds', 0) for m in ROAD['milestones'])} "
      f"on the Victory Road; the cheapest deal is {min(g['diamonds'] for g in DEALS['potions'] + DEALS['charters'])}")


# --- live ops: the realm's calendar (Wave 4) -----------------------------------
#
# Everything that runs for everyone: an hourly event rolled from a published
# table, the calendar's three-day festivals, the 28-day season with its Royal
# Charter, the weekly and season boards with the season's nobility, and the
# deeds (achievements). Timed bonuses ride the timed lanes (economy.AddTemp),
# every grant goes through the one reward path, and the Charter's royal lane is
# paid: looks, diamonds, potions and pardons only (CheckReward(paid)).

def hourly(id, name, blurb, minutes, bp, effect):
    return {"id": id, "name": name, "blurb": blurb, "icon": f"hourly/{id}", "minutes": minutes,
            "bp": bp, "effect": effect}


# The hourly event: at each hour's top the realm rolls one from this table (bp,
# 10000 in all), never the same event twice running, and it lasts its minutes.
# The roll is a keyed hash of the hour, so every server and every lord agree,
# and the panel can force or skip an hour. Honor Hour (+1 arena fight) joins
# with the arena in Wave 5, its share taken from "none".
HOURLY = {
    "table": [
        {"id": "none", "bp": 3400},
        hourly("gold_rush", "Gold Rush", "Every job pays double gold.", 15, 1300,
               {"kind": "boost", "bucket": "collect_income_bp", "bp": 10000}),
        hourly("scholars_hour", "Scholar's Hour", "Every job pays double experience.", 15, 1000,
               {"kind": "boost", "bucket": "xp_bp", "bp": 10000}),
        hourly("fortunes_favour", "Fortune's Favour", "Luck smiles on the market and the chests.", 30, 900,
               {"kind": "boost", "bucket": "luck_bp", "bp": 3000}),
        hourly("quartermasters_sale", "Quartermaster's Sale", "Energy refills cost half.", 30, 800,
               {"kind": "refill_discount", "bp": 5000}),
        hourly("fresh_wares", "Fresh Wares", "The market restocks once for nothing.", 60, 900,
               {"kind": "free_reroll", "count": 1}),
        hourly("busy_hands", "Busy Hands", "The day's quests count double.", 30, 800,
               {"kind": "quest_multiplier", "x": 2}),
        hourly("royal_courier", "Royal Courier", "A courier brings a cart writ from the crown.", 60, 500,
               {"kind": "gift", "grant": {"tokens": {"cart": 1}}}),
        # Wave 5, its share taken from "none" exactly as promised above. A gift
        # of a token, not a new effect kind: the Royal Courier's cart writ is
        # the same road, and a token can be spent after the hour has passed,
        # which a lord who was asleep for it will thank us for.
        hourly("honor_hour", "Honor Hour", "One more fight in the Honour Arena.", 60, 400,
               {"kind": "gift", "grant": {"tokens": {"arena_ticket": 1}}}),
    ],
    "no_repeat": True,
}


def etask(id, name, short, icon, deed, target, grant):
    return {"id": id, "name": name, "short": short, "icon": icon, "deed": deed, "target": target, "grant": grant}


def pts(deed, points, per=1):
    return {"deed": deed, "points": points, "per": per}


RANK_REWARDS_EVENT = [
    {"top": 1, "grant": {"diamonds": 100}},
    {"top": 3, "grant": {"diamonds": 60}},
    {"top": 10, "grant": {"diamonds": 30}},
    {"top": 50, "grant": {"diamonds": 10}},
]


def with_title(ranks, title):
    out = [dict(r, grant=dict(r["grant"])) for r in ranks]
    out[0]["grant"]["cosmetics"] = [title]
    return out


# The calendar's festivals: three days each, scheduled from the panel and frozen
# as they stand at scheduling. Each carries a realm-wide bonus, points for what
# its lords do (capped a day, so a festival is won by coming back, not by one
# sitting), five tasks, point milestones ending in its own frame, and places on
# its board paid by letter when it closes -- with anything unclaimed.
EVENT_TEMPLATES = [
    {"id": "harvest_festival", "name": "Harvest Festival", "theme": "harvest",
     "blurb": "The granaries overflow: every job pays a quarter more gold.",
     "days": 3, "effect": {"bucket": "collect_income_bp", "bp": 2500},
     "points": [pts("collects", 1), pts("golden_hours", 40), pts("carts_opened", 15), pts("daily_quests", 20)],
     "daily_cap": 600,
     "tasks": [
         etask("sheaves", "Bring in the Sheaves", "Collect 300 times", "quest_bolt", "collects", 300, {"gold_wages": 60}),
         etask("long_day", "The Long Day", "Spend 1,500 energy", "quest_bolt", "energy", 1500, {"tokens": {"flask_small": 1}}),
         etask("golden_harvest", "A Golden Harvest", "Light 2 Golden Hours", "quest_bolt", "golden_hours", 2, {"tokens": {"cart": 1}}),
         etask("market_day", "Market Day", "Buy 3 market items", "quest_scroll", "buys", 3, {"gold_wages": 40}),
         etask("feast_table", "The Feast Table", "Finish 6 daily quests", "quest_scroll", "daily_quests", 6, {"diamonds": 10}),
     ],
     "milestones": [
         {"at": 300, "grant": {"gold_wages": 60}},
         {"at": 800, "grant": {"tokens": {"cart": 2}}},
         {"at": 1400, "grant": {"tokens": {"flask_small": 1}, "diamonds": 10}},
         {"at": 1800, "grant": {"cosmetics": ["frame_event_harvest"]}},
     ],
     "ranks": with_title(RANK_REWARDS_EVENT, "title_bountiful")},
    {"id": "blood_moon", "name": "Blood Moon", "theme": "blood_moon",
     "blurb": "Blood on the moon: every raid carries half again as much renown.",
     "days": 3, "effect": {"bucket": "reputation_bp", "bp": 5000},
     "points": [pts("collects", 1, 2), pts("raids", 5), pts("raid_wins", 20), pts("revenge_wins", 40),
                pts("defenses_held", 10), pts("daily_quests", 20)],
     "daily_cap": 600,
     "tasks": [
         etask("night_raids", "Night Raids", "Win 5 raids", "quest_swords", "raid_wins", 5, {"gold_wages": 60}),
         etask("blood_for_blood", "Blood for Blood", "Win a revenge strike", "quest_swords", "revenge_wins", 1, {"tokens": {"shield_8h": 1}}),
         etask("hold_the_walls", "Hold the Walls", "Hold 3 raids off", "quest_swords", "defenses_held", 3, {"tokens": {"flask_small": 1}}),
         etask("steel_and_oaths", "Steel and Oaths", "Collect 300 times", "quest_bolt", "collects", 300, {"tokens": {"cart": 1}}),
         etask("oathsworn", "Oathsworn", "Finish 6 daily quests", "quest_scroll", "daily_quests", 6, {"diamonds": 10}),
     ],
     "milestones": [
         {"at": 300, "grant": {"gold_wages": 60}},
         {"at": 800, "grant": {"tokens": {"shield_8h": 1}}},
         {"at": 1400, "grant": {"tokens": {"flask_small": 1}, "diamonds": 10}},
         {"at": 1800, "grant": {"cosmetics": ["frame_event_blood_moon"]}},
     ],
     "ranks": with_title(RANK_REWARDS_EVENT, "title_crimson")},
    {"id": "merchant_caravan", "name": "Merchant Caravan", "theme": "caravan",
     "blurb": "A caravan fills the market: everything there costs a tenth less.",
     "days": 3, "effect": {"bucket": "shop_discount_bp", "bp": 1000},
     "points": [pts("collects", 1, 2), pts("buys", 20), pts("sells", 5), pts("carts_opened", 15),
                pts("daily_quests", 20)],
     "daily_cap": 600,
     "tasks": [
         etask("browse", "Browse the Stalls", "Buy 5 market items", "quest_scroll", "buys", 5, {"gold_wages": 40}),
         etask("clear_armoury", "Clear the Armoury", "Sell 10 pieces", "quest_scroll", "sells", 10, {"gold_wages": 40}),
         etask("tolls", "Tolls on the Road", "Open 4 Tax Carts", "quest_scroll", "carts_opened", 4, {"tokens": {"flask_small": 1}}),
         etask("haggler", "The Haggler", "Buy 10 market items", "quest_scroll", "buys", 10, {"tokens": {"cart": 1}}),
         etask("trade_winds", "Trade Winds", "Finish 6 daily quests", "quest_scroll", "daily_quests", 6, {"diamonds": 10}),
     ],
     "milestones": [
         {"at": 300, "grant": {"gold_wages": 60}},
         {"at": 800, "grant": {"tokens": {"cart": 2}}},
         {"at": 1400, "grant": {"tokens": {"flask_small": 1}, "diamonds": 10}},
         {"at": 1800, "grant": {"cosmetics": ["frame_event_caravan"]}},
     ],
     "ranks": with_title(RANK_REWARDS_EVENT, "title_caravaneer")},
]
EVENTS = {"templates": EVENT_TEMPLATES, "announce_hours": 72, "top_shown": 50}


# The season: 28 days from a Monday, the Royal Charter's 50 tiers on its points.
# Points come from what a lord does each day, capped a day; a free lane for
# everyone and a royal lane for a lord who unlocks it (900 diamonds, or the
# season_pass product). The royal lane is paid, so it holds no gold, gear,
# experience or flask (FAIR: time, comfort, looks).
SEASON_TIERS = 50


def free_tier(t):
    if t % 10 == 0:
        return {"diamonds": 20 if t < 50 else 40, **({"items": [{"tier": "epic", "count": 1}]} if t == 50 else {})}
    if t % 5 == 0:
        return {"diamonds": 10}
    if t in (8, 18, 28, 38, 48):
        return {"tokens": {"flask_small": 1}}
    if t in (3, 13, 23, 33, 43):
        return {"tokens": {"cart": 1}}
    if t in (15, 35):
        return {"items": [{"tier": "rare", "count": 1}]}
    band = (t - 1) // 10  # 0..4
    return {"gold_wages": [20, 30, 40, 50, 60][band]}


def royal_tier(t):
    if t == 10:
        return {"cosmetics": ["color_charter"], "diamonds": 20}
    if t == 25:
        return {"cosmetics": ["title_chartered"], "diamonds": 30}
    if t == 50:
        return {"cosmetics": ["frame_charter"], "diamonds": 60}
    if t in (7, 17, 27, 37, 47):
        return {"tokens": {"energy_potion": 1}}
    if t in (12, 32):
        return {"tokens": {"pardon": 1}}
    if t in (20, 40):
        return {"tokens": {"shield_8h": 1}, "diamonds": 20}
    return {"diamonds": 10 if t % 2 else 15}


SEASON = {
    # Season 1 began on this Monday (UTC); each runs `days`.
    "epoch": "2026-09-14",
    "days": 28,
    "tiers": SEASON_TIERS,
    "points_per_tier": 120,
    "daily_cap": 800,
    "sources": [pts("daily_claims", 60), pts("daily_quests", 25), pts("weekly_quests", 40),
                pts("energy", 1, 5), pts("raid_wins", 15), pts("carts_opened", 15), pts("golden_hours", 30),
                pts("buys", 5)],
    "royal_diamonds": 900,
    "royal_product": "season_pass",
    "knight_tier": 25,
    "free": [free_tier(t) for t in range(1, SEASON_TIERS + 1)],
    "royal": [royal_tier(t) for t in range(1, SEASON_TIERS + 1)],
}

# The boards: the week's (the UTC week, everyone's same Monday) and the season's
# (its renown, its raids, its experience and the Might it saw gained), rebuilt
# with the rankings, paid by letter when the period closes. The season's
# renown (its Charter points) also crowns its nobility, worn through the next
# season: Emperor, Prince, Duke by place, Count and Baron by share, and Knight
# for anyone whose Charter reached tier 25.
def board_rewards(scale):
    return [{"top": 1, "grant": {"diamonds": 50 * scale}}, {"top": 3, "grant": {"diamonds": 30 * scale}},
            {"top": 10, "grant": {"diamonds": 15 * scale}}, {"top": 50, "grant": {"diamonds": 5 * scale}}]


RANKS = {
    "weekly": [
        {"id": "week_raids", "name": "Raids this week", "deed": "raid_wins", "rewards": board_rewards(1)},
        {"id": "week_xp", "name": "Experience this week", "deed": "xp", "rewards": board_rewards(1)},
        {"id": "week_arena", "name": "Arena wins this week", "deed": "arena_wins",
         "rewards": board_rewards(1)},
    ],
    "season": [
        {"id": "season_renown", "name": "Renown this season", "deed": "renown", "rewards": board_rewards(3)},
        {"id": "season_raids", "name": "Raids this season", "deed": "raid_wins", "rewards": board_rewards(2)},
        {"id": "season_xp", "name": "Experience this season", "deed": "xp", "rewards": board_rewards(2)},
        # Might gained since the lord's first deed of the season (the army's
        # cached Might, as the Might board ranks it).
        {"id": "season_might", "name": "Might gained this season", "deed": "might_gain", "rewards": board_rewards(2)},
        # The peak rating reached in the Honour Arena, not the wins: the ladder
        # is the thing the arena measures, and wins alone would pay whoever
        # spent the most tickets.
        {"id": "season_arena", "name": "The Honour Arena", "deed": "arena_rating",
         "rewards": board_rewards(3)},
    ],
    "nobility": [
        {"id": "emperor", "top": 1},
        {"id": "prince", "top": 5},
        {"id": "duke", "top": 25},
        {"id": "count", "top_pct": 5},
        {"id": "baron", "top_pct": 20},
        {"id": "knight", "charter_tier": 25},
    ],
}

# Each deed's four tiers pay these; the fourth also its title.
ACHIEVEMENT_TIERS = [{"diamonds": 5}, {"diamonds": 10}, {"diamonds": 20}, {"diamonds": 40}]

emit("liveops.json", json.dumps({
    "_comment": "Live ops. hourly: the table rolled each hour (bp, 10000 in all), never twice running. events: the "
                "calendar's festival templates, frozen when scheduled. season: the 28-day season and its Royal Charter "
                "(50 tiers, free and royal lanes; the royal lane is paid: looks, diamonds, potions, pardons). ranks: the "
                "weekly and season boards and the season's nobility. achievements: 24 deeds in four tiers.",
    "hourly": HOURLY,
    "events": EVENTS,
    "season": SEASON,
    "ranks": RANKS,
    "achievements": ACHIEVEMENTS,
    "achievement_tiers": ACHIEVEMENT_TIERS,
}, indent=2) + "\n")

_free_d = sum(g.get("diamonds", 0) for g in SEASON["free"])
_royal_d = sum(g.get("diamonds", 0) for g in SEASON["royal"])
_ach_d = sum(t["diamonds"] for t in ACHIEVEMENT_TIERS) * len(ACHIEVEMENTS)
print(f"liveops.json   : {len(HOURLY['table']) - 1} hourly events, {len(EVENT_TEMPLATES)} festivals, a {SEASON['days']}-day "
      f"season ({_free_d} free / {_royal_d} royal diamonds over {SEASON_TIERS} tiers; royal costs {SEASON['royal_diamonds']}), "
      f"{len(ACHIEVEMENTS)} deeds x 4 ({_ach_d} diamonds in all)")
# What the live ops add to a lord who never pays, beside the table above: the
# Charter's free lane a season, a festival's tasks and milestones a fortnight
# (the panel's planned cadence; its places pay only the board's top), and the
# deeds once in a lifetime.
_fest_d = sum(sum(x["grant"].get("diamonds", 0) for x in t["tasks"] + t["milestones"])
              for t in EVENT_TEMPLATES) / len(EVENT_TEMPLATES)
print(f"f2p live ops   : {_free_d * 7 / SEASON['days']:.1f}/week the Charter's free lane + {_fest_d * 7 / 14:.1f}/week "
      f"festivals (one a fortnight) + {_ach_d} once on the deeds; the royal lane returns {_royal_d} of its "
      f"{SEASON['royal_diamonds']} with its looks")


# --- rekabet: the arena, the bounty board and the Throne (Wave 5) -------------
#
# The Attack tab's other three sub-tabs. RAID is Wave 0's; CAMPAIGN opens in
# Wave 7 and has no data here at all, because a section with no rows would
# validate as a feature that pays nothing.
#
# Unlock levels are NOT here: they are progression.sections rows (arena 12,
# bounty 15) read through Bundle.SectionLevel, and this document only names its
# gate. A second copy of the number is exactly how tiers.json's stat_mult came
# to disagree with the curve the game ran on. Boards are not here either: every
# board in the game lives in liveops.ranks, and a parallel list would give
# service.timedBoards a second source.

ARENA_LEAGUES = [
    ("bronze", "Bronze", 0, 0, ""),
    ("silver", "Silver", 1150, 0, ""),
    ("gold", "Gold", 1300, 0, ""),
    ("platinum", "Platinum", 1450, 0, "frame_arena_platinum"),
    ("sapphire", "Sapphire", 1600, 0, "frame_arena_sapphire"),
    # The last league is a PLACE as well as a rating: >= 1800 AND the top 50.
    # Written as "or" it would be everyone above 1800, which at a season's end
    # is most of the ladder.
    ("imperial", "Imperial", 1800, 50, "frame_imperial"),
]

ARENA = {
    "section": "arena",
    # Five fights a day, and nothing may buy a sixth: a ladder whose rungs are
    # for sale measures a wallet. Honour Hour's token is the one way past, and
    # it is never paid_ok.
    "tickets_per_day": 5,
    "refreshes_per_day": 3,
    "opponents_shown": 3,
    "start_rating": 1000,
    "floor_rating": 800,
    "max_rating": 5000,
    "k_factor": 32,
    # The DEFENDER moves half as far: a lord fought while asleep did not choose
    # the fight. The price is a ladder that inflates, and reset_bp pays it.
    "defender_k_bp": 5000,
    "band_rating": 150,
    "band_widen": 100,
    "band_steps": 3,
    "repeat_block": 3,
    "reset_bp": 5000,
    "leagues": [
        dict({"id": i, "name": n, "at_rating": r, "emblem": f"arena/league_{i}"},
             **({"top_n": t} if t else {}), **({"cosmetic": c} if c else {}))
        for i, n, r, t, c in ARENA_LEAGUES
    ],
    # Gold, never experience and never energy. The arena sits outside
    # scripts/pace.py's budget BECAUSE validate_pvp.go refuses a grant that
    # would put it back inside -- a comment would not have held.
    "first_win": {"gold_wages": 45},
    "win_grant": {"gold_wages": 8},
    "loss_grant": {"gold_wages": 3},
    # Four rungs, which is what arena.png paints: wood, iron, silver and gold.
    # Paid once a SEASON (the mask is cleared by the half reset), so a climb is
    # worth making again.
    "milestones": [
        {"rating": 1150, "grant": {"diamonds": 10}},
        {"rating": 1300, "grant": {"diamonds": 20, "tokens": {"cart": 1}}},
        {"rating": 1450, "grant": {"diamonds": 30, "tokens": {"pardon": 1}}},
        {"rating": 1600, "grant": {"diamonds": 50, "items": [{"tier": "rare", "count": 1}]}},
    ],
    # The hired champion, offered when the band holds nobody. Not a seeded bot
    # row: a bot would need a rating of its own and bots are excluded from every
    # board in the game. Built from the asker's own army, as the steward's
    # bandit is, and it neither takes nor gives a rating to anyone else.
    "bot": {"name": "A Hired Champion", "avatar": "knight", "might_bp": 9500, "rating_bp": 5000},
}

# The board's three plates, which is what bounties.png paints. The client never
# types an amount: it names a plate and the server prices it.
BOUNTY_PLATES = [1000, 5000, 20000]
BOUNTY_FEE_BP = 2000
BOUNTY = {
    "section": "bounty",
    "min_amount": BOUNTY_PLATES[0],
    "plates": [{"id": f"plate_{a}", "amount": a} for a in BOUNTY_PLATES],
    # Burned, and never re-minted. A bounty with no fee is a pipe that moves
    # gold between two accounts for nothing; the burn is the only thing that
    # makes this a sink rather than a pipe.
    "fee_bp": BOUNTY_FEE_BP,
    "hours": 48,
    # One claim draws at most three raid caps. The escrow stays on the board
    # until it is empty or the two days are up, so a large bounty is a week's
    # hunt rather than one lucky morning.
    "claim_cap_multiple": 3,
    "places_per_day": 3,
    "open_per_target": 3,
    # Never punching down, and never on somebody who cannot answer.
    "max_levels_above": 5,
    "min_target_might_bp": 7000,
    "claims_per_target": 4,
    "cooldown_minutes": 120,
    "pair_claims_per_week": 2,
    "min_account_hours": 72,
    # A shield is a shield. The forty-eight hours outlast any shield sold, and
    # the hunted lord is told a price is on their head, so hiding costs the
    # hunter a wait and never the bounty.
    "ignores_shield": False,
}

THRONE = {
    # The first Monday a reign is settled for: the week Wave 5 ships. A week
    # that began before the Throne existed was not played for.
    "epoch": "2026-09-21",
    "min_members": 3,
    "reign_days": 7,
    # Renown GAINED in the week. Kingdom renown as it stands is cumulative and
    # decays 2% a day, so "most on Monday" would crown the same kingdom every
    # Monday and the feature would be over after one.
    "measure": "week_gain",
    # The whole realm feels it, like an hourly event: the Throne is realm news,
    # which is what makes a lord with no kingdom care who sits on it.
    "decree_scope": "realm",
    "decrees_per_reign": 1,
    # The three names throne.png paints on its cards, word for word.
    "decrees": [
        {"id": "hour_of_plenty", "name": "Hour of Plenty",
         "blurb": "By imperial decree, every job pays half again as much gold.",
         "icon": "throne/decree_hour_of_plenty", "bucket": "collect_income_bp", "bp": 5000, "minutes": 60},
        {"id": "hour_of_learning", "name": "Hour of Learning",
         "blurb": "By imperial decree, every job teaches half again as much.",
         "icon": "throne/decree_hour_of_learning", "bucket": "xp_bp", "bp": 5000, "minutes": 60},
        {"id": "hour_of_fortune", "name": "Hour of Fortune",
         "blurb": "By imperial decree, fortune smiles on the realm.",
         "icon": "throne/decree_hour_of_fortune", "bucket": "luck_bp", "bp": 3000, "minutes": 60},
    ],
    "emperor_frame": "frame_imperial",
    "emperor_title": "title_crowned_emperor",
    "court_title": "title_imperial_court",
    # Sent as a letter's attachment, so the one reward path checks it and a full
    # armory never half-pays a crowning.
    "emperor_grant": {"diamonds": 150, "gold_wages": 120},
    "court_grant": {"diamonds": 30, "gold_wages": 40},
    "past_reigns_shown": 4,
}

emit("pvp.json", json.dumps({
    "_comment": "Rekabet. arena: the Honour Arena's integer Elo ladder (K=32, the defender at half K), "
                "its leagues, its five daily fights that nothing may buy, and its season half reset. "
                "bounty: what a price on a head costs (the fee is BURNED), how long it stands, and "
                "every leash on claiming one. throne: Emperor of the Week -- the kingdom with the most "
                "renown GAINED in the UTC week, at least min_members strong, crowns its king for a "
                "reign, once in which he may declare one decree the whole realm feels. Unlock levels "
                "are progression.sections' (arena 12, bounty 15), never repeated here.",
    "arena": ARENA,
    "bounty": BOUNTY,
    "throne": THRONE,
}, indent=2) + "\n")

_ms_d = sum(m["grant"].get("diamonds", 0) for m in ARENA["milestones"])
print(f"pvp.json       : an arena of {len(ARENA['leagues'])} leagues "
      f"({ARENA['tickets_per_day']} fights a day, K {ARENA['k_factor']}, the defender at "
      f"{ARENA['defender_k_bp'] / 100:.0f}%), a board of {len(BOUNTY['plates'])} plates at "
      f"{BOUNTY['fee_bp'] / 100:.0f}% burned over {BOUNTY['hours']}h, and a throne crowned each Monday "
      f"with {len(THRONE['decrees'])} decrees of {THRONE['decrees'][0]['minutes']} minutes")
# What Rekabet adds to a lord who never pays. The arena's milestones are once a
# season and only to a lord who actually climbs; the board and the throne pay
# gold, which levels nobody and is measured nowhere else here either.
print(f"f2p rekabet    : {_ms_d * 7 / SEASON['days']:.1f}/week the arena's four rungs "
      f"({_ms_d} a season, to a lord who reaches {ARENA['milestones'][-1]['rating']}), "
      f"{THRONE['court_grant'].get('diamonds', 0)}/week to each lord of the crowned kingdom; "
      f"the bounty board pays gold only and burns {BOUNTY['fee_bp'] / 100:.0f}% of every purse set on a head")

# --- sosyal (Wave 6) -----------------------------------------------------------
#
# The hall, the friends' gift, the spyglass, the kingdom's aid and its shared
# goal. Two gates are levels (progression.sections: friends 3), the rest are a
# KINGDOM -- a lord with no kingdom has no hall and no aid, which is not a level
# and is therefore not a section row.
#
# Nothing here may be bought, and nothing here pays experience: a hall that sold
# energy would be the wallet's third door, and a kingdom that levelled its
# members would make choosing a big kingdom the game. Gold, energy and looks
# only, and validate_social.go refuses the rest.

CHAT = {
    "max_chars": 240,
    # What a lord sees on arriving: enough to read the room, not a history.
    "history": 60,
    "retention_days": 30,
    # A hall is a room, not a broadcast. Five ready, one back every three
    # seconds, and thirty in five minutes whatever the bucket says.
    "burst": 5,
    "refill_seconds": 3,
    "window_minutes": 5,
    "window_max": 30,
    # A masked word costs nothing; a blocked one is a strike. Three strikes in
    # a day and the hall is shut for an hour -- the mute is time, never a fine,
    # because a fine would price bad words.
    "strikes_to_mute": 3,
    "strike_window_hours": 24,
    "mute_minutes": 60,
    # Three lords reporting the same line hides it from everyone, before any
    # admin wakes up. The queue then decides whether it stays hidden.
    "reports_to_hide": 3,
    "report_cooldown_minutes": 5,
    "blocked_max": 100,
    # The version a lord agreed to. Raise it and every lord is asked again,
    # which is what App Review 1.2 wants of a hall that has changed its rules.
    "rules_version": 1,
    "rules_title": "Rules of the Hall",
    "rules": [
        "Speak as you would in your own hall.",
        "No abuse, no hate, no threats, and nothing of a private life -- yours or another's.",
        "No trade of accounts, gold or anything outside the realm.",
        "A line reported by three lords is hidden until the crown has read it.",
        "The crown may silence a tongue for an hour, a day, or for good.",
        "Block a lord and you will not hear from them again.",
    ],
    "support_email": "accounts@miavstudios.co.uk",
}

FRIENDS = {
    "section": "friends",
    "max_friends": 50,
    "requests_per_day": 20,
    "pending_max": 30,
    # A day old, both the account and the friendship: a farm of fresh accounts
    # gifting each other is the whole reason this rule exists.
    "min_account_hours": 24,
    "min_friend_hours": 24,
    # One gift a day to each friend, and three taken a day. A gift is a FLASK
    # (rewards.tokens), which is how energy has always entered this game
    # outside the pool and the day's refills -- so a friend's gift is a share
    # of the taker's own pool and not a flat number that would be worth a
    # morning to a new lord and a shrug to an old one.
    #
    # Three a day is what scripts/pace.py leaves room for: three draughts of
    # two parts in a hundred is six parts of a pool a day, which with the aid
    # below moves casual level 60 by 1.8% against a budget of 3%.
    "gifts_received_per_day": 3,
    "gift_token": "flask_friend",
}

SPY = {
    # A look at a rival's army, for gold, for an hour. Gold is the sink; the
    # rival is told they were scouted, which is what keeps it a move in a game
    # rather than a camera.
    "gold_per_level": 60,
    "minutes": 60,
    "per_day": 10,
}

AID = {
    # A kingdom's own help: five calls answered a day, five stacks held, each
    # +1% gold and experience for six hours. It is a TIMED lane bonus
    # (economy.AddTemp), so its ceiling is the timed lane's and not a new one
    # -- and five stacks of six hours is what scripts/pace.py leaves room for
    # beside the gift.
    "per_day": 5,
    "max_stacks": 5,
    "stack_bp": 100,
    "hours": 6,
    # What answering is worth to the one who answers: kingdom favour, which
    # buys nothing but the kingdom's own shelf.
    "favour_per_aid": 3,
    "ask_cooldown_minutes": 60,
}

GOAL = {
    # One shared goal a day for a kingdom, claimed within two days. The target
    # scales with the kingdom so a hall of thirty is not a hall of three with
    # the same bar, and a lord who joined after it began cannot claim it.
    "kinds": [
        {"id": "energy", "name": "Hands to the Work", "icon": "help/goal_energy",
         "blurb": "Spend energy in honest work, together.", "per_member": 400},
        {"id": "victories", "name": "Swords of the Realm", "icon": "help/goal_victories",
         "blurb": "Win raids and arena fights, together.", "per_member": 6},
        # The road and the beast (Waves 7 and 8). Twelve miles is a little over
        # an hour's play for one lord; three blows is half of what a member has,
        # and a beast that falls takes about seven tenths of the kingdom's
        # blows with it, so a kingdom that kills one has met this on the way.
        {"id": "campaign", "name": "The Road South", "icon": "help/goal_campaign",
         "blurb": "Walk the campaign's miles, together.", "per_member": 12},
        {"id": "boss", "name": "The Beast at the Gate", "icon": "help/goal_boss",
         "blurb": "Strike the kingdom's beast, together.", "per_member": 3},
    ],
    "hours": 24,
    "claim_hours": 48,
    "min_members": 3,
    # A quarter of an equal share: a kingdom cannot be carried by one lord and
    # claimed by thirty.
    "min_share_of_equal_bp": 2500,
    "tiers": [
        {"at_bp": 4000, "grant": {"gold_wages": 25}},
        {"at_bp": 7000, "grant": {"gold_wages": 45, "tokens": {"cart": 1}}},
        {"at_bp": 10000, "grant": {"gold_wages": 70, "diamonds": 10}},
    ],
}

emit("social.json", json.dumps({
    "_comment": "Sosyal. chat: the kingdom's hall -- what a line may be, how fast it may be said, "
                "what a blocked word costs, what three reports do, and the rules a lord agrees to "
                "(App Review 1.2). friends: the cap, the leashes, and the one gift a day, whose "
                "energy is the only energy in this document and is measured by scripts/pace.py. "
                "spy: gold for an hour's look at a rival's army, and the rival is told. aid: the "
                "kingdom's own help, a timed lane bonus through economy.AddTemp. goal: one shared "
                "goal a day, its target scaled by the kingdom's size, three chests at 40/70/100%. "
                "The friends gate is progression.sections' (3); the hall's gate is a kingdom.",
    "chat": CHAT,
    "friends": FRIENDS,
    "spy": SPY,
    "aid": AID,
    "goal": GOAL,
}, indent=2) + "\n")

_pool60 = ENERGY["base_max"] + ENERGY["per_level"] * 60
_gift_day = FRIENDS["gifts_received_per_day"] * FLASK_FRIEND_PCT
print(f"social.json    : a hall of {CHAT['max_chars']} characters "
      f"({CHAT['burst']} ready, {CHAT['window_max']} in {CHAT['window_minutes']}m, "
      f"{CHAT['strikes_to_mute']} strikes -> {CHAT['mute_minutes']}m), {FRIENDS['max_friends']} friends, "
      f"a draught of {FLASK_FRIEND_PCT}% of the pool ({FRIENDS['gifts_received_per_day']} a day, "
      f"{_gift_day}% of a pool in all, {_pool60 * _gift_day // 100} energy at level 60), "
      f"aid of {AID['max_stacks']}x{AID['stack_bp'] / 100:.0f}% for {AID['hours']}h, and "
      f"{len(GOAL['kinds'])} shared goals with {len(GOAL['tiers'])} chests")
print(f"f2p sosyal     : {_pool60 * _gift_day // 100} energy a day from friends at level 60 and "
      f"{AID['max_stacks'] * AID['stack_bp'] / 100:.0f}% for {AID['hours']}h from the kingdom "
      f"(together 1.8% of casual level 60, against a budget of 3%), "
      f"{GOAL['tiers'][-1]['grant'].get('diamonds', 0)} diamonds a day from the kingdom's last chest; "
      f"the spyglass burns gold, and nothing here is for sale")


# --- fetih ve derinlik: the campaign, the hunt, the forge and the talents (Wave 7)
#
# Ten chapters of twelve stages fought against the realm's own garrisons, the
# expeditions a soldier is sent on, the forge that makes three pieces into one,
# and the talents a lord spends their levels on.
#
# THE GARRISONS ARE WRITTEN DOWN, not rolled. Each stage names its captain and
# the soldiers behind them, and the Might of that roster is computed HERE by a
# mirror of the server's own arithmetic (army.SoldierBase / UnitHP / EffectiveHP
# / Sum) and recorded in the document. validate_campaign.go recomputes it in Go
# and refuses a document whose recorded Might is not what the game would work
# out -- the rule that tiers.json's stat_mult once broke by drifting into
# fiction with nothing reading it.
#
# WHAT A STAGE PAYS IS WAGES, never a gold figure: gold_wages is "what this much
# energy earns at the best job you can do" (game/rewards.Resolve), so a stage is
# worth the same share of a day's play at level 6 and at level 60. A first clear
# pays three times the energy it cost; a repeat pays a fifth of that, which is
# 0.6 of simply collecting -- so farming the campaign is always worse than
# working, and Validate holds that line rather than hoping.

CAMPAIGN_FIRST_LEVEL = 6
CAMPAIGN_STAGES = 12
CAMPAIGN_BOSS_STAGES = (6, 12)
CAMPAIGN_STARS = {"win": 1, "two_at_hp_bp": 3000, "three_at_hp_bp": 6000}
CAMPAIGN_FIRST_MULT = 3
CAMPAIGN_REPEAT_BP = 2000
# The chapters, each its own painting (art/reference/campaign_map_NN.png), named
# for what the owner painted: a green vale, a valley of mills, a timber wood, a
# gorge, a burning waste, a frozen coast, a desert, the peaks, a drowned city,
# and the road to the capital. boss_tier is the piece a boss's FIRST clear pays.
CAMPAIGN_CHAPTERS = [
    ("vale",      "The Vale",             "Bandits on the road out of the valley.",           "common"),
    ("millwater", "The Millwaters",       "The river villages are paying a toll to somebody.", "common"),
    ("timber",    "The Timberwood",       "Deserters hold the forest road and its bridges.",  "uncommon"),
    ("ravine",    "The Ravine",           "Something older than the realm keeps this gorge.", "uncommon"),
    ("cinder",    "The Cinder Waste",     "The black country, and the forge-lords in it.",    "rare"),
    ("frost",     "The Frozen Coast",     "Raiders winter here, and they are not asleep.",    "rare"),
    ("sands",     "The Golden Sands",     "The caravan road, and whoever is taxing it now.",  "epic"),
    ("peaks",     "The Cloudbreak Peaks", "The pass is held. It has always been held.",       "epic"),
    ("drowned",   "The Drowned City",     "What the sea left, and what moved into it.",       "legendary"),
    ("road",      "The Emperor's Road",   "The last miles, and the men who want them.",       "legendary"),
]
# What a stage is tuned to: the Might the reference lord of its level brings,
# divided by this, is the garrison's. The first stage of a chapter is a walk
# (the win curve puts 1.35 at 87%), the eleventh is a fight (1.05 at ~58%), and
# a boss is the wall that says come back stronger (1.00 and 0.95 -- 52% and 45%
# for a lord who is exactly the reference). combat's own calibration test is
# where those percentages come from.
CAMPAIGN_RATIO_FIRST, CAMPAIGN_RATIO_LAST = 1.35, 1.05
CAMPAIGN_BOSS_RATIO = {6: 1.00, 12: 0.95}
# The most soldiers a garrison may stand. A lord fields ten; a garrison in a
# gorge may field fourteen, and the last chapters need it to be a wall.
CAMPAIGN_GARRISON_MAX = 14


def _isqrt(n):
    if n <= 0:
        return 0
    x, y = n, (n + 1) // 2
    while y < x:
        x, y = y, (y + n // y) // 2
    return x


def _soldier_base(type_id, tier):
    t = next(x for x in SOLDIER_TYPES if x["id"] == type_id)
    m = int(round(TIER_MULT[TIER_IDS.index(tier)] * 10000))
    return (half_up(t["attack"] * m, 10000), half_up(t["defense"] * m, 10000),
            half_up(t["hp"] * m, 10000))


def _unit_hp(base_hp, defense, level):
    raw = base_hp + defense * SOLDIER_COMBAT["hp_per_defense_bp"] // 10000
    return raw * (10000 + SOLDIER_COMBAT["hp_level_bonus_bp"] * level) // 10000


def _dr_bp(defense, level):
    if defense <= 0:
        return 0
    k = SOLDIER_COMBAT["dr_level_coef"] * level + SOLDIER_COMBAT["dr_base"]
    return min(defense * 10000 // (defense + k), SOLDIER_COMBAT["dr_cap_bp"])


def _ehp(hp, defense, level):
    return hp * 10000 // max(10000 - _dr_bp(defense, level), 1)


def _item_stat(slot, tier, ilvl):
    base = SLOT_BASE[slot]
    tb = int(round(TIER_MULT[TIER_IDS.index(tier)] * 10000))
    lb = 10000 + LEVEL_MULT_PER_ILVL_BP * ilvl

    def sc(v):
        if v == 0:
            return 0
        num = v * tb * lb * 100 * 100
        den = 10000 * 10000 * 100 * 100
        return (num + den // 2) // den
    return sc(base["attack"]), sc(base["defense"]), sc(base["speed"])


def _hero_stats_geared(level, pts_attack, pts_defense, gear_tier=None, gear_ilvl=0):
    """A lord's own numbers at a level, with a rank of gear on: attack, defence,
    hit points and SPEED.

    Speed comes from the horse and nowhere else, exactly as it does for a real
    lord (service/army.go sums it off equipped gear). It is not part of Might --
    Might is attack against effective hit points -- but it is most of what crit
    and dodge turn on, so a garrison written down without it would hand every
    player a free +26% of damage and a free 15% of dodges. That is the sharpest
    way the campaign could have been easier than its own numbers claim."""
    p = SOLDIER_PLAYER
    steps = level // p["levels_per_stat_step"] if p["levels_per_stat_step"] else 0
    base = p["base_stat"] + p["stat_step"] * steps
    attack = base + p["per_stat_point"] * pts_attack
    defense = base + p["per_stat_point"] * pts_defense
    speed = 0
    if gear_tier:
        for slot in ("weapon", "armor", "horse"):
            a, d, sp = _item_stat(slot, gear_tier, gear_ilvl or level)
            attack += a
            defense += d
            speed += sp
    raw = (p["base_hp"] + p["hp_per_level"] * level
           + defense * SOLDIER_COMBAT["hp_per_defense_bp"] // 10000)
    hp = raw * (10000 + SOLDIER_COMBAT["hp_level_bonus_bp"] * level) // 10000
    return attack, defense, hp, speed


def _army_might(units):
    """army.Sum: 2*sqrt(sum attack * sum ehp), integer square root and all."""
    return 2 * _isqrt(sum(u[0] for u in units) * sum(u[1] for u in units))


def _tier_rung(level):
    """Which rung of the ladder a lord of `level` is on, and how far up the next
    one they have climbed (0..1).

    A rung every ten levels. The FRACTION is what matters: the roster and the
    gear used to step whole rungs at 12 and 30, and the campaign's difficulty
    stepped with them -- a chapter's fifth stage was a stroll and its sixth a
    wall, for no reason a player could see.
    """
    # A rung every ten levels, and the ladder STOPS at mystic: a lord's own gear
    # does not keep climbing past it, and a rung that wrapped round -- which the
    # first version did at level 52, sending the reference back to the bottom of
    # the rung it had just climbed -- put a hole in the middle of a chapter.
    p = min(max(level - 2, 0) / 10.0, 5.0)
    rung = min(int(p), 4)
    return rung, min(p - rung, 1.0)


def _tier_for(level):
    """The rung itself, for the garrisons' tier band."""
    return TIER_IDS[_tier_rung(level)[0]]


def _reference_roster(level):
    """The soldiers a lord of `level` is likely to have: slots filled as they
    open, and the better troops arriving a couple at a time rather than the
    whole roster changing hands on one birthday."""
    slots = min(level // 4 + 1, MAX_SLOTS)
    glad = min(max((level - 30) // 2, 0), slots) if level >= 30 else 0
    merc = min(max((level - 12) // 2, 0), slots - glad) if level >= 12 else 0
    return {"gladiator": glad, "mercenary": merc, "peasant": slots - glad - merc}


def _might_at_rung(level, tier):
    pts = level - 1
    a, d, hp, _ = _hero_stats_geared(level, pts // 2, pts - pts // 2, tier, level)
    units = [(a, _ehp(hp, d, level))]
    for typ, n in _reference_roster(level).items():
        sa, sd, sh = _soldier_base(typ, tier)
        for _ in range(n):
            units.append((sa, _ehp(_unit_hp(sh, sd, level), sd, level)))
    return _army_might(units)


def _reference_might(level):
    """What a lord of `level` brings: the roster cmd/seedbots builds, with the
    gear the shop would have sold them by then, read BETWEEN two rungs of the
    ladder rather than on one -- a lord halfway through a decade has some of the
    better gear and not all of it. The yardstick every stage is cut to, and the
    only reason the campaign's difficulty is a curve rather than a guess."""
    rung, frac = _tier_rung(level)
    low = _might_at_rung(level, TIER_IDS[rung])
    high = _might_at_rung(level, TIER_IDS[min(rung + 1, len(TIER_IDS) - 1)])
    return int(round(low * (1 - frac) + high * frac))


def _garrison_might(enemy):
    """The Might of a written-down garrison, exactly as Go will read it back."""
    lvl = enemy["level"]
    units = [(enemy["attack"], _ehp(enemy["hp"], enemy["defense"], lvl))]
    for g in enemy["soldiers"]:
        sa, sd, sh = _soldier_base(g["type"], g["tier"])
        for _ in range(g["count"]):
            units.append((sa, _ehp(_unit_hp(sh, sd, lvl), sd, lvl)))
    return _army_might(units)


# The captains, by chapter: a name for the thing standing in the road.
CAMPAIGN_CAPTAINS = [
    ("Reaver", "Reaver Chief"), ("Tollman", "Toll Baron"),
    ("Deserter", "Deserter Captain"), ("Gorge Warden", "Warden of the Ravine"),
    ("Forge-thrall", "Forge-lord"), ("Ice Raider", "Raider King"),
    ("Sand Rider", "Rider of the Dunes"), ("Pass Guard", "Keeper of the Pass"),
    ("Drowned Man", "The Drowned Prince"), ("Imperial Guard", "The Emperor's Champion"),
]


def _stage_level(index):
    """The level a stage is meant for: the campaign opens at 6 and its last mile
    is the cap, walked in even steps so a chapter is about five levels."""
    total = len(CAMPAIGN_CHAPTERS) * CAMPAIGN_STAGES
    span = LEVEL_CAP - CAMPAIGN_FIRST_LEVEL
    return CAMPAIGN_FIRST_LEVEL + (index - 1) * span // (total - 1)


def _stage_energy(index):
    """6 + ceil(s/10): seven for the first mile, eighteen for the last."""
    return 6 + -(-index // 10)


def _chapter_troops(chapter_ix):
    """Who stands behind the captain, by chapter: levies on the valley road,
    hired swords in the middle country, and gladiators on the last miles."""
    if chapter_ix <= 2:
        return "peasant"
    if chapter_ix <= 6:
        return "mercenary"
    return "gladiator"


def _near_tiers(tier):
    i = TIER_IDS.index(tier)
    return [TIER_IDS[j] for j in range(max(0, i - 1), min(len(TIER_IDS) - 1, i + 1) + 1)]


def _build_garrison(level, target, boss, chapter_ix, chapter_tier):
    """The garrison whose Might lands closest to `target`.

    A garrison is the same KIND of thing as a lord -- a captain with soldiers
    behind them -- so the fight reads as a fight and not as a wall of numbers,
    and every number in it is one the game could have produced on its own. What
    the search may move: how many soldiers stand there, which of the three tiers
    around the chapter's own they are, and what the captain carries (a tier and
    a mark of gear). What it may NOT move: the troop type, which follows the
    road, and the captain's own level and stat points, which are a lord's.

    Every captain carries gear. A captain with an empty hand would have no
    SPEED, and speed is what crit and dodge turn on -- an unhorsed garrison
    would hand the player a third more damage and a free dodge in seven, so
    every stage would be markedly easier than the Might it is written to.
    """
    pts = level - 1
    typ = _chapter_troops(chapter_ix)
    best = None
    for tier in _near_tiers(chapter_tier):
        # A garrison is not a lord's barracks: it may stand more than ten. The
        # cap used to be a lord's own slot schedule, and three stages came out
        # a tenth weaker than they were written to be because of it.
        for count in range(0, CAMPAIGN_GARRISON_MAX + 1):
            for gear in _near_tiers(chapter_tier):
                for ilvl in range(max(1, level - 4), level + 5):
                    a, d, hp, sp = _hero_stats_geared(level, pts // 2, pts - pts // 2, gear, ilvl)
                    enemy = {"level": level, "attack": a, "defense": d, "hp": hp, "speed": sp,
                             "soldiers": ([{"type": typ, "tier": tier, "count": count}]
                                          if count else [])}
                    got = _garrison_might(enemy)
                    # Closest first; then the fuller garrison, then the plainer
                    # gear -- a captain standing alone in the road is the last
                    # resort, and a modest mark of gear beats a fine one.
                    key = (abs(got - target), -count, ilvl)
                    if best is None or key < best[0]:
                        enemy["gear"] = {"tier": gear, "ilvl": ilvl}
                        best = (key, enemy, got)
    _, enemy, got = best
    enemy["name"] = CAMPAIGN_CAPTAINS[chapter_ix][1 if boss else 0]
    enemy["might"] = got
    return enemy


campaign_chapters = []
_cmp_worst = 0
for ci, (cid, cname, blurb, boss_tier) in enumerate(CAMPAIGN_CHAPTERS):
    stages = []
    for st in range(1, CAMPAIGN_STAGES + 1):
        index = ci * CAMPAIGN_STAGES + st
        level = _stage_level(index)
        energy = _stage_energy(index)
        boss = st in CAMPAIGN_BOSS_STAGES
        if boss:
            ratio = CAMPAIGN_BOSS_RATIO[st]
        else:
            ratio = (CAMPAIGN_RATIO_FIRST
                     + (CAMPAIGN_RATIO_LAST - CAMPAIGN_RATIO_FIRST) * (st - 1) / (CAMPAIGN_STAGES - 1))
        target = int(round(_reference_might(level) / ratio))
        enemy = _build_garrison(level, target, boss, ci, _tier_for(level))
        _cmp_worst = max(_cmp_worst, abs(enemy["might"] - target) * 10000 // max(target, 1))
        stage = {
            "stage": st,
            "kind": "boss" if boss else "field",
            "level": level,
            "energy": energy,
            "might": enemy.pop("might"),
            "enemy": enemy,
        }
        if boss:
            # A boss pays a piece of gear the first time it falls, and nothing
            # the times after: the reason to come back is the stars.
            stage["first_clear_item_tier"] = boss_tier
        stages.append(stage)
    campaign_chapters.append({
        "id": cid,
        "name": cname,
        "blurb": blurb,
        "art": "campaign/map_%02d" % (ci + 1),
        "level": stages[0]["level"],
        "boss_item_tier": boss_tier,
        # 12, 24 and 36 of the chapter's 36 stars. What they pay grows with the
        # chapter, and every one of them is wages, a piece of gear or diamonds --
        # never a number that means something different at level 6 and level 60.
        "chests": [
            {"stars": 12, "grant": {"gold_wages": 20 + 10 * ci, "tokens": {"flask_small": 1}}},
            {"stars": 24, "grant": {"gold_wages": 40 + 20 * ci,
                                    "items": [{"tier": boss_tier, "count": 1}]}},
            {"stars": 36, "grant": {"diamonds": 10 + 2 * ci, "xp_wages": 40 + 20 * ci}},
        ],
        "stages": stages,
    })

emit("campaign.json", json.dumps({
    "_comment": "Fetih Kampanyasi. Ten chapters of twelve stages against the realm's own "
                "garrisons, from level 6 -- four levels before another lord may raid you back. "
                "Every garrison is WRITTEN DOWN (a captain and the soldiers behind them) and its "
                "Might is computed by a mirror of internal/game/army and recorded here; "
                "validate_campaign.go recomputes it in Go and refuses a document that disagrees. "
                "A stage pays WAGES (what its energy would have earned at your best job): three "
                "times the energy on the first clear, a fifth of that on a repeat -- 0.6 of simply "
                "collecting, so farming a stage is always worse than working. Stars: the win is "
                "one, half your health left is two, three fifths is three. Stage 6 and stage 12 "
                "are bosses and pay a piece of gear the first time they fall. The chests at "
                "12/24/36 stars are the chapter's own.",
    "section": "campaign",
    "stages_per_chapter": CAMPAIGN_STAGES,
    "boss_stages": list(CAMPAIGN_BOSS_STAGES),
    "stars": CAMPAIGN_STARS,
    "first_clear_wages_mult": CAMPAIGN_FIRST_MULT,
    "repeat_bp": CAMPAIGN_REPEAT_BP,
    "chapters": campaign_chapters,
}, indent=2) + "\n")

_cmp_stages = sum(len(c["stages"]) for c in campaign_chapters)
print(f"campaign.json  : {len(campaign_chapters)} chapters x {CAMPAIGN_STAGES} stages "
      f"({_cmp_stages} in all), levels {campaign_chapters[0]['level']}..{campaign_chapters[-1]['stages'][-1]['level']}, "
      f"energy {_stage_energy(1)}..{_stage_energy(_cmp_stages)}, "
      f"garrisons within {_cmp_worst / 100:.1f}% of their target Might")
print(f"  first clear  : {CAMPAIGN_FIRST_MULT}x the energy in wages, repeat "
      f"{CAMPAIGN_REPEAT_BP / 100:.0f}% of that "
      f"({CAMPAIGN_FIRST_MULT * CAMPAIGN_REPEAT_BP / 10000:.1f}x collecting, so never worth farming)")


# --- the hunt: expeditions (Wave 7) -------------------------------------------
#
# A soldier is sent out and comes back with what they found. It is the only
# income in the game that costs no energy at all -- so what it costs instead is
# the soldier: away, they do not fight, cannot be rerolled, dismissed or
# re-geared, and the Army screen says so on their card.
#
# What they bring back is WAGES (the energy yardstick again), rolled AT DISPATCH
# and frozen: the field's range is shown before the tap, and what came of it is
# already decided when the lord walks away. A recall pays nothing, because a
# reward that survives a recall is a reward you take by cancelling.

HUNT_SLOTS = [
    {"level": 8, "slots": 1},
    {"level": 20, "slots": 2},
    {"level": 40, "slots": 3},
]
HUNT_FIELDS = [
    ("meadow", "The Meadow",      1,  2,  "Close work. An afternoon in the grass."),
    ("wood",   "The King's Wood", 2,  5,  "Deeper in, where the king's deer are."),
    ("hills",  "The Iron Hills",  4, 11,  "A day's walk, and the old workings."),
    ("wilds",  "The Far Wilds",   8, 24,  "A night out. Whatever is out there is out there."),
]
# What a soldier's rank is worth on the road: a quarter of the ladder's own
# multiplier, so a mystic gladiator brings back about twice a villager rather
# than five times -- your best soldier is also your best fighter, and the choice
# has to stay a choice.
HUNT_TIER_SHARE_BP = 2500
# The roll: a fifth either side of the field's own figure, so the range on the
# card is honest and the number that comes back is not always the same.
HUNT_SPREAD_BP = 2000
# What share of a field's wages come back as EXPERIENCE. Gold is what the road
# is for; experience is what the pace budget protects.
HUNT_XP_SHARE_BP = 2500

hunt_fields = []
for fid, fname, hours, wages, blurb in HUNT_FIELDS:
    hunt_fields.append({
        "id": fid,
        "name": fname,
        "hours": hours,
        "blurb": blurb,
        "gold_wages": wages,
        # A quarter of it in experience, and no more. The road is the one income
        # that costs no energy, and three soldiers out all day would otherwise
        # move a lord's climb further than every free source in the game put
        # together (scripts/pace.py measures it, and holds it to 5%). What the
        # road is FOR is gold: the anvil in this same wave burns it.
        "xp_wages": max(1, round(wages * HUNT_XP_SHARE_BP / 10000)),
        # A piece of gear now and then, of the rank the field deserves. Rolled at
        # dispatch with everything else.
        "item_chance_bp": 150 * hours,
        "item_tier": "common" if hours <= 2 else ("uncommon" if hours == 4 else "rare"),
    })

HUNT = {
    "section": "hunt",
    "slots": HUNT_SLOTS,
    "fields": hunt_fields,
    "tier_share_bp": HUNT_TIER_SHARE_BP,
    "spread_bp": HUNT_SPREAD_BP,
    # A soldier called home early brings nothing: the reward was rolled when
    # they left, and a recall that paid it would be a reward taken by cancelling.
    "recall_pays": False,
}

emit("hunt.json", json.dumps({
    "_comment": "Seferler. A soldier sent out for 1, 2, 4 or 8 hours comes back with wages -- "
                "what that much energy earns at your best job -- scaled by their rank (a quarter "
                "of the tier ladder, so your best gladiator is worth about twice a villager), "
                "rolled AT DISPATCH inside the spread and frozen. One expedition at level 8, two "
                "at 20, three at 40. Away, a soldier does not fight and cannot be rerolled, "
                "dismissed or re-geared. A recall pays nothing.",
    **HUNT,
}, indent=2) + "\n")

_hunt_top = HUNT_FIELDS[-1][3]
_hunt_best = _hunt_top * (10000 + (int(round(TIER_MULT[5] * 10000)) - 10000) * HUNT_TIER_SHARE_BP // 10000) // 10000
print(f"hunt.json      : {len(hunt_fields)} fields ({'/'.join(str(f['hours']) + 'h' for f in hunt_fields)}), "
      f"{HUNT_SLOTS[-1]['slots']} at once by level {HUNT_SLOTS[-1]['level']}; "
      f"a night in the Far Wilds pays {_hunt_top} wages, {_hunt_best} with a mystic gladiator "
      f"({3 * _hunt_best} for three, against a level-60 day of about 360 energy)")


# --- the forge (Wave 7) -------------------------------------------------------
#
# Three pieces of the same slot and rank, and gold, make one of the rank above.
# The gold is what stops it being a machine: it is a share of what the piece
# above SELLS for, so forging and selling is always a loss, and Validate proves
# that rather than trusting it.

FORGE = {
    "section": "forge",
    "pieces": 3,
    # The fee, as a share of the next rank's shop price. At 60% the round trip
    # (three sold, or forged and sold) loses by a mile either way.
    "fee_bp_of_next_price": 6000,
    # Special cannot be forged: there is nothing above it.
    "tiers": TIER_IDS[:-1],
    # The piece that comes out: the highest mark of the three, a fresh quality
    # roll and a fresh chance at a masterwork. The odds are published because a
    # forge whose odds are hidden is a slot machine.
    "keeps_highest_ilvl": True,
    "quality": {"min_pct": QUALITY_MIN_PCT, "max_pct": QUALITY_MAX_PCT},
    "masterwork_chance_bp": 300,
}


# --- the talents (Wave 7) -----------------------------------------------------
#
# A point every three levels from ten, and one for each Legacy: twenty-seven in
# all against fifty-one ranks, so the tree is a CHOICE and never a checklist.
#
# Every rank feeds a channel the game already has (the same bucket names the
# Family's upgrades use), so a talent is folded in exactly where an upgrade is
# and nothing new can compound. The permanent lane, always: a talent is the one
# bonus a lord keeps forever, and the caps in economy.Caps are what bound it.
#
# A branch's deeper tiers open as its own points are spent, so the tree asks a
# lord to commit rather than to sprinkle.

TALENT_FIRST_LEVEL = 10
TALENT_LEVELS_PER_POINT = 3
TALENT_TIER_GATES = [0, 3, 6, 10, 14]      # points in the branch to open tier 1..5
TALENT_RESPEC_BASE_GOLD = 8000
TALENT_RESPEC_STEP_BP = 20000              # each respec costs twice the last
TALENT_RESPEC_MAX_GOLD = 200000

TALENT_BRANCHES = [
    ("war", "WAR", "What you take.", [
        ("war_edge",    "Sharpened Steel",  "soldier_atk_bp",   150, 4, "Your soldiers hit harder."),
        ("war_speed",   "Light Horse",      "soldier_spd_bp",   200, 3, "Your soldiers strike first more often."),
        ("war_spoils",  "Right of Spoils",  "steal_cap_bp",     250, 4, "A raid carries more away."),
        ("war_ransom",  "Ransom Custom",    "ransom_bp",        300, 3, "Holding off a raid pays better."),
        ("war_fury",    "The Old Fury",     "soldier_atk_bp",   250, 3, "Your soldiers hit harder still."),
    ]),
    ("defence", "DEFENCE", "What you keep.", [
        ("def_wall",    "Shield Wall",      "soldier_def_bp",   150, 4, "Your soldiers take less."),
        ("def_larder",  "Deep Larder",      "max_energy_flat",    6, 4, "Your pool holds more."),
        ("def_vigil",   "The Night Watch",  "energy_regen_bp",  150, 3, "Energy comes back faster."),
        ("def_stores",  "Long Stores",      "storehouse_minutes", 30, 3, "The storehouse keeps more of a day."),
        ("def_bastion", "Bastion",          "soldier_def_bp",   250, 3, "Your soldiers take less still."),
    ]),
    ("economy", "ECONOMY", "What you make.", [
        ("eco_granary", "Full Granaries",   "collect_income_bp", 200, 4, "Every collect pays more."),
        ("eco_ledger",  "The Ledger",       "xp_bp",             200, 4, "You learn faster."),
        ("eco_tithe",   "Tithe Rights",     "tax_income_bp",     100, 3, "Your estates earn more."),
        ("eco_market",  "Market Standing",  "shop_discount_bp",  150, 3, "The market asks less of you."),
        ("eco_fortune", "A Lucky Hand",     "luck_bp",           200, 3, "Better rolls, everywhere they are rolled."),
    ]),
]

talent_branches = []
_talent_ranks = 0
for bid, bname, bblurb, rows in TALENT_BRANCHES:
    talents = []
    for tix, (tid, tname, bucket, per_rank, ranks, blurb) in enumerate(rows):
        talents.append({
            "id": tid,
            "name": tname,
            "tier": tix + 1,
            "bucket": bucket,
            "per_rank": per_rank,
            "ranks": ranks,
            "blurb": blurb,
        })
        _talent_ranks += ranks
    talent_branches.append({"id": bid, "name": bname, "blurb": bblurb, "talents": talents})

_talent_points = len(range(TALENT_FIRST_LEVEL, LEVEL_CAP + 1, TALENT_LEVELS_PER_POINT))
_legacy_points = LEGACY["max_stacks"]

emit("talents.json", json.dumps({
    "_comment": "Yetenek agaci. A point every three levels from ten, and one for each Legacy: "
                f"{_talent_points} + {_legacy_points} = {_talent_points + _legacy_points} against "
                f"{_talent_ranks} ranks, so the tree is a choice. Every rank feeds a channel the "
                "game already has -- the same bucket names the Family's upgrades use -- and is "
                "folded in where an upgrade is, in the PERMANENT lane, under the same caps. A "
                "branch's deeper tiers open as its own points are spent (0/3/6/10/14). Respec "
                "costs gold and doubles each time, to a ceiling.",
    "section": "talents",
    "first_level": TALENT_FIRST_LEVEL,
    "levels_per_point": TALENT_LEVELS_PER_POINT,
    "point_per_legacy": 1,
    "tier_gates": TALENT_TIER_GATES,
    "respec": {
        "base_gold": TALENT_RESPEC_BASE_GOLD,
        "step_bp": TALENT_RESPEC_STEP_BP,
        "max_gold": TALENT_RESPEC_MAX_GOLD,
    },
    "branches": talent_branches,
}, indent=2) + "\n")

emit("forge.json", json.dumps({
    "_comment": "Demirci. Three pieces of the same slot and rank, and gold worth 60% of what the "
                "rank above COSTS in the shop, make one piece of that rank: the highest mark "
                "of the three, a fresh quality roll and a fresh chance at a masterwork, with the "
                "odds published. Special cannot be forged -- there is nothing above it. "
                "validate_forge.go proves the round trip always loses money rather than trusting it.",
    **FORGE,
}, indent=2) + "\n")

print(f"talents.json   : {len(talent_branches)} branches x 5 tiers, {_talent_ranks} ranks, "
      f"{_talent_points} points from levels + {_legacy_points} from Legacy "
      f"= {_talent_points + _legacy_points} of {_talent_ranks}; respec "
      f"{TALENT_RESPEC_BASE_GOLD:,}g doubling to {TALENT_RESPEC_MAX_GOLD:,}g")
print(f"forge.json     : {FORGE['pieces']} pieces + {FORGE['fee_bp_of_next_price'] / 100:.0f}% of the "
      f"next rank's price; {len(FORGE['tiers'])} rungs can be forged (special cannot)")


# --- krallik boss ve savaslari: the kingdom's boss and its wars (Wave 8) ------
#
# The two things a kingdom does TOGETHER. Both are written here and validated in
# gameconfig, and neither pays anything money could buy.

# The six that come round, one at a time, in this order. Each is a painting
# (art/reference/bosses_<id>.png) and a temper: what it hits with, and what it
# shrugs off.
#
# Both numbers are shares of an AVERAGE member's Might, not of the kingdom's
# whole strength: what the beast swings at is one lord, and a blow that scaled
# with the muster would kill the first lord to raise a sword in a great kingdom.
# The kingdom's size is in its HEALTH, where it belongs.
BOSS_ROTATION = [
    ("ashfall_wyrm",  "Ashfall Wyrm",  "A dragon out of the burning hills, and the sky goes dark.",
     5200, 2600),
    ("garrow",        "Garrow",        "The reaver who took the north road, and never gave it back.",
     5800, 2000),
    ("iron_colossus", "Iron Colossus", "A siege engine that learned to walk. It does not hurry.",
     3400, 4200),
    ("fen_witch",     "Fen Witch",     "She asks for a name. Whoever answers does not come home.",
     6000, 1800),
    ("ulgrim",        "Ulgrim",        "The mountain king's last son, and the axe that outlived him.",
     4600, 3000),
    ("black_knight",  "Black Knight",  "No banner, no face, no word. Only the road behind him.",
     5000, 2600),
]
# The cycle, and what a lord may spend on it.
BOSS_CYCLE_HOURS = 48
BOSS_HITS_PER_MEMBER = 6
# A hit is a real fight, cut short: the lord swings for this many rounds and
# whatever they did to the boss in them is their damage. A boss that could be
# fought to the death in one sitting would be a raid, not a siege.
BOSS_ROUNDS_PER_HIT = 8
# What one blow costs, in energy: the raid's own cost, so a boss hit and a raid
# are the same decision about the same pool.
BOSS_ENERGY_BASE = 12
BOSS_ENERGY_PER_LEVEL = 0.35
# The wall. HP is the kingdom's whole Might times the blows each member has
# times this share: a beast is sized against the swords that will be raised at
# it, so twenty lords do not trivialise what five could not scratch. The share
# is CALIBRATED, not guessed: server/internal/game/boss/calibration_test.go
# fights cycles of reference lords and holds the TURNOUT a kill needs to the
# design's 65-80% -- that is, a kingdom that raises about three quarters of the
# blows it has puts the beast down, and one that shrugs does not.
BOSS_HP_PER_MIGHT_BP = 3250
# And it hardens as it is beaten: each level over the first is a tenth more.
BOSS_HP_GROWTH_BP = 11000
BOSS_MAX_LEVEL = 50
# What a lord must do to be counted brave: half of an equal share of the damage.
BOSS_VALOUR_SHARE_BP = 5000
# What the first three on the damage list are paid, on top of their chests.
BOSS_TOP_DIAMONDS = [10, 6, 4]

boss_rotation = [{
    "id": bid,
    "name": name,
    "blurb": blurb,
    "art": "boss/%s" % bid,
    # Its own numbers, as shares of an AVERAGE member's Might: the beast swings
    # at one lord at a time, and its health is where the kingdom's size lives.
    "attack_bp": atk,
    "defense_bp": dfn,
} for bid, name, blurb, atk, dfn in BOSS_ROTATION]

BOSS = {
    "section": "boss",
    "cycle_hours": BOSS_CYCLE_HOURS,
    "hits_per_member": BOSS_HITS_PER_MEMBER,
    "rounds_per_hit": BOSS_ROUNDS_PER_HIT,
    "energy_base": BOSS_ENERGY_BASE,
    "energy_per_level_bp": int(round(BOSS_ENERGY_PER_LEVEL * 10000)),
    "hp_per_might_bp": BOSS_HP_PER_MIGHT_BP,
    "hp_growth_bp": BOSS_HP_GROWTH_BP,
    "max_level": BOSS_MAX_LEVEL,
    "valour_share_bp": BOSS_VALOUR_SHARE_BP,
    "top_diamonds": BOSS_TOP_DIAMONDS,
    "top_title": "title_slayer",
    "rotation": boss_rotation,
    # The three chests under the beast, and what each asks for. Wages again --
    # what that much energy would have earned at the lord's own best job -- so
    # a chest is worth the same to a lord of six and a lord of sixty, and the
    # boss's level is what makes it worth more.
    "chests": [
        {"id": "struck", "name": "The Blooded", "need": "hit",
         "grant": {"gold_wages": 20, "xp_wages": 10}},
        {"id": "valour", "name": "The Valiant", "need": "valour",
         "grant": {"gold_wages": 45, "xp_wages": 25, "tokens": {"flask_small": 1}}},
        {"id": "slain", "name": "The Slayers", "need": "kill",
         "grant": {"gold_wages": 90, "xp_wages": 50, "diamonds": 5}},
    ],
    # What a chest is worth at the boss's level: a tenth more each time, as its
    # health is.
    "chest_growth_bp": 11000,
}

emit("boss.json", json.dumps({
    "_comment": "Krallik Boss Baskini. One boss stands against a kingdom for 48 hours; every member "
                "may strike it six times, each blow costing the energy a raid costs. A blow is a real "
                "fight cut to eight rounds, and what the lord did to the beast in them is their "
                "damage -- so a stronger army digs deeper, and a lord who falls early digs less. The "
                "beast's health is the kingdom's OWN Might times the blows each member has, times a "
                "calibrated share, so twenty lords do not trivialise what five could not scratch; it "
                "hardens a tenth each time it falls. Three chests: one for striking it, one for half "
                "an equal share of the damage, one for the kingdom that put it down -- and the first "
                "three on the damage list take diamonds and the Slayer's title. Everything here is "
                "paid in WAGES, so a chest is worth the same to a lord of six and a lord of sixty.",
    **BOSS,
}, indent=2) + "\n")


# The wars. A kingdom is matched on a Friday, fights from Saturday to Monday,
# and what is at stake is points -- never a lord's gold, and never their shield.
WAR_MATCH_WEEKDAY = 4          # Monday is 0: Friday
WAR_MATCH_HOUR = 20            # 20:00 UTC
WAR_DAYS = 3                   # Saturday, Sunday, Monday
WAR_TOP_MEMBERS = 15
WAR_MAX_RATIO_BP = 15000       # a kingdom is never matched against 1.5x its own
WAR_MIN_MEMBERS = 3
WAR_ATTACKS_PER_DAY = 3
WAR_BANNERS = 3                # what a defender has to lose
WAR_ROUT_BP = 2500             # what a win over a routed lord is worth
WAR_WIN_BASE = 10
WAR_RATIO_MIN_BP, WAR_RATIO_MAX_BP = 5000, 20000
WAR_LOSS_POINTS = 2
WAR_HELD_POINTS = 3

WAR = {
    "section": "war",
    "match_weekday": WAR_MATCH_WEEKDAY,
    "match_hour": WAR_MATCH_HOUR,
    "days": WAR_DAYS,
    "top_members": WAR_TOP_MEMBERS,
    "max_ratio_bp": WAR_MAX_RATIO_BP,
    "min_members": WAR_MIN_MEMBERS,
    "attacks_per_day": WAR_ATTACKS_PER_DAY,
    "banners": WAR_BANNERS,
    "rout_bp": WAR_ROUT_BP,
    "points": {
        "win_base": WAR_WIN_BASE,
        "ratio_min_bp": WAR_RATIO_MIN_BP,
        "ratio_max_bp": WAR_RATIO_MAX_BP,
        "loss": WAR_LOSS_POINTS,
        "held": WAR_HELD_POINTS,
    },
    # What the week is worth. The winning kingdom's lords are paid by letter,
    # the kingdom itself takes reputation (which is what feeds the Throne) and
    # experience; the lords who lost are paid for turning up, because a war
    # nobody dares enter is a war nobody has.
    "won": {"grant": {"gold_wages": 120, "xp_wages": 60, "diamonds": 10},
            "reputation": 400, "kingdom_xp": 250000},
    "lost": {"grant": {"gold_wages": 40, "xp_wages": 20},
             "reputation": 100, "kingdom_xp": 80000},
    "warlord_title": "title_warlord",
}

emit("war.json", json.dumps({
    "_comment": "Krallik Savaslari. Kingdoms are matched on Friday evening by the Might of their best "
                "fifteen, never against more than 1.5x their own and never the same pair twice in a "
                "row; the war runs Saturday to Monday. NOTHING of a lord's is at stake: no gold is "
                "stolen, a shield neither stops a war attack nor breaks on one, and the only thing "
                "that moves is points. Three attacks a day; a defender has three banners, and a lord "
                "who loses all three is routed -- beating them again is worth a quarter. A win pays "
                "ten times the Might ratio (clamped to half and double, so punching up is worth it "
                "and farming down is not), a loss two, a defence held three. The winning kingdom's "
                "lords are paid by letter and the kingdom takes reputation and experience; the best "
                "lord of the week is the Warlord.",
    **WAR,
}, indent=2) + "\n")

print(f"boss.json      : {len(boss_rotation)} bosses, {BOSS_CYCLE_HOURS}h cycles, "
      f"{BOSS_HITS_PER_MEMBER} blows a member at {BOSS_ENERGY_BASE}+{BOSS_ENERGY_PER_LEVEL:.2f}/level energy; "
      f"hp = {BOSS_HP_PER_MIGHT_BP / 10000:.2f}x the kingdom's Might a blow, +{(BOSS_HP_GROWTH_BP - 10000) / 100:.0f}% a level")
print(f"war.json       : matched Friday {WAR_MATCH_HOUR}:00 on the best {WAR_TOP_MEMBERS} (<= "
      f"{WAR_MAX_RATIO_BP / 10000:.1f}x), {WAR_DAYS} days, {WAR_ATTACKS_PER_DAY} attacks a day, "
      f"{WAR_BANNERS} banners; a win pays {WAR_WIN_BASE} x the ratio "
      f"({WAR_RATIO_MIN_BP / 10000:.1f}-{WAR_RATIO_MAX_BP / 10000:.1f}), a loss {WAR_LOSS_POINTS}, "
      f"a defence held {WAR_HELD_POINTS}")
