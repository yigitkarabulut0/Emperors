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
