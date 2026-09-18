"""Builds docs/art/PAINTING_BRIEFS_2.md (and a JSON of the prompts for the page)
from the shared blocks of PAINTING_BRIEFS.md, so every prompt is complete and
copy-once."""
import json, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
src = open(f"{ROOT}/docs/art/PAINTING_BRIEFS.md").read()


def block(name):
    m = re.search(r"### " + re.escape(name) + r"[^\n]*\n\n```text\n(.*?)\n```", src, re.S)
    assert m, name
    return m.group(1)


STYLE = block("STYLE (her promptun başına)")
SHELL_KINGDOM = block("SHELL-KINGDOM (menüde KINGDOM yanık)")
SHELL_FAMILY = block("SHELL-FAMILY (menüde FAMILY yanık)")
PAGE = block("PAGE (oyunun üstüne açılan tam sayfa)")
SHEET = block("SHEET (nesne sayfası — düz lacivert zemin)")
TEXT_RULE = block("TEXT RULE")
AVOID = block("AVOID")

SCREEN_HEAD = ("Output exactly one image for {file}. Portrait 9:16, render at 1440x2560 pixels; no phone mockup.\n"
               "Adapt reference art style to this specification. References are style references, not layout to copy.")
MAP_HEAD = ("Output exactly one image for {file}. Portrait 3:4, render at 1086x1448 pixels or larger at the same shape.\n"
            "Adapt reference art style to this specification. References are style references, not layout to copy.")
BOSS_HEAD = ("Output exactly one image for {file}. Landscape 16:10, render at 1586x992 pixels or larger at the same shape.\n"
             "Adapt reference art style to this specification. References are style references, not layout to copy.")

MAP_RULE = ("MAP — A standalone illustrated campaign map in portrait 3:4, seen obliquely from above like a painted "
            "tabletop map, in the same rich painterly style and warm golden light as the attached maps, filling the "
            "whole image edge to edge with no interface, no border and no text. One continuous dirt road about as wide "
            "as a cart enters at the middle of the bottom edge, winds up the whole height of the map in gentle S-curves "
            "and leaves at the middle of the top edge. Along its whole length the road runs over open, uncluttered "
            "ground, with a clear margin of plain grass, earth or stone on both sides that is free of buildings, trees, "
            "rocks and figures, because the game places its own round stage markers on the road. There are NO markers "
            "of any kind on or beside the road: no medallions, no circles, no rings, no stars, no numbers, no flags or "
            "banners on the road, no skull crests, no treasure chests, no signposts and no people or animals on the road "
            "itself.")

ROAD_RULE = ("ROAD — A standalone painted journey map in portrait 3:4, seen from above at a gentle angle, in warm "
             "parchment-and-gold storybook tones like the attached road.png, filling the whole image edge to edge with "
             "no interface, no border and no text. One continuous dirt road enters EXACTLY at the middle of the bottom "
             "edge and leaves EXACTLY at the middle of the top edge, so that three of these maps stacked one above "
             "another make one unbroken road. The top 6% and the bottom 6% of the image fade into the same soft, pale "
             "golden morning mist, so the seams between the stacked maps disappear. The road winds in wide S-curves "
             "with a clear margin of open ground on both sides, free of buildings, trees and figures, because the game "
             "places its own milestone shields on it. There are NO markers of any kind: no shields, no medallions, no "
             "circles, no numbers, no chests, no flags on the road and no figures on the road.")


def prompt(head, file, *blocks):
    return "\n\n".join([head.format(file=file), *blocks])


def screen(file, body, shell=None):
    parts = [STYLE] + ([shell] if shell else []) + [body, TEXT_RULE, AVOID]
    return prompt(SCREEN_HEAD, file, *parts)


def page(file, body):
    return prompt(SCREEN_HEAD, file, STYLE, PAGE, body, TEXT_RULE, AVOID)


def sheet(file, body):
    return prompt(SCREEN_HEAD, file, STYLE, SHEET, body, TEXT_RULE, AVOID)


ITEMS = []


def add(**kw):
    ITEMS.append(kw)


# ============================================================================ fixes
add(id="tabs_a", group="fix", prio=1, file="tabs_sheet_a.png",
    title="Sekme sayfası A — Saldırı ve Krallık sekmeleri",
    why=("arena / bounties / campaign tablolarında başlık ve sekme şeridi farklı yükseklikte; chat / help / war / boss "
         "tablolarında krallık üstü birbirini tutmuyor. Alt sekme değişince ekran zıplamasın diye bütün sekmeler tek "
         "boyda, yanık ve sönük halleriyle tek sayfadan kesilecek."),
    attach="arena.png ve chat.png (sekmelerin görünüşü için)",
    cut="Her plaka `tabs/<ad>_on` ve `tabs/<ad>_off` olarak kesilir; Saldırı'nın 4'lü şeridi ve Krallık'ın 2 sıra 8'li şeridi bunlardan kurulur.",
    prompt=sheet("tabs_sheet_a.png",
        "BODY — Navigation tab plates, all exactly the same size, laid out in fourteen rows of two: in every row the "
        "LEFT plate is the UNLIT state — a dark slate-navy bar with small chamfered corners, a thin pale steel border and "
        "the word in ivory engraved Cinzel capitals — and the RIGHT plate is the LIT state of the same word — a glowing "
        "deep-crimson bar with a thin gold rim, a soft warm inner glow and the word in ivory engraved Cinzel capitals — "
        "exactly like the selected and unselected tabs in the attached arena.png and chat.png. Every plate is about "
        "three and a half times as wide as it is tall; the word is centred and set at the same letter size on every "
        "plate, small enough that the longest word fits with a margin. The fourteen words, one per row, top to bottom: "
        "\"RAID\", \"ARENA\", \"CAMPAIGN\", \"BOUNTIES\", \"REVENGE\", \"TARGETS\", \"REALM\", \"LORDS\", \"WORKS\", "
        "\"RANKS\", \"CHAT\", \"BOSS\", \"WAR\", \"HELP\". Even gaps between all plates; nothing else on the sheet."))

