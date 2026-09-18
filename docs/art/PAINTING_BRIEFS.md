# Emperors — Tablo Prompt Kitapçığı

Bu kitapçık, oyunun yeni ekranları ve şu an zayıf kalan görselleri için
üretilecek **referans tabloların** promptlarıdır. Oyundaki her ikon, düğme,
çerçeve ve portre bu tablolardan **kesilir** (`art/SLICING_GUIDE.md`); oyun
yalnızca canlı yazıyı (sayılar, isimler, sayaçlar) kendisi basar. Bu yüzden
tabloların hem güzel hem de **kesilebilir** olması gerekir: doğru yerde doğru
nesne, doğru kelime, ve canlı yazının geleceği yerde **boş** plaka.

Promptlar İngilizcedir (üreticiler İngilizceyi daha iyi izler); açıklamalar
Türkçedir. Her prompt kendi kutusundadır — tek dokunuşla kopyalanır.

## İçindekiler

1. [Nasıl kullanılır](#1-nasıl-kullanılır)
2. [Ortak bloklar](#2-ortak-bloklar)
3. [Parti 1 — Saray, mağaza, posta (Dalga 1–2)](#3-parti-1--saray-mağaza-posta-dalga-12)
4. [Parti 2 — Günlük döngü, etkinlik, sezon (Dalga 2–4)](#4-parti-2--günlük-döngü-etkinlik-sezon-dalga-24)
5. [Parti 3 — Rekabet ve sosyal (Dalga 5–6)](#5-parti-3--rekabet-ve-sosyal-dalga-56)
6. [Parti 4 — PvE ve krallık savaşları (Dalga 7–8)](#6-parti-4--pve-ve-krallık-savaşları-dalga-78)
7. [Yeniden boyamalar (zayıf mevcut görseller)](#7-yeniden-boyamalar-zayıf-mevcut-görseller)
8. [Teslim kontrol listesi](#8-teslim-kontrol-listesi)

---

## 1. Nasıl kullanılır

### 1.1 Promptu birleştirme sırası

Her tablonun başında hangi blokların hangi sırayla yapıştırılacağı yazılıdır.
İki kalıp var:

- **Ekran tablosu:** `STYLE` → `SHELL-<giriş>` (veya `PAGE`) → `BODY` → `TEXT RULE` → `AVOID`
- **Nesne sayfası:** `STYLE` → `SHEET` (veya `SHEET-TEAL`) → `BODY` → `TEXT RULE` → `AVOID`

Blokları aynı mesaja alt alta yapıştır (arada boş satır olabilir). Ortak bloklar
[2. bölümdedir](#2-ortak-bloklar); `BODY` her tablonun kendi kutusudur.

**Üretici görsel referans kabul ediyorsa** (GPT görüntü, Midjourney `--sref`
vb.): her üretimde `art/reference/collect.png` ve konuya en yakın mevcut tabloyu
(ör. mağaza için `shop.png`, krallık için `kingdom.png`) **stil referansı**
olarak ekle. Tek dünya görünümünü en çok bu korur.

### 1.2 Boyut, biçim, dosya adı

- **Ekranlar ve çoğu sayfa:** dikey **9:16**, en az **1080×1920** (daha büyüğü
  iyidir). Oyun 941×1672 tuvalde çalışır; tabloyu biz
  `scripts/normalize-reference.py` ile bu boyuta indiririz. Kendin kırpma, ölçekleme.
- **İstisnalar** tablonun kendi satırında yazar: kampanya haritaları **3:4**
  (≥1552×2070), boss sahneleri **16:10** (≥1542×964).
- **PNG** kaydet (JPEG kenarlarda kir bırakır). Filigran, imza, çerçeve ekleme.
- Dosya adı **aynen** buradaki gibi olmalı ve `art/reference/` klasörüne girmeli
  (kesim manifestleri bu adları okur). Bir dosyada **tek tablo**.

### 1.3 "EMPTY" ne demek, neden önemli

Promptta `EMPTY` yazan her plaka, alan, pencere veya rozet **tamamen boş**
boyanmalı: harf yok, rakam yok, sembol yok — sadece plakanın yüzeyi. Oraya oyun
canlı yazıyı (fiyat, isim, sayaç, seviye) kendisi basar. Tabloda orada yazı
çıkarsa silmemiz gerekir; silme izi bırakır ve o parçayı yeniden kesmek ya da
tabloyu yeniden ürettirmek gerekir. Tırnak içindeki kelimeler ise **sabit**
yazılardır (başlıklar, düğme kelimeleri) ve tablonun içinde kalır.

### 1.4 Göndermeden önce kontrol et

Her tabloyu teslim etmeden önce şu listeyle bak (bir madde bile tutmuyorsa
yeniden üret ya da üreticinin düzenleme/inpaint aracıyla sadece o bölgeyi düzelt):

1. **Kelimeler:** tırnaklı her kelime harfi harfine doğru; başka hiçbir yazı,
   uydurma kelime veya anlamsız harf yok. `×2` işareti `x2` çıkarsa kabul.
2. **EMPTY'ler gerçekten boş** (en sık yapılan hata budur).
3. **Sol menü (ekran tablolarında):** 8 giriş (FAMILY, COLLECT, INVENTORY, SHOP,
   ARMY, ATTACK, KINGDOM, COURT) **eşit aralıklı**, doğru giriş kızıl yanık, en
   altta kum saatli altın mühür görünüyor; üstte portre madalyonu ve "33".
4. **Üç hap** en üstte: `493.48M`, `127`, `513/513` ve artı düğmeleri.
5. **Hiçbir panel kenardan taşmıyor/kesilmiyor**, tekrar eden kartlar eşit aralıklı.
6. **Stil:** yan yana koyduğunda `collect.png` ile aynı dünyadan görünüyor
   (lacivert zemin, ince altın/çelik çerçeve, zümrüt ve kızıl plakalar, sıcak ışık).
7. **Nesne sayfalarında:** zemin düz ve tek renk, nesneler birbirine ve kenara
   değmiyor.
8. **Karakter tutarlılığı:** kâhya, genç lord gibi tekrar eden kişiler aynı kişi
   gibi görünüyor.

### 1.5 Teslimden sonra ne olur (benim tarafım)

1. `scripts/normalize-reference.py` → 941×1672'ye getirilir (kaynak hazırlığı).
2. `art/tools/grid.py` ve `probe.py` ile ölçülür.
3. `art/slices/<ad>.json` (kesim manifesti) ve `.layout.json` (yerleşim) yazılır.
4. `scripts/slice-reference.py` ile kesilir, Godot'ya import edilir, lint çalışır.
5. Ekran 941×1672 ve 941×2040 tuvallerde yakalanır, tabloyla yan yana
   `art/qa/<ekran>_sbs.png` üretilir ve yakınlaştırılarak kontrol edilir.
6. Kusur varsa (kesilmiş kenar, hale, kalan harf) manifest düzeltilip yeniden
   kesilir; gerekirse senden o tabloyu yeniden istemem gerekir.

### 1.6 Tutarlılık ipuçları

- Aynı parti içindeki tabloları mümkünse **aynı oturumda** üret.
- Işık hep **sol üstten**; sahnelerde sıcak altın saat ışığı.
- Aynı düğme (yeşil "CLAIM", kızıl "ATTACK" vb.) her tabloda aynı görünmeli;
  farklı çıkarsa en iyisini seçeriz, diğerleri o parçayı kullanır — ama ne kadar
  benzerse o kadar iyi.
- Kısa kelimeler üreticilerde daha doğru çıkar; uzun başlıkta harf hatası
  olursa sadece o bölgeyi düzenleyerek düzelt.
- **Sign in with Apple düğmesi için tablo gerekmez** — Apple'ın kendi düğmesi
  kullanılır (tablo kuralına tek istisna).
- **HUNT düğmesi için tablo gerekmez** — mevcut `army.png`'den kesilir.

---

## 2. Ortak bloklar

### STYLE (her promptun başına)

```text
STYLE — Premium portrait mobile strategy-RPG screen for a medieval fantasy kingdom game, painted as a rich semi-realistic digital oil painting: crisp, highly detailed, with warm golden-hour sunlight in every painted scene and soft candle-warm light on objects. The interface ground is a very dark blue-slate navy (#0B151F) with a faint fine grain. Content panels are a slightly lighter slate navy (#15222F to #1B2B3B) with a subtle brushed texture, small chamfered corners, and thin bevelled double borders in pale steel-silver with a warm antique-gold inner hairline; featured frames (item frames, crests, portraits, highlighted cards) use heavier antique-gold filigree borders with small corner ornaments. Accent colours are warm gold (#E3BE62), deep crimson (#8E1B1E to #B22A2A) and emerald green (#1E6A34 to #2F8C46). Primary buttons are emerald-green bevelled plates with a thin gold rim, a soft top highlight and ivory engraved Roman capitals; selected tabs, alerts and the active navigation cell are glowing crimson plates with a gold rim; quiet buttons are dark navy plates with a thin steel border and ivory capitals. Screen titles are large engraved Cinzel-style Roman capitals in warm gold with a soft dark drop shadow; panel titles are smaller ivory Cinzel capitals; sentences use a classic old-style serif (EB Garamond style) in warm parchment white; tiny labels are letter-spaced small capitals in muted steel blue. Icons are miniature painted objects with real highlights and shadows — a gold coin stamped with a crown, a faceted blue diamond, a yellow lightning bolt, crossed steel swords with gold hilts, a small gold crown — never flat symbols. A painted scenic header fills the top of each screen (for example a white-stone castle with red conical roofs on a green hill under a blue sky with soft clouds, crimson banners bearing a golden lion) and fades softly into the navy ground below it. The bottom edge of the screen is dark, softly blurred foreground foliage and a weathered wooden beam with a gentle vignette. Everything is evenly spaced and aligned; no element touches or crosses the image edges.
```

### SHELL-COURT (menüde COURT yanık)

```text
SHELL — The left 17% of the screen width is a full-height dark navy navigation rail with a subtle vertical texture and a thin antique-gold line down its right edge. At the top of the rail sits a round crimson portrait medallion framed by a gold laurel wreath with a small gold crown on top, showing a handsome young lord with dark wavy hair and a crimson collar; under it a small dark-red plaque with a gold rim shows "33". Below the medallion, eight navigation entries are stacked down the rail at exactly equal spacing, separated by short thin grey-gold divider lines; each entry is a painted icon centred above an ivory Cinzel capital label: "FAMILY" (a gold crown set with red jewels), "COLLECT" (a tied burlap sack), "INVENTORY" (a brown leather backpack), "SHOP" (a red-and-white striped market tent), "ARMY" (a gold Spartan-style helmet with a red crest), "ATTACK" (two crossed steel swords with gold hilts), "KINGDOM" (a small sand-stone castle tower with red pennants), "COURT" (a small gilded throne with a crimson velvet seat). The "COURT" entry is selected: its whole cell is a glowing crimson plate with a gold rim and a small gold arrowhead on its right edge pointing into the content; every other entry sits on the plain navy rail. At the very bottom of the rail, under the eighth entry, is a round ornate gold seal medallion with a crimson centre bearing a small golden hourglass, above an EMPTY small dark plaque. Along the very top of the content area, right of the rail, three dark rounded pills with thin antique-gold borders sit side by side with even gaps: the first holds a gold coin, the number "493.48M" and a small square gold-bronze button with a white plus sign; the second a faceted blue diamond, "127" and the same plus button; the third a yellow lightning bolt, "513/513" and the same plus button.
```

### SHELL-ATTACK (menüde ATTACK yanık)

```text
SHELL — The left 17% of the screen width is a full-height dark navy navigation rail with a subtle vertical texture and a thin antique-gold line down its right edge. At the top of the rail sits a round crimson portrait medallion framed by a gold laurel wreath with a small gold crown on top, showing a handsome young lord with dark wavy hair and a crimson collar; under it a small dark-red plaque with a gold rim shows "33". Below the medallion, eight navigation entries are stacked down the rail at exactly equal spacing, separated by short thin grey-gold divider lines; each entry is a painted icon centred above an ivory Cinzel capital label: "FAMILY" (a gold crown set with red jewels), "COLLECT" (a tied burlap sack), "INVENTORY" (a brown leather backpack), "SHOP" (a red-and-white striped market tent), "ARMY" (a gold Spartan-style helmet with a red crest), "ATTACK" (two crossed steel swords with gold hilts), "KINGDOM" (a small sand-stone castle tower with red pennants), "COURT" (a small gilded throne with a crimson velvet seat). The "ATTACK" entry is selected: its whole cell is a glowing crimson plate with a gold rim and a small gold arrowhead on its right edge pointing into the content; every other entry sits on the plain navy rail. At the very bottom of the rail, under the eighth entry, is a round ornate gold seal medallion with a crimson centre bearing a small golden hourglass, above an EMPTY small dark plaque. Along the very top of the content area, right of the rail, three dark rounded pills with thin antique-gold borders sit side by side with even gaps: the first holds a gold coin, the number "493.48M" and a small square gold-bronze button with a white plus sign; the second a faceted blue diamond, "127" and the same plus button; the third a yellow lightning bolt, "513/513" and the same plus button.
```

### SHELL-KINGDOM (menüde KINGDOM yanık)

```text
SHELL — The left 17% of the screen width is a full-height dark navy navigation rail with a subtle vertical texture and a thin antique-gold line down its right edge. At the top of the rail sits a round crimson portrait medallion framed by a gold laurel wreath with a small gold crown on top, showing a handsome young lord with dark wavy hair and a crimson collar; under it a small dark-red plaque with a gold rim shows "33". Below the medallion, eight navigation entries are stacked down the rail at exactly equal spacing, separated by short thin grey-gold divider lines; each entry is a painted icon centred above an ivory Cinzel capital label: "FAMILY" (a gold crown set with red jewels), "COLLECT" (a tied burlap sack), "INVENTORY" (a brown leather backpack), "SHOP" (a red-and-white striped market tent), "ARMY" (a gold Spartan-style helmet with a red crest), "ATTACK" (two crossed steel swords with gold hilts), "KINGDOM" (a small sand-stone castle tower with red pennants), "COURT" (a small gilded throne with a crimson velvet seat). The "KINGDOM" entry is selected: its whole cell is a glowing crimson plate with a gold rim and a small gold arrowhead on its right edge pointing into the content; every other entry sits on the plain navy rail. At the very bottom of the rail, under the eighth entry, is a round ornate gold seal medallion with a crimson centre bearing a small golden hourglass, above an EMPTY small dark plaque. Along the very top of the content area, right of the rail, three dark rounded pills with thin antique-gold borders sit side by side with even gaps: the first holds a gold coin, the number "493.48M" and a small square gold-bronze button with a white plus sign; the second a faceted blue diamond, "127" and the same plus button; the third a yellow lightning bolt, "513/513" and the same plus button.
```

### SHELL-ARMY (menüde ARMY yanık)

```text
SHELL — The left 17% of the screen width is a full-height dark navy navigation rail with a subtle vertical texture and a thin antique-gold line down its right edge. At the top of the rail sits a round crimson portrait medallion framed by a gold laurel wreath with a small gold crown on top, showing a handsome young lord with dark wavy hair and a crimson collar; under it a small dark-red plaque with a gold rim shows "33". Below the medallion, eight navigation entries are stacked down the rail at exactly equal spacing, separated by short thin grey-gold divider lines; each entry is a painted icon centred above an ivory Cinzel capital label: "FAMILY" (a gold crown set with red jewels), "COLLECT" (a tied burlap sack), "INVENTORY" (a brown leather backpack), "SHOP" (a red-and-white striped market tent), "ARMY" (a gold Spartan-style helmet with a red crest), "ATTACK" (two crossed steel swords with gold hilts), "KINGDOM" (a small sand-stone castle tower with red pennants), "COURT" (a small gilded throne with a crimson velvet seat). The "ARMY" entry is selected: its whole cell is a glowing crimson plate with a gold rim and a small gold arrowhead on its right edge pointing into the content; every other entry sits on the plain navy rail. At the very bottom of the rail, under the eighth entry, is a round ornate gold seal medallion with a crimson centre bearing a small golden hourglass, above an EMPTY small dark plaque. Along the very top of the content area, right of the rail, three dark rounded pills with thin antique-gold borders sit side by side with even gaps: the first holds a gold coin, the number "493.48M" and a small square gold-bronze button with a white plus sign; the second a faceted blue diamond, "127" and the same plus button; the third a yellow lightning bolt, "513/513" and the same plus button.
```

### SHELL-FAMILY (menüde FAMILY yanık)

```text
SHELL — The left 17% of the screen width is a full-height dark navy navigation rail with a subtle vertical texture and a thin antique-gold line down its right edge. At the top of the rail sits a round crimson portrait medallion framed by a gold laurel wreath with a small gold crown on top, showing a handsome young lord with dark wavy hair and a crimson collar; under it a small dark-red plaque with a gold rim shows "33". Below the medallion, eight navigation entries are stacked down the rail at exactly equal spacing, separated by short thin grey-gold divider lines; each entry is a painted icon centred above an ivory Cinzel capital label: "FAMILY" (a gold crown set with red jewels), "COLLECT" (a tied burlap sack), "INVENTORY" (a brown leather backpack), "SHOP" (a red-and-white striped market tent), "ARMY" (a gold Spartan-style helmet with a red crest), "ATTACK" (two crossed steel swords with gold hilts), "KINGDOM" (a small sand-stone castle tower with red pennants), "COURT" (a small gilded throne with a crimson velvet seat). The "FAMILY" entry is selected: its whole cell is a glowing crimson plate with a gold rim and a small gold arrowhead on its right edge pointing into the content; every other entry sits on the plain navy rail. At the very bottom of the rail, under the eighth entry, is a round ornate gold seal medallion with a crimson centre bearing a small golden hourglass, above an EMPTY small dark plaque. Along the very top of the content area, right of the rail, three dark rounded pills with thin antique-gold borders sit side by side with even gaps: the first holds a gold coin, the number "493.48M" and a small square gold-bronze button with a white plus sign; the second a faceted blue diamond, "127" and the same plus button; the third a yellow lightning bolt, "513/513" and the same plus button.
```

### SHELL-COLLECT (menüde COLLECT yanık)

```text
SHELL — The left 17% of the screen width is a full-height dark navy navigation rail with a subtle vertical texture and a thin antique-gold line down its right edge. At the top of the rail sits a round crimson portrait medallion framed by a gold laurel wreath with a small gold crown on top, showing a handsome young lord with dark wavy hair and a crimson collar; under it a small dark-red plaque with a gold rim shows "33". Below the medallion, eight navigation entries are stacked down the rail at exactly equal spacing, separated by short thin grey-gold divider lines; each entry is a painted icon centred above an ivory Cinzel capital label: "FAMILY" (a gold crown set with red jewels), "COLLECT" (a tied burlap sack), "INVENTORY" (a brown leather backpack), "SHOP" (a red-and-white striped market tent), "ARMY" (a gold Spartan-style helmet with a red crest), "ATTACK" (two crossed steel swords with gold hilts), "KINGDOM" (a small sand-stone castle tower with red pennants), "COURT" (a small gilded throne with a crimson velvet seat). The "COLLECT" entry is selected: its whole cell is a glowing crimson plate with a gold rim and a small gold arrowhead on its right edge pointing into the content; every other entry sits on the plain navy rail. At the very bottom of the rail, under the eighth entry, is a round ornate gold seal medallion with a crimson centre bearing a small golden hourglass, above an EMPTY small dark plaque. Along the very top of the content area, right of the rail, three dark rounded pills with thin antique-gold borders sit side by side with even gaps: the first holds a gold coin, the number "493.48M" and a small square gold-bronze button with a white plus sign; the second a faceted blue diamond, "127" and the same plus button; the third a yellow lightning bolt, "513/513" and the same plus button.
```

### PAGE (oyunun üstüne açılan tam sayfa)

```text
PAGE — This is a full-screen page over the game: one tall page panel fills the phone screen with narrow margins (about 3% at the sides, 4% at the top and bottom) over a near-black dimmed backdrop in which no other interface is visible. The panel is dark slate navy with a heavy antique-gold filigree frame, chamfered corners and small corner ornaments. The page title sits centred at the top in large gold engraved Cinzel capitals; the body below it is a vertical list of sections and rows; a foot area at the bottom holds the buttons.
```

### SHEET (nesne sayfası — düz lacivert zemin)

```text
SHEET — This is an asset sheet, not a game screen. Separate objects are laid out on an invisible grid on a perfectly flat, uniform deep navy background (#0B151F) — no gradient, no vignette, no texture, no floor, no cast shadows on the background. Each object is centred in its own cell with at least 48 pixels of empty background on every side, never touching or overlapping another object or the image edge. Every object is fully visible, lit from the upper left with a crisp rim light so its outline separates cleanly from the background, painted in the style described, with clean edges. No labels, captions, numbers or grid lines unless a word is given in double quotes.
```

### SHEET-TEAL (metal nesneler için düz teal zemin)

```text
SHEET — This is an asset sheet, not a game screen. Separate objects are laid out on an invisible grid on a perfectly flat, uniform muted teal background (#2D6E6E) — no gradient, no vignette, no texture, no floor, no cast shadows on the background. Each object is centred in its own cell with at least 48 pixels of empty background on every side, never touching or overlapping another object or the image edge. Every object is fully visible, lit from the upper left, painted in the style described, with clean edges. No labels, captions, numbers or grid lines.
```

### TEXT RULE

```text
TEXT RULE — Spell every word shown in double quotes exactly as written, in the typeface described, and write no other text, letters, numbers or symbols anywhere in the image. Every element described as EMPTY contains no letters, digits or symbols at all — only the plain surface of the plate, field, badge or window.
```

### AVOID

```text
AVOID — No flat vector UI, no cartoon, anime or chibi style, no neon, no sci-fi or modern elements, no modern fonts, no misspelled, invented or gibberish words, no extra labels, buttons or numbers that were not described, no watermark, signature or logo, no photographic realism, no blur on the interface, no panels cut off by the image edge, no uneven spacing between repeated elements.
```

---
## 3. Parti 1 — Saray, mağaza, posta (Dalga 1–2)

Bu parti satın alma dalgasını ve yeni 8 girişli menüyü açar; **önce bu parti**.

- [ ] 1.1 `court.png`
- [ ] 1.2 `store.png`
- [ ] 1.3 `store_2.png`
- [ ] 1.4 `offers.png`
- [ ] 1.5 `offers_popup.png`
- [ ] 1.6 `mail.png`
- [ ] 1.7 `favour.png`
- [ ] 1.8 `wardrobe.png`
- [ ] 1.9 `rewards_sheet.png` (S1)
- [ ] 1.10 `ui_bits_sheet.png` (S2)
- [ ] 1.11 `diamond_packs_large.png` (S3)
- [ ] 1.12 `frames_cosmetic_a.png` (S4a)
- [ ] 1.13 `frames_cosmetic_b.png` (S4b)
- [ ] 1.14 `plates_sheet.png` (R9)

### 1.1 `court.png` — Saray (COURT) ekranı

**Tuval:** 9:16, ≥1080×1920 → 941×1672 · **Sıra:** STYLE → SHELL-COURT → BODY → TEXT RULE → AVOID · **Dalga:** 1–2

**Ne için:** Sol menünün yeni 8. girişi COURT'un ana ekranı: Mağaza, Sezon Kartı,
Etkinlikler, Posta, Sandıklar ve Teklifler buradaki altı karttan açılır. Bu tablo
aynı zamanda **8 girişli menünün kanonik kaynağıdır** — tüm menü ikonları ve COURT'un
kızıl plakası buradan yeniden kesilir.

```text
BODY — The content area (right of the rail, below the pills) shows the ROYAL COURT screen. Top quarter: a painted throne-hall header — a gilded throne on a raised dais under a crimson velvet canopy, a tall crimson banner with a golden lion, white marble columns, warm candlelight, softly blurred courtiers in rich robes, and tall arched windows showing the white castle with red roofs in afternoon light; the header fades into the navy ground at its bottom edge. Over the lower left of the header, the large gold engraved title "ROYAL COURT" and beneath it, in parchment serif, "Treasures, tidings and favours of the crown." Below the header, six equal cards in two columns and three rows fill the content down to just above the foliage at the bottom, with even gutters. Each card is a navy panel with an antique-gold filigree frame and chamfered corners; its upper two-thirds is a painted scene, then its title in gold engraved capitals centred on a thin dark band, then an EMPTY dark inset status plate across the bottom of the card; on each card's top-right corner sits an EMPTY small red gold-rimmed circle badge. The cards, left to right and top to bottom: "STORE" — an open iron-bound chest overflowing with faceted blue diamonds on crimson velvet, lit from above; "SEASON PASS" — a long crimson banner with gold laurel embroidery hanging over a sunny tournament field with striped pavilions; "EVENTS" — a festive joust with colourful pennants and glowing paper lanterns at dusk; "ROYAL MAIL" — a wooden writing desk with sealed letters, red wax seals, a quill and a lit candle; "CHESTS" — a sturdy wooden cart at the castle gate carrying a small iron-banded chest that glows softly at its seams; "OFFERS" — a gilded merchant stand with blue potion bottles, a small velvet pouch of diamonds and a small gold crown in a shaft of light, a crimson ribbon draped across it.
```

**Birebir kelimeler:** "ROYAL COURT", "Treasures, tidings and favours of the crown.", "STORE", "SEASON PASS", "EVENTS", "ROYAL MAIL", "CHESTS", "OFFERS" (+ kabuk kelimeleri).
**EMPTY:** altı durum plakası, altı kırmızı rozet dairesi, menü dibindeki mührün altındaki plaka.
**Kesim notu:** `court/header` [155, 0, 786, ~430] (haplar inpaint); `court/card_store|pass|events|mail|chests|offers` ~372×360 (durum plakası silinir, rozet alanı yumuşatılır); menü: `nav/<8 giriş>` darkkey (yükseklik ≤ ~164), `nav/active_court` (poligon maske, 148×~162), `chrome/rail_divider` 110×8, `chrome/rail_bottom` 160×112, `chrome/event_seal` 80×80, `chrome/event_plaque` ~150×24.

### 1.2 `store.png` — Kraliyet Mağazası (üst kısım)

**Tuval:** 9:16, ≥1080×1920 → 941×1672 · **Sıra:** STYLE → SHELL-COURT → BODY → TEXT RULE → AVOID · **Dalga:** 1

**Ne için:** Satın alma mağazasının üst bölümü: başlangıç paketi, Crown Patronage
(VIP abonelik) kartı ve altı elmas paketi. Adil kural gereği hiçbir kartta
satılık altın/güç imgesi yok — elmas, iksir, taç.

```text
BODY — The content area (right of the rail, below the pills) shows the top of the ROYAL STORE. Header (top ~22%): a treasure vault with heaps of faceted blue diamonds in open chests and on velvet cushions, tall gold candlesticks and a crimson curtain, warm light; over the lower left of the header the large gold engraved title "ROYAL STORE" and beneath it, in parchment serif, "Comforts for a busy lord." Just under the pills at the top left of the content, a small navy back button with a gold left chevron and the word "COURT". Below the header, top to bottom: (1) a wide featured card across the content: "STARTER CRATE" in gold capitals at its top left, a gold-banded wooden crate with its lid ajar holding three blue potion bottles and a small heap of blue diamonds on the left, a small hourglass beside an EMPTY timer plate at the card's top right, three EMPTY square content tiles in a row in the middle, and an EMPTY emerald-green price plate at the bottom right; (2) a second wide card: a jewelled gold crown resting on a crimson velvet cushion with gold tassels on the left, an EMPTY title plate, three short EMPTY perk lines each led by a tiny gold crown bullet, and an EMPTY emerald-green price plate on the right; (3) under a small gold section heading "DIAMONDS" with thin gold flourishes on both sides, six diamond pack cards in three columns and two rows; each card is a navy panel with a thin gold frame showing one diamond container above an EMPTY amount plate and an EMPTY emerald-green price plate: card 1 a small tied leather pouch with a few diamonds spilling out; card 2 a small wooden casket with its lid open, half full of diamonds; card 3 a brass-bound coffer brimming with diamonds; card 4 an iron strongbox spilling diamonds onto the stone floor; card 5 a large overflowing treasure chest of diamonds; card 6 a royal vault chest with a crown crest on its lid and diamonds radiating light. Card 3 has a crimson corner ribbon across its top-left corner reading "MOST POPULAR"; card 6 has a crimson corner ribbon reading "BEST VALUE". Card 1 carries, in its top-right corner, a round red wax seal with a large gold "×2" in its centre and the words "FIRST PURCHASE" in tiny gold capitals around its rim. At the bottom of the content, above the foliage, a quiet dark navy plate with a thin steel border reading "RESTORE PURCHASES".
```

**Birebir kelimeler:** "ROYAL STORE", "Comforts for a busy lord.", "COURT", "STARTER CRATE", "DIAMONDS", "MOST POPULAR", "BEST VALUE", "×2", "FIRST PURCHASE", "RESTORE PURCHASES".
**EMPTY:** zamanlayıcı plakası, 3 içerik kutusu, başlık/perk satırları, 6 miktar plakası, 8 yeşil fiyat plakası.
**Kesim notu:** `store/header` [155, 0, 786, ~380]; `store/back` (dokunma alanı 200×95); `store/starter_card`, `store/patron_card` (yazı alanları silinir); `store/pack_card` (bir kart çerçevesi, boş); `icons/pack_1..6` (rect + maske, ~150–200 px); `store/ribbon_most_popular`, `store/ribbon_best_value`; `store/first_purchase_seal` ~90 px; `store/price_plate` ~192×56 (boş yeşil); `store/restore_plate`; "DIAMONDS" başlığı sabit kesilir.

### 1.3 `store_2.png` — Kraliyet Mağazası (aşağı kaydırılmış)

**Tuval:** 9:16, ≥1080×1920 → 941×1672 · **Sıra:** STYLE → SHELL-COURT → BODY → TEXT RULE → AVOID · **Dalga:** 1

**Ne için:** Mağazanın alt bölümleri: Royal Stipend (aylık kart), günlük fırsatlar
(biri her gün bedava), konfor paketleri (Kâhya = otomatik toplayıcı, Quartermaster
= +50 çanta), ödüllü reklam (Haberci), Royal Largesse ve alt bağlantılar. Kâhya
**altın değil**, mektup ve sandık topluyor olarak boyanır.

```text
BODY — The content area (right of the rail, below the pills) shows the lower part of the ROYAL STORE, scrolled down so that no header is visible: panels begin directly under the pills. Top to bottom, each section led by a small gold section heading with thin gold flourishes: (1) "ROYAL STIPEND" — a wide card: a rolled royal charter tied with a gold ribbon and sealed with red wax lying beside a small parchment calendar marked with thirty little squares, an EMPTY title plate, an EMPTY line plate, a green plate reading "CLAIM TODAY" and an EMPTY emerald-green price plate; (2) "DAILY DEALS" — a small hourglass with an EMPTY timer plate at the right end of the heading, then four small deal cards in a row: the first holds a crimson gift box tied with a gold ribbon bow and a green plate reading "FREE"; the second holds two blue potion bottles; the third a sealed parchment charter bearing a small blue shield emblem (a protection charter); the fourth a small empty gilded portrait frame; each of the last three has an EMPTY price plate with a small blue diamond on its left; (3) "COMFORTS" — two cards side by side: "THE STEWARD", a kindly grey-bearded steward in a dark green velvet coat holding a large ring of iron keys and an open ledger, beside him a neat stack of sealed letters and a small closed chest he has gathered; and "THE QUARTERMASTER", a covered supply wagon packed with leather satchels, bags and bedrolls; each with an EMPTY price plate; (4) "HERALD'S TIDINGS" — a wide card: a herald in a crimson tabard raising a long gold trumpet with a hanging crimson banner, an EMPTY line plate, an EMPTY count plate and a green plate reading "WATCH"; (5) "ROYAL LARGESSE" — a wide card: an ornate open gift chest spilling blue diamonds and ribbons under a hanging kingdom banner with a golden lion, an EMPTY line plate and an EMPTY emerald-green price plate; (6) at the very bottom, three small quiet navy plates in a row reading "RESTORE PURCHASES", "TERMS" and "PRIVACY".
```

**Birebir kelimeler:** "ROYAL STIPEND", "CLAIM TODAY", "DAILY DEALS", "FREE", "COMFORTS", "THE STEWARD", "THE QUARTERMASTER", "HERALD'S TIDINGS", "WATCH", "ROYAL LARGESSE", "RESTORE PURCHASES", "TERMS", "PRIVACY".
**EMPTY:** tüm başlık, satır, sayaç ve fiyat plakaları.
**Kesim notu:** kart çerçeveleri (yazılar silinir); resimler `store/stipend_art`, `icons/gift_box`, `store/steward_art`, `store/quartermaster_art`, `store/herald_art`, `store/largesse_art`, `icons/protection_charter`; kelimeli plakalar "FREE", "CLAIM TODAY", "WATCH", "TERMS", "PRIVACY" ayrı kesilir; bölüm başlıkları sabit kesilir.

### 1.4 `offers.png` — Teklifler ekranı

**Tuval:** 9:16, ≥1080×1920 → 941×1672 · **Sıra:** STYLE → SHELL-COURT → BODY → TEXT RULE → AVOID · **Dalga:** 1

**Ne için:** Süreli, tetiklenen tekliflerin listelendiği COURT ▸ OFFERS ekranı
(enerji bitti, level 10/20/30, yenilgi sonrası, çanta dolu).

```text
BODY — The content area (right of the rail, below the pills) shows the ROYAL OFFERS screen. Header (top ~20%): a gilded merchant stand in a shaft of warm light with blue potion bottles, velvet pouches of diamonds and a small crown, crimson drapes and a striped awning; over the lower left the large gold engraved title "ROYAL OFFERS" and beneath it, in parchment serif, "For a limited time only." A small navy back button with a gold left chevron and the word "COURT" sits under the pills at the top left of the content. Below the header, three wide offer cards are stacked with even gaps. Each card: a crimson banner strip across its top holding an EMPTY title plate; a large painted bundle picture filling the left third; three EMPTY square content tiles in a row; an EMPTY value plate with a thin diagonal gold line struck through it; a small hourglass beside an EMPTY timer plate; and an EMPTY emerald-green price plate at the bottom right. Card 1's bundle: a glowing wooden crate with blue potions and a small heap of diamonds, with a crimson corner ribbon reading "BEST VALUE"; card 2's bundle: three blue potion bottles on a velvet cushion beside a small pouch of diamonds; card 3's bundle: a sealed protection charter with a blue shield emblem beside a small pouch of diamonds.
```

**Birebir kelimeler:** "ROYAL OFFERS", "For a limited time only.", "COURT", "BEST VALUE".
**EMPTY:** başlık, 9 içerik kutusu, 3 üstü çizili değer, 3 zamanlayıcı, 3 fiyat plakası.
**Kesim notu:** `offers/header`; `offers/card` (boş çerçeve, banner şeridi dahil); `offers/bundle_1..3` (rect ~250×250); `offers/strike_plate`.

### 1.5 `offers_popup.png` — Teklif açılır penceresi

**Tuval:** 9:16, ≥1080×1920 → 941×1672 · **Sıra:** STYLE → BODY → TEXT RULE → AVOID (kabuk yok) · **Dalga:** 1

**Ne için:** Doğru anda (sakin bir anda, oturumda bir kez) çıkan teklif penceresi.

```text
BODY — A modal offer window over the game: the whole image behind the window is a near-black dimmed backdrop in which no interface or text is visible. Centred, a modal panel about 82% of the image width and about 62% of its height: dark slate navy with a heavy antique-gold filigree frame and chamfered corners. Across its top, a crimson banner with a gold rim holding an EMPTY title plate; at the panel's top-right corner, a small round gold close button with a white "X". In the upper middle, a large painted bundle picture: an open ornate chest holding three blue potion bottles, a small heap of blue diamonds and a folded crimson banner, bathed in light rays; a crimson corner ribbon reading "BEST VALUE" across the picture's top-left corner. Below the picture, three EMPTY square content tiles in a row; then a small hourglass beside an EMPTY timer plate; then a large EMPTY emerald-green price plate centred; under it a quiet dark navy plate reading "LATER".
```

**Birebir kelimeler:** "X", "BEST VALUE", "LATER".
**EMPTY:** başlık, 3 kutu, zamanlayıcı, fiyat plakası.
**Kesim notu:** `offers/popup_frame` (9-patch köşeler korunur); `offers/popup_banner`; `offers/popup_bundle` (~420×320); `offers/close` 64×64; `offers/later_plate`.

### 1.6 `mail.png` — Kraliyet Postası

**Tuval:** 9:16, ≥1080×1920 → 941×1672 · **Sıra:** STYLE → SHELL-COURT → BODY → TEXT RULE → AVOID · **Dalga:** 0–1

**Ne için:** Posta kutusu: sezon ödülleri, telafi hediyeleri, Largesse, referans,
duyurular. Mektup satırları, mühür türleri, açık mektup kartı ve boş kutu resmi.

```text
BODY — The content area (right of the rail, below the pills) shows ROYAL MAIL. Header (top ~20%): a candle-lit writing room — a wooden desk with a pile of sealed letters, red wax seals, a brass seal stamp, an inkwell and a quill, and a window with a view of the castle at dusk; over the lower left the large gold engraved title "ROYAL MAIL" and beneath it, in parchment serif, "Letters from the crown and your allies." A small navy back button with a gold left chevron and the word "COURT" sits under the pills. Below the header, six letter rows are stacked with small even gaps; each row is a navy plate with a thin steel border: on its left a folded cream envelope; to the right an EMPTY sender plate, an EMPTY subject plate beneath it and an EMPTY date plate; at the far right of the row, three tiny attachment icons in a line: a small gold coin, a small blue diamond and a small blue potion bottle. Rows 1 to 3 are unread letters: the envelope is closed with an unbroken, faintly glowing red wax seal — row 1's seal stamped with a crown, row 2's seal stamped with a golden lion banner, row 3's seal stamped with two clasped hands; a small hourglass icon sits beside row 2's date plate. Rows 4 to 6 are read letters: the envelope is open with a broken, dimmer seal and the whole row is slightly dimmed. Under the rows, a green plate reading "CLAIM ALL", centred. Below that, an open letter card on the navy ground: a large sheet of cream parchment with deckled edges and a red wax seal at its top centre, an EMPTY text area, a row of three EMPTY attachment tiles with thin gold frames, and a green plate reading "CLAIM". In the lower right corner of the content, a small separate framed vignette of an empty writing desk with a quill standing in an inkwell and no letters on it.
```

**Birebir kelimeler:** "ROYAL MAIL", "Letters from the crown and your allies.", "COURT", "CLAIM ALL", "CLAIM".
**EMPTY:** gönderen/konu/tarih plakaları, mektup metin alanı, 3 ek kutusu.
**Kesim notu:** `mail/header`; `mail/row` (9-patch, yazılar silinir); `mail/envelope_closed_crown|banner|hands`, `mail/envelope_open` (~96×72); `icons/hourglass_small`; `mail/claim_all` 248×68; `mail/letter` (parşömen 9-patch); `mail/claim` 172×58; `mail/empty_desk` ~300×220.

### 1.7 `favour.png` — Crown'un İltifatı (VIP) sayfası

**Tuval:** 9:16, ≥1080×1920 → 941×1672 · **Sıra:** STYLE → PAGE → BODY → TEXT RULE → AVOID · **Dalga:** 1

**Ne için:** Crown Patronage aboneliği (abone ol / yönet) ve harcamaya göre VIP
1–10 rütbe yolu. **Herkese görünen küçük VIP mührü** (numarasız) bu tablodan kesilir.

```text
BODY — The page title "THE CROWN'S FAVOUR" at the top. Under it, inside the page frame, a painted header vignette: a jewelled gold crown on a crimson velvet cushion on a white marble plinth in a beam of warm gold light. Section heading "CROWN PATRONAGE": a perk card with five EMPTY perk lines, each led by a small gold crown bullet; an EMPTY price plate; a large emerald-green plate reading "SUBSCRIBE" and, beside it, a quiet dark navy plate reading "MANAGE"; below them a small EMPTY fine-print area. Section heading "ROYAL FAVOUR", and beside this heading a small round crimson wax seal with a tiny gold crown above the letters "VIP" and no number. Under it, a horizontal rank track: a long gold-rimmed dark bar with its left third filled with gold, and ten small shield-shaped badges evenly spaced along it; each badge is a crimson enamel shield with a gold rim and an EMPTY numeral plate in its centre; the first four badges are lit and gleaming, the rest are dim. Under the track, an EMPTY progress plate. At the foot of the page, a quiet dark navy plate reading "CLOSE".
```

**Birebir kelimeler:** "THE CROWN'S FAVOUR", "CROWN PATRONAGE", "SUBSCRIBE", "MANAGE", "ROYAL FAVOUR", "VIP", "CLOSE".
**EMPTY:** perk satırları, fiyat, ince yazı alanı, 10 rozet numarası, ilerleme plakası.
**Kesim notu:** `favour/header_art`; `favour/perk_bullet` ~32 px; `favour/subscribe` 326×90; `favour/manage` 248×68; `icons/vip_seal` ~56 px (her yerde, herkese görünür); `favour/vip_badge_lit|dim` ~64×72 (numara canlı yazı); `favour/rank_track` + `favour/rank_fill`.

### 1.8 `wardrobe.png` — SPLENDOUR (kozmetik dolabı) sayfası

**Tuval:** 9:16, ≥1080×1920 → 941×1672 · **Sıra:** STYLE → PAGE → BODY → TEXT RULE → AVOID · **Dalga:** 1

**Ne için:** Kozmetik dolabı: çerçeve, unvan, isim rengi ve arma sekmeleri; sahip
olunan/kuşanılan/kilitli/satın alınabilir durumlar.

```text
BODY — The page title "SPLENDOUR" at the top, over a painted vignette inside the page frame: a dressing room with a wooden mannequin wearing a crimson fur-trimmed cloak and a small crown on a stand beside a tall mirror. Under it, four tab chips in a row: "FRAMES" (selected: a glowing crimson plate with a gold rim), "TITLES", "COLOURS" and "CRESTS" (dark navy plates with thin copper-gold edges and ivory capitals). Below, a grid of nine cosmetic tiles in three columns and three rows; each tile is a navy tile with a thin steel border holding a decorative portrait frame whose window is EMPTY dark velvet (no face), and an EMPTY name plate under it: an oak-leaf frame, a bronze laurel frame, a gilded laurel frame, a gold frame with a small star, a gold frame with a small crown, a radiant sunburst frame, a silver frame with clasped hands at its base, an iron frame with a key and wax seal, a bronze frame with a rising sun. One tile carries a small gold tick wax seal in its corner (equipped), one carries a small padlock (locked), one carries an EMPTY price plate with a small blue diamond. Below the grid, a row of samples: an unrolled parchment title scroll plate (EMPTY), a small blank oval enamel colour chip in white-gold, and three small heraldic shields — a gilded stag on green, an imperial black eagle on gold, and a crimson banner charged with a gold star. At the foot, a green plate reading "EQUIP" and a quiet dark navy plate reading "CLOSE".
```

**Birebir kelimeler:** "SPLENDOUR", "FRAMES", "TITLES", "COLOURS", "CRESTS", "EQUIP", "CLOSE".
**EMPTY:** 9 isim plakası, fiyat plakası, unvan parşömeni, renk çipi.
**Kesim notu:** `wardrobe/header_art`; `wardrobe/chip_active|idle` (etiketler ayrıca darkkey); `wardrobe/tile` (boş); `wardrobe/title_scroll` ~260×56; `wardrobe/colour_chip` ~80×40 (renk kodla tonlanır); `icons/tick_seal`, `icons/padlock`; armalar `icons/crest_stag_gilt`, `icons/crest_eagle_imperial`, `icons/crest_banner_star` 91×120. (Çerçevelerin kendisi S4 sayfalarından kesilir.)

### 1.9 `rewards_sheet.png` — S1: sandıklar, hediye, kasa, taç, kupalar

**Tuval:** 9:16, ≥1080×1920 → 941×1672 · **Sıra:** STYLE → SHEET → BODY → TEXT RULE → AVOID · **Dalga:** 1–4

**Ne için:** Mağaza, posta, günlük/haftalık sandık, sıralama ödülleri ve teslimat
törenlerinde kullanılan tekil nesneler. Kit'te şu an bağımsız sandık/hediye/kupa yok.

```text
BODY — Fifteen objects in a grid of three columns and five rows, all at a similar generous size. Row 1: a wooden chest with iron bands and a round lock, closed; the same wooden chest open, with a soft warm glow rising from inside; a silver chest with engraved panels and a lion lock, closed. Row 2: the same silver chest open and glowing with pale light; a royal gold chest with a small crown on its lid and red gems on its corners, closed; the same royal gold chest open, with golden light rays bursting upward. Row 3: a crimson gift box tied with a gold ribbon bow, closed; the same gift box open, with golden light and sparkles rising from it; a starter crate — a gold-banded wooden crate with its lid ajar and three blue potion bottles inside. Row 4: a jewelled gold crown resting on a crimson velvet cushion with gold tassels; a gold trophy cup with two handles on a small round base; a silver trophy cup of the same shape. Row 5: a bronze trophy cup of the same shape; a small closed wooden chest with a steel sword hilt strapped to its lid; a small ornate iron key with a crown-shaped bow.
```

**Birebir kelimeler:** yok. **EMPTY:** yok.
**Kesim notu:** rect + maske (içleri koyu — darkkey değil), büyük boyanır küçük çizilir: sandıklar ~220×190 → `icons/chest_wood|silver|gold(_open)`, hediye ~170×170 → `icons/gift(_open)`, kasa ~240×190 → `icons/starter_crate`, taç ~200×170 → `icons/vip_crown`, kupalar ~150×200 → `icons/trophy_gold|silver|bronze`, `icons/gear_chest`, `icons/chest_key`.

### 1.10 `ui_bits_sheet.png` — S2: arayüz parçaları ve küçük ikonlar

**Tuval:** 9:16, ≥1080×1920 → 941×1672 · **Sıra:** STYLE → SHEET → BODY → TEXT RULE → AVOID · **Dalga:** 1–8

**Ne için:** Birçok ekranda ortak kullanılan küçük parçalar: kurdeleler, boş fiyat
plakaları, rozet balonu, etkinlik mührü, VIP mührü ve 72 px ikon seti.

```text
BODY — Twenty-nine objects in a grid of four columns and eight rows (the last row holds one object). Row 1: a crimson ribbon banner with forked ends and a gold edge reading "BEST VALUE"; a crimson ribbon banner of the same shape reading "MOST POPULAR"; a round red wax seal with a large gold "×2" in its centre and the words "FIRST PURCHASE" in tiny gold capitals around its rim; a small round crimson wax seal with a tiny gold crown above the letters "VIP". Row 2: an EMPTY dark rounded price pill with a thin gold border and a faceted blue diamond at its left end; an EMPTY dark rounded price pill with a thin gold border and a gold coin at its left end; an EMPTY emerald-green bevelled price plate with a gold rim; a small round red count bubble with a gold rim, EMPTY. Row 3: a round ornate gold seal medallion with a crimson centre bearing a small golden hourglass, glowing brightly (lit); the same seal medallion dull and unlit; a small gold tick inside a round gold wax seal; a small iron padlock. Row 4: an ornate iron key; a folded letter sealed with red wax; a brass hourglass with golden sand; a brass spyglass. Row 5: a small anvil with a hammer resting on it; two steel gauntlets clasped in a handshake; a small skull under a gold crown; two crossed crimson war banners on poles. Row 6: a folded parchment map with a brass compass on it; a small crimson pennant flag with a raised open hand embroidered in gold; a long gold herald trumpet; a lit gold five-pointed star. Row 7: an empty star socket (a dark recessed star outline with a thin gold rim); a small gold crown bullet; a round gold "i" information button; a round gold close button with a white "X". Row 8: a small gold right-pointing chevron.
```

**Birebir kelimeler:** "BEST VALUE", "MOST POPULAR", "×2", "FIRST PURCHASE", "VIP", "i", "X".
**EMPTY:** iki fiyat hapı, yeşil fiyat plakası, sayaç balonu.
**Kesim notu:** kurdeleler ~240×70 (`store/ribbon_*`); mühür ~110; `icons/vip_seal` ~56 (herkese görünen mühür); `ui/price_pill_diamond|coin` 190×56; `ui/price_plate` 192×56; `icons/count_bubble` 44; `chrome/event_seal(_idle)` 80; ikonlar 72 px darkkey (`icons/key`, `icons/letter`, `icons/hourglass`, `icons/spyglass`, `icons/anvil`, `icons/clasped_hands`, `icons/skull_crown`, `icons/war_banners`, `icons/map`, `icons/hand_flag`, `icons/trumpet`, `icons/star_on|off`, `icons/crown_bullet`, `icons/info`, `icons/close`, `icons/chevron_right`, `icons/tick_seal`, `icons/padlock`).

### 1.11 `diamond_packs_large.png` — S3: büyük elmas kapları

**Tuval:** 9:16, ≥1080×1920 → 941×1672 · **Sıra:** STYLE → SHEET → BODY → TEXT RULE → AVOID · **Dalga:** 1

**Ne için:** Teklif penceresi ve teslimat töreni için mağazadaki altı kabın büyük
çizimleri (mağaza kartlarındakilerle aynı tasarım).

```text
BODY — Six diamond containers in a grid of two columns and three rows, each large and richly detailed, all filled with faceted sky-blue diamonds that catch the light: (1) a small tied brown leather pouch with a few diamonds spilling out onto the ground; (2) a small wooden casket with brass corners, lid open, half full of diamonds; (3) a brass-bound oak coffer brimming with diamonds; (4) a heavy iron strongbox with rivets, lid open, spilling diamonds onto a stone floor; (5) a large overflowing wooden treasure chest of diamonds with a few loose diamonds around it; (6) a royal vault chest in gold and crimson enamel with a crown crest on its lid, packed with diamonds radiating soft blue light.
```

**Birebir kelimeler:** yok. **EMPTY:** yok.
**Kesim notu:** rect + maske, ~300×260 → `icons/pack_large_1..6`.

### 1.12 `frames_cosmetic_a.png` — S4a: kozmetik portre çerçeveleri (1/2)

**Tuval:** 9:16, ≥1080×1920 → 941×1672 · **Sıra:** STYLE → SHEET → BODY → TEXT RULE → AVOID · **Dalga:** 1

**Ne için:** Oyuncunun taktığı portre çerçeveleri; rakip kartında, profilde, sıralama
ve krallık satırlarında görünür. Her çerçeve iki biçimde: kare (kartlar/profil) ve
halka (satırlar/sohbet).

```text
BODY — Six decorative portrait frames, one per row, each shown twice side by side: on the left a large square frame, on the right a smaller round ring frame of the same design. The window inside every frame is EMPTY flat dark navy (no portrait, no face). Row 1: a frame of carved dark oak with acorns and oak leaves at the corners. Row 2: a bronze laurel-wreath frame. Row 3: a bright gold laurel frame set with small red and blue gems. Row 4: a gold frame with crimson enamel inlay and a small eight-pointed gold star at the top. Row 5: a gold frame with a small gold crown at the top and crimson velvet trim along its inner edge. Row 6: a gold frame with radiant sunburst rays fanning out behind it.
```

**Satırlar:** 1 Oak · 2 Laurel · 3 Gilded Laurel · 4 Founder's · 5 Patron's · 6 Aureole.
**Birebir kelimeler:** yok. **EMPTY:** 12 pencere.
**Kesim notu:** `hollow` modu; kare dış 160 / pencere 136 → `frames/<id>_square`, halka dış 96 / pencere 76 → `frames/<id>_ring` (büyük boyanır, küçük çizilir). id'ler: `oak`, `laurel`, `laurel_gilded`, `founder`, `patron`, `aureole`.

### 1.13 `frames_cosmetic_b.png` — S4b: kozmetik portre çerçeveleri (2/2)

**Tuval:** 9:16, ≥1080×1920 → 941×1672 · **Sıra:** STYLE → SHEET → BODY → TEXT RULE → AVOID · **Dalga:** 1–3

**Ne için:** Referans (Companion), level 30 teklifi (Thirtieth), 28 günlük takvim
7. gün (Loyal Vassal), Zafer Yolu L20 (Rising Lord), rehber bitişi (Heir) ve sezon
kartı (Royal Charter) çerçeveleri.

```text
BODY — Six decorative portrait frames, one per row, each shown twice side by side: on the left a large square frame, on the right a smaller round ring frame of the same design. The window inside every frame is EMPTY flat dark navy (no portrait, no face). Row 1: a polished silver frame with two clasped hands worked in relief at its base. Row 2: a gold frame with a small laurel at its top and three small gold stars set along its lower edge. Row 3: an iron frame with a small red wax seal and an iron key hanging from its lower edge. Row 4: a bronze frame with a rising sun at its top. Row 5: a silver frame with a small jewelled coronet at its top. Row 6: a gold frame wrapped with a crimson ribbon, a red wax seal at its lower right.
```

**Satırlar:** 1 Companion's · 2 Thirtieth · 3 Loyal Vassal · 4 Rising Lord · 5 Heir · 6 Royal Charter.
**Birebir kelimeler:** yok. **EMPTY:** 12 pencere.
**Kesim notu:** S4a ile aynı ölçüler; id'ler: `companion`, `thirtieth`, `loyal_vassal`, `rising_lord`, `heir`, `charter`.

### 1.14 `plates_sheet.png` — R9: boş düğme plakaları (yeniden boyama)

**Tuval:** 9:16, ≥1080×1920 → 941×1672 · **Sıra:** STYLE → SHEET → BODY → TEXT RULE → AVOID · **Dalga:** 1

**Ne için:** Oyunun yazı basılan tüm düğme plakaları. Şu an kızıl "tehlike"
plakası, yeşil plakanın renk kanalları değiştirilerek üretilmiş bir kopya; boş
COLLECT yüzü de kodla boyanıyor. Gerçek boyanmış plakalarla değişecek.

```text
BODY — Sixteen EMPTY button plates with no words, arranged in rows by size; every plate is a bevelled rectangle with slightly chamfered corners, a thin gold rim, a soft top highlight and a gentle drop shadow, exactly like the game's buy buttons. Row 1: a wide emerald-green plate, a wide crimson plate. Row 2: a wide dark navy quiet plate with a thin steel border (same wide proportions, about 3.6 to 1). Row 3: a medium emerald-green plate, a medium crimson plate, a medium dark navy quiet plate (about 3.6 to 1). Row 4: a collect-size emerald-green plate, a collect-size crimson plate, a collect-size dark navy quiet plate (about 2.3 to 1). Row 5: a buy-size emerald-green plate, a buy-size crimson plate, a buy-size dark navy quiet plate (about 3 to 1). Row 6: a small emerald-green plate, a small crimson plate, a small dark navy quiet plate (about 2.8 to 1). Row 7: a collect-size crimson plate that looks dimmed and exhausted, with a slightly darker, desaturated face (the "no energy" state).
```

**Birebir kelimeler:** yok. **EMPTY:** 16 plakanın hepsi.
**Kesim notu:** hedef boylar (büyük boyanır, küçük çizilir): geniş 326×90 (`family/btn_upgrade_plate` ailesi), orta 248×68, collect 178×76 (`collect/collect_button_empty` yerine kızıl "no energy"), buy 172×58 (`shop/buy_plate`, `shop/danger_plate` gerçek kızıl ile değişir), küçük 122×43 (`inventory/btn_equip_plate`, `btn_sell_plate`). `tools/make_button_plates.gd` ve `make_empty_button.gd` yerine bu kesimler kullanılır.

---
## 4. Parti 2 — Günlük döngü, etkinlik, sezon (Dalga 2–4)

- [ ] 2.1 `chests.png`
- [ ] 2.2 `calendar.png`
- [ ] 2.3 `deeds.png`
- [ ] 2.4 `road.png`
- [ ] 2.5 `guide.png`
- [ ] 2.6 `events.png`
- [ ] 2.7 `collect_events.png`
- [ ] 2.8 `events_kit.png`
- [ ] 2.9 `event_themes.png`
- [ ] 2.10 `pass.png`
- [ ] 2.11 `family_storehouse.png`
- [ ] 2.12 `frames_noble.png` (S5a)
- [ ] 2.13 `frames_events.png` (S5b)
- [ ] 2.14 `titles_sheet.png` (S5c)
- [ ] 2.15 `ftue_sheet.png` (S6)
- [ ] 2.16 `reward_icons.png` (S8)

### 2.1 `chests.png` — Vergi Arabası (COURT ▸ CHESTS)

**Tuval:** 9:16, ≥1080×1920 → 941×1672 · **Sıra:** STYLE → SHELL-COURT → BODY → TEXT RULE → AVOID · **Dalga:** 3

**Ne için:** Her 4 saatte bir dolan **ücretsiz** sandık (en çok 3 birikir). Hazır,
boş, yolda ve açılış halleri; oranlar (i) düğmesiyle açılır.

```text
BODY — The content area (right of the rail, below the pills) shows THE TAX CART. Header (top ~20%): the castle gate at golden hour with a cobbled road winding in; over the lower left the large gold engraved title "THE TAX CART" and beneath it, in parchment serif, "The crown's cart returns every four hours." A small navy back button with a gold left chevron and the word "COURT" sits under the pills. Main: a large framed scene filling the middle of the content in an antique-gold frame: a sturdy wooden cart with iron-rimmed wheels stands at the gate; on it a small iron-banded chest glows softly with golden light leaking from its seams; a tired courier in a green hood leans on the wheel. Under the scene: a row of three small cart-shaped stock pips, two lit gold and one dim; a brass hourglass beside an EMPTY timer plate; a large emerald-green plate reading "OPEN"; and a small round gold "i" button. Below that, a strip of three smaller framed vignettes of the same cart, each above an EMPTY caption plate: the cart empty with a tarp folded in its bed in dusk light; the cart rolling up the road in the far distance; the chest's lid thrown open with light rays, a few gold coins, a blue diamond, a blue potion bottle and a rolled scroll bursting upward in a spray of sparkles.
```

**Birebir kelimeler:** "THE TAX CART", "The crown's cart returns every four hours.", "COURT", "OPEN", "i".
**EMPTY:** zamanlayıcı ve 3 başlık plakası.
**Kesim notu:** `chests/header`; `chests/cart_ready` ~760×420 (ana sahne); `chests/cart_idle|arriving|opening` ~240×180 (büyük boyanır); `chests/pip_on|off` ~48; `chests/open` 248×68.

### 2.2 `calendar.png` — 28 günlük giriş takvimi

**Tuval:** 9:16, ≥1080×1920 → 941×1672 · **Sıra:** STYLE → PAGE → BODY → TEXT RULE → AVOID · **Dalga:** 3

**Ne için:** Günlük ödül sayfası (elmas hapından da açılır): 28 kare, 7/14/21/28.
günler taç günü, seri alevi, seri kırılınca kurtarma (elmas veya af mührü) ve
"bu hafta" sandık çubuğu.

```text
BODY — The page title "DAILY REWARDS" at the top, over a small painted vignette inside the page frame: a royal steward presenting a velvet tray at dawn in a castle hall. Under it, a small gold brazier with a bright flame beside an EMPTY streak plate. Then a calendar grid of twenty-eight square tiles in four rows of seven, evenly spaced. Most tiles are dark navy with a thin steel border, a small painted reward in the centre and an EMPTY day-number plate along the bottom; the small rewards alternate between a blue diamond, a small leather coin purse, a small blue potion flask, a rolled scroll with a gold ribbon, and a tiny wooden cart. The first five tiles of the first row are already taken: dimmed, each with a gold tick wax seal over it. The sixth tile of the first row is today: a glowing gold frame with a soft light. The last tile of every row (the seventh, fourteenth, twenty-first and twenty-eighth) is a crown tile: a gold laurel-wreath frame with a small crown at its top holding a bigger reward — a crown on a cushion, an ornate portrait frame, a small chest, and a heraldic crest shield. Below the grid, a torn crimson ribbon with ragged ends reading "BROKEN", beside a round red wax seal stamped with an olive branch; then three buttons in a row: a crimson plate reading "RESTORE" above a small blue diamond and an EMPTY price plate, a quiet dark navy plate reading "USE PARDON", and a quiet dark navy plate reading "START ANEW". Then a section heading "THIS WEEK": a long gold-rimmed points bar with small notches, partly filled with gold, with three chests standing on it at one third, two thirds and the end — a wooden chest, an iron chest and a gold chest — each above an EMPTY threshold plate, and an EMPTY points plate at the bar's left end. At the foot, a large emerald-green plate reading "CLAIM".
```

**Birebir kelimeler:** "DAILY REWARDS", "BROKEN", "RESTORE", "USE PARDON", "START ANEW", "THIS WEEK", "CLAIM".
**EMPTY:** seri, 28 gün numarası, fiyat, 3 eşik, puan plakası.
**Kesim notu:** kare türleri ~108×112: `calendar/tile_ahead|today|taken`, `calendar/tile_crown`; ödül ikonları S8'den; `calendar/flame` ~64; `calendar/pardon_seal` ~72; `calendar/broken_ribbon` ~300×60; düğmeler 248×68; `calendar/week_track` + dolgu + `calendar/chest_wood|iron|gold` ~90×80.

### 2.3 `deeds.png` — Başarımlar (DEEDS)

**Tuval:** 9:16, ≥1080×1920 → 941×1672 · **Sıra:** STYLE → PAGE → BODY → TEXT RULE → AVOID · **Dalga:** 4

**Ne için:** 24 başarım × 4 kademe; bronz/gümüş/altın/imparatorluk madalyaları,
kilitli ve gizli haller, kategori ikonları. Family şeridindeki DEEDS kartından açılır.

```text
BODY — The page title "DEEDS" at the top. Under it, two tab chips: "DEEDS" (selected: a glowing crimson plate with a gold rim) and "VICTORY ROAD" (a dark navy plate with a thin copper-gold edge). Then a row of seven small round category icons, each on a navy disc with a thin gold rim: crossed hammer and pick, crossed swords, a stone tower, a small gold crown, a rolled scroll, a laurel wreath, a small closed chest. Then six achievement rows stacked with even gaps; each row is a navy plate with a thin steel border, a round medallion on the left, an EMPTY title plate, an EMPTY description plate, a thin progress bar with a gold fill and an EMPTY progress plate: row 1 a bronze medallion with a small hammer; row 2 a silver medallion with crossed swords; row 3 a gold medallion with a laurel and a crown, and a green plate reading "CLAIM" at the row's right; row 4 an imperial medallion of gold with crimson enamel and small gems, with a gold tick wax seal at the row's right; row 5 a dark iron medallion with a small padlock; row 6 a dark medallion showing a large gold "?". At the foot, a quiet dark navy plate reading "CLOSE".
```

**Birebir kelimeler:** "DEEDS", "VICTORY ROAD", "CLAIM", "?", "CLOSE".
**EMPTY:** başlık, açıklama, ilerleme plakaları.
**Kesim notu:** `deeds/medal_bronze|silver|gold|imperial|locked|hidden` ~96; `deeds/cat_*` 64 darkkey; `deeds/row` (9-patch); sekme çipleri (Victory Road ile ortak).

### 2.4 `road.png` — Zafer Yolu (VICTORY ROAD)

**Tuval:** 9:16, ≥1080×1920 → 941×1672 · **Sıra:** STYLE → PAGE → BODY → TEXT RULE → AVOID · **Dalga:** 3

**Ne için:** L1→L60 yolculuğu: her seviyenin ödülü ve açılan özellik; 15 kilometre
taşı sandığı. Yol dört biyomdan geçer; oyunda her 15 seviyelik grup arkasında o
biyom bandı kullanılır.

```text
BODY — The same page with the two tab chips under the title "DEEDS": now "VICTORY ROAD" is selected (glowing crimson plate) and "DEEDS" is a dark navy plate. The page body is a tall painted journey map in warm parchment tones seen from above: a winding dirt road rises from the bottom of the page to the top, passing through four clearly separated bands of landscape — green fields and farms at the bottom, then a deep forest, then snowy mountains, and at the very top a great white castle with red roofs and crimson banners. Along the road, evenly spaced, round milestone shields with gold rims and EMPTY numeral plates; beside each shield an EMPTY small reward tile. The shields in the fields band are lit gold (reached); one shield in the forest band glows brightest and a small gold marching-lord token stands on it — a tiny armoured figure with a crimson cloak holding a banner; the shields above it are dim (ahead). Three milestone chests sit beside the road: a closed wooden chest, a glowing chest, and an opened chest with a gold tick wax seal. An EMPTY level plate sits at the page's top right. At the foot, a large emerald-green plate reading "CLAIM" and a quiet dark navy plate reading "CLOSE".
```

**Birebir kelimeler:** "DEEDS", "VICTORY ROAD", "CLAIM", "CLOSE".
**EMPTY:** kalkan numaraları, ödül kutuları, level plakası.
**Kesim notu:** `road/band_fields|forest|mountains|castle` (dört biyom bandı, sayfa genişliği); `road/shield_reached|current|ahead` ~80; `road/token` ~64; `road/chest_closed|glow|claimed` ~90.

### 2.5 `guide.png` — Rehber: kâhya, konuşma plakası, haberci, anahtarlar

**Tuval:** 9:16, ≥1080×1920 → 941×1672 · **Sıra:** STYLE → SHEET → BODY → TEXT RULE → AVOID · **Dalga:** 2–3

**Ne için:** Rehberli ilk 10 dakikanın kâhyası ve konuşma parşömeni, açılış hikâye
kartı, push izni isteyen haberci, ATLA düğmesi, bildirim ayarlarının kol
anahtarları ve adımlayıcısı, kategori zilleri. **Kâhya bu kitapçığın her yerinde
aynı kişidir.**

```text
BODY — Eleven objects in a loose grid. (1) and (2): the Royal Steward — a kindly grey-bearded man with a neat short beard, wearing a dark green velvet coat with gold buttons, a gold chain of office and a ring of iron keys at his belt — painted as a head-and-shoulders bust, twice: once turned three-quarters to the right, once turned three-quarters to the left, each about a third of the image width. (3) A wide speech-scroll plate: an unrolled cream parchment scroll with curled ends and a small red wax seal at its left end, completely EMPTY. (4) A wide story card: a painted scene in a thin gold frame — an empty, half-ruined stone keep at dawn, mist in the valley below, a single crimson banner stirring on its tower. (5) A herald on a white horse, full figure facing right, raising a long gold trumpet from which hangs a crimson banner with a gold lion. (6) A quiet dark navy plate reading "SKIP". (7) A toggle lever switched on: a gold lever with a small green gem. (8) The same toggle lever switched off: an iron lever with a small grey gem. (9) A small stepper: a narrow EMPTY navy plate with a round gold minus button on its left and a round gold plus button on its right. (10) A row of four small gold bells: one with a tiny hourglass on it, one with tiny crossed swords, one with a tiny castle, one with a tiny star. (11) A small gold scroll-shaped plate reading "NOTIFICATIONS".
```

**Birebir kelimeler:** "SKIP", "NOTIFICATIONS".
**EMPTY:** konuşma parşömeni, adımlayıcı plakası.
**Kesim notu:** `guide/steward_r|l` ~300×340 (rect + maske); `guide/speech` (parşömen 9-patch, ~700×180); `guide/story` ~760×430; `guide/herald` ~360×360; `guide/skip` 178×76; `ui/toggle_on|off` ~96×48; `ui/stepper` ~220×64; `icons/bell_timers|raids|kingdom|events` ~56.

### 2.6 `events.png` — Etkinlikler (COURT ▸ EVENTS)

**Tuval:** 9:16, ≥1080×1920 → 941×1672 · **Sıra:** STYLE → SHELL-COURT → BODY → TEXT RULE → AVOID · **Dalga:** 4

**Ne için:** Planlı etkinlikler (Hasat Festivali, Kan Ayı, Tüccar Kervanı), saatlik
"kraliyet saati" şeridi ve yaklaşan etkinlikler listesi.

```text
BODY — The content area (right of the rail, below the pills) shows EVENTS. Header (top ~20%): a festival in the castle courtyard at dusk — colourful pennants, glowing paper lanterns, a jousting lane and a cheering crowd; over the lower left the large gold engraved title "EVENTS" and beneath it, in parchment serif, "Festivals, hunts and royal hours." A small navy back button with a gold left chevron and the word "COURT" sits under the pills. Below: (1) a large hero card in a heavy gold frame: golden wheat fields at sunset strung with lanterns, a harvest wagon piled with sheaves and villagers dancing; an EMPTY title plate, an EMPTY line plate, a brass hourglass beside an EMPTY timer plate, and a green plate reading "VIEW"; (2) two event cards side by side: a huge crimson moon rising over dark castle battlements lit by torches; covered wagons with colourful canopies arriving at a city gate; each card with an EMPTY title plate, an EMPTY timer plate and an EMPTY small red badge circle on its top-right corner; (3) a slim wide strip with the heading "ROYAL HOURS": a round ornate gold seal medallion with a crimson centre and a golden hourglass on its left, an EMPTY event-name plate, an EMPTY timer plate, and at its right a small plate reading "NEXT" beside an EMPTY plate; (4) a section heading "UPCOMING" with three slim EMPTY rows, each led by a small parchment calendar icon.
```

**Birebir kelimeler:** "EVENTS", "Festivals, hunts and royal hours.", "COURT", "VIEW", "ROYAL HOURS", "NEXT", "UPCOMING".
**EMPTY:** tüm başlık/satır/zamanlayıcı plakaları, rozetler.
**Kesim notu:** `events/header`; `events/hero_card` ~760×360; `events/card_moon|caravan` ~372×280; `events/hours_strip` ~760×110; `events/view` 172×58; `events/next` ~120×44.

### 2.7 `collect_events.png` — Collect ekranı: etkinlik bandı, haftalık görevler, Altın Saat

**Tuval:** 9:16, ≥1080×1920 → 941×1672 · **Sıra:** STYLE → SHELL-COLLECT → BODY → TEXT RULE → AVOID · **Dalga:** 3–4

**Ne için:** Collect ekranına eklenenler, ekranın kendi ışığı ve ölçeğinde:
başlığın altındaki etkinlik bandı, "THIS WEEK'S QUESTS" görev paneli + sayfa
noktaları, haftalık sandık çubuğu ve Altın Saat göstergesi.

```text
BODY — The content area (right of the rail, below the pills) shows the COLLECT TASKS screen. Header (top ~17%): a sunny valley with a white castle with red conical roofs on a hill, farmhouses, hay bales and a cart on a dirt road; over the header's left the large gold engraved title "COLLECT TASKS" and beneath it, in parchment serif, "Spend Energy to collect resources and earn Gold and XP." Over the right side of the header, a round gold-framed sunburst gauge with a small hourglass at its centre and twelve segments around its rim, seven of them lit amber, beside an EMPTY small plate. Directly under the header, a slim wide event banner across the content: a small painted window on its left showing golden harvest fields strung with lanterns, an EMPTY title plate, an EMPTY line plate, a brass hourglass beside an EMPTY timer plate on its right, and a small gold right chevron. Below it, the quests panel titled "THIS WEEK'S QUESTS" in ivory Cinzel capitals, with two small pager dots at the panel's top right (one lit gold, one dim steel); inside, three quest cards side by side — a parchment scroll icon, a lightning bolt icon and a crossed-swords icon — each with EMPTY text lines, an EMPTY slim progress bar and an EMPTY reward plate. Under the panel, a long gold-rimmed points bar with small notches, partly filled with gold, with a small wooden chest, iron chest and gold chest standing on it and an EMPTY plate under each. Below that, the job rows continue as in the game: three rows, each a navy row with a picture window on the left (grapes on the vine, ripe strawberries, a golden wheat sheaf), the names "GRAPES", "STRAWBERRIES" and "WHEAT HARVEST" in ivory capitals, three small icons (a lightning bolt, a gold coin, a gold crown) each followed by an EMPTY number plate, a thin mastery track with three small gold diamond markers under the label "MASTERY BONUSES", and a green plate reading "COLLECT" on the right.
```

**Birebir kelimeler:** "COLLECT TASKS", "Spend Energy to collect resources and earn Gold and XP.", "THIS WEEK'S QUESTS", "GRAPES", "STRAWBERRIES", "WHEAT HARVEST", "MASTERY BONUSES", "COLLECT".
**EMPTY:** gösterge plakası, bant başlık/satır/zamanlayıcı, görev yazıları ve ödülleri, sandık eşikleri, sayılar.
**Kesim notu:** `collect/event_banner` [166, 509, 762, 110] (pencere [10, 8, 150, 94]); `collect/quests_title_week`; `collect/pager_dot_on|off` ~20; `collect/week_track` + dolgu + sandıklar; `collect/frenzy_gauge` (filling hali, ~120) — diğer haller `events_kit.png`'den.

### 2.8 `events_kit.png` — Etkinlik parçaları ve 8 saatlik etkinlik ikonu

**Tuval:** 9:16, ≥1080×1920 → 941×1672 · **Sıra:** STYLE → SHEET → BODY → TEXT RULE → AVOID · **Dalga:** 3–4

**Ne için:** Altın Saat göstergesinin üç hali, COLLECT düğmesi üzerindeki altın parıltı
ve sahibin istediği **saatlik rastgele etkinliklerin** 8 ikonu.

```text
BODY — Fourteen objects in a grid of three columns. Row 1: the same round gold-framed sunburst gauge three times, with a small hourglass at its centre and twelve segments around its rim — first with all segments dark; second with seven segments lit amber; third with every segment blazing gold, small flames licking the rim and a bright warm glow around it. Row 2: a short wide band of soft diagonal golden light with a few sparkles (a sheen overlay); a small quiet dark navy plate reading "NEXT"; a single sparkle star of golden light. Rows 3 to 5: eight round event icons, each a painted object inside a navy disc with a thin gold rim: a burlap sack overflowing with gold coins; an open book with a glowing quill above it; a four-leaf clover amulet set in gold; a blue potion bottle with a small paper price tag tied to its neck; a small red-and-white striped market tent with sparkles; a hammer and a wooden rake crossed; a small wooden courier cart carrying a sealed letter and a gold trumpet; two crossed swords over a gold laurel wreath.
```

**Birebir kelimeler:** "NEXT". **EMPTY:** yok.
**Kesim notu:** `events/gauge_empty|filling|ignited` ~160 (rect + maske); `collect/golden_sheen` 178×76'ya çizilir (darkkey); `events/sparkle`; ikonlar ~96: `events/icon_gold_rush`, `_scholar`, `_fortune`, `_sale`, `_fresh_wares`, `_busy_hands`, `_courier`, `_honor`.

### 2.9 `event_themes.png` — Üç etkinlik başlık sahnesi

**Tuval:** 9:16, ≥1080×1920 → 941×1672 · **Sıra:** STYLE → SHEET → BODY → TEXT RULE → AVOID · **Dalga:** 4

**Ne için:** Etkinlik detay sayfalarının geniş başlık resimleri.

```text
BODY — Three wide landscape scenes stacked vertically with even navy gaps, each filling the full width minus the margins and about two and a half times as wide as it is tall, each with a thin antique-gold frame and no text: (1) the Harvest Festival — golden wheat fields at sunset strung with glowing lanterns, a wagon piled with sheaves, villagers dancing around a maypole, the white castle on the hill behind; (2) the Blood Moon — an enormous crimson moon rising behind dark castle battlements, torches burning along the walls, crimson banners, soldiers silhouetted on the ramparts; (3) the Merchant Caravan — a long line of covered wagons with colourful striped canopies arriving at a stone city gate, merchants and pack horses, bales of cloth and barrels.
```

**Birebir kelimeler:** yok. **EMPTY:** yok.
**Kesim notu:** `events/theme_harvest|blood_moon|caravan` ~786×300 (rect).

### 2.10 `pass.png` — Sezon Kartı "ROYAL CHARTER" (COURT ▸ SEASON PASS)

**Tuval:** 9:16, ≥1080×1920 → 941×1672 · **Sıra:** STYLE → SHELL-COURT → BODY → TEXT RULE → AVOID · **Dalga:** 4

**Ne için:** 28 günlük sezon, 50 kademe; ücretsiz ve "ROYAL" (premium) şerit.
Adil kural: premium sütunda **altın, eşya, güç yok** — elmas, iksir, çerçeve, arma.

```text
BODY — The content area (right of the rail, below the pills) shows the ROYAL CHARTER season pass. Header (top ~20%): a tournament pavilion with striped tents under a blue sky, a tall crimson banner embroidered with a gold laurel and crown, and in the foreground a large unrolled royal charter scroll with a red wax seal; over the lower left the large gold engraved title "ROYAL CHARTER" and beneath it, in parchment serif, "This season's honours, free and royal."; at the header's bottom right an EMPTY season-name plate and a brass hourglass beside an EMPTY timer plate. A small navy back button with a gold left chevron and the word "COURT" sits under the pills. Below the header, a progress strip: a large round tier medallion with a gold laurel rim and an EMPTY numeral plate on the left, a long gold-rimmed progress bar partly filled with gold, an EMPTY progress plate, and on the right a crimson plate with a gold rim reading "UNLOCK" with an EMPTY price plate beneath it. Then two column headings: "FREE" on the left and "ROYAL" on the right, the latter in gold with a tiny crown. Then five tier rows: each row has a round medallion in the centre with an EMPTY numeral, a reward tile on its left in a plain gold frame and a reward tile on its right in a richer gold filigree frame set with small gems, all joined by a thin vertical gold line running through the medallions. The rewards shown are small painted objects: a small heap of blue diamonds, a blue potion bottle, a tiny wooden cart, an empty ornate portrait frame and a heraldic crest shield — never gold coins in the right-hand column. The right-hand tiles of rows 3, 4 and 5 carry a small padlock; both tiles of row 1 carry gold tick wax seals; the left tile of row 2 has a small green plate reading "CLAIM". At the bottom of the content, a stone pedestal in a pool of warm light holding an ornate imperial portrait frame (the final reward), and a large emerald-green plate reading "CLAIM ALL".
```

**Birebir kelimeler:** "ROYAL CHARTER", "This season's honours, free and royal.", "COURT", "UNLOCK", "FREE", "ROYAL", "CLAIM", "CLAIM ALL".
**EMPTY:** sezon adı, zamanlayıcı, kademe numaraları, ilerleme, fiyat.
**Kesim notu:** `pass/header`; `pass/medallion_big` ~110; `pass/medallion` ~72; `pass/tile_free`, `pass/tile_royal` ~150; `pass/line`; `pass/unlock` 248×68; `pass/claim_all` 326×90; `pass/pedestal` ~300×280.

### 2.11 `family_storehouse.png` — Family ekranı: Ambar kartı ve TALENTS/DEEDS/ROAD şeridi

**Tuval:** 9:16, ≥1080×1920 → 941×1672 · **Sıra:** STYLE → SHELL-FAMILY → BODY → TEXT RULE → AVOID · **Dalga:** 2–3

**Ne için:** Estate geliri artık ambarda birikiyor ve dokunarak toplanıyor (ambar
dolunca bildirim). Kartın üç hali (boş/yarı/taşan) ve yetenek/başarım/zafer yolu
madalyon kartları.

```text
BODY — The content area (right of the rail, below the pills) shows the FAMILY screen. Header (top ~35%): the young lord with dark wavy hair in black-and-gold plate armour and a crimson fur-trimmed cloak, seated on a gilded throne on a balcony, a crimson banner with a golden lion behind him and a vast white castle with red roofs beyond. Under the header, an identity plate: a crimson heater shield with a gold lion on the left, an EMPTY name plate, a small gold crown beside an EMPTY level plate, a gold progress bar and an EMPTY progress plate. Then a stats strip of three cells with painted icons — crossed swords, a red-and-silver shield, a gold compass star — labelled "ATTACK", "DEFENCE" and "POWER" above EMPTY value plates. Then the ledger: (1) a wide card in the style of an upgrade card: on its left a painted scene of a stone storehouse with its doors open, sacks and crates of harvest inside and a few gold coins spilling from a barrel; on its right the title "STOREHOUSE" in ivory capitals, an EMPTY amount plate, a gold-rimmed fill bar two-thirds full, a brass hourglass beside an EMPTY timer plate, a green plate reading "COLLECT" and a quiet dark navy plate reading "TO VAULT"; (2) below it, three medallion cards side by side: "TALENTS" — a gold medallion showing an oak tree whose three boughs end in a sword, a shield and a wheat sheaf; "DEEDS" — a gold medallion showing a laurel wreath around a star; "ROAD" — a gold medallion showing a winding road leading to a castle; each with an EMPTY small plate below and an EMPTY small red badge circle on its top-right corner; (3) under those, a strip of three small framed vignettes of the same storehouse, each the same size as the card's scene: its floor empty and swept clean; half full of sacks and crates; overflowing, with sacks and coins spilling out of its doors.
```

**Birebir kelimeler:** "ATTACK", "DEFENCE", "POWER", "STOREHOUSE", "COLLECT", "TO VAULT", "TALENTS", "DEEDS", "ROAD".
**EMPTY:** isim, level, değerler, miktar, zamanlayıcı, madalyon plakaları, rozetler.
**Kesim notu:** `family/storehouse_card` (748×253 çerçeve, yazılar silinir); `family/storehouse_empty|half|full` 364×216 (üç hal, kartın resmi); `family/to_vault` 178×76; `family/strip_talents|deeds|road` 240×150 (x 172 / 428 / 684).

### 2.12 `frames_noble.png` — S5a: soyluluk çerçeveleri

**Tuval:** 9:16, ≥1080×1920 → 941×1672 · **Sıra:** STYLE → SHEET → BODY → TEXT RULE → AVOID · **Dalga:** 4

**Ne için:** Sezon sonu soyluluk unvanlarının çerçeveleri (bir sonraki sezon
boyunca takılır): Knight, Baron, Count, Duke, Prince, Emperor — metal ve süs
kademe kademe zenginleşir.

```text
BODY — Six portrait frames of rising splendour, one per row, each shown twice side by side: on the left a large square frame, on the right a smaller round ring frame of the same design. The window inside every frame is EMPTY flat dark navy (no portrait, no face). Row 1: a plain dark iron frame with rivets and a small sword at its top. Row 2: a bronze frame with a small baron's coronet of four pearls at its top. Row 3: a silver frame with a small count's coronet and a thin blue enamel band. Row 4: a gold frame with a strawberry-leaf ducal coronet and crimson enamel. Row 5: a gold frame set with rubies and sapphires, with a jewelled prince's crown at its top. Row 6: an imperial frame of gold and deep crimson enamel with an imperial crown and a small double-headed eagle at its top, gold light radiating from it.
```

**Satırlar:** 1 Knight · 2 Baron · 3 Count · 4 Duke · 5 Prince · 6 Emperor.
**Birebir kelimeler:** yok. **EMPTY:** 12 pencere.
**Kesim notu:** S4a ölçüleri (kare 160/136, halka 96/76), `frames/noble_<id>_square|ring`.

### 2.13 `frames_events.png` — S5b: taht, etkinlik ve savaş çerçeveleri

**Tuval:** 9:16, ≥1080×1920 → 941×1672 · **Sıra:** STYLE → SHEET → BODY → TEXT RULE → AVOID · **Dalga:** 4–8

**Ne için:** Haftanın İmparatoru (Crowned Emperor) ve onun krallığı (Imperial Court),
üç etkinliğin özel çerçeveleri ve Krallık Savaşı'nın en iyi oyuncusu (Warlord).

```text
BODY — Six portrait frames, one per row, each shown twice side by side: on the left a large square frame, on the right a smaller round ring frame of the same design. The window inside every frame is EMPTY flat dark navy (no portrait, no face). Row 1: a massive gold frame with a tall jewelled imperial crown at its top, crimson velvet drapery at its sides and gold light radiating behind it. Row 2: a gold frame with a small crimson banner bearing a gold lion hanging from each upper corner. Row 3: a frame woven of golden wheat sheaves with tiny glowing lanterns at its corners. Row 4: a blackened iron frame with a crimson moon at its top and blood-red enamel. Row 5: a frame of carved wood and striped merchant canvas with tiny brass lanterns and a small coin purse at its base. Row 6: a scarred steel frame with crossed war axes at its top and two small crimson war banners.
```

**Satırlar:** 1 Crowned Emperor · 2 Imperial Court · 3 Harvest Festival · 4 Blood Moon · 5 Merchant Caravan · 6 Warlord of the Week.
**Birebir kelimeler:** yok. **EMPTY:** 12 pencere.
**Kesim notu:** S4a ölçüleri; `frames/crowned_emperor`, `imperial_court`, `event_harvest`, `event_blood_moon`, `event_caravan`, `warlord`.

### 2.14 `titles_sheet.png` — S5c: unvan kurdeleleri ve iki rozet

**Tuval:** 9:16, ≥1080×1920 → 941×1672 · **Sıra:** STYLE → SHEET → BODY → TEXT RULE → AVOID · **Dalga:** 4–8

**Ne için:** İsmin altında görünen unvanlar (yazı canlı basılır) için yedi kademe
kurdele, ve iki sabit rozet: Haftanın İmparatoru ve Warlord of the Week.

```text
BODY — Nine objects in a single column with even gaps. Rows 1 to 7: seven EMPTY ribbon banners of the same shape — a slightly curved banner with forked ends and a thin rim — in escalating materials: plain dark iron grey; bronze; silver; gold; gold with small rubies; crimson and gold with a tiny crown at its centre top; deep imperial crimson with heavy gold filigree and a small double-headed eagle at its centre top. Row 8: a wide gold emblem badge with laurel branches on both sides, a small imperial crown above, and the words "CROWNED EMPEROR" in engraved gold capitals on a crimson band. Row 9: a wide scarred-steel emblem badge with crossed war axes behind it and the words "WARLORD OF THE WEEK" in engraved ivory capitals on a dark red band.
```

**Birebir kelimeler:** "CROWNED EMPEROR", "WARLORD OF THE WEEK".
**EMPTY:** yedi kurdele.
**Kesim notu:** `titles/ribbon_1..7` ~260×56 (unvan metni canlı); `titles/badge_crowned_emperor` ~320×96; `titles/badge_warlord` ~320×96.

### 2.15 `ftue_sheet.png` — S6: rehber işaretçisi (çelik eldiven)

**Tuval:** 9:16, ≥1080×1920 → 941×1672 · **Sıra:** STYLE → SHEET-TEAL → BODY → TEXT RULE → AVOID · **Dalga:** 3

**Ne için:** İlk 10 dakikada ekrandaki düğmeyi gösteren boyalı eldiven. Teal zemin,
metal kenarların temiz ayrılması için (lacivert zeminde çelik kaybolur).

```text
BODY — Four objects in a grid of two columns and two rows: (1) a polished steel plate gauntlet with gold edging, index finger extended and pointing toward the upper left, the other fingers curled, seen slightly from above; (2) the same gauntlet in a pressing pose, fingertip pushed forward and slightly lower, with a tiny flash of light at the fingertip; (3) a glowing gold tap ring — a thin circle of warm golden light with a soft outer glow; (4) a curved gold arrow with a soft glow, bending from lower right to upper left.
```

**Birebir kelimeler:** yok. **EMPTY:** yok.
**Kesim notu:** `scripts/cut-item-paintings.py` ile maskelenir → `ftue/hand` ~180×220, `ftue/hand_press`, `ftue/ring`, `ftue/arrow`.

### 2.16 `reward_icons.png` — S8: ödül ikon seti

**Tuval:** 9:16, ≥1080×1920 → 941×1672 · **Sıra:** STYLE → SHEET → BODY → TEXT RULE → AVOID · **Dalga:** 2–4

**Ne için:** Takvim, araba, haftalık sandık, sezon kartı, posta ekleri ve Zafer
Yolu'nda ödül türünü gösteren küçük boyalı ikonlar (tek bir görünüm, her yerde aynı).

```text
BODY — Sixteen reward icons in a grid of four columns and four rows, all at the same generous size: a small leather coin purse with a few gold coins peeking out; a heavy, bulging leather coin purse tied with gold cord; a small corked glass flask of glowing blue-green liquid; a larger corked bottle of the same liquid; a tall blue potion bottle with a gold stopper and a lightning-bolt shaped glint; a rolled parchment scroll tied with a gold ribbon and a quill beside it; a four-leaf clover amulet set in gold; a miniature wooden cart with iron-rimmed wheels; a small closed chest with a steel sword hilt strapped to its lid; a small empty gilded portrait frame; a gold five-pointed star medal on a crimson ribbon; a round red wax seal stamped with an olive branch; a parchment charter with a blue shield emblem and a red seal; an ornate iron key; a small lit brass lantern; a gold laurel wreath.
```

**Birebir kelimeler:** yok. **EMPTY:** yok.
**Kesim notu:** ~110 px, rect + maske: `rewards/purse_small|heavy`, `flask_small|large`, `potion`, `xp_scroll`, `fortune_charm`, `cart_token`, `gear_chest`, `cosmetic_token`, `season_star`, `pardon`, `protection_charter`, `key`, `homecoming_lantern`, `renown_laurel`.

---
## 5. Parti 3 — Rekabet ve sosyal (Dalga 5–6)

- [ ] 3.1 `arena.png`
- [ ] 3.2 `bounties.png`
- [ ] 3.3 `throne.png`
- [ ] 3.4 `chat.png`
- [ ] 3.5 `chat_rules.png`
- [ ] 3.6 `help.png`
- [ ] 3.7 `profile.png`
- [ ] 3.8 `rival.png`
- [ ] 3.9 `arena_kit.png` (S7)

### 3.1 `arena.png` — Saldırı ▸ ARENA (dört sekmeli yeni Saldırı başlığı)

**Tuval:** 9:16, ≥1080×1920 → 941×1672 · **Sıra:** STYLE → SHELL-ATTACK → BODY → TEXT RULE → AVOID · **Dalga:** 5

**Ne için:** Altın çalınmayan sıralamalı arena. Bu tablo aynı zamanda Saldırı
ekranının **kanonik yeni başlığı ve dört sekmesidir** (RAID · ARENA · CAMPAIGN · BOUNTIES).

```text
BODY — The content area (right of the rail, below the pills) shows the Attack screen's ARENA tab. Header (top ~16%): two crossed steel swords with gold hilts beside the large gold engraved title "ATTACK", beneath it in spaced ivory capitals "RAID RIVALS. GROW STRONGER.", with an army of armoured soldiers and crimson banners before a castle on a hill behind. Directly under the header, four tabs across the content in one row with equal widths: "RAID", "ARENA", "CAMPAIGN", "BOUNTIES"; "ARENA" is selected (a glowing crimson plate with a gold rim), the other three are dark navy plates with thin copper-gold edges and ivory capitals. Below the tabs: a wide league panel — on its left a large league emblem, a gold laurel-wreathed heater shield bearing a golden lion in a gold frame; beside it an EMPTY league-name plate, an EMPTY rating plate, a slim gold-rimmed rating bar partly filled with gold, and a brass hourglass beside an EMPTY season-timer plate; along the bottom of the panel, five small sword-shaped attempt pips (three lit gold, two dark and spent) and a small quiet dark navy plate reading "REFRESH". Then three opponent cards stacked with even gaps, in the style of raid target cards: a square portrait window with a gold frame (a different lord in each: a bearded lord in furs, a dark-haired lady with a circlet, a knight in a steel helm), a heraldic crest shield beside it, an EMPTY name plate, an EMPTY level plate and an EMPTY rating plate, and on the right a green plate with small crossed swords reading "FIGHT". At the bottom, a strip of four small reward chests — wooden, iron, silver and gold — each above an EMPTY plate.
```

**Birebir kelimeler:** "ATTACK", "RAID RIVALS. GROW STRONGER.", "RAID", "ARENA", "CAMPAIGN", "BOUNTIES", "REFRESH", "FIGHT".
**EMPTY:** lig adı, puan, sezon, isim/level/puan, sandık plakaları.
**Kesim notu:** `attack/header` [155, 0, 786, ~280] (şerit bandı yumuşatılır); sekme şeridi [160, 280, 776, 68], 4 × 194: `attack/tab_label_raid|arena|campaign|bounties` darkkey, aktif/pasif çerçeveler; `arena/league_emblem` ~150; `arena/pip_on|off` ~40×64; `arena/opponent_card` (~748×200, yazılar silinir); `attack/btn_fight` ~230×64; `arena/refresh`.

### 3.2 `bounties.png` — Saldırı ▸ BOUNTIES (Ödül Tahtası)

**Tuval:** 9:16, ≥1080×1920 → 941×1672 · **Sıra:** STYLE → SHELL-ATTACK → BODY → TEXT RULE → AVOID · **Dalga:** 5

**Ne için:** Mafia Wars'tan esinli "Hit List": birinin başına altın ödül koy, onu yenen alır.

```text
BODY — The content area (right of the rail, below the pills) shows the Attack screen's BOUNTIES tab: the same header as the Arena screen (crossed swords, the large gold title "ATTACK", "RAID RIVALS. GROW STRONGER.", soldiers before a castle) and the same row of four tabs "RAID", "ARENA", "CAMPAIGN", "BOUNTIES", with "BOUNTIES" selected (glowing crimson) and the others dark navy. Below: a weathered wooden notice board with iron nails and a crimson ribbon across its top corner, its carved header reading "BOUNTY BOARD". Pinned to the board, four yellowed parchment posters with torn edges in two rows; each poster has the word "WANTED" printed large at its top in black woodcut capitals, a square EMPTY dark portrait window with a thin black frame (no face), an EMPTY name plate, and an EMPTY reward plate with a small tied sack of gold drawn beside it. Under the board, two slim sections, each with one EMPTY row: "ON YOUR HEAD" and "YOUR BOUNTIES". Then a placing panel: three EMPTY preset amount plates in a row (dark navy with thin gold rims), an EMPTY fee plate, and a crimson plate with a gold rim reading "PLACE BOUNTY"; a small leather coin sack and a coil of gold-fringed crimson ribbon lie in the panel's corner.
```

**Birebir kelimeler:** "ATTACK", "RAID RIVALS. GROW STRONGER.", "RAID", "ARENA", "CAMPAIGN", "BOUNTIES", "BOUNTY BOARD", "WANTED", "ON YOUR HEAD", "YOUR BOUNTIES", "PLACE BOUNTY".
**EMPTY:** portre pencereleri, isim/ödül, hazır tutar, ücret plakaları, satırlar.
**Kesim notu:** `bounties/board_header` ~760×120; `bounties/poster` ~170×230 (portre penceresi ~110×110 boş); `bounties/preset_plate`; `bounties/place` 248×68; `icons/coin_sack`.

### 3.3 `throne.png` — Taht (Haftanın İmparatoru)

**Tuval:** 9:16, ≥1080×1920 → 941×1672 · **Sıra:** STYLE → SHELL-KINGDOM → BODY → TEXT RULE → AVOID · **Dalga:** 5

**Ne için:** Haftanın en itibarlı krallığının kralı "Crowned Emperor" olur; herkes
görür, bir kez 60 dakikalık ferman ilan eder. Portre penceresi boş boyanır (oyuncunun
avatarı içine çizilir).

```text
BODY — The content area (right of the rail, below the pills) shows THE THRONE. Header (top ~32%): a grand throne room — a towering gilded throne under a crimson canopy embroidered with a golden lion, white marble pillars, beams of warm light through high arched windows, a long red carpet leading to the dais; over the header's lower left the large gold engraved title "THE THRONE" and beneath it, in parchment serif, "The realm's mightiest kingdom wears the crown." In front of the throne, centred, an ornate imperial portrait frame of gold and crimson enamel with an imperial crown at its top and an EMPTY dark velvet window (no face), and under it an EMPTY name plate and an EMPTY kingdom plate. Below the header, a section heading "DECREE": an unrolled royal decree scroll with a red wax seal across the panel's top, then three decree cards side by side, each a navy card with a gold frame, a painted emblem, a title and an EMPTY small plate: "HOUR OF PLENTY" with a golden wheat sheaf and a coin purse; "HOUR OF LEARNING" with an open book and a glowing quill; "HOUR OF FORTUNE" with a four-leaf clover amulet. Under the cards, a crimson plate with a gold rim reading "DECLARE" beside an EMPTY timer plate. At the bottom, a section heading "PAST REIGNS" with four slim EMPTY rows, each led by a small gold crown.
```

**Birebir kelimeler:** "THE THRONE", "The realm's mightiest kingdom wears the crown.", "DECREE", "HOUR OF PLENTY", "HOUR OF LEARNING", "HOUR OF FORTUNE", "DECLARE", "PAST REIGNS".
**EMPTY:** portre penceresi, isim, krallık, kart plakaları, zamanlayıcı, geçmiş satırları.
**Kesim notu:** `throne/header`; `throne/portrait_frame` ~220×260 (hollow); `throne/decree_card_plenty|learning|fortune` ~230×260; `throne/declare` 248×68; `throne/reign_row`.

### 3.4 `chat.png` — Krallık ▸ CHAT (iki sıra sekme, kanonik)

**Tuval:** 9:16, ≥1080×1920 → 941×1672 · **Sıra:** STYLE → SHELL-KINGDOM → BODY → TEXT RULE → AVOID · **Dalga:** 6

**Ne için:** Krallık sohbeti. Başlık yukarı kaydırılmış halde: iki sekme sırası
hapların hemen altında. Bu tablo Krallık'ın **ikinci sekme sırasının** (CHAT · BOSS ·
WAR · HELP) etiket kaynağıdır.

```text
BODY — The content area (right of the rail, below the pills) shows the Kingdom screen scrolled so that its header is gone: directly under the pills, two rows of four tabs across the content, each tab a dark navy plate with a thin copper-gold edge and ivory capitals: row 1 "REALM", "LORDS", "WORKS", "RANKS"; row 2 "CHAT", "BOSS", "WAR", "HELP", with "CHAT" selected (a glowing crimson plate with a gold rim). Below, the chat feed on the navy ground: a thin gold divider line with the word "TODAY" in small capitals at its centre; a message from another lord — a round gold portrait ring on the left (a bearded lord in furs), an EMPTY gold name plate with a tiny crown beside it, an EMPTY small time plate, and a slightly lighter navy speech bubble with a thin gold hairline holding two EMPTY lines; a one-line message from a lady — a portrait ring (a dark-haired lady with a circlet) and a bubble with one EMPTY line; a centred parchment-gold proclamation strip with a small herald trumpet icon on its left and one EMPTY line; the player's own message on the right side, in a warm brown-gold tinted bubble with one EMPTY line and no portrait; a second proclamation strip with one EMPTY line and a small green plate reading "CLAIM" at its right. At the bottom of the content, an input bar: a long EMPTY text field of parchment inside dark iron edging with a small quill icon at its left end, and a green plate reading "SEND".
```

**Birebir kelimeler:** "REALM", "LORDS", "WORKS", "RANKS", "CHAT", "BOSS", "WAR", "HELP", "TODAY", "CLAIM", "SEND".
**EMPTY:** isim, zaman, balon satırları, bildiri satırları, metin alanı.
**Kesim notu:** ikinci sıra [151, 628, 780, 68], genişlikler 206/186/197/192: `kingdom/tab_label_chat|boss|war|help` darkkey, `kingdom/tab_chat_active`; `chat/bubble_other|mine` (9-patch); `chat/proclamation` (9-patch ~760×80); `chat/divider_today`; `chat/field` [176, H−112, 560, 86]; `chat/send` [744, H−118, 176, 95]; `chat/claim` 122×43.

### 3.5 `chat_rules.png` — "Rules of the Hall" (sohbet kuralları)

**Tuval:** 9:16, ≥1080×1920 → 941×1672 · **Sıra:** STYLE → PAGE → BODY → TEXT RULE → AVOID · **Dalga:** 6

**Ne için:** Sohbete ilk yazmadan önce kabul edilen kurallar (App Store 1.2 şartı).
Kural metni oyun tarafından basılır.

```text
BODY — The page title "RULES OF THE HALL" at the top. The page body is a large unrolled cream parchment scroll with curled top and bottom ends and wooden rollers, sealed at its top centre with a red wax seal stamped with crossed swords; the parchment's writing area is completely EMPTY. At the foot, a large emerald-green plate reading "I AGREE" and a quiet dark navy plate reading "CLOSE".
```

**Birebir kelimeler:** "RULES OF THE HALL", "I AGREE", "CLOSE".
**EMPTY:** parşömen yazı alanı.
**Kesim notu:** `chat/rules_scroll` (9-patch, ~760×900); `chat/agree` 326×90.

### 3.6 `help.png` — Krallık ▸ HELP (yardımlaşma ve ortak hedef)

**Tuval:** 9:16, ≥1080×1920 → 941×1672 · **Sıra:** STYLE → SHELL-KINGDOM → BODY → TEXT RULE → AVOID · **Dalga:** 6

**Ne için:** Üyelerin birbirine günlük yardımı ve krallığın günlük ortak hedefi
(%40/%70/%100 sandıklar).

```text
BODY — The content area (right of the rail, below the pills) shows the Kingdom screen scrolled so that its header is gone: directly under the pills, the two rows of four tabs — row 1 "REALM", "LORDS", "WORKS", "RANKS"; row 2 "CHAT", "BOSS", "WAR", "HELP" — with "HELP" selected (glowing crimson) and the others dark navy. Below: (1) a wide card titled "TODAY'S GOAL": a painted scene of villagers and soldiers together hauling a great crimson banner up a castle wall with ropes; an EMPTY goal plate; a long gold-rimmed progress bar with a wooden chest, a silver chest and a gold chest standing on it at 40%, 70% and the end, each above an EMPTY plate; an EMPTY share plate; a green plate reading "CLAIM"; (2) a card titled "AID": two steel gauntlets clasped over a crimson shield, an EMPTY count plate and an EMPTY bonus plate; (3) a list of four member rows: each a navy row plate with a round gold portrait ring (a different lord or lady in each), an EMPTY name plate, an EMPTY level plate, and a green plate reading "AID" on the right; the first two rows carry a small crimson pennant with a raised gold hand beside the name; (4) at the bottom, a quiet dark navy plate with a thin gold rim reading "ASK FOR AID".
```

**Birebir kelimeler:** "REALM", "LORDS", "WORKS", "RANKS", "CHAT", "BOSS", "WAR", "HELP", "TODAY'S GOAL", "CLAIM", "AID", "ASK FOR AID".
**EMPTY:** hedef, eşikler, pay, sayaç, bonus, isim, level plakaları.
**Kesim notu:** `kingdom/tab_help_active`; `help/goal_card` ~760×380 (sahne ~340×220); `help/aid_card`; `help/member_row`; `help/aid` 178×64; `help/ask` 326×90; `icons/hand_flag`.

### 3.7 `profile.png` — Profil merkezi

**Tuval:** 9:16, ≥1080×1920 → 941×1672 · **Sıra:** STYLE → PAGE → BODY → TEXT RULE → AVOID · **Dalga:** 6

**Ne için:** Oyuncunun kendi profili: portre (kozmetik çerçeve), unvan, arkadaşlar,
dolap, sıralamalar, ayarlar, hesap, kod kullan, arkadaş davet et. Portre penceresi
boş (avatar içine çizilir).

```text
BODY — The page title "YOUR LORDSHIP" at the top. Under it, a portrait in an ornate gold frame set with small gems, its window EMPTY dark velvet (no face); beside it an EMPTY name plate, an EMPTY title ribbon, a crimson heater shield with a gold lion, and three EMPTY small stat plates with tiny icons (a gold crown, crossed swords, a small castle). Then seven menu rows stacked with even gaps; each is a navy row plate with a thin steel border, a painted icon on its left, a label in ivory capitals and a small gold right chevron at its right: "FRIENDS" with two clasped gauntlets and an EMPTY small red badge circle; "WARDROBE" with a mannequin wearing a crimson cloak and a small crown; "RANKINGS" with a small gold trophy cup; "SETTINGS" with a brass astrolabe; "ACCOUNT" with an ornate iron key; "REDEEM A CODE" with a sealed letter tied with ribbon; "INVITE A FRIEND" with a herald trumpet. Below them, a section heading "FRIENDS" with two friend rows: each a round gold portrait ring (a young knight, an older lady), a small green online dot on the ring, an EMPTY name plate, an EMPTY level plate and a small green plate with a lightning bolt reading "GIFT". At the foot, two toggle levers side by side — one switched on (a gold lever with a small green gem), one switched off (an iron lever with a small grey gem) — and a quiet dark navy plate reading "CLOSE".
```

**Birebir kelimeler:** "YOUR LORDSHIP", "FRIENDS", "WARDROBE", "RANKINGS", "SETTINGS", "ACCOUNT", "REDEEM A CODE", "INVITE A FRIEND", "GIFT", "CLOSE".
**EMPTY:** portre penceresi, isim, unvan, stat, rozet, arkadaş isim/level plakaları.
**Kesim notu:** `profile/portrait_frame` (hollow ~220); `profile/row` + ikonlar 64 (`profile/icon_friends|wardrobe|rankings|settings|account|redeem|invite`); `profile/gift` 122×43; `ui/toggle_on|off` (guide.png ile aynı nesne; hangisi daha iyiyse o kullanılır).

### 3.8 `rival.png` — Rakip profili ve casusluk

**Tuval:** 9:16, ≥1080×1920 → 941×1672 · **Sıra:** STYLE → PAGE → BODY → TEXT RULE → AVOID · **Dalga:** 6

**Ne için:** Başka bir lorda dokununca açılan profil: seviye, unvan, VIP mührü,
krallık, Might, eşya adları ve ordu özeti; "SPY" ile 60 dakikalık tam ordu raporu.

```text
BODY — The page title "LORD OF THE REALM" at the top. Under it, a portrait in an ornate gold frame, its window EMPTY dark velvet (no face); beside it a heraldic crest shield (a silver wolf on steel blue), an EMPTY name plate with a small round crimson wax seal beside it showing a tiny gold crown above the letters "VIP", an EMPTY title ribbon, and EMPTY level, kingdom and might plates with tiny icons (a gold crown, a small castle, crossed swords). Then a section heading "GEAR" with three square gear tiles in gold frames — a steel sword, a steel breastplate, a brown horse head — each above an EMPTY name plate. Then a section heading "ARMY" with a row of five small soldier heads in round frames — a hooded villager, a mercenary in a steel helmet, a gladiator in a golden crested helmet, another mercenary, another villager — each with a tiny EMPTY gold-rimmed diamond badge. Then a row of buttons: a green plate reading "ADD FRIEND", a dark navy plate with a gold rim and a small brass spyglass reading "SPY" with an EMPTY cost plate beneath it, and a crimson plate with small crossed swords reading "ATTACK". Beside the portrait, a round crimson wax stamp reading "SCOUTED" with an EMPTY timer plate under it. At the foot, a small quiet dark navy plate reading "REPORT" and a quiet dark navy plate reading "CLOSE".
```

**Birebir kelimeler:** "LORD OF THE REALM", "VIP", "GEAR", "ARMY", "ADD FRIEND", "SPY", "ATTACK", "SCOUTED", "REPORT", "CLOSE".
**EMPTY:** portre, isim, unvan, level/krallık/Might, eşya adları, rozetler, maliyet, zamanlayıcı.
**Kesim notu:** `rival/portrait_frame` (hollow ~220); `rival/gear_tile` 140; `rival/soldier_head_*` ~64 + rozet ~32; `rival/add_friend`, `rival/spy`, `rival/attack` 248×68; `rival/scouted_seal` ~120; `rival/report`.

### 3.9 `arena_kit.png` — S7: lig armaları ve lig çerçeveleri

**Tuval:** 9:16, ≥1080×1920 → 941×1672 · **Sıra:** STYLE → SHEET → BODY → TEXT RULE → AVOID · **Dalga:** 5

**Ne için:** Onur Arenası'nın altı lig arması (Bronz → İmparator) ve üst üç ligin
sezon sonu çerçeveleri.

```text
BODY — Twelve objects. Rows 1 and 2: six league crests in a grid of three columns, each a heater shield with a laurel wreath around it, rising in splendour: a bronze shield with a small bronze sword; a silver shield with crossed silver swords; a gold shield with a golden lion; a platinum-white shield with a gold lion and small pale gems; a sapphire-blue shield with a gold lion and a crown of diamonds; a crimson and gold imperial shield with a double-headed eagle and an imperial crown, radiating light. Rows 3 to 5: three portrait frames, one per row, each shown twice side by side — a large square frame on the left and a smaller round ring frame of the same design on the right — with an EMPTY flat dark navy window: a platinum frame with small pale gems; a sapphire-blue and gold frame set with diamonds; an imperial crimson and gold frame with a laurel and a crown at its top.
```

**Birebir kelimeler:** yok. **EMPTY:** 6 pencere.
**Kesim notu:** `arena/crest_bronze|silver|gold|platinum|diamond|emperor` ~120×140; `frames/arena_platinum|diamond|emperor_square|ring` (S4a ölçüleri).

---
## 6. Parti 4 — PvE ve krallık savaşları (Dalga 7–8)

- [ ] 4.1 `campaign.png`
- [ ] 4.2 `campaign_map_02.png` … `campaign_map_10.png` (9 dosya)
- [ ] 4.3 `hunt.png`
- [ ] 4.4 `expedition.png`
- [ ] 4.5 `forge.png`
- [ ] 4.6 `talents.png`
- [ ] 4.7 `boss.png`
- [ ] 4.8 `bosses_ashfall_wyrm.png`, `bosses_garrow.png`, `bosses_iron_colossus.png`, `bosses_fen_witch.png`, `bosses_ulgrim.png`, `bosses_black_knight.png` (6 dosya)
- [ ] 4.9 `war.png`

### 4.1 `campaign.png` — Saldırı ▸ CAMPAIGN (Fetih Kampanyası, 1. bölüm "The Vale")

**Tuval:** 9:16, ≥1080×1920 → 941×1672 · **Sıra:** STYLE → SHELL-ATTACK → BODY → TEXT RULE → AVOID · **Dalga:** 7

**Ne için:** 10 bölüm × 12 aşamalık PvE haritası; bu tablo 1. bölümü ve ekranın
çerçevesini (bölüm çubuğu, alt çubuk, FIGHT) verir. Diğer 9 bölüm yalnız harita olarak
ayrı üretilir (4.2).

```text
BODY — The content area (right of the rail, below the pills) shows the Attack screen's CAMPAIGN tab: the same header (two crossed swords, the large gold title "ATTACK", "RAID RIVALS. GROW STRONGER.", soldiers before a castle) and the same row of four tabs "RAID", "ARENA", "CAMPAIGN", "BOUNTIES", with "CAMPAIGN" selected (glowing crimson) and the others dark navy. Under the tabs, a chapter bar: a round gold chevron button pointing left, an EMPTY chapter-name plate, a small gold star beside an EMPTY stars plate, and a round gold chevron button pointing right. Below it, filling most of the content, an oblique painted map of a green vale in a thin antique-gold frame: a river with a stone bridge, a village with thatched roofs, a forest and a hilltop keep, with a dirt road winding from the bottom of the map to its top through twelve round gold-rimmed stage medallions with EMPTY dark centres, three small star sockets under each; medallions 6 and 12 are larger, with a small crimson banner and a skull-under-a-crown crest; the first three medallions have lit gold stars, the fourth glows brightly (current), the rest are dim; a small closed treasure chest sits near the top of the road. At the bottom of the content, a bar with an EMPTY stage-title plate, a small crossed-swords icon beside an EMPTY might plate, a lightning bolt beside an EMPTY energy plate, and a green plate reading "FIGHT".
```

**Birebir kelimeler:** "ATTACK", "RAID RIVALS. GROW STRONGER.", "RAID", "ARENA", "CAMPAIGN", "BOUNTIES", "FIGHT".
**EMPTY:** bölüm adı, yıldız, aşama merkezleri, aşama adı, Might, enerji plakaları.
**Kesim notu:** `attack/tab_campaign_active`; `campaign/chapter_bar` + `campaign/chevron_l|r`; `campaign/map_vale` (~776×1030, 12 düğüm konumu ölçülür); `campaign/node_done|current|boss|locked` ~72–96; `campaign/star_on|off` ~24; `campaign/bottom_bar` ~760×150; `attack/btn_fight`.

### 4.2 `campaign_map_02..10.png` — Dokuz bölüm haritası

**Tuval:** **3:4**, ≥1552×2070 → 776×1030 · **Sıra:** STYLE → BODY (ortak MAP + bölüm satırı) → TEXT RULE → AVOID · **Dalga:** 7

**Ne için:** Kampanyanın 2–10. bölümleri. Her dosya için önce ortak MAP bloğunu,
sonra o bölümün satırını yapıştır. Arayüz yok, yazı yok.

```text
MAP — A standalone illustrated campaign map in portrait 3:4, seen obliquely from above like a painted tabletop map, in the same rich painterly style and warm light, filling the whole image edge to edge with no interface, no border and no text. A dirt road winds from the bottom edge to the top edge through twelve round gold-rimmed stage medallions spaced evenly along it, each with an EMPTY dark centre and three small empty star sockets beneath it; medallions 6 and 12 are larger, with a small crimson banner and a skull-under-a-crown crest; a small closed treasure chest sits beside the road near the top.
```

`campaign_map_02.png` — Riverlands:
```text
The land: a broad river delta with reed beds, wooden watermills, fishing boats and stone bridges, green meadows between the channels.
```
`campaign_map_03.png` — Ironhills:
```text
The land: rugged brown hills with mine entrances, ore carts on wooden rails, a smoking forge town and slag heaps, pine trees on the ridges.
```
`campaign_map_04.png` — Blackwood:
```text
The land: a dark dense forest of twisted ancient trees, mist between the trunks, a ruined overgrown chapel and a hidden woodcutters' camp.
```
`campaign_map_05.png` — Ashen Marches:
```text
The land: burnt grey plains with charred trees, glowing lava cracks in the ground, a ruined watchtower and drifting ash under an orange sky.
```
`campaign_map_06.png` — Frostmere:
```text
The land: a frozen lake surrounded by snowy pines, an ice-covered castle on an island, sleds and frozen waterfalls under a pale sky.
```
`campaign_map_07.png` — Sehra Dunes:
```text
The land: golden sand dunes with a palm-fringed oasis, sandstone towers and domes, a camel caravan crossing the road.
```
`campaign_map_08.png` — Dragonspine:
```text
The land: jagged mountain peaks with enormous dragon bones half buried in the rock, narrow cliff paths, a distant dragon circling a peak.
```
`campaign_map_09.png` — The Sunken Crown:
```text
The land: flooded ruins of an ancient city, broken columns and a drowned palace rising from shallow blue-green water, wooden walkways between the ruins.
```
`campaign_map_10.png` — The Emperor's Road:
```text
The land: a wide paved imperial road lined with statues and banners leading to a radiant golden capital city with domes and towers on a hill.
```

**Birebir kelimeler:** yok. **EMPTY:** 12 madalyon merkezi.
**Kesim notu:** `campaign/map_<bölüm>` 776×1030 (rect); her haritada 12 düğüm konumu ölçülüp layout'a yazılır.

### 4.3 `hunt.png` — Ordu ekranı: HUNT / REROLL / DISMISS ve sefer kurdeleleri

**Tuval:** 9:16, ≥1080×1920 → 941×1672 · **Sıra:** STYLE → SHELL-ARMY → BODY → TEXT RULE → AVOID · **Dalga:** 7

**Ne için:** Seferler/Av: seçili asker 1–8 saatlik ava gönderilir. Asker kartlarında
"AWAY" (uzakta) ve "BACK" (döndü) kurdeleleri; seçili asker panelinde üç düğme.

```text
BODY — The content area (right of the rail, below the pills) shows the ARMY screen. Header (top ~20%): the young lord with dark wavy hair in black-and-gold armour and a crimson fur cloak standing before rows of helmeted soldiers and crimson banners at a castle; at the header's upper left the large ivory engraved title "ARMY", beneath it crossed gold swords and the small gold label "ARMY MIGHT" above an EMPTY number plate. Below: a panel titled "HERO SUPPORT" with a small round gold "i" button at its right and three stat cells — crossed swords, a red-and-silver shield, a gold crown within a laurel — labelled "ATTACK", "DEFENCE" and "TROOP HP" above EMPTY value plates. Then a panel titled "SOLDIERS" with a gold plate reading "AUTO EQUIP" at its right and a horizontal row of five tall soldier cards: card 1 a hooded villager holding a spear, a small gold-rimmed diamond badge with an EMPTY centre at its top left, the label "VILLAGER" and three small stat icons with EMPTY numbers; card 2 a mercenary in a steel helmet and blue scarf, dimmed, with a diagonal crimson ribbon across it reading "AWAY" and an EMPTY small timer plate on the ribbon; card 3 a gladiator in a golden crested helmet, with a gold ribbon across its top reading "BACK" and a small sparkle; card 4 another mercenary, normal; card 5 a "NEXT SLOT" card with an iron padlock and a brown plate reading "UNLOCK". Then a panel titled "SELECTED SOLDIER": a large portrait of the villager in a gold-framed window with a diamond badge with an EMPTY centre, the name "VILLAGER" beside an EMPTY small tier chip, two EMPTY description lines, three stat icons with EMPTY values, and a "GEAR" row of three tiles (a spear, a leather jerkin, a brown horse); on the panel's right, a column of three stacked buttons: a green plate with a gold crosshair reading "HUNT", a green plate with circular gold arrows reading "REROLL", and a crimson plate with a small bin icon reading "DISMISS". At the bottom, a panel titled "RECRUIT SOLDIERS" with three recruit cards (a villager, a mercenary, a gladiator), each with an EMPTY tier chip, EMPTY odds text, a gold coin with an EMPTY price plate and a green plate reading "RECRUIT".
```

**Birebir kelimeler:** "ARMY", "ARMY MIGHT", "HERO SUPPORT", "i", "ATTACK", "DEFENCE", "TROOP HP", "SOLDIERS", "AUTO EQUIP", "VILLAGER", "AWAY", "BACK", "NEXT SLOT", "UNLOCK", "SELECTED SOLDIER", "GEAR", "HUNT", "REROLL", "DISMISS", "RECRUIT SOLDIERS", "RECRUIT".
**EMPTY:** Might, değerler, rozet merkezleri, zamanlayıcı, tier çipi, açıklama, oranlar, fiyatlar.
**Kesim notu:** `army/card_away_ribbon`, `army/card_back_ribbon` ~150×60; sağ sütun düğmeleri 178×77 boya / 95 dokunma: `army/hunt` (mevcut `army.png`'den de alınabilir), `army/reroll_btn`, `army/dismiss`; `army/soldiers_away` metin alanı. HUNT'ın mevcut kesimi: `army.png` [726, 1056, 179, 77].

### 4.4 `expedition.png` — "THE HUNT" sefer sayfası

**Tuval:** 9:16, ≥1080×1920 → 941×1672 · **Sıra:** STYLE → PAGE → BODY → TEXT RULE → AVOID · **Dalga:** 7

**Ne için:** Askerin gideceği av alanını seçme sayfası (1/2/4/8 saat); ödüller
gönderirken belirlenir, önceden yalnız aralık gösterilir.

```text
BODY — The page title "THE HUNT" at the top. Under it, on the left, a soldier portrait in a gold frame (a mercenary in a steel helmet and blue scarf) with an EMPTY name plate and an EMPTY small tier chip beside it. Then four hunting-ground cards in a grid of two columns and two rows; each card is a navy card with a gold frame whose upper part is a painted scene: a sunny woodland edge with deer drinking at a stream; a misty old forest of giant oaks pierced by shafts of light; wolf-haunted rocky hills at dusk with a wolf silhouetted on a crag; dragon-haunted crags with drifting smoke and a distant dragon. Under each scene: an EMPTY name plate, a brass hourglass beside an EMPTY duration plate, and a row of three small reward icons — a leather coin purse, a small gold crown, a small chest — each above an EMPTY plate. The second card has a glowing gold selection frame; the fourth card carries a small iron padlock beside an EMPTY level plate. At the foot, a large emerald-green plate reading "SEND" and a quiet dark navy plate reading "CLOSE".
```

**Birebir kelimeler:** "THE HUNT", "SEND", "CLOSE".
**EMPTY:** isim, tier, alan adı, süre, ödül ve level plakaları.
**Kesim notu:** `expedition/ground_woods|old_forest|wolf_hills|dragon_wilds` (sahne ~340×200); `expedition/card` (boş); `expedition/selected_frame`; `expedition/send` 326×90.

### 4.5 `forge.png` — "THE FORGE" (Demirci)

**Tuval:** 9:16, ≥1080×1920 → 941×1672 · **Sıra:** STYLE → PAGE → BODY → TEXT RULE → AVOID · **Dalga:** 7

**Ne için:** 3 aynı tier eşya + altın → bir üst tier eşya. Envanter kartındaki FORGE
düğmesinden açılır; oranlar (i) ile görünür.

```text
BODY — The page title "THE FORGE" at the top. The upper half of the page is a painted forge scene inside the page frame: a dark stone smithy with a heavy iron anvil at its centre, glowing orange coals in a stone hearth behind it, a smith's hammer resting on the anvil, sparks drifting in the air, tongs and chains hanging on the wall. In front of the anvil, three EMPTY square sockets in a row — dark recessed frames with thin gold rims and faint anvil engravings. Below them, a glowing gold arrow pointing down to a larger, radiant EMPTY result socket with a gold filigree frame and soft light rays around it. Under the result socket, a small gold coin beside an EMPTY cost plate, and an EMPTY odds plate beside a small round gold "i" button. At the foot, a large emerald-green plate reading "FORGE" and a quiet dark navy plate reading "CLOSE".
```

**Birebir kelimeler:** "THE FORGE", "i", "FORGE", "CLOSE".
**EMPTY:** 4 soket, maliyet ve oran plakaları.
**Kesim notu:** `forge/scene` ~860×520; `forge/socket` ~140; `forge/result_socket` ~180; `forge/arrow`; `forge/button` 326×90.

### 4.6 `talents.png` — Yetenek ağacı (TALENTS)

**Tuval:** 9:16, ≥1080×1920 → 941×1672 · **Sıra:** STYLE → PAGE → BODY → TEXT RULE → AVOID · **Dalga:** 7

**Ne için:** WAR / DEFENCE / ECONOMY dalları, 5'er kademe; puan L10'da başlar.
Family şeridindeki TALENTS kartından açılır.

```text
BODY — The page title "TALENTS" at the top, with an EMPTY points plate at the page's top right. Behind the upper part of the page body, a painted great oak tree whose trunk splits into three boughs ending in a sword, a shield and a wheat sheaf. Three columns, each headed by a hanging banner: "WAR" on a crimson banner, "DEFENCE" on a steel-blue banner, "ECONOMY" on a gold-green banner. Each column holds five round gold-rimmed talent medallions stacked vertically and joined by thin gold lines. WAR: a sword, a horseman, a pennant, a laurel wreath, a war horn. DEFENCE: a kite shield, a stone tower, an iron-bound chest, a beacon fire, a fortress gate. ECONOMY: a wheat sheaf, balance scales, a rolled scroll, a four-leaf clover, an open book. Under each medallion, five tiny gem sockets in a row, some lit gold and some dark. The top two medallions of each column are lit and gleaming; the lower three are dark and dim. At the foot, a crimson plate reading "RESPEC" and a quiet dark navy plate reading "CLOSE".
```

**Birebir kelimeler:** "TALENTS", "WAR", "DEFENCE", "ECONOMY", "RESPEC", "CLOSE".
**EMPTY:** puan plakası.
**Kesim notu:** `talents/tree` (arka plan); `talents/banner_war|defence|economy`; `talents/node_<15 id>_lit|dim` ~96; `talents/gem_on|off` ~14; `talents/respec` 248×68.

### 4.7 `boss.png` — Krallık ▸ BOSS (başlıkla birlikte, iki sıra sekme)

**Tuval:** 9:16, ≥1080×1920 → 941×1672 · **Sıra:** STYLE → SHELL-KINGDOM → BODY → TEXT RULE → AVOID · **Dalga:** 8

**Ne için:** 48 saatte bir gelen krallık boss'u; üyeler enerjiyle vurur. Bu tablo
Krallık başlığının iki sıra sekmeli **kanonik** halidir (BOSS aktif etiketi buradan).

```text
BODY — The content area (right of the rail, below the pills) shows the Kingdom screen. Header (top ~30%): a castle vista through a marble colonnade with crimson banners bearing a golden lion; a large crimson heater shield with a golden lion in an ornate gold frame on the left; beside it an EMPTY kingdom-name plate, an EMPTY motto plate, a small gold crown beside an EMPTY level plate and a gold progress bar. Under the header, three stat cards with painted icons — a gold star in a laurel, a stack of gold coins, a group of gold figures — labelled "RENOWN", "TREASURY" and "MEMBERS" above EMPTY value plates. Then two rows of four tabs, each tab a dark navy plate with a thin copper-gold edge and ivory capitals: row 1 "REALM", "LORDS", "WORKS", "RANKS"; row 2 "CHAT", "BOSS", "WAR", "HELP", with "BOSS" selected (a glowing crimson plate with a gold rim). Below: a large boss card in a heavy gold frame — a huge ash-grey dragon perched on a burning ridge, wings spread, embers in the air — with an EMPTY boss-name plate across its top; under the picture a long crimson health bar in a heavy gold frame, three-quarters full, with an EMPTY number plate at its centre; a brass hourglass beside an EMPTY timer plate; six small sword pips, four lit gold and two dark; and a crimson plate with a gold rim reading "ATTACK" with a small lightning bolt beside an EMPTY cost plate. Then a row of three chests — wooden, silver and gold — each above an EMPTY threshold plate. Then a panel titled "DAMAGE": three rows led by a gold, a silver and a bronze medal engraved with "1", "2" and "3", then EMPTY rank plates on further rows, each row with a round portrait ring, an EMPTY name plate, an EMPTY damage plate and a thin crimson bar.
```

**Birebir kelimeler:** "RENOWN", "TREASURY", "MEMBERS", "REALM", "LORDS", "WORKS", "RANKS", "CHAT", "BOSS", "WAR", "HELP", "ATTACK", "DAMAGE", "1", "2", "3".
**EMPTY:** krallık adı/slogan/level, değerler, boss adı, HP sayısı, zamanlayıcı, maliyet, eşikler, sıra/isim/hasar plakaları.
**Kesim notu:** `kingdom/header_two_rows` (iki sıra sekmeyle kanonik başlık); `kingdom/tab_boss_active`; `boss/card_frame`; `boss/hp_track` + `boss/hp_fill` + uçlar (~740×40); `boss/pip_on|off`; `boss/attack` 248×68; `boss/chest_*`; `boss/medal_1|2|3` ~48. Boss resimleri 4.8'den.

### 4.8 `bosses_<id>.png` — Altı boss sahnesi

**Tuval:** **16:10**, ≥1542×964 → 771×482 · **Sıra:** STYLE → BODY (ortak BOSS SCENE + boss satırı) → TEXT RULE → AVOID · **Dalga:** 8

**Ne için:** Boss kartının resmi ve savaş tekrarında sağdaki boss portresi. Her dosya
için ortak BOSS SCENE bloğunu, sonra o boss'un satırını yapıştır.

```text
BOSS SCENE — A standalone wide painted battle scene in landscape 16:10, in the same rich painterly style, filling the whole image edge to edge with no interface, no border and no text. The boss fills the right two-thirds of the picture, turned slightly toward the left, dramatically lit by warm firelight and a cool rim light; its head and shoulders sit in the upper-right area so that a square portrait can be cut from it. The left third is a darker, calmer part of the same landscape.
```

`bosses_ashfall_wyrm.png` — The Ashfall Wyrm:
```text
The boss: a huge ash-grey dragon with cracked, ember-lit scales perched on a burning mountain ridge, wings half spread, glowing orange eyes, ash and embers swirling in the air.
```
`bosses_garrow.png` — Garrow the Bandit King:
```text
The boss: a scarred, broad-shouldered bandit king in a patched fur cloak and a crown of bent gold, seated on a throne of stolen loot in a forest camp lit by torches, a heavy cleaver across his knees.
```
`bosses_iron_colossus.png` — The Iron Colossus:
```text
The boss: a towering riveted iron giant with a glowing furnace burning in its chest, steam venting from its joints, standing in a ruined foundry yard, one enormous fist raised.
```
`bosses_fen_witch.png` — The Fen Witch:
```text
The boss: a gaunt witch in tattered green robes rising from a misty swamp, crackling green witchfire in her hands, twisted dead trees and floating will-o'-the-wisps around her.
```
`bosses_ulgrim.png` — Warlord Ulgrim:
```text
The boss: a massive barbarian warlord in fur and bone armour with a horned helmet and a great double axe, standing on snowy ground before a burning war camp, war banners behind him.
```
`bosses_black_knight.png` — The Black Knight:
```text
The boss: a knight in black plate armour with a crimson plume on a rearing black warhorse, a long black lance, a burning chapel behind him at night.
```

**Birebir kelimeler:** yok. **EMPTY:** yok.
**Kesim notu:** `bosses/<id>_scene` 771×460 (rect); `bosses/<id>_portrait` sağ üstten kare (~236, savaş tekrarı).

### 4.9 `war.png` — Krallık ▸ WAR (haftalık Krallık Savaşı)

**Tuval:** 9:16, ≥1080×1920 → 941×1672 · **Sıra:** STYLE → SHELL-KINGDOM → BODY → TEXT RULE → AVOID · **Dalga:** 8

**Ne için:** Cumartesi–Pazartesi krallık savaşı: iki krallık, puan çekişmesi, düşman
lordlar listesi (altın çalınmaz), savaş kaydı.

```text
BODY — The content area (right of the rail, below the pills) shows the Kingdom screen scrolled so that its header is gone: directly under the pills, the two rows of four tabs — row 1 "REALM", "LORDS", "WORKS", "RANKS"; row 2 "CHAT", "BOSS", "WAR", "HELP" — with "WAR" selected (glowing crimson) and the others dark navy. Below: a wide war panel with two heraldic shields facing each other across crossed swords — on the left a crimson shield with a golden lion, on the right a steel-blue shield with a silver wolf — each under an EMPTY name plate; between them a tug-of-war bar filled crimson from the left and steel-blue from the right, meeting at a small gold marker, with an EMPTY points plate at each end; beneath the bar the words "ENDS IN" beside a brass hourglass and an EMPTY timer plate; and three small crimson pennant pips. Then a section heading "ENEMY LORDS" with four enemy rows: each a navy row plate with a round portrait ring, an EMPTY name plate, an EMPTY level plate, three small pennant pips, a crossed-swords icon beside an EMPTY might plate and a green plate reading "FIGHT"; the third row is dimmed and stamped diagonally with a crimson stamp reading "ROUTED". At the bottom, a thin panel titled "WAR LOG" with two EMPTY lines.
```

**Birebir kelimeler:** "REALM", "LORDS", "WORKS", "RANKS", "CHAT", "BOSS", "WAR", "HELP", "ENDS IN", "ENEMY LORDS", "FIGHT", "ROUTED", "WAR LOG".
**EMPTY:** krallık adları, puanlar, zamanlayıcı, isim/level/Might plakaları, kayıt satırları.
**Kesim notu:** `kingdom/tab_war_active`; `war/shield_us|them` ~150; `war/tug_track` + iki dolgu (~700×36); `war/pennant_on|off`; `war/enemy_row`; `war/routed_stamp` ~160×60; `war/log_panel`.

---
## 7. Yeniden boyamalar (zayıf mevcut görseller)

Bunlar yeni özellik için değil, **bugün zayıf kalan** yerler için: aynı resmin tekrar
tekrar kullanıldığı ya da kodla çizildiği yerler. Herhangi bir partiyle birlikte
gönderilebilir. (R9 plakalar Parti 1'dedir; R11 HUNT düğmesi için tablo gerekmez —
`army.png` [726, 1056, 179, 77]'den kesilir.)

- [ ] R1 `collect_jobs_a.png`, `collect_jobs_b.png` — 9 yeni iş resmi
- [ ] R2 `ledger_upgrades.png`, `ledger_holdings.png` — 18 ledger sahnesi
- [ ] R3 `works_sheet.png` — 8 krallık işi
- [ ] R4 `avatars_sheet.png` — 12 avatar büstü
- [ ] R6 `soldiers_sheet.png` — 9 asker portresi
- [ ] R7 `numerals_sheet.png` — tier rakamları I–VII + itibar altıgenleri
- [ ] R8 `battle_fx.png` — savaş efektleri
- [ ] R10 `items_weapons.png`, `items_armor.png`, `items_horses.png` — 42 eşya tasarımı
- [ ] R14 `crests_sheet.png` — 12 hanedan arması

### R1 `collect_jobs_a.png` ve `collect_jobs_b.png` — İş listesi resimleri

**Tuval:** 9:16, ≥1080×1920 → 941×1672 · **Sıra:** STYLE → SHELL-COLLECT → BODY → TEXT RULE → AVOID · **Dalga:** herhangi

**Ne için:** 15 işin yalnız 6'sının resmi var (üzüm, çilek, buğday, kereste, taş, vergi
arabası) ve bunlar dönerek tekrar ediyor. Eksik 9 iş: Tend the Orchard, Fish the River,
Mine Iron Ore, Hunt the King's Wood, Escort a Trade Caravan, Smelt Silver, Clear the
Bandit Camp, Delve the Deep Mine, Plunder the Dragon's Hoard. Resimler gerçek iş
satırı içinde boyanır ki kesim mevcut satır çerçevesine birebir otursun.

`collect_jobs_a.png`:
```text
BODY — The content area (right of the rail, below the pills) shows the Collect job list scrolled so that no header is visible: directly under the pills, six job rows fill the content with even gaps, followed by the dark foliage at the bottom. Each row is a navy row panel with a thin steel border: on its left a picture window with a thin dark frame holding a painted scene; the job name in ivory Cinzel capitals; a row of three small painted icons — a lightning bolt, a gold coin and a gold crown — each followed by an EMPTY number plate; an EMPTY count plate at the top right of the text area; a green plate reading "COLLECT" on the right; and under the icons the small label "MASTERY BONUSES" beside a thin track with three small gold diamond markers. The six rows and their pictures: "TEND THE ORCHARD" — an apple orchard in late sun with wooden ladders against the trees and baskets of red apples; "FISH THE RIVER" — a clear river with a small wooden boat, nets full of silver fish and reeds; "MINE IRON ORE" — a timber-braced mine entrance in a hillside with carts of rust-red ore; "HUNT THE KING'S WOOD" — a royal stag in a forest clearing, a hunting horn and a boar spear resting against a log; "ESCORT A TRADE CARAVAN" — covered wagons on a forest road guarded by mounted soldiers; "SMELT SILVER" — a glowing furnace pouring bright molten silver into moulds.
```

`collect_jobs_b.png`:
```text
BODY — The content area (right of the rail, below the pills) shows the Collect job list scrolled so that no header is visible: directly under the pills, six job rows fill the content with even gaps, followed by the dark foliage at the bottom. Each row is a navy row panel with a thin steel border: on its left a picture window with a thin dark frame holding a painted scene; the job name in ivory Cinzel capitals; a row of three small painted icons — a lightning bolt, a gold coin and a gold crown — each followed by an EMPTY number plate; an EMPTY count plate at the top right of the text area; a green plate reading "COLLECT" on the right; and under the icons the small label "MASTERY BONUSES" beside a thin track with three small gold diamond markers. The six rows and their pictures: "CLEAR THE BANDIT CAMP" — a bandit camp in a dark wood with toppled tents and a burning campfire, abandoned weapons; "DELVE THE DEEP MINE" — a deep cavern of glowing blue crystals lit by miners' lanterns; "PLUNDER THE DRAGON'S HOARD" — a sleeping red dragon curled on a mountain of gold coins and treasure in a cave; "TEND THE ORCHARD" — a pear orchard in morning light with a farmer on a ladder; "FISH THE RIVER" — fishermen casting a net from a stone bridge at dawn; "MINE IRON ORE" — miners with picks inside a lantern-lit tunnel loading ore into a cart.
```

**Birebir kelimeler:** satır adları, "COLLECT", "MASTERY BONUSES".
**EMPTY:** tüm sayılar.
**Kesim notu:** yalnız resim pencereleri kesilir: `collect/job_<id>` **190×158** (orchard, fish, iron, hunt, caravan, silver, bandits, deep_mine, dragon_hoard). `collect_jobs_b`'nin son üç satırı ikinci denemedir; hangisi daha iyiyse o seçilir.

### R2 `ledger_upgrades.png` ve `ledger_holdings.png` — Ledger sahneleri

**Tuval:** 9:16, ≥1080×1920 → 941×1672 · **Sıra:** STYLE → SHEET → BODY → TEXT RULE → AVOID · **Dalga:** herhangi

**Ne için:** Family ekranındaki 11 upgrade ve 8 mülk kartının hepsi şu an aynı Granary
resmini kullanıyor. Her kartın kendi sahnesi olacak (Granary zaten var).

`ledger_upgrades.png`:
```text
BODY — Ten landscape scene panels in a grid of two columns and five rows, each panel a painted scene exactly 1.69 times as wide as it is tall, with no frame and no text, separated by even navy gaps: (1) a large timber tithe barn with open doors, sheaves of grain stacked high and a tithe cart outside; (2) a candlelit stone scriptorium where monks copy illuminated manuscripts at slanted desks; (3) a stone watchtower on a hill with a blazing beacon fire at dusk and more beacons burning on distant hills; (4) a cool stone larder with hanging hams, wheels of cheese, barrels and jars on shelves; (5) a stone armoury with racks of swords, spears and shields and the glow of a forge at the back; (6) thick castle walls with a reinforced gate and soldiers on the ramparts; (7) a timber stable yard with fine horses in stalls and grooms at work; (8) merchants shaking hands at a market stall piled with bales of cloth, spices and brass scales; (9) an iron-banded war chest standing open on a table beside campaign maps and a helmet; (10) a locked vault room of chained chests watched by a guard holding a ring of keys.
```

`ledger_holdings.png`:
```text
BODY — Eight landscape scene panels in a grid of two columns and four rows, each panel a painted scene exactly 1.69 times as wide as it is tall, with no frame and no text, separated by even navy gaps: (1) golden wheat fields with a farmhouse and a haystack under a blue sky; (2) a stone watermill with a turning wheel beside a clear river; (3) a stone quarry with cut blocks, wooden cranes and workers; (4) terraced vineyards on a sunny hillside with a stone wine press; (5) a mine entrance in a rocky hillside with carts of rust-red iron ore; (6) a bustling town market square with striped stalls, a fountain and townsfolk; (7) a river port with wooden cogs moored at a quay and cargo cranes; (8) a ducal mint workshop with presses stamping coins and coin trays glowing in lamplight.
```

**Birebir kelimeler:** yok. **EMPTY:** yok.
**Kesim notu:** `family/ledger_<id>` → kartta **364×216** çizilir (büyük boyanır, küçük çizilir). Upgrade id'leri: tithe_barn, scriptorium, beacons, larder, armoury, bulwark, stables, merchant, war_chest, coffers. Mülk id'leri: wheat_farm, watermill, quarry, vineyard, iron_mine, market, river_port, mint.

### R3 `works_sheet.png` — Krallık işleri (8)

**Tuval:** 9:16, ≥1080×1920 → 941×1672 · **Sıra:** STYLE → SHEET → BODY → TEXT RULE → AVOID · **Dalga:** herhangi

**Ne için:** Krallığın 8 upgrade'i için bugün yalnız 4 küçük resim var.

```text
BODY — Eight small building scenes in a grid of two columns and four rows, each scene 1.25 times as wide as it is tall, framed with a thin antique-gold frame like a thumbnail, no text, separated by even navy gaps: (1) a grand stone granary with royal banners and carts of grain; (2) a tall library hall with shelves of books and scrolls and a reading table; (3) a treasury vault door flanked by two guards, chests visible inside; (4) an armoury hall with racks of weapons and suits of armour; (5) a massive curtain wall and gatehouse with a raised portcullis; (6) courier stables with riders galloping out of the gate carrying satchels; (7) a hall hung with many long crimson banners bearing golden lions; (8) a throne hall where nobles gather before an empty throne.
```

**Birebir kelimeler:** yok. **EMPTY:** yok.
**Kesim notu:** `kingdom/work_<id>` → 86×69 çizilir (≥152×122 boyanır): royal_granaries, royal_archives, royal_treasury, royal_armoury, royal_bulwark, royal_couriers, royal_banners, royal_court.

### R4 `avatars_sheet.png` — 12 avatar büstü

**Tuval:** 9:16, ≥1080×1920 → 941×1672 · **Sıra:** STYLE → SHEET → BODY → TEXT RULE → AVOID · **Dalga:** herhangi

**Ne için:** 12 avatar seçeneği bugün 4 yüze eşleniyor; rakip kartları, lord satırları,
sohbet ve savaş tekrarı hep bu yüzlerden. Her avatarın kendi yüzü olacak.

```text
BODY — Twelve head-and-shoulders portraits in a grid of three columns and four rows, each portrait painted inside its own square with a softly blurred warm background (a castle interior, a banner or a sky), squares separated by even navy gaps, in the same painterly style as noble portraits, each person facing slightly toward the viewer: (1) a knight in a steel helmet with its visor raised and a crimson surcoat; (2) a bearded king with a gold crown and an ermine collar; (3) a queen with auburn hair, a jewelled circlet and a crimson gown; (4) a young archer in a green hood with a quiver strap across the chest; (5) a tonsured monk in a brown habit with a wooden cross; (6) a wild red-bearded berserker in wolf fur; (7) a grinning knave in a black hood with a scar on the cheek; (8) a herald in a crimson-and-gold tabard with a feathered cap; (9) a templar in white with a red cross and a mail coif; (10) a pale witch with long black hair and a sprig of herbs; (11) a battle-worn captain with grey stubble, a steel gorget and a blue cloak; (12) a young princess with golden braids and a small tiara.
```

**Birebir kelimeler:** yok. **EMPTY:** yok.
**Kesim notu:** `portraits/avatar_<id>` kare **272×272** (rect) + `_ring` (elips maske); kartlarda 136, savaşta 236, lord satırında 76 çizilir. id sırası: knight, king, queen, archer, monk, berserk, knave, herald, templar, witch, captain, princess.

### R6 `soldiers_sheet.png` — 9 asker portresi

**Tuval:** 9:16, ≥1080×1920 → 941×1672 · **Sıra:** STYLE → SHEET → BODY → TEXT RULE → AVOID · **Dalga:** herhangi

**Ne için:** Üç asker tipinin tier bandına göre görünüşü (kaba I–II, ince III–V,
yaldızlı VI–VII). Bugün tek büyük portre var.

```text
BODY — Nine tall portraits in a grid of three columns and three rows, each painted inside its own vertical panel about 0.71 times as wide as it is tall, with a softly blurred battlefield background of banners and tents in warm light, panels separated by even navy gaps; each figure shown from the waist up, facing slightly left. Column 1 is the villager, column 2 the mercenary, column 3 the gladiator; row 1 is ragged, row 2 fine, row 3 gilded. Row 1: a hooded peasant in worn brown wool holding a crude spear; a mercenary in a dented kettle helmet and a patched blue scarf over rusty mail; a gladiator in a bronze helmet with a frayed red crest, leather straps on bare arms. Row 2: a militia villager in a quilted gambeson with a polished spear; a mercenary in a polished steel helmet, blue scarf and bright mail; a gladiator in a golden crested helmet with a crimson cape and a round shield. Row 3: a heroic peasant champion in gilded leather holding a spear with a banner; a mercenary knight in gilded plate with a crimson cloak; a gladiator champion in an ornate gold helmet with a tall crimson crest and gold-inlaid armour.
```

**Birebir kelimeler:** yok. **EMPTY:** yok.
**Kesim notu:** `portraits/soldier_<tip>_<bant>` **214×301** (büyük, seçili asker); kart büstü 133×160 alt-kesim. Bantlar: low (I–II), mid (III–V), high (VI–VII).

### R7 `numerals_sheet.png` — Tier rakamları I–VII ve itibar altıgenleri

**Tuval:** 9:16, ≥1080×1920 → 941×1672 · **Sıra:** STYLE → SHEET → BODY → TEXT RULE → AVOID · **Dalga:** herhangi

**Ne için:** Asker tier rozetlerinde bugün yalnız I–III boyalı (üstü boş plaka + yazı);
itibar altıgenlerinden yalnız II yanık (diğerleri renk kaplamalı).

```text
BODY — Twenty-two badges in four rows. Row 1: seven small diamond-shaped (rhombus) badges of equal size, each a dark navy face inside a bevelled antique-gold rim, carrying an engraved gold Roman numeral: "I", "II", "III", "IV", "V", "VI", "VII". Row 2: the same seven badges again, larger and more ornate, with small filigree tips at the four points: "I", "II", "III", "IV", "V", "VI", "VII". Row 3: four hexagonal reputation plaques, unlit — dark bronze-rimmed hexagons with dim steel faces and engraved numerals "I", "II", "III", "IV". Row 4: the same four hexagonal plaques lit — each glowing, with a bright gold rim and a luminous face: "I" warm copper, "II" blue-violet, "III" silver-white, "IV" radiant gold.
```

**Birebir kelimeler:** "I", "II", "III", "IV", "V", "VI", "VII".
**EMPTY:** yok.
**Kesim notu:** `army/numeral_1..7` **50×50**, `army/numeral_large_1..7` **72×68** (rect + maske, bugünkü I–III ile aynı konum: rakam elmasın ortasında); `kingdom/rep_hex_1..4` ve `_lit` ~56×66. Boş-plaka + canlı yazı ve renk kaplaması geri dönüşleri kalkar.

### R8 `battle_fx.png` — Savaş efektleri

**Tuval:** 9:16, ≥1080×1920 → 941×1672 · **Sıra:** STYLE → SHEET → BODY → TEXT RULE → AVOID · **Dalga:** herhangi

**Ne için:** Savaş tekrarındaki darbe ve kesik efektleri bugün kodla çiziliyor;
zafer/yenilgi afişi ve "Fortune of War" zarları yok.

```text
BODY — Ten effects and plates on the navy background, glowing effects painted as light on dark: (1) an impact burst — a bright white-gold starburst with sparks; (2) a slash arc — a curved crescent streak of white light with a fading tail; (3) a critical-hit burst — a larger jagged red-and-gold explosion of light with flying sparks; (4) a dodge swoosh — a wide horizontal sweep of pale motion streaks, about twice as wide as tall; (5) a shield spark — a small blue-white flash with sparks; (6) a wide crimson and gold ribbon banner with laurel ends reading "VICTORY" in large gold engraved capitals; (7) a wide dark steel and ash-grey ribbon banner with torn ends reading "DEFEAT" in large ivory engraved capitals; (8) a small dark navy plate with a gold rim reading "ROUND" followed by an EMPTY square numeral window; (9) and (10) two ivory dice with gold pips and rounded edges, one showing five pips and one showing two pips, slightly tilted.
```

**Birebir kelimeler:** "VICTORY", "DEFEAT", "ROUND".
**EMPTY:** tur numarası penceresi.
**Kesim notu:** darkkey: `battle/impact`, `battle/slash`, `battle/crit` **256×256**, `battle/dodge` 256×128, `battle/shield_spark` 128; rect + maske: `battle/banner_victory|defeat` **600×180**, `battle/round_plate` ~200×80, `battle/die_a|b` ~96. `tools/make_battle_fx.gd` emekliye ayrılır.

### R10 `items_weapons.png`, `items_armor.png`, `items_horses.png` — 42 eşya tasarımı

**Tuval:** 9:16, ≥1080×1920 → 941×1672 · **Sıra:** STYLE → SHEET → BODY → TEXT RULE → AVOID · **Dalga:** herhangi

**Ne için:** 63 eşya tanımı için yalnız 21 resim var (`client/assets/items/painted/`:
weapon_01–07, armor_01–07, horse_01–07); tanımların **42'si** başka bir eşyanın
resmini kullanıyor (ör. "The Gilded Verdict" = "Rusted Arming Sword"ın resmi).
Her tanım adına uygun, kendi tier renginde bir resim alacak. Mevcut 21'in duruşu
korunur: silahlar sol alttan (uç) sağ üste (kabza) çapraz; zırhlar önden, içi boş,
başsız gövde; atlar sağa bakan üç çeyrek baş-göğüs portresi. Tier ışıması:
Common yok · Uncommon hafif yeşil · Rare soğuk mavi · Epic mor · Legendary altın-kor ·
Mystic magenta · Special kızıl ateş.

`items_weapons.png` (14 silah):
```text
BODY — Fourteen weapons in a grid of three columns and five rows (the last cell stays empty), each weapon laid diagonally from its point at the lower left to its hilt at the upper right, same size and angle in every cell, with the glow colour given for each: (1) Silvered Arming Sword — a straight double-edged arming sword with a mirror-bright silvered blade and a blue enamel crossguard, cool blue sheen; (2) Warden's Falchion — a single-edged curved falchion of dark steel with a blue leather grip and a small tower emblem on the guard, cool blue sheen; (3) Duskfang Spear — a long spear with a fang-shaped head sheened violet and an ash shaft wrapped in purple leather, faint violet runes, violet glow; (4) Bastion Greatsword — a massive two-handed greatsword with a broad blade, a tower-shaped pommel and a violet gemstone, violet glow; (5) Kingsguard Flamberge — a wavy-bladed flamberge with a gold and violet guard bearing a royal crest, violet glow; (6) Dawnbreaker Rapier — a slender rapier with a swept gold basket hilt shaped like sun rays, its blade catching golden dawn light, gold glow; (7) Ashfang Leafblade — a leaf-shaped broad blade with glowing embers along its edges and a charred black and gold hilt, gold-ember glow; (8) The Gilded Verdict — an ornate gold-plated arming sword with a scales-of-justice pommel, radiant gold glow; (9) Starfall Falchion — a falchion of dark meteoric steel flecked with magenta starlight, glowing magenta edge; (10) Wyrmtongue Spear — a spear with a forked serpent-tongue head and a dragon-scale shaft, magenta arcane glow; (11) The Sundering — an enormous greatsword with a cracked blade leaking magenta light; (12) Crown of Flame — a flamberge wreathed in crimson fire with a crown-shaped guard, crimson fire glow; (13) Emperor's Mercy — a crimson and gold rapier with an imperial eagle on its guard, crimson glow; (14) The Last Word — a black and crimson leafblade with a burning red edge and a single red gem in its pommel, crimson fire glow.
```

`items_armor.png` (14 zırh):
```text
BODY — Fourteen armours in a grid of three columns and five rows (the last cell stays empty), each shown from the front as an empty headless torso piece with its shoulders, no person inside, same size and angle in every cell, with the glow colour given for each: (1) Warden's Gambeson — a quilted blue-grey gambeson with steel studs, cool blue sheen; (2) Silvered Jerkin — a leather jerkin with silvered steel plates and blue trim, cool blue sheen; (3) Duskmail Hauberk — a dark chainmail hauberk with violet-tinted rings and a purple half-cape, violet glow; (4) Bastion Breastplate — a heavy steel breastplate with a tower emblem in violet enamel, violet glow; (5) Kingsguard Cuirass — a polished cuirass with a royal crest and a violet cloak on one shoulder, violet glow; (6) Dawnward Harness — gold-trimmed plate with sunburst motifs on the chest, gold glow; (7) The Gilded Aegis — full gilded plate with a lion aegis on the chest, radiant gold glow; (8) Ashen Gambeson — a charcoal quilted gambeson with ember-glowing gold stitching, gold-ember glow; (9) Starfall Jerkin — dark leather studded with small magenta star crystals, magenta glow; (10) Wyrmscale Hauberk — a hauberk of iridescent dragon scales with a magenta sheen; (11) The Unbroken Breastplate — a massive breastplate with glowing magenta cracks mended with gold; (12) Crown Cuirass — a crimson-enamelled cuirass with a gold crown on the chest, crimson glow; (13) The Last Harness — black and crimson plate with burning red runes, crimson fire glow; (14) Emperor's Aegis — imperial gold and crimson plate with an eagle on the chest and a fur mantle, crimson radiance.
```

`items_horses.png` (14 at):
```text
BODY — Fourteen horses in a grid of three columns and five rows (the last cell stays empty), each a three-quarter head-and-chest portrait facing right with its tack or barding, same size and angle in every cell, with a crisp rim light so dark coats separate from the background, and the glow colour given for each: (1) Swaybacked Plough Horse — an old gentle chestnut plough horse with a blue-dyed harness and silver fittings, cool blue sheen; (2) Silvermane Pony — a sturdy pony with a flowing silver mane and a blue bridle, cool blue sheen; (3) Duskmane Rouncey — a dark bay rouncey with a violet-black mane and purple barding, violet glow; (4) Kingsguard Courser — a sleek grey courser in a royal purple and gold caparison, violet glow; (5) Dawnward Destrier — a powerful destrier in violet barding with small sun motifs, violet glow; (6) The Ninth Siege Warhorse — a scarred armoured warhorse in battle-worn gold plate with nine notches cut into its chanfron, gold glow; (7) The Gilded Charger — a white charger in gilded barding, radiant gold glow; (8) Starfall Plough Horse — a humble plough horse in a golden harness with a starlit gold mane, gold glow; (9) Wyrmborn Pony — a pony with faint dragon scales on its neck and glowing magenta eyes and mane; (10) The Tempest Rouncey — a storm-grey horse with a lightning-streaked magenta mane; (11) Crown Courser — a black courser with a small crown-shaped chanfron, magenta glow; (12) The Last Destrier — a black destrier in crimson and black barding with glowing red eyes, crimson glow; (13) Emperor's Warhorse — a white warhorse in imperial crimson and gold barding, crimson radiance; (14) Sunrise Charger — a chestnut-gold charger with a flame-red mane and a crimson caparison, crimson glow.
```

**Birebir kelimeler:** yok (eşya adları yalnız betimleme içindir; tabloya **yazılmaz** — tırnaksız verildi). **EMPTY:** yok.
**Kesim notu:** `scripts/cut-item-paintings.py` (nesne maskesi + parlaklık anahtarı, ışıma korunur) → `items/painted/<tanım id>` **256×256**, hücre ~280 px boyanır. Sıra = tanım sırası: silahlar weapon_rare_02 … weapon_special_03, zırhlar armor_rare_02 … armor_special_03, atlar horse_rare_02 … horse_special_03. `gen-balance.py`'de `art = tanım id` olur; `item_art.gd` 63'ünün de var olduğunu doğrular.

### R14 `crests_sheet.png` — 12 hanedan arması

**Tuval:** 9:16, ≥1080×1920 → 941×1672 · **Sıra:** STYLE → SHEET → BODY → TEXT RULE → AVOID · **Dalga:** herhangi

**Ne için:** Krallık armaları ve kozmetik armalar. Mevcut 4 arma (aslan, kurt, geyik,
kartal) da tek görünüm için aynı sayfada yeniden boyanır.

```text
BODY — Twelve heraldic heater shields in a grid of three columns and four rows, all the same size and shape, each with a bevelled antique-gold rim, a subtle enamel sheen and a painted charge: (1) a golden lion rampant on crimson; (2) a silver wolf's head on steel blue; (3) a golden stag on forest green; (4) a black eagle with spread wings on silver; (5) a black bear standing on brown; (6) a red dragon on black; (7) a black boar on ochre; (8) a white falcon on sky blue; (9) a silver tower on purple; (10) a crimson rose on white; (11) a golden sun with a face on azure; (12) a black raven on grey.
```

**Birebir kelimeler:** yok. **EMPTY:** yok.
**Kesim notu:** `icons/crest_<id>` **91×120** (≥182×240 boyanır; rect + maske): lion, wolf, stag, eagle, bear, dragon, boar, falcon, tower, rose, sun, raven.

---
## 8. Teslim kontrol listesi

Toplam **74 dosya**. Hepsi `art/reference/` altına, buradaki adla. Boyut sütunu
üretim boyutudur; biz normalize ederiz.

| # | Dosya | Parti | Üretim boyutu | Teslim |
|---|---|---|---|---|
| 1 | `court.png` | 1 | 9:16, ≥1080×1920 | [ ] |
| 2 | `store.png` | 1 | 9:16, ≥1080×1920 | [ ] |
| 3 | `store_2.png` | 1 | 9:16, ≥1080×1920 | [ ] |
| 4 | `offers.png` | 1 | 9:16, ≥1080×1920 | [ ] |
| 5 | `offers_popup.png` | 1 | 9:16, ≥1080×1920 | [ ] |
| 6 | `mail.png` | 1 | 9:16, ≥1080×1920 | [ ] |
| 7 | `favour.png` | 1 | 9:16, ≥1080×1920 | [ ] |
| 8 | `wardrobe.png` | 1 | 9:16, ≥1080×1920 | [ ] |
| 9 | `rewards_sheet.png` (S1) | 1 | 9:16, ≥1080×1920 | [ ] |
| 10 | `ui_bits_sheet.png` (S2) | 1 | 9:16, ≥1080×1920 | [ ] |
| 11 | `diamond_packs_large.png` (S3) | 1 | 9:16, ≥1080×1920 | [ ] |
| 12 | `frames_cosmetic_a.png` (S4a) | 1 | 9:16, ≥1080×1920 | [ ] |
| 13 | `frames_cosmetic_b.png` (S4b) | 1 | 9:16, ≥1080×1920 | [ ] |
| 14 | `plates_sheet.png` (R9) | 1 | 9:16, ≥1080×1920 | [ ] |
| 15 | `chests.png` | 2 | 9:16, ≥1080×1920 | [ ] |
| 16 | `calendar.png` | 2 | 9:16, ≥1080×1920 | [ ] |
| 17 | `deeds.png` | 2 | 9:16, ≥1080×1920 | [ ] |
| 18 | `road.png` | 2 | 9:16, ≥1080×1920 | [ ] |
| 19 | `guide.png` | 2 | 9:16, ≥1080×1920 | [ ] |
| 20 | `events.png` | 2 | 9:16, ≥1080×1920 | [ ] |
| 21 | `collect_events.png` | 2 | 9:16, ≥1080×1920 | [ ] |
| 22 | `events_kit.png` | 2 | 9:16, ≥1080×1920 | [ ] |
| 23 | `event_themes.png` | 2 | 9:16, ≥1080×1920 | [ ] |
| 24 | `pass.png` | 2 | 9:16, ≥1080×1920 | [ ] |
| 25 | `family_storehouse.png` | 2 | 9:16, ≥1080×1920 | [ ] |
| 26 | `frames_noble.png` (S5a) | 2 | 9:16, ≥1080×1920 | [ ] |
| 27 | `frames_events.png` (S5b) | 2 | 9:16, ≥1080×1920 | [ ] |
| 28 | `titles_sheet.png` (S5c) | 2 | 9:16, ≥1080×1920 | [ ] |
| 29 | `ftue_sheet.png` (S6) | 2 | 9:16, ≥1080×1920 | [ ] |
| 30 | `reward_icons.png` (S8) | 2 | 9:16, ≥1080×1920 | [ ] |
| 31 | `arena.png` | 3 | 9:16, ≥1080×1920 | [ ] |
| 32 | `bounties.png` | 3 | 9:16, ≥1080×1920 | [ ] |
| 33 | `throne.png` | 3 | 9:16, ≥1080×1920 | [ ] |
| 34 | `chat.png` | 3 | 9:16, ≥1080×1920 | [ ] |
| 35 | `chat_rules.png` | 3 | 9:16, ≥1080×1920 | [ ] |
| 36 | `help.png` | 3 | 9:16, ≥1080×1920 | [ ] |
| 37 | `profile.png` | 3 | 9:16, ≥1080×1920 | [ ] |
| 38 | `rival.png` | 3 | 9:16, ≥1080×1920 | [ ] |
| 39 | `arena_kit.png` (S7) | 3 | 9:16, ≥1080×1920 | [ ] |
| 40 | `campaign.png` | 4 | 9:16, ≥1080×1920 | [ ] |
| 41 | `campaign_map_02.png` | 4 | 3:4, ≥1552×2070 | [ ] |
| 42 | `campaign_map_03.png` | 4 | 3:4, ≥1552×2070 | [ ] |
| 43 | `campaign_map_04.png` | 4 | 3:4, ≥1552×2070 | [ ] |
| 44 | `campaign_map_05.png` | 4 | 3:4, ≥1552×2070 | [ ] |
| 45 | `campaign_map_06.png` | 4 | 3:4, ≥1552×2070 | [ ] |
| 46 | `campaign_map_07.png` | 4 | 3:4, ≥1552×2070 | [ ] |
| 47 | `campaign_map_08.png` | 4 | 3:4, ≥1552×2070 | [ ] |
| 48 | `campaign_map_09.png` | 4 | 3:4, ≥1552×2070 | [ ] |
| 49 | `campaign_map_10.png` | 4 | 3:4, ≥1552×2070 | [ ] |
| 50 | `hunt.png` | 4 | 9:16, ≥1080×1920 | [ ] |
| 51 | `expedition.png` | 4 | 9:16, ≥1080×1920 | [ ] |
| 52 | `forge.png` | 4 | 9:16, ≥1080×1920 | [ ] |
| 53 | `talents.png` | 4 | 9:16, ≥1080×1920 | [ ] |
| 54 | `boss.png` | 4 | 9:16, ≥1080×1920 | [ ] |
| 55 | `bosses_ashfall_wyrm.png` | 4 | 16:10, ≥1542×920 | [ ] |
| 56 | `bosses_garrow.png` | 4 | 16:10, ≥1542×920 | [ ] |
| 57 | `bosses_iron_colossus.png` | 4 | 16:10, ≥1542×920 | [ ] |
| 58 | `bosses_fen_witch.png` | 4 | 16:10, ≥1542×920 | [ ] |
| 59 | `bosses_ulgrim.png` | 4 | 16:10, ≥1542×920 | [ ] |
| 60 | `bosses_black_knight.png` | 4 | 16:10, ≥1542×920 | [ ] |
| 61 | `war.png` | 4 | 9:16, ≥1080×1920 | [ ] |
| 62 | `collect_jobs_a.png` (R1) | Yeniden | 9:16, ≥1080×1920 | [ ] |
| 63 | `collect_jobs_b.png` (R1) | Yeniden | 9:16, ≥1080×1920 | [ ] |
| 64 | `ledger_upgrades.png` (R2) | Yeniden | 9:16, ≥1080×1920 | [ ] |
| 65 | `ledger_holdings.png` (R2) | Yeniden | 9:16, ≥1080×1920 | [ ] |
| 66 | `works_sheet.png` (R3) | Yeniden | 9:16, ≥1080×1920 | [ ] |
| 67 | `avatars_sheet.png` (R4) | Yeniden | 9:16, ≥1080×1920 | [ ] |
| 68 | `soldiers_sheet.png` (R6) | Yeniden | 9:16, ≥1080×1920 | [ ] |
| 69 | `numerals_sheet.png` (R7) | Yeniden | 9:16, ≥1080×1920 | [ ] |
| 70 | `battle_fx.png` (R8) | Yeniden | 9:16, ≥1080×1920 | [ ] |
| 71 | `items_weapons.png` (R10) | Yeniden | 9:16, ≥1080×1920 | [ ] |
| 72 | `items_armor.png` (R10) | Yeniden | 9:16, ≥1080×1920 | [ ] |
| 73 | `items_horses.png` (R10) | Yeniden | 9:16, ≥1080×1920 | [ ] |
| 74 | `crests_sheet.png` (R14) | Yeniden | 9:16, ≥1080×1920 | [ ] |

**Tablo gerekmeyenler:** Sign in with Apple düğmesi (Apple'ın resmi düğmesi) ·
HUNT düğmesi (R11, `army.png`'den kesilir).
