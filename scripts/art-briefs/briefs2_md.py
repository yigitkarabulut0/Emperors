import json, sys

items = json.load(open(sys.argv[1]))
out = sys.argv[2]
P = {1: "Önce", 2: "Sonra", 3: "İsteğe bağlı"}

md = []
w = md.append
w("""# Emperors — Tablo Kitapçığı 2: düzeltmeler ve eksik sayfalar

İlk kitapçıktaki (`PAINTING_BRIEFS.md`) 74 tablonun tamamı `Emperors_Design_Pack` ile
geldi. Bu kitapçık iki şey içerir:

1. Paketin **tablo tablo incelemesi**: sağlam olanlar ve düzeltilmesi gerekenler.
2. Oyunda **hiç tablosu olmayan, şu an sade duran sayfalar** için yeni promptlar. Bunları
   çalışan oyunun ekran görüntüleri alınarak tespit ettim.

Her prompt **tek parçadır**: bir kutuyu kopyala, ChatGPT'ye yapıştır, bir resim al.
İlk kitapçıktaki gibi blok birleştirmek gerekmez.

---

## 1. Paket incelemesi

**Genel sonuç: çok iyi.** 74 tablonun 74'ü geldi ve hepsine tek tek baktım. Boyutlar boru
hattımıza uygun: ekranlar 941×1672, haritalar 1086×1448, boss sahneleri 1586×992.

- Tırnaklı kelimeler doğru yazılmış.
- EMPTY plakalar gerçekten boş.
- 8 girişli menü ve üç hap her ekranda aynı.
- Üslup ilk yedi tabloyla aynı dünyadan.

Aşağıdakiler olduğu gibi kullanılacak:

| Tablolar | Durum |
|---|---|
| court, store, store_2, offers, offers_popup, mail, favour, wardrobe | ✅ kullanılacak |
| rewards_sheet, ui_bits_sheet, diamond_packs_large, frames_cosmetic_a/b, plates_sheet, reward_icons, titles_sheet, frames_noble, frames_events, ftue_sheet | ✅ kullanılacak |
| chests, calendar, deeds, guide, events, collect_events, events_kit, event_themes, pass, family_storehouse | ✅ kullanılacak |
| arena, arena_kit, bounties, throne, chat, chat_rules, help, profile, rival | ✅ kullanılacak (sekmeler için bkz. düzeltme 1) |
| campaign, hunt, expedition, forge, talents, boss, war | ✅ kullanılacak (düzeltme 1, 4, 9) |
| collect_jobs_a/b, ledger_upgrades, ledger_holdings, works_sheet, avatars_sheet, soldiers_sheet, numerals_sheet, battle_fx, items_weapons, items_armor, crests_sheet | ✅ kullanılacak |
| bosses: ashfall_wyrm, iron_colossus, fen_witch | ✅ kullanılacak |

Düzeltilmesi gerekenler:

| # | Sorun | Nerede | Çözüm |
|---|---|---|---|
| 1 | **Sekmeler tutarsız.** Saldırı alt ekranlarında (arena, bounties, campaign) başlık ve sekme şeridi farklı yükseklikte. Krallık alt ekranlarında (chat, help, war, boss) üst kısım üç ayrı biçimde. `road.png`'de sekme sırası `deeds.png`'nin tersi. Alt sekme değiştirince ekran zıplar. | arena, bounties, campaign, chat, help, war, boss, deeds, road | Bütün sekmeler tek boyda, yanık ve sönük halleriyle iki sayfadan kesilecek (`tabs_sheet_a/b`). Tabloların içerik kısmı aynen kullanılır. |
| 2 | **Menüde SHOP ve INVENTORY'nin yanık hali yok.** Diğer altı giriş de tablodan tabloya birkaç piksel oynuyor. | tüm ekranlar | `rail_lit_sheet` |
| 3 | **Kampanya haritalarındaki aşama sayısı tutmuyor.** Her bölüm 12 aşama olmalı, bosslar 6. ve 12. aşamada. Teslimde: 02 → 13 düğüm · 03 → 11 düğüm, ara boss 4. sırada · 04 → 11 düğüm, ara boss yok · 05 → 14 düğüm · 06 → 13 · 07 → 13, ara boss yok · 08 → ara boss 7. sırada · 10 → 13. **Yalnız 09 doğru.** Düğümler boyanın içinde olduğu için silinemez. | campaign_map_02…10 | Haritalar **düğümsüz** gelecek (mevcut resmin düzenlenmesiyle). Düğümleri, yıldızları ve sandığı oyun `campaign_nodes_sheet`'ten kesip yolun üstüne kendisi dizecek. 1. bölümün ayrı haritası da yok → `campaign_map_01`. |
| 4 | **Atlar çerçeveli ve renkli arka planlı.** Silah ve zırh sayfaları temizdi; oyun her eşyayı kendi karosuna oturttuğu için atlar çift çerçeveli görünür. | items_horses | temiz yeniden |
| 5 | **Zafer Yolu'nun 15 kilometre taşı var**, `road.png` tek sayfada 5 tane gösteriyor. | road | 3 parçalı düğümsüz yol haritası. `road.png` sayfa çerçevesi için kalır. |
| 6 | **Kara Şövalye'nin arkasında haçlı bir kilise yanıyor** (dini hassasiyet, mağaza yaş sınıfı) ve düşman oyuncunun kendi arması olan altın aslanı taşıyor. | bosses_black_knight | yeniden |
| 7 | Garrow ve Ulgrim'in silahında kan var. | bosses_garrow, bosses_ulgrim | isteğe bağlı temizlik |
| 8 | `hunt.png`'deki HUNT / REROLL / DISMISS düğmeleri mevcut Army ekranındakilerden farklı aileden. | hunt | `army_bits_sheet` |
| 9 | **42 ek durum ekranı** (`art/states`) boyama değil, parçalardan yapılmış SVG taslakları. Küçük ve düz yazılı, düz paneller. İçlerinde oyunda olmayan ya da senin seçmediğin şeyler var: müzik, ses, titreşim, dil, bulut kaydı. | art/states | Sanat olarak kullanılmayacak. Onaylar, hatalar ve ödüller oyunun boyalı diyalog kitiyle kurulur; ödül töreni `ceremony_sheet`'ten gelir. |

**Tablosu hiç olmayan ve sade duran sayfalar.** Oyunda yakalanan ekranlarda gördüklerim:

- Savaş ekranı
- Seviye atlama ve ustalık törenleri
- Sıralamalar
- Kraliyet Hazinesi
- Stat puanları
- Savaş geçmişi
- "Sen yokken" sayfası
- Koleksiyon duvarı
- Krallığı olmayan lordun krallık salonu
- Giriş ekranı
- Kurallar, olasılıklar, teçhizat ve reroll sayfaları

Bunlar şimdiye kadar lacivert bir levha üstüne yazıyla kuruluydu. Aşağıda her biri için tablo promptu var.

---

## 2. Nasıl kullanılır

- **Her kutu bir resim.** Kutunun tamamını kopyala ve ChatGPT'ye yapıştır.
- **Ek (attach):** Her promptun başında hangi resimlerin ekleneceği yazar.
  - Paketteki resimler zaten `Emperors_Design_Pack/art/reference/` içinde.
  - Pakette olmayan dördünü (`collect.png`, `army.png`, `kingdom.png`, `launch.png`) senin
    için `~/Downloads/Emperors_Design_Pack_2/references/` klasörüne koydum.
- **Düzenleme (edit) promptları:** Harita ve boss düzeltmeleri, **yüklediğin resmin kendisini
  düzenler**. Resmi ekle, promptu gönder. Sonuç lekeli çıkarsa altındaki **yedek prompt** ile
  sıfırdan üret.
- **Boyut:** Ekranlar ve sayfalar paketteki gibi 9:16 (941×1672 ya da daha büyüğü, aynı oranda).
  Haritalar 3:4. Boss 16:10.
- **Dosya adı** aynen buradaki gibi olsun.
  - Yeni tablolar: `~/Downloads/Emperors_Design_Pack_2/` klasörüne koy.
  - Düzeltilenler: aynı klasöre aynı adla koy. Paketteki eskinin üzerine yazma; ikisini ben karşılaştırırım.
- **Kontrol:** Göndermeden önce ilk kitapçığın 1.4 bölümündeki listeyle bak.
  - Tırnaklı kelimeler doğru mu?
  - EMPTY'ler boş mu?
  - Üslup `collect.png` ile aynı dünyadan mı?

---

## 3. Sıra

""")
for prio in (1, 2, 3):
    w(f"**{P[prio]}**\n")
    for it in items:
        if it["prio"] == prio:
            w(f"- [ ] `{it['file']}` — {it['title']}")
    w("")