add(id="tabs_b", group="fix", prio=1, file="tabs_sheet_b.png",
    title="Sekme sayfası B — Başarımlar, sıralamalar, gardırop",
    why=("deeds.png'de sekme sırası DEEDS | VICTORY ROAD, road.png'de tam tersi; sıralamalar, görev sayfalayıcısı ve "
         "gardırop sekmelerinin de hem yanık hem sönük hali lazım."),
    attach="deeds.png ve wardrobe.png",
    cut="`tabs/<ad>_on|off`. Başarımlar/Zafer Yolu, Collect'in TODAY/THIS WEEK sayfalayıcısı, Sıralamalar ve Gardırop aynı plakaları kullanır.",
    prompt=sheet("tabs_sheet_b.png",
        "BODY — Navigation tab plates, all exactly the same size as each other, laid out in fourteen rows of two: in "
        "every row the LEFT plate is the UNLIT state — a dark slate-navy bar with small chamfered corners, a thin pale "
        "steel border and the word in ivory engraved Cinzel capitals — and the RIGHT plate is the LIT state of the same "
        "word — a glowing deep-crimson bar with a thin gold rim, a soft warm inner glow and the word in ivory engraved "
        "Cinzel capitals — exactly like the selected and unselected tabs in the attached deeds.png and wardrobe.png. "
        "Every plate is about three and a half times as wide as it is tall; the word is centred and set at the same "
        "letter size on every plate, small enough that the longest phrase fits with a margin. The fourteen words, one "
        "per row, top to bottom: \"DEEDS\", \"VICTORY ROAD\", \"TODAY\", \"THIS WEEK\", \"MIGHT\", \"LEVEL\", "
        "\"WEALTH\", \"SEASON\", \"ALL TIME\", \"FRAMES\", \"TITLES\", \"COLOURS\", \"CRESTS\", \"PORTRAITS\". Even gaps "
        "between all plates; nothing else on the sheet."))

add(id="rail_lit", group="fix", prio=1, file="rail_lit_sheet.png",
    title="Yanık menü hücreleri — 8 giriş",
    why=("8 girişli menüde SHOP ve INVENTORY'nin yanık hali hiçbir tabloda yok; diğerleri de tablodan tabloya birkaç "
         "piksel farklı. Menü court.png'den kesilir, sekiz yanık hücre bu sayfadan."),
    attach="court.png (yanık COURT hücresi örnek alınsın)",
    cut="`nav/active_<giriş>`: sekizi de aynı kutu boyunda, court.png'nin menü aralığına oturtulur.",
    prompt=sheet("rail_lit_sheet.png",
        "BODY — Eight selected navigation cells for the game's left rail, laid out in four rows of two, all exactly "
        "the same size: each cell is a square-ish glowing deep-crimson plate with a thin gold rim, a soft warm inner "
        "glow and a small gold arrowhead on the middle of its right edge, with the entry's painted icon centred in its "
        "upper part and the entry's name in ivory engraved Cinzel capitals under it — identical in size, glow, icon "
        "scale and lettering to the lit \"COURT\" cell in the attached court.png. The eight cells, left to right and "
        "top to bottom: \"FAMILY\" (a gold crown set with red jewels), \"COLLECT\" (a tied burlap sack), \"INVENTORY\" "
        "(a brown leather backpack), \"SHOP\" (a red-and-white striped market tent), \"ARMY\" (a gold Spartan-style "
        "helmet with a red crest), \"ATTACK\" (two crossed steel swords with gold hilts), \"KINGDOM\" (a small sand-stone "
        "castle tower with red pennants), \"COURT\" (a small gilded throne with a crimson velvet seat). Even gaps; nothing "
        "else on the sheet."))

add(id="nodes", group="fix", prio=1, file="campaign_nodes_sheet.png",
    title="Kampanya ve Zafer Yolu işaretleri",
    why=("Haritalardaki boyalı düğümlerin sayısı tutmuyor (aşağıya bak). Haritalar düğümsüz yeniden gelecek; "
         "düğümleri, yıldızları ve sandığı oyun bu sayfadan kesip yolun üstüne kendisi yerleştirecek."),
    attach="campaign_map_09.png ve road.png (düğümlerin mevcut görünüşü)",
    cut="`campaign/node_<durum>`, `campaign/boss_<durum>`, `campaign/star_on|off`, `campaign/chest_closed|open`, `campaign/lord`, `road/shield_<durum>`.",
    prompt=sheet("campaign_nodes_sheet.png",
        "BODY — Map markers in a grid of four columns and four rows, each centred in its own cell, all painted exactly "
        "like the stage medallions on the attached campaign maps. Row 1, a round stage medallion with a gold rim, an "
        "EMPTY dark centre and three small star-shaped sockets beneath it, in four states: LOCKED (the rim dark iron, "
        "the centre darker, a small iron padlock at the centre, the whole medallion desaturated), OPEN (bright gold rim, "
        "EMPTY dark centre), CURRENT (bright gold rim with a soft golden halo glowing around it), CLEARED (gold rim with "
        "a small green laurel sprig curving under it). Row 2, the larger boss medallion — the same round medallion with "
        "a small crimson banner behind it and a skull-under-a-crown crest on top — in the same four states LOCKED, OPEN, "
        "CURRENT, CLEARED. Row 3: a single five-pointed star LIT (polished gold, bright); the same star EMPTY (a dark "
        "star-shaped socket with a thin gold edge); a small wooden treasure chest with gold bands CLOSED; the same chest "
        "OPEN with warm golden light spilling out. Row 4: a tiny marching-lord token — an armoured figure in a crimson "
        "cloak holding a crimson banner with a golden lion, standing on a small round gold base; then a round "
        "milestone shield with a gold rim and an EMPTY numeral plate under it in three states: REACHED (gold, lit), "
        "CURRENT (gold with a bright halo), AHEAD (dim steel)."))

add(id="map01", group="fix", prio=1, file="campaign_map_01.png",
    title="Kampanya haritası 01 — The Vale (yeni, düğümsüz)",
    why="1. bölümün ayrı haritası yok (campaign.png'deki harita ekranın parçası). Diğer dokuzuyla aynı dilde, düğümsüz.",
    attach="campaign_map_02.png ve campaign_map_09.png (üslup)",
    cut="`campaign/map_01` — oyun 12 aşamayı yolun üstüne kendisi dizer.",
    prompt=prompt(MAP_HEAD, "campaign_map_01.png", STYLE, MAP_RULE,
        "The land: The Vale, where the journey begins — a green valley in early summer with a clear river and an old "
        "stone bridge, a village of thatched cottages with smoke rising from the chimneys, wheat fields and apple "
        "orchards, the edge of a deep forest, sheep in a meadow, and at the very top a small grey stone keep on a hill "
        "flying crimson banners with a golden lion.", TEXT_RULE, AVOID))

MAPS = [
    ("02", "a broad river delta with reed beds, wooden watermills, fishing boats and stone bridges, green meadows between the channels"),
    ("03", "rugged brown hills with mine entrances, ore carts on wooden rails, a smoking forge town and slag heaps, pine trees on the ridges"),
    ("04", "a dark dense forest of twisted ancient trees, mist between the trunks, a ruined overgrown chapel and a hidden woodcutters' camp"),
    ("05", "burnt grey plains with charred trees, glowing lava cracks in the ground, a ruined watchtower and drifting ash under an orange sky"),
    ("06", "a frozen lake surrounded by snowy pines, an ice-covered castle on an island, sleds and frozen waterfalls under a pale sky"),
    ("07", "golden sand dunes with a palm-fringed oasis, sandstone towers and domes, a camel caravan crossing near the road"),
    ("08", "jagged mountain peaks with enormous dragon bones half buried in the rock, narrow cliff paths, a distant dragon circling a peak"),
    ("09", "flooded ruins of an ancient city, broken columns and a drowned palace rising from shallow blue-green water, wooden walkways between the ruins"),
    ("10", "a wide paved imperial road lined with statues and banners leading to a radiant golden capital city with domes and towers on a hill"),
]
COUNTS = {"02": "13 düğüm (1 fazla)", "03": "11 düğüm, ara boss 4. sırada", "04": "11 düğüm, ara boss yok",
          "05": "14 düğüm, ara boss 8. sırada", "06": "13 düğüm", "07": "13 düğüm, ara boss yok",
          "08": "12 düğüm ama ara boss 7. sırada",
          "09": "doğru (12 düğüm, bosslar 6 ve 12'de), ama diğerleri gibi temiz olmalı: oyun kilitli/açık/şimdiki/geçildi hallerini ve yıldızları boyalı düğümün üstüne çizemez",
          "10": "13 düğüm"}
EDIT = ("Edit the attached painting {file}. Remove every round gold-rimmed stage medallion, every star socket, every "
        "larger medallion with a crimson banner and a skull-under-a-crown crest, and every treasure chest from the road "
        "and its sides. Where each one was, continue the dirt road and the ground beside it naturally, matching the "
        "surrounding painting exactly — the same light, colours, texture and level of detail. Change nothing else: the "
        "composition, the landscape, the buildings, the sky, the lighting and the framing stay exactly as they are. Keep "
        "the same size, 1086x1448. Add no text, no markers and no new objects.")
for n, land in MAPS:
    f = f"campaign_map_{n}.png"
    add(id="map" + n, group="fix", prio=1, file=f,
        title=f"Kampanya haritası {n} — düğümsüz (düzenleme)",
        why=(f"Teslimde {COUNTS[n]}." if n == "09" else
             f"Teslimde {COUNTS[n]}. Bölüm 12 aşama, bosslar 6 ve 12; bunu oyun yerleştirecek, harita temiz olmalı."),
        attach=f"{f} (düzenlenecek resmin kendisi)",
        cut=f"`campaign/map_{n}`",
        prompt=EDIT.format(file=f),
        fallback=prompt(MAP_HEAD, f, STYLE, MAP_RULE, f"The land: {land}.", TEXT_RULE, AVOID))

add(id="horses", group="fix", prio=1, file="items_horses.png",
    title="Atlar — çerçevesiz, arka plansız (yeniden)",
    why=("Silah ve zırh sayfası temiz nesnelerdi; atlar ise altın kalkan çerçeve ve renkli arka planla gelmiş. Oyun "
         "her eşyayı kendi karosuna oturtur; çerçeve ve arka plan iki kez çerçevelenmiş görünür."),
    attach="items_weapons.png (sunuş aynen böyle olmalı) ve items_horses.png (atların tasarımı korunsun)",
    cut="`items/painted/horse_<id>`",
    prompt=sheet("items_horses.png",
        "BODY — Fourteen horses presented exactly like the weapons in the attached items_weapons.png: each horse floats "
        "on the plain flat navy background with only a soft glow of its tier colour around it — NO frame, NO border, NO "
        "shield shape, NO coloured backdrop, NO scenery and NO ground behind any horse. Keep the horse designs of the "
        "attached items_horses.png. Grid of three columns and five rows (the last cell stays empty); each is a "
        "three-quarter head-and-chest portrait facing right with its tack or barding, the same size and angle in every "
        "cell, with a crisp rim light so dark coats separate from the background: (1) Swaybacked Plough Horse — an old "
        "gentle chestnut plough horse with a blue-dyed harness and silver fittings, cool blue sheen; (2) Silvermane Pony "
        "— a sturdy pony with a flowing silver mane and a blue bridle, cool blue sheen; (3) Duskmane Rouncey — a dark "
        "bay rouncey with a violet-black mane and purple barding, violet glow; (4) Kingsguard Courser — a sleek grey "
        "courser in a royal purple and gold caparison, violet glow; (5) Dawnward Destrier — a powerful destrier in violet "
        "barding with small sun motifs, violet glow; (6) The Ninth Siege Warhorse — a scarred armoured warhorse in "
        "battle-worn gold plate with nine notches cut into its chanfron, gold glow; (7) The Gilded Charger — a white "
        "charger in gilded barding, radiant gold glow; (8) Starfall Plough Horse — a humble plough horse in a golden "
        "harness with a starlit gold mane, gold glow; (9) Wyrmborn Pony — a pony with faint dragon scales on its neck and "
        "glowing magenta eyes and mane; (10) The Tempest Rouncey — a storm-grey horse with a lightning-streaked magenta "
        "mane; (11) Crown Courser — a black courser with a small crown-shaped chanfron, magenta glow; (12) The Last "
        "Destrier — a black destrier in crimson and black barding with glowing red eyes, crimson glow; (13) Emperor's "
        "Warhorse — a white warhorse in imperial crimson and gold barding, crimson radiance; (14) Sunrise Charger — a "
        "chestnut-gold charger with a flame-red mane and a crimson caparison, crimson glow."))