def section(group, heading):
    w("---\n")
    w(heading + "\n")
    n = 0
    for it in items:
        if it["group"] != group:
            continue
        n += 1
        w(f"### {n}. `{it['file']}` — {it['title']}\n")
        w(f"**Neden:** {it['why']}  ")
        w(f"**Ekle:** {it['attach']}  ")
        w(f"**Sıra:** {P[it['prio']]}  ")
        w(f"**Kesim:** {it['cut']}\n")
        w("```text")
        w(it["prompt"])
        w("```\n")
        if it.get("fallback"):
            w("Düzenleme olmazsa **yedek prompt** (sıfırdan, düğümsüz):\n")
            w("```text")
            w(it["fallback"])
            w("```\n")

section("fix", "## 4. Düzeltmeler")
section("new", "## 5. Yeni sayfalar")
section("more", "## 6. Ek istekler (3. tur)")

w("""---

## 6. Teslim kontrol listesi

Her tablo için ilk kitapçığın 1.4 bölümündeki kontrollere ek olarak:

- **Sekme ve menü sayfaları:**
  - Bütün plakalar aynı boyda.
  - Kelimeler aynı harf boyunda.
  - Yanık (kızıl) ve sönük (lacivert) hali yan yana.
- **Haritalar:**
  - Yolun üstünde ve kenarında **hiçbir** işaret yok: madalyon, yıldız, sandık, bayrak, figür.
  - Yol aşağının ortasından girip yukarının ortasından çıkıyor.
- **Zafer Yolu parçaları:** Üst ve alt kenar aynı açık altın siste eriyor. Üçü alt alta konunca yol kesintisiz.
- **Atlar:** Hiçbir atın arkasında çerçeve, kalkan şekli ya da renkli zemin yok. Silah sayfasıyla aynı sunuş.
- **Kara Şövalye:** Kilise, haç ve aslan arması yok.
""")
open(out, "w").write("\n".join(md))
print("wrote", out)