ROADS = [
    ("1", "the start of the road: green fields and farms, a village with red-roofed cottages, a windmill, an orchard and a flock of sheep, a small stone bridge over a stream"),
    ("2", "the middle of the road: a deep old forest with tall oaks and shafts of sunlight, a river crossed by a wooden bridge, a woodcutters' clearing and a mossy ruined watchtower"),
    ("3", "the end of the road: rocky foothills rising to snowy mountains, a mountain pass with a stone gate, and at the very top a great white castle with red roofs and crimson banners bearing a golden lion, catching the sunrise"),
]
for n, land in ROADS:
    add(id="road" + n, group="fix", prio=2, file=f"road_map_{n}.png",
        title=f"Zafer Yolu haritası {n}/3 — düğümsüz",
        why=("road.png tek sayfada 5 kilometre taşı gösteriyor; yolun 15 taşı var. Üç parça alt alta kayan tek bir "
             "yol olur, taşları oyun yerleştirir. road.png sayfanın çerçevesi (başlık, sekmeler, CLAIM) için kalır."),
        attach="road.png (üslup ve renkler)",
        cut=f"`road/map_{n}` — üç parça alt alta, sis bantları üst üste bindirilerek birleşir.",
        prompt=prompt(MAP_HEAD, f"road_map_{n}.png", STYLE, ROAD_RULE, f"The land: {land}.", TEXT_RULE, AVOID))

add(id="black_knight", group="fix", prio=2, file="bosses_black_knight.png",
    title="Kara Şövalye — yanan kilise ve aslan arması olmadan",
    why=("Arkada haçlı bir kilise yanıyor (dini hassasiyet, mağaza yaş sınıfı) ve düşman boss oyuncunun kendi arması "
         "olan kırmızı zemin üstüne altın aslanı taşıyor. Aslan oyuncunundur; boss kendi armasını taşımalı."),
    attach="bosses_black_knight.png (kompozisyon korunsun)",
    cut="`bosses/black_knight`",
    prompt=prompt(BOSS_HEAD, "bosses_black_knight.png", STYLE,
        "BODY — The same scene as the attached bosses_black_knight.png, repainted: a black knight in dark plate armour "
        "with a crimson plume on a rearing black warhorse, a long lance, a moonlit night sky with a full moon on the "
        "left, a castle on a hill with a bridge in the distance. Changes: his heraldry — on his shield, his horse's "
        "caparison and his banners — is a silver wolf's head on black and dark crimson, never a golden lion. The fire "
        "behind him is a burning timber palisade and a burning stone siege tower; there is no church, no chapel, no "
        "cross and no religious symbol anywhere. The field below is strewn only with broken shields, helmets, spears and "
        "fallen banners — no bodies. Same framing, light and mood.", TEXT_RULE, AVOID))

for boss, what in [("garrow", "the blood on his cleaver"), ("ulgrim", "the blood on his axe")]:
    f = f"bosses_{boss}.png"
    add(id="boss_" + boss, group="fix", prio=3, file=f,
        title=f"{boss.capitalize()} — kansız (isteğe bağlı)",
        why="Silahta kan var. Oyunun geri kalanında kan yok; yaş sınıfını düşük tutmak için temizlenebilir.",
        attach=f"{f} (düzenlenecek resmin kendisi)",
        cut=f"`bosses/{boss}`",
        prompt=(f"Edit the attached painting {f}. Remove {what}, leaving clean, battle-worn steel with the same light "
                "and reflections. Change nothing else: the figure, the pose, the background, the colours and the framing "
                "stay exactly as they are. Keep the same size, 1586x992. Add no text."))

# ============================================================================ new pages
add(id="battle", group="new", prio=1, file="battle.png",
    title="Savaş ekranı",
    why=("Oyunun kalbi olan yağma savaşı şu an lacivert zeminde küçük bir şerit, iki portre ve düz bir DEFEAT kutusu. "
         "Savaş sahnesi, portre çerçeveleri, VS arması, can çubukları ve sonuç paneli boyalı olmalı. VICTORY/DEFEAT "
         "bayrakları ve efektler battle_fx.png'den gelir."),
    attach="collect.png (üslup), battle_fx.png (efektlerle aynı dünya)",
    cut="`battle/stage`, `battle/frame_you|rival`, `battle/vs`, `battle/bar_track`, `battle/bar_fill_you|rival`, `battle/round`, `battle/fortune`, `battle/result_panel`, `battle/continue`.",
    prompt=screen("battle.png",
        "BODY — A full-screen battle screen with NO navigation rail and NO currency pills. The top 58% is a painted "
        "battlefield at golden hour seen from slightly above: a trampled green field before a white-stone castle with "
        "red conical roofs on a hill, two small armies facing each other across the field — on the left the player's "
        "troops under crimson banners with a golden lion, on the right the rival's troops under dark blue banners with a "
        "silver wolf — dust hanging in the low sun; the painting fades softly into the navy ground below it. At the top "
        "centre, a small ornate gold plate reading \"ROUND\" above an EMPTY small number plate. At the top right, a small "
        "quiet dark navy plate reading \"SKIP\". Across the middle of the battlefield, two large portrait frames facing "
        "each other: on the left a heavy antique-gold filigree frame, on the right the same frame worked in crimson and "
        "gold; both windows are EMPTY dark navy. Between them, centred, a VS emblem: two crossed steel swords with gold "
        "hilts over a small round steel shield. Under each frame an EMPTY name plate, and under it a small crossed-swords "
        "icon beside an EMPTY might plate. Under each, a long horizontal health bar: an EMPTY dark track with a thin "
        "steel border, the left one filled three quarters with warm emerald green, the right one filled half with deep "
        "crimson. Below the battlefield, on the navy ground, a small centred plate reading \"FORTUNE OF WAR\" with an "
        "EMPTY small plate on each side of it. The lower third holds a large result panel: slate navy with a heavy "
        "antique-gold filigree frame and chamfered corners, a wide EMPTY banner area across its top, and three EMPTY "
        "reward rows, each with a small painted icon on the left — a gold coin, a small gold crown, a faceted blue "
        "diamond — and an EMPTY value plate. Under the panel, a large emerald-green plate reading \"CONTINUE\"."))

add(id="ceremony", group="new", prio=1, file="ceremony_sheet.png",
    title="Tören parçaları — seviye, ustalık, teslimat, açılan bölüm",
    why=("Seviye atlama ve ustalık şu an lacivert üstüne yazı ve bir parıltı. Satın alma teslimatı (\"A ROYAL "
         "DELIVERY\") ve yeni sekme açılışı da aynı tören dilini kullanacak."),
    attach="rewards_sheet.png ve reward_icons.png",
    cut="`ceremony/level_medal`, `ceremony/rays`, `ceremony/mastery`, `ceremony/delivery`, `ceremony/unlocked`, `ceremony/confetti`, `ceremony/reward_tile`, `ceremony/continue`.",
    prompt=sheet("ceremony_sheet.png",
        "BODY — Celebration pieces in a grid of two columns and four rows, each centred in its own cell: (1) a large gold "
        "laurel wreath medallion with a small gold crown on top and an EMPTY round dark-red centre plate framed in gold, "
        "with a wide crimson ribbon across its lower part reading \"LEVEL UP\"; (2) a radiant burst of warm golden light "
        "rays spreading evenly in every direction from a bright centre, soft-edged, with no object in it; (3) a wide "
        "crimson ribbon banner with swallow-tailed ends and gold edges reading \"MASTERY\", a small gold star medal above "
        "its middle; (4) a wide royal-blue ribbon banner with gold edges reading \"A ROYAL DELIVERY\", a small open "
        "treasure chest spilling light above its middle; (5) a wide emerald ribbon banner with gold edges reading \"NEW "
        "LANDS OPENED\", a small gold key above its middle; (6) a loose scatter of spinning gold coins and tiny golden "
        "sparkles like confetti, with nothing at the centre; (7) a square reward tile — slate navy with a thin "
        "antique-gold frame and chamfered corners, its window EMPTY — with an EMPTY small value plate under it; (8) a "
        "large emerald-green bevelled plate reading \"CONTINUE\"."))

add(id="rankings", group="new", prio=1, file="rankings.png",
    title="Sıralamalar",
    why=("Şu an boş bir sayfada üç düğme ve düz satırlar. Kürsülü bir şeref salonu olmalı; sezon ve hafta tabloları "
         "(Dalga 4) da buraya gelecek."),
    attach="profile.png ve mail.png (sayfa dili)",
    cut="`rankings/header`, `rankings/podium`, `rankings/row`, `rankings/row_you`, `rankings/medal_1|2|3`.",
    prompt=page("rankings.png",
        "BODY — The page title \"RANKINGS\" in large gold engraved capitals over a header illustration across the top of "
        "the panel: a hall of fame — a marble gallery with crimson banners bearing a golden lion, three bronze statues of "
        "armoured lords on plinths, warm light from tall windows. Under the header, a row of three tab plates "
        "\"MIGHT\", \"LEVEL\", \"WEALTH\" with \"MIGHT\" selected (glowing crimson) and the others dark navy; under it a "
        "row of three smaller chips \"THIS WEEK\", \"SEASON\", \"ALL TIME\" with \"ALL TIME\" selected. Below, a podium of "
        "three stone plinths draped in crimson: the centre plinth tallest with a gold laurel medal, the left with a "
        "silver laurel medal, the right with a bronze laurel medal; on each a round portrait frame (gold, silver, "
        "bronze) with an EMPTY window, and under each an EMPTY name plate and an EMPTY value plate. Below the podium, six "
        "evenly spaced list rows, each a navy plate with a thin steel border: an EMPTY small rank plate on the left, a "
        "small round portrait frame with an EMPTY window, an EMPTY name plate with a smaller EMPTY level plate under it, "
        "and an EMPTY value plate on the right. Just above the foot, one more row with a heavier antique-gold border and "
        "a faint gold glow, a small ribbon on its left reading \"YOUR RANK\", with the same EMPTY plates. At the foot, a "
        "quiet dark navy plate reading \"CLOSE\"."))

add(id="treasury", group="new", prio=2, file="treasury.png",
    title="Kraliyet Hazinesi",
    why="Şu an iki satır ve boş bir alan. Kasa dairesi resmi, iki büyük tutar plakası ve hızlı seçimler olmalı.",
    attach="mail.png (sayfa dili)",
    cut="`treasury/header`, `treasury/on_hand`, `treasury/in_vault`, `treasury/field`.",
    prompt=page("treasury.png",
        "BODY — The page title \"ROYAL TREASURY\" over a header illustration: a vault chamber deep under the castle — a "
        "massive round iron vault door standing ajar, heaps of gold coins and chests glowing inside, two guards with "
        "halberds, torches on the stone walls. Under the title in parchment serif: \"Gold in the vault cannot be "
        "stolen.\" Two large wide plates stacked: the first with a heap of gold coins on its left, the words \"ON HAND\" "
        "and an EMPTY amount plate on its right; the second with a blue-and-gold shield bearing a keyhole on its left, "
        "the words \"IN THE VAULT\" and an EMPTY amount plate on its right. Below them a thin EMPTY note plate. Then a "
        "wide EMPTY input field with a small gold coin at its left, and under it three quiet chips \"ALL ON HAND\", "
        "\"HALF\", \"ALL IN VAULT\". At the foot, an emerald-green plate reading \"DEPOSIT\", a quiet dark navy plate "
        "reading \"WITHDRAW\" and a quiet plate reading \"CLOSE\"."))

add(id="stats", group="new", prio=2, file="stats.png",
    title="Stat puanları",
    why="Şu an üç satır ve boş sayfa. Eğitim avlusu resmi ve büyük stat kartları olmalı.",
    attach="family_storehouse.png (lordun yüzü aynı kalsın) ve mail.png",
    cut="`stats/header`, `stats/card`, `stats/icon_attack|defence|energy`, `stats/minus`, `stats/plus`.",
    prompt=page("stats.png",
        "BODY — The page title \"STAT POINTS\" over a header illustration: a castle training yard at golden hour — the "
        "young dark-haired lord (the same face as in the attached family_storehouse.png) in half-armour sparring with a "
        "grey-bearded master-at-arms, straw training dummies, a weapon rack, crimson banners on the wall. Under the "
        "title: \"Points cannot be moved once they are spent.\" A centred plate with a small gold star and an EMPTY "
        "count. Three tall stat cards stacked with even gaps, each a navy panel with an antique-gold frame: on the left a "
        "large painted icon — card 1 two crossed steel swords, card 2 a steel heater shield, card 3 a yellow lightning "
        "bolt — beside it the title \"ATTACK\", \"DEFENCE\" or \"MAX ENERGY\", an EMPTY green gain plate and a smaller "
        "EMPTY plate under it; on the right a control group: a small quiet round plate with a minus sign, an EMPTY value "
        "plate, a small emerald round plate with a plus sign, and a small quiet plate reading \"ALL\". At the foot, an "
        "EMPTY emerald-green plate and a quiet dark navy plate reading \"CLOSE\"."))

add(id="history", group="new", prio=2, file="history.png",
    title="Savaş geçmişi",
    why="Şu an boş sayfa ve düz satırlar. Harp odası resmi ve sonucu bir bakışta söyleyen mühürler olmalı.",
    attach="mail.png",
    cut="`history/header`, `history/row`, `history/seal_victory|defeat|held|raided`.",
    prompt=page("history.png",
        "BODY — The page title \"BATTLE HISTORY\" over a header illustration: a war room — a heavy oak table with a "
        "painted campaign map, carved army figurines, a candle, a helmet and a sheathed sword, a window onto the castle "
        "at dusk. Under the title: \"Your raids and the raids on you.\" Three chips \"ALL\", \"MY RAIDS\", \"ON ME\" with "
        "\"ALL\" selected. Seven evenly spaced list rows, each a navy plate with a thin steel border: on the left a round "
        "wax-seal badge, going down the list through four kinds — a gold seal with crossed swords (victory), a dark-red "
        "seal with a broken sword (defeat), a steel seal with a shield (a defence held) and a crimson seal with a "
        "clenched gauntlet (raided); then an EMPTY title plate with a smaller EMPTY line plate under it; on the right a "
        "small gold coin beside an EMPTY gold plate and a small gold chevron pointing right. At the foot, a quiet dark "
        "navy plate reading \"CLOSE\"."))

add(id="away", group="new", prio=2, file="away.png",
    title="Sen yokken (While you were away)",
    why=("Oyuncu geri döndüğünde yağmaları anlatan sayfa şu an iki satır yazı. Sunucunun verdiği dört sayı (yağma, "
         "kaybedilen altın, kazanılan fidye, öç alınabilecek) dört karo olmalı."),
    attach="mail.png",
    cut="`away/header`, `away/tile_raids|gold_lost|ransom|avenge`.",
    prompt=page("away.png",
        "BODY — The page title \"WHILE YOU WERE AWAY\" over a header illustration: the castle at night under a full "
        "moon, torches along the walls, a herald on the ramparts reading a long scroll by lantern light, thin smoke "
        "rising from a raided storehouse below the walls. Under the title: \"The realm did not sleep.\" A two-by-two "
        "grid of large square tiles, each a navy tile with an antique-gold frame, a painted icon, an EMPTY value plate "
        "and a small caption: (1) crossed swords glinting red, caption \"RAIDS\"; (2) a heap of gold coins with a small "
        "red downward arrow, caption \"GOLD LOST\"; (3) a steel shield with a gold coin on it, caption \"RANSOM EARNED\"; "
        "(4) a crimson clenched gauntlet, caption \"TO AVENGE\". Under the grid, a thin parchment note with a small "
        "shield-and-keyhole icon: \"Gold in the Royal Treasury cannot be stolen.\" At the foot, a crimson plate reading "
        "\"TAKE REVENGE\" and a quiet dark navy plate reading \"CONTINUE\"."))

add(id="collection", group="new", prio=2, file="collection.png",
    title="Koleksiyon duvarı",
    why="Şu an düz satırlar. Kupa salonu: her yuva ve kademe için çerçeve, elde olan yanık, bulunacak sönük.",
    attach="mail.png ve items_weapons.png",
    cut="`collection/header`, `collection/wall_row`, `collection/frame_<kademe>_on|off`, `collection/luck`.",
    prompt=page("collection.png",
        "BODY — The page title \"THE COLLECTION\" over a header illustration: a trophy hall in the castle — a long stone "
        "wall hung with swords, shields, suits of armour on stands and ornate horse tack, crimson banners, warm "
        "candlelight. Under the title, a wide plate with a four-leaf clover on its left and an EMPTY line. Then three "
        "wall sections, each headed by small ivory capitals — \"WEAPONS\", \"ARMOR\", \"HORSES\" — and each a row of "
        "seven square frames mounted on dark oak panelling, the frames coloured by tier from left to right: plain steel, "
        "green, blue, purple, gold, magenta and crimson, every window EMPTY; in each row the first four frames glow "
        "softly (held) and the rest are dim (still to find). Under the wall, a small heading \"NEW TO THE WALL\" and two "
        "rows, each a navy plate: a square tier frame with an EMPTY window, an EMPTY name plate with a smaller EMPTY line "
        "under it, and an emerald-green plate reading \"DONATE\". At the foot, a quiet dark navy plate reading "
        "\"CLOSE\"."))

add(id="hall", group="new", prio=2, file="kingdom_hall.png",
    title="Krallık salonu — krallığı olmayan lord",
    why="Krallığa katılma ekranı şu an üst resim ve altında boşluk. Davet, önerilen krallıklar ve kurma kartları boyalı olmalı.",
    attach="kingdom.png (mevcut başlık) ve boss.png (8 girişli menü)",
    cut="`hall/header`, `hall/search`, `hall/invite_card`, `hall/kingdom_card`, `hall/found_card`.",
    prompt=screen("kingdom_hall.png",
        "BODY — The content area (right of the rail, below the pills) shows the Kingdom screen for a lord with no "
        "kingdom. Header (top ~22%): a castle vista through a marble colonnade with crimson banners bearing a golden "
        "lion, the large gold title \"JOIN A KINGDOM\" and beneath it in parchment serif \"Stand with other lords and "
        "share their bonuses.\" Under the header, a wide EMPTY search field with a small magnifying-glass icon and a "
        "quiet plate reading \"SEARCH\". A small heading \"INVITATIONS\" and one invitation card: a navy card with a "
        "heavier gold frame, a crest socket on its left (an empty gold-rimmed heater-shield outline), an EMPTY "
        "kingdom-name plate, an EMPTY small line plate, an emerald plate reading \"ACCEPT\" and a quiet plate reading "
        "\"DECLINE\". A small heading \"RECOMMENDED FOR YOU\" and three kingdom cards evenly spaced, each with a crest "
        "socket, an EMPTY name plate, a small people icon beside an EMPTY plate, a small laurel icon beside an EMPTY "
        "plate, and an emerald plate reading \"JOIN\". Then a thin gold rule with the small word \"OR\" at its centre, "
        "and a last card: a round blue-and-gold shield emblem with a small castle, the title \"RAISE YOUR OWN BANNER\", "
        "an EMPTY line plate and an emerald plate reading \"FOUND\".", SHELL_KINGDOM))

add(id="auth", group="new", prio=2, file="auth.png",
    title="Giriş ekranı",
    why=("Mevcut giriş ekranı açılış resmi üstüne düz bir form. Sign in with Apple (Dalga 2) gelince Apple'ın kendi "
         "düğmesi için temiz bir yer lazım (tablo kuralının tek istisnası)."),
    attach="client/assets/branding/launch@2x.png (bu klasörde references/launch.png) ve collect.png",
    cut="`auth/art`, `auth/panel`, `auth/field`, `auth/sign_in`, `auth/create`.",
    prompt=screen("auth.png",
        "BODY — A full-screen sign-in screen with NO navigation rail and NO currency pills. The top 55% is the game's "
        "title painting: through a tall stone window framed by crimson drapes and crimson banners with gold stars, a "
        "white castle on a mountain crag in morning light; in front of it, centred, the large \"EMPERORS\" crest — "
        "steel-and-gold Roman capitals with a gold crown above and crimson banners and crossed swords behind, as in the "
        "attached launch image. The lower part is the navy ground with a slate-navy panel in an antique-gold filigree "
        "frame with chamfered corners: at its top the ivory capitals \"ENTER THE REALM\"; two EMPTY wide input fields "
        "with a thin copper edge, the first with a small quill icon at its left, the second with a small key icon; a "
        "large emerald-green plate reading \"SIGN IN\"; a quiet dark navy plate reading \"CREATE ACCOUNT\"; a thin gold "
        "rule with the small word \"OR\" at its centre; and under it an EMPTY band of plain panel as tall as a button, "
        "left completely clear. Under the panel, small letter-spaced steel-blue capitals \"TERMS\" and \"PRIVACY\" "
        "separated by a small gold dot."))

add(id="army_bits", group="new", prio=2, file="army_bits_sheet.png",
    title="Ordu parçaları — HUNT düğmesi ve AWAY/BACK kurdeleleri",
    why=("hunt.png'deki HUNT / REROLL / DISMISS düğmeleri mevcut Army ekranındakilerden farklı boyda ve biçimde. "
         "Mevcut ekrana yeni bir düğme eklenirken aynı aileden olmalı."),
    attach="army.png (mevcut REROLL ve DISMISS düğmeleri) ve hunt.png (AWAY/BACK kurdeleleri)",
    cut="`army/btn_hunt`, `army/ribbon_away`, `army/ribbon_back`.",
    prompt=sheet("army_bits_sheet.png",
        "BODY — Three pieces for the Army screen, each centred in its own cell: (1) a button identical in shape, size, "
        "bevel, border and lettering to the \"REROLL\" and \"DISMISS\" buttons on the attached army.png, but worked in "
        "warm bronze with a small hunting horn icon on its left and the word \"HUNT\"; (2) a small slanted ribbon in "
        "deep crimson with gold edges reading \"AWAY\", made to lie across the corner of a soldier card; (3) the same "
        "ribbon in emerald green reading \"BACK\"."))

add(id="headers", group="new", prio=3, file="page_headers_sheet.png",
    title="Bilgi sayfası başlıkları — kurallar, olasılıklar, teçhizat, reroll",
    why="Kurallar, asker olasılıkları, teçhizat seçimi ve reroll sayfaları yalnız yazı; birer başlık resmi yeter.",
    attach="mail.png (başlık resminin sayfaya nasıl eridiği)",
    cut="`headers/rules|odds|gear|reroll`",
    prompt=sheet("page_headers_sheet.png",
        "BODY — Four wide header illustrations stacked one above another with even gaps, each about three times as wide "
        "as it is tall, each a finished painted scene whose bottom edge fades softly into the navy ground (the top and "
        "sides stay crisp), with no text: (1) an open leather codex on a lectern with a quill, red wax seals, a candle "
        "and a war map pinned on the wall behind; (2) a recruiting tent at a muster field — a sergeant at a table with a "
        "ledger, villagers and mercenaries queuing, crimson banners with a golden lion; (3) an armoury — racks of "
        "swords and spears, shields on the wall, a suit of plate armour on a stand and a saddle, warm torchlight; (4) a "
        "training post — a soldier striking a wooden pell while a master-at-arms watches, sparks off the steel."))


# ============================================================================ round 3
add(id="tabs_c", group="more", prio=1, file="tabs_sheet_c.png",
    title="Kısa sekme plakaları — dörtlü şeritler için",
    why=("tabs_sheet_a/b'deki plakalar 4:1 geniş; Krallık'ın REALM / LORDS / WORKS / RANKS şeridi gibi dörtlü "
         "şeritlere sığınca %54'e küçülüyor, yazı tablodakinden ince kalıyor. Dörtlü şeritler (Krallık, Saldırı'nın "
         "RAID / ARENA / CAMPAIGN / BOUNTIES'i, Krallık'ın ikinci sırası) ve Savaş Geçmişi'nin üç sekmesi için "
         "yaklaşık 3:1 kısa plakalar lazım. history.png'deki \"MY RADS\" yazım hatası da bu plakalarla düzelir."),
    attach="tabs_sheet_a.png (aynı plakaların uzun hali) ve kingdom.png (dörtlü şeridin boyu)",
    cut="`tabs/short_<ad>` ve `tabs/short_<ad>_lit` — dörtlü şeritler bunlardan, tablodaki yükseklikte kurulur.",
    prompt=sheet("tabs_sheet_c.png",
        "BODY — Short navigation tab plates, all exactly the same size, laid out in fifteen rows of two: in every row "
        "the LEFT plate is the UNLIT state — a dark slate-navy bar with small chamfered corners, a thin pale steel "
        "border and the word in ivory engraved Cinzel capitals — and the RIGHT plate is the LIT state of the same word "
        "— a glowing deep-crimson bar with a thin gold rim, a soft warm inner glow and the word in ivory engraved Cinzel "
        "capitals — exactly like the plates in the attached tabs_sheet_a.png, but shorter: every plate is only about "
        "three times as wide as it is tall. The word is centred and set at the same letter size on every plate, as "
        "large as the longest word allows with a margin. The fifteen words, one per row, top to bottom: \"RAID\", "
        "\"ARENA\", \"CAMPAIGN\", \"BOUNTIES\", \"REALM\", \"LORDS\", \"WORKS\", \"RANKS\", \"CHAT\", \"BOSS\", "
        "\"WAR\", \"HELP\", \"ALL\", \"MY RAIDS\", \"ON ME\". Even gaps between all plates; nothing else on the sheet."))

add(id="horse_pony", group="more", prio=2, file="items_horses_2.png",
    title="Bir at daha — köy midillisi",
    why=("items_horses.png'de 14 at geldi (son hücre boş); oyunda 21 at tanımı var, 20'si artık kendi resmini "
         "taşıyor. \"Village Pony\" hâlâ \"Plough Horse\"un resmini paylaşıyor. Tek bir at bunu kapatır."),
    attach="items_horses.png (üslup, ışık ve boyut)",
    cut="`items/painted/horse_02` — Village Pony kendi resmine geçer, paylaşım kalkar.",
    prompt=sheet("items_horses_2.png",
        "BODY — One horse only, centred on the sheet and painted exactly like the frameless horses in the attached "
        "items_horses.png — the same three-quarter view of the head, neck and shoulders, the same size, light and "
        "finish, with no frame and no plate: a small, sturdy village pony of the humblest kind, shaggy dun coat and a "
        "thick dark mane falling over its eyes, a plain rope halter and a worn woven saddle blanket in faded brown and "
        "cream, no armour, no gold, no jewels."))

add(id="ledger_extra", group="more", prio=2, file="ledger_extra_sheet.png",
    title="Aile defteri — Hazine ve Miras sahneleri",
    why=("Aile sekmesindeki defterde 21 kartın 19'u artık kendi sahnesini taşıyor. Royal Treasury ve The Legacy "
         "kartları hâlâ başka kartların resmini ödünç alıyor (kale ve ordu)."),
    attach="ledger_upgrades.png (sahnelerin boyu, çerçevesi ve üslubu)",
    cut="`family/ledger_treasury` ve `family/ledger_legacy`, ötekiler gibi 364×216.",
    prompt=sheet("ledger_extra_sheet.png",
        "BODY — Two painted scenes, one above the other with an even gap, each exactly the shape and size of one "
        "scene on the attached ledger_upgrades.png (about five units wide to three tall), painted in the same way, "
        "each a finished scene edge to edge with no frame and no text: (1) THE ROYAL TREASURY — a vaulted stone "
        "counting house under the castle: a great round iron vault door standing open, chests of gold coins and "
        "stacked ingots behind it, a clerk in a dark robe weighing coins on brass scales at a table with a ledger, "
        "two guards with halberds at the door, crimson banners with a golden lion, warm torchlight; (2) THE LEGACY — "
        "a long gallery of the family's ancestors: tall portraits of past kings and queens in gold frames down a "
        "candlelit hall, a great family-tree tapestry at the end, a young heir in a crimson cloak standing before it "
        "with his back half turned, a crown resting on a velvet cushion on a pedestal."))


add(id="crest_constancy", group="more", prio=1, file="crest_constancy.png",
    title="Sadakat Tacı arması (Crown of Constancy) — takvimin 28. günü",
    why=("28 günlük takvimin son ödülü \"Crown of Constancy\" arması. Tek resmi calendar.png'nin 28. karesindeki "
         "61×79'luk kalkan; profil, rakip kartı ve gardırop armaları 182×240 boyanmış crests_sheet kalkanlarıyla "
         "çiziliyor. Bu arma gelene kadar küçük haliyle, hiç büyütülmeden gösteriliyor."),
    attach="crests_sheet.png (kalkanların boyu, çerçevesi ve üslubu) ve calendar.png (28. kare: kırmızı kalkan, altın aslan)",
    cut="`icons/crest_constancy` 182×240, crests_sheet'teki on iki arma gibi — takvimin 28. karesi resmini korur.",
    prompt=sheet("crest_constancy.png",
        "BODY — One heraldic crest only, centred on the sheet and painted exactly like the shields on the attached "
        "crests_sheet.png — the same heater-shield shape, the same size, the same heavy antique-gold filigree border "
        "and the same light and finish, with no plate and no ribbon: a deep crimson field bearing a golden lion "
        "rampant, as on the red shield in the last square of the attached calendar.png, crowned with a small gold "
        "crown set with one red jewel, and a thin ring of small gold laurel leaves around the shield's rim, the lion "
        "and the crown in raised polished gold."))


add(id="family_treasury", group="more", prio=2, file="family_treasury.png",
    title="Aile ekranı — Kraliyet Hazinesi (banka) kartı",
    why=("Hazine şu an Aile defterinin ortasında, yükseltmelerin arasında bir satırdı: kolayca unutuluyor ve "
         "banka olduğu anlaşılmıyordu. Oyun artık onu STOREHOUSE'un hemen altında, aynı çerçevede kendi kartı "
         "olarak oyunun kendi parçalarından kuruyor. Bu tablo karta kendi boyalı halini ve kasaya ambar gibi "
         "boş / yarım / dolu hallerini verir; gelirse kart bundan yeniden kesilir."),
    attach="family_storehouse.png (ekranın kendisi ve STOREHOUSE kartı) ve treasury.png (kasa dairesi)",
    cut=("`family/treasury_card` (STOREHOUSE kartıyla aynı ölçüler), `family/treasury_empty`, `_half`, `_full` "
         "(kasanın üç hali), `family/treasury_icon_vault`, `family/treasury_icon_coins`; oyundaki geçici kart bunlarla değişir."),
    prompt=screen("family_treasury.png",
        "BODY — The Family screen exactly as in the attached family_storehouse.png from the top down to the bottom of "
        "its STOREHOUSE card: the same young lord on his throne, the same castle, the same name plate, stat plates and "
        "STOREHOUSE card, unchanged. Directly under the STOREHOUSE card, with the same gap, a second card of exactly "
        "the same size, frame and inner layout: the treasury card. On its left, the same picture window as the "
        "storehouse's, showing a vault chamber under the castle as in the attached treasury.png: a massive round iron "
        "vault door standing open, gold coins and chests glowing inside, one guard with a halberd beside it, warm "
        "torchlight. On its right, the title \"ROYAL TREASURY\" in the same engraved Cinzel capitals and size as "
        "\"STOREHOUSE\"; under it an EMPTY amount plate with a small blue-and-gold shield bearing a keyhole at its "
        "left; under that an EMPTY plate with a small heap of gold coins at its left; then two plates side by side, "
        "exactly the size and shape of the storehouse's two buttons: an emerald-green plate reading \"DEPOSIT\" and "
        "a quiet dark navy plate reading \"WITHDRAW\". Under the treasury card, the TALENTS, DEEDS and ROAD cards "
        "exactly as in the attached family_storehouse.png. At the bottom of the screen, where family_storehouse.png "
        "shows its three storehouse states, three pictures of the same vault chamber in a row, each in the same small "
        "gold frame: (1) the vault door shut and barred over a bare stone floor, no gold; (2) the door half open, a "
        "modest pile of coins and one chest inside; (3) the door wide open, gold spilling out of the vault in heaps "
        "and chests overflowing.",
        shell=SHELL_FAMILY))


if __name__ == "__main__":
    json.dump(ITEMS, open(sys.argv[1], "w"), ensure_ascii=False, indent=1)
    print(len(ITEMS), "items")
