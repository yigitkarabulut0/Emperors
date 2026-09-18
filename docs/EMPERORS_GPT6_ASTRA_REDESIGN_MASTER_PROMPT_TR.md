# EMPERORS — GPT-6 ASTRA İÇİN EKSİKSİZ YENİDEN TASARIM MASTER PROMPTU

Bu metni yeni bir GPT-6 Astra konuşmasının ilk mesajı olarak kullan. Köşeli parantezli alanları doldurabilir veya boş bırakarak Astra'nın önce bunları sormasını sağlayabilirsin.

---

## PROMPT BAŞLANGICI

Sen kıdemli bir mobil oyun ürün tasarımcısı, game UX/UI direktörü, görsel sistem tasarımcısı ve asset production lead'sin. Birlikte **Emperors** adlı mevcut ve çalışan bir oyunun bütün oyuncu deneyimini görsel olarak sıfırdan tasarlayacağız.

Bu bir fikir üretme egzersizi değildir. Oyunun mekanikleri, özellikleri ve yönlendirmeleri zaten vardır. Senin görevin:

1. Mevcut işlevlerin hiçbirini kaybetmeden yepyeni bir görsel kimlik ve UX sistemi kurmak.
2. Her ekranı tek tek, üretilebilir ayrıntıda tasarlamak.
3. Her ekranın bütün durumlarını, etkileşimlerini, yönlendirmelerini ve dinamik verilerini belirtmek.
4. İhtiyaç duyulan her asset'i tek tek listelemek ve üretim promptlarını hazırlamak.
5. Ekranlar arasında tutarlı bir component/design-token sistemi kurmak.
6. Hiçbir özellik, modal, hata durumu, boş durum, kilitli durum veya geri dönüş yolunu atlamamak.

Bu brief oyuncunun gördüğü Godot oyun istemcisini kapsar. Repo içindeki geliştiriciye özel Next.js live-ops/admin paneli oyuncu deneyiminin veya oyun asset paketinin parçası değildir; onu bu çalışmaya dahil etme. İstenirse daha sonra ayrı bir admin tasarım brief'i hazırlanacaktır.

Ben sana ekranları **birer birer** yaptıracağım. Bir mesajda bütün oyunu yüzeysel biçimde tasarlama. Her cevapta yalnızca üzerinde çalıştığımız ekranı tam çöz; sonra onayımı bekle.

### Proje girdileri

- Yeni sanat yönü: **[buraya yazacağım; boşsa işe başlamadan önce 3 güçlü ve birbirinden belirgin sanat yönü öner]**
- Hedef duygu: **[örn. kudretli, yaşayan, premium, karanlık, sıcak, tarihsel, fantastik]**
- Referans oyunlar/filmler/sanatçılar: **[varsa]**
- Kaçınılacak stiller: **[varsa]**
- Platform önceliği: iPhone; sonra Android; sonra Steam.
- Oyun içi metin dili: İngilizce.
- Benimle çalışma dili: Türkçe.
- Tasarım grid'i: 941 × 1672 portrait temel tuval. Daha uzun telefonlarda arayüz dikey olarak daha fazla alan göstermeli; körlemesine ölçeklenmemeli. Safe area/notch/Dynamic Island hesaba katılmalı.
- Kontrol modeli: dokunmatik öncelikli; minimum güvenli tap hedefi yaklaşık 44 pt. Desktop'ta mouse ile de çalışmalı.

## 1. OYUNUN KİMLİĞİ VE GERÇEK OYUN DÖNGÜSÜ

**Emperors**, karakter yürütmesi veya açık dünya gezintisi olmayan, tamamen menüler, kartlar, listeler, seçimler, ilerleme sayıları ve kısa savaş gösterimleri üzerinden oynanan 2D portrait mobil idle/RPG kingdom oyunudur. Yapısal olarak klasik sosyal/idle suç-imparatorluğu oyunlarının ortaçağ krallığına uyarlanmış hali ile karakter ekipmanı, asker ordusu ve asenkron PvP'yi birleştirir.

Oyuncu bir lorddur. Temel döngü şöyledir:

1. Zamanla yenilenen enerjiyi Collect işlerinde harcar.
2. Gold ve XP kazanır; level atlar.
3. Level ile yeni sekmeler, işler ve sistemler açar.
4. Stat point dağıtır; ekipman satın alır, kuşanır, satar veya Collection'a bağışlar.
5. Family upgrade'ları ve Territory holding'leri satın alarak aktif ve pasif ekonomisini büyütür.
6. Asker slotları açar, asker toplar, onların rarity/tier'ını reroll eder ve ekipman verir.
7. Army Might değerini yükseltir.
8. Diğer oyunculara asenkron raid yapar; gold çalar, XP kazanır, gelen saldırılara revenge yapar ve battle replay izler.
9. Royal Treasury'ye gold yatırarak bir kısmını saldırılardan korur; yatırırken ücret öder.
10. Level 20'de bir Kingdom'a katılır veya kurar; bağış, roller, ortak upgrade'lar, favour shop ve sıralamalar üzerinden sosyal uzun dönem döngüsüne girer.
11. Level cap'te Legacy başlatarak bazı ilerlemeyi sıfırlar, kalıcı income bonusu kazanır ve döngüyü tekrarlar.

Ana kaynaklar:

- **Gold:** işler, passive tax, raid ve ödüllerden gelir; shop, upgrade, holding, asker, slot, kingdom ve başka ilerleme harcamalarında kullanılır. Elde taşınan gold çalınabilir.
- **Treasury gold:** vault'ta korunan gold; raid ile çalınamaz. Deposit sırasında %10 fee yanar, withdraw ücretsizdir.
- **Diamonds:** level-up ve daily reward ile kazanılır; full energy, protection/shield, shop reroll, soldier reroll ve rename gibi zaman/konfor işlemlerinde kullanılır. Doğrudan güç paketi gibi sunulmamalıdır.
- **Energy:** aktif aksiyonların yakıtıdır; zamanla dolar, level-up'ta tamamen yenilenir. Max energy ile regen hızı ayrı kavramlardır.
- **XP / Level:** ana açılım eksenidir. Level cap 60'tır.
- **Stat points:** level-up ile gelir; Attack, Defence veya Max Energy'ye kalıcı ve geri alınamaz biçimde dağıtılır.
- **Might:** hero + asker ordusunun karşılaştırmalı savaş gücüdür.
- **Kingdom treasury / XP / reputation:** Kingdom'a ait ortak ilerleme kaynaklarıdır.
- **Favour:** kişisel Kingdom bağış ödülüdür; Kingdom shop'ta harcanır.
- **Collection luck:** benzersiz item tasarımlarını kalıcı olarak Collection'a bağışlayarak artar; gelecekteki roll şanslarını iyileştirir.
- **Legacy stacks:** level 60 döngüsünü bitirerek kazanılan kalıcı income bonus katmanıdır; en fazla 10 stack.

Önemli oyun gerçeği: istemci oyun sayılarını hesaplamaz ve savaşı simüle etmez. Gold, XP, fiyat, payout, odds, Might, raid sonucu ve diğer sayısal sonuçlar sunucudan çözülmüş halde gelir. UI bunları gösterir, açıklar ve animasyonla sunar.

## 2. GÜNCEL İLERLEME VE AÇILIMLAR

Ana navigation'da 7 görünür sekme vardır:

1. Family — level 1
2. Collect — level 1
3. Shop — level 2
4. Inventory — level 3
5. Army — level 5
6. Attack — level 10
7. Kingdom — level 20; Legacy sonrasında level düşse bile mevcut Kingdom üyesi erişimini korur.

Family içinde ayrıca şu alt sistemler kademeli açılır:

- Estates/Territory — level 4
- Royal Treasury/Bank — level 8
- Legacy — level 60'ta kullanılabilir

Diğer önemli gerçekler:

- Level cap 60.
- Oyuncunun enerji tabanı 120; level başına +4 max energy; energy stat point başına +5 max energy; baz regen 30 saniyede 1 energy.
- Her level 3 stat point ve 5 diamond verir; level-up energy'yi doldurur.
- Rename 100 diamond.
- Full Energy 12 diamond.
- 8 saatlik Protection 20 diamond.
- Daily diamond takvimi 7 gün: 5, 5, 10, 10, 15, 15, 25; gün kaçırılırsa streak resetlenir.
- Inventory kapasitesi 150 item.
- 3 item slot türü vardır: Weapon, Armor, Horse. Hero'nun ve her askerin ayrı üç slotu olabilir.
- 7 rarity/tier: Common, Uncommon, Rare, Epic, Legendary, Mystic, Special. Rarity yalnızca renkle anlatılmamalı; adı ve sembolik rank/pip/frame farkı da olmalı.
- Rarity renk referansı işlevsel anlam için: Common gri, Uncommon yeşil, Rare açık mavi, Epic mor, Legendary altın, Mystic parlak magenta, Special kırmızı. Yeni sanat yönünde tonlar değişebilir fakat yedi kademe anında ayırt edilmelidir.
- Asker türleri: Villager, Mercenary, Gladiator.
- En fazla 10 asker slotu vardır. Askerlerin ayrıca büyüyen bir level sistemi yoktur; type + tier + ekipman ile güçlenirler.
- Recruit edilen askerin tier'ı reroll edilebilir. Tek roll ve hedef tier'a ulaşana/diamond bitene/uygulama arka plana gidene kadar süren Auto Roll vardır.

## 3. GLOBAL UYGULAMA MİMARİSİ VE NAVIGATION

Akış:

`Native launch image → Loading/Boot → Sign In/Create Account → Main Game Shell → 7 ana sekme → sheet/modal/ceremony/battle overlay'leri`

Ana kabuk her ana sekmede kalıcı olarak şunları gösterir:

- Oyuncu portresi ve level; portreye dokununca Profile açılır.
- 7 ana navigation girişi.
- Aktif sekme durumu.
- Kilitli sekmelerde dim/lock + “LV N” bilgisi; dokununca unlock mesajı.
- Gold, Diamonds, Energy/Max Energy kaynak göstergeleri.
- Gold alanına dokunmak Collect'e götürür.
- Diamond alanına dokunmak Daily Reward sayfasını açar.
- Energy alanındaki artı Full Energy satın alma akışını açar; ürün bulunamazsa Shop'a yönlendirebilir.
- Bir sonraki energy için geri sayım.
- Aktif shield/protection için kalan süre.
- Collect üzerinde claim edilebilir quest sayısı badge'i.
- Attack üzerinde revenge sayısı badge'i.
- Kingdom üzerinde bekleyen join request sayısı badge'i.
- Diamond göstergesinde claim edilebilir daily reward noktası/badge'i.
- Bağlantı yoksa kaybolmayan, dokunarak retry yapılabilen offline banner.
- Başarı/hata/bilgi için kısa süreli toast.

Ana navigation mevcut oyunda sol dikey rail'dir, fakat yeni tasarımda bunu korumak zorunda değilsin. Bottom nav, hibrit nav veya başka bir mobil çözüm önerebilirsin. Ancak 7 sekmenin keşfedilebilirliği, locked/badge/active durumları ve tek elle kullanım çözülmek zorundadır. Navigation değişirse her yönlendirmenin yeni karşılığını açıkla.

Overlay katman önceliği:

1. Normal ana ekran
2. Sheet/full-page overlay
3. Battle replay
4. Level/Mastery ceremony
5. Confirmation/input dialog
6. Toast

Bir scene/account geçişinde açık overlay'ler temizlenmelidir. Back/close davranışını her ekran için açıkça belirt.

## 4. EKSİKSİZ EKRAN VE YÜZEY ENVANTERİ

Aşağıdaki hiçbir yüzeyi atlama. Bunları üretim checklist'i olarak kullan.

### A. Giriş ve yaşam döngüsü

- A01 Native Launch/Splash
- A02 Loading/Boot — normal progress
- A03 Loading/Boot — offline retry
- A04 Loading/Boot — server unavailable/retry loop
- A05 Sign In / Create Account
- A06 First-run Onboarding — 5 adım
- A07 Returning player / While You Were Away
- A08 App-resume refresh durumu

### B. Global shell ve ortak bileşenler

- B01 Main shell/navigation/chrome
- B02 Locked tab durumu
- B03 Nav badge ve daily indicator durumları
- B04 Offline persistent banner
- B05 Toast: success/error/info
- B06 Generic confirmation dialog
- B07 Destructive confirmation dialog
- B08 Text input dialog
- B09 Numeric amount dialog/input
- B10 Choice/action sheet
- B11 Loading/skeleton state
- B12 Empty state
- B13 Server/error/retry state

### C. Ana sekmeler

- C01 Family
- C02 Collect
- C03 Inventory
- C04 Shop / Royal Market
- C05 Army
- C06 Attack — Revenge görünümü
- C07 Attack — Targets görünümü
- C08 Kingdom — Realm overview
- C09 Kingdom — Lords
- C10 Kingdom — Works
- C11 Kingdom — Ranks
- C12 Kingdom Hall — henüz Kingdom'sız oyuncu

### D. Yardımcı sayfalar ve yoğun akışlar

- D01 Profile / Your Lordship
- D02 Avatar picker state
- D03 Global Leaderboards — Might / Level / Wealth
- D04 Daily Reward calendar
- D05 Stat Points allocation
- D06 Royal Treasury
- D07 Item Picker / gear selection
- D08 Collection / Wall
- D09 Full Battle History
- D10 Raid Rules
- D11 Recruit Odds
- D12 Soldier Reroll panel — single roll
- D13 Soldier Reroll panel — auto-roll target selection/running/stopped
- D14 Battle Replay — intro/fortune
- D15 Battle Replay — combat
- D16 Battle Replay — victory
- D17 Battle Replay — defeat
- D18 Level-up Ceremony
- D19 Mastery Ceremony
- D20 Legacy confirmation/result states

## 5. EKRANLARIN İŞLEVSEL ŞARTNAMESİ

### A01–A04 — Launch ve Boot

Amaç: Uygulama açılışını premium ve güvenilir hissettirmek; session/token yenileme, state yükleme ve bağlantı sorunlarını görünür kılmak.

Zorunlu davranışlar:

- Native launch statik olmalı; sahte çalışan progress göstermemeli.
- Boot ekranında gerçek yükleme adımlarına bağlı progress olmalı.
- Mevcut session varsa token refresh denenir, ardından game state alınır.
- İnternet yoksa “Cannot reach the server. Retrying…” benzeri kalıcı durum ve otomatik retry.
- Session geçerli fakat server cevaplamıyorsa kullanıcı login'e düşürülmez; artan aralıklarla retry edilir.
- Session yoksa auth ekranına gider.
- Başarıda main shell açılır.
- Çok uzun cihazlarda logo/oyun adı kırpılmamalı; safe area çözümü gösterilmeli.

Asset ihtiyacı: app icon, launch art, loading art/background, progress track, progress fill, studio mark, gerekiyorsa bağlantı/error sembolleri.

### A05 — Sign In / Create Account

Zorunlu içerik ve durumlar:

- Oyun markası/atmosferi.
- Username field: 3–16 karakterlik kullanıcı adı kuralına uygun; harf, rakam, underscore.
- Password field, gizli metin.
- SIGN IN ana aksiyonu.
- CREATE ACCOUNT ikincil aksiyonu.
- Inline validation/server error alanı.
- Loading/busy state; double submit engeli.
- “Entering the realm…” başarı/geçiş durumu.
- Session server tarafından bitirildiyse sebebi bu ekranda görünür.
- Klavye açılınca form klavye altında kalmamalı.

### A06 — Onboarding

İlk kez gelen düşük-level oyuncuya bir kez gösterilir. 5 adım:

1. Collect: energy harca, gold + XP kazan, level-up energy doldurur.
2. Family: stat points, hero gear, estates/passive income.
3. Army: asker recruit et, gear tak, tier reroll et, Might artır.
4. Attack: level 10'da raid ve revenge; Treasury gold korunur.
5. Kingdom: level 20'de join/found ve ortak gelişim.

Her adımda görsel, başlık, kısa açıklama, progress dots, Next; ara adımlarda Skip; son adımda Begin. Kullanıcıyı bilgiye boğmadan oyunun gerçek mental modelini kur.

### A07 — While You Were Away

Yalnızca oyuncu yokken raid olduysa açılır:

- Kaç kez raid edildi.
- Toplam gold lost.
- Başarılı savunmalardan ransom earned.
- Treasury gold'un güvende olduğu hatırlatması.
- Hâlâ kullanılabilir revenge sayısı.
- TAKE REVENGE → Attack/Revenge.
- LATER/CLOSE.
- Gold kaybı yok, yalnız ransom var; yalnız kayıp var; ikisi de var durumlarını ayrı çöz.

### C01 — Family

Bu ekran oyuncunun kişisel merkezidir ve uzun dikey içerik taşıyabilir.

Üst bölüm:

- Büyük hero portresi.
- Oyuncu adı ve rename/edit aksiyonu.
- Level.
- XP current / XP-to-next progress.
- Attack, Defence, Power/Might göstergeleri.
- Unspent stat point varsa belirgin çağrı; stat strip'e dokununca Stat Points sayfası.

Hero gear:

- Weapon, Armor, Horse slotları.
- Dolu slot: item art, tier, level/ilvl ve anlamlı temel stat/power.
- Boş slot: hangi item türünün takılacağını anlatan ghost/label.
- Slot'a dokununca Item Picker; dolu item başka biri tarafından giyiliyorsa transfer confirmation gerekir.
- EQUIP BEST: scope hero.

Family ledger/card grupları:

- 11 Family upgrade: Granary, Tithe Barn, Scriptorium, Watchtower Beacons, Larder, Armoury, Bulwark, Stables, Merchant Ties, War Chest, Ransom Coffers.
- Her kart: isim, açıklama, mevcut level/max, mevcut etki, sonraki etki, fiyat, affordability, maxed, locked state, upgrade CTA.
- Upgrade grupları ekonomik anlamlarına göre görsel olarak ayrılmalı: income/learning, army, realm/raid.
- 8 Territory holding: Wheat Farm, Watermill, Stone Quarry, Vineyard, Iron Mine, Market Square, River Port, Ducal Mint.
- Her holding: unlock level, level/max 5, current hourly yield, next yield, price, expand/buy CTA, locked/maxed/affordable durumları.
- Royal Treasury card: vault bakiyesi, unlock level 8, deposit fee bilgisi, page'e giriş.
- Legacy card: stack/max, current permanent income bonus, next bonus, available/locked state ve Begin Legacy akışı.

Kartlardan her harcama önce anlaşılır confirmation gösterir; işlem sırasında ilgili CTA busy/disabled olur; başarıda state yenilenir ve feedback verilir.

### C02 — Collect

Oyunun en sık kullanılan aktif kazanç ekranıdır.

Today's Quests bölümü:

- Her gün oyuncunun level'ında yapılabilir görevlerden 3 tanesi.
- Türler: belirli sayıda collect, energy harcama, raid win, shop purchase.
- Kart başına: isim, kısa blurb, progress/target, reward XP + gold, done, claimable, claimed.
- Günün yerel midnight'ına kalan süre.
- Claim ile ödül float/feedback ve yeni state.
- Empty/error/loading states.

Job listesi — 15 iş:

1. Pick Grapes — L1 — 1 energy
2. Gather Strawberries — L3 — 2 energy
3. Harvest Wheat — L5 — 3 energy
4. Tend the Orchard — L8 — 4 energy
5. Chop Timber — L11 — 6 energy
6. Fish the River — L14 — 8 energy
7. Quarry Stone — L18 — 10 energy
8. Mine Iron Ore — L22 — 13 energy
9. Hunt the King's Wood — L26 — 16 energy
10. Escort a Trade Caravan — L30 — 20 energy
11. Smelt Silver — L35 — 25 energy
12. Clear the Bandit Camp — L40 — 31 energy
13. Delve the Deep Mine — L45 — 38 energy
14. Collect the Crown Tithe — L52 — 46 energy
15. Plunder the Dragon's Hoard — L60 — 55 energy

Her job row:

- Tema/iş illüstrasyonu.
- Job name.
- Energy cost, resolved gold payout, resolved XP payout.
- COLLECT CTA.
- Locked ise gereken level.
- Yetersiz energy durumu.
- Current total collects.
- Mastery track: reached milestone, next milestone, after-next marker; permanent gold bonus.
- Mastery threshold'ları: 25/+5%, 50/+10%, 100/+15%, 250/+20%, 500/+25%, 1000/+30%. Bunlar stack olmaz; ulaşılan en yüksek bonus geçerlidir.
- Dokunma sonrası optimistic hissiyat olabilir fakat confirmed state mantığı bozulmamalı; double-spend/double-tap önlenmeli.

### C03 — Inventory

Üstte hero'nun Equipped Gear bölümü:

- Weapon, Armor, Horse.
- Dolu slot'a dokununca unequip confirmation.
- Boş slot state.

Filtreler:

- All, Common, Uncommon, Rare, Epic, Legendary, Mystic, Special.
- Aktif/inaktif states.
- Collection/Wall giriş butonu.
- `used / 150` kapasite.

Bag item grid/list:

- Başkası veya hero tarafından giyilen item'lar ana bag grid'inde gösterilmez.
- Item art, name, slot type, rarity, ilvl, Attack/Defence/Speed, combined Power, masterwork göstergesi, sell price.
- EQUIP ve SELL aksiyonları.
- Equip, doğru hero slotuna gider; mevcut item varsa davranış açık olmalı.
- Sell destructive confirmation; item kalıcı silinir ve belirtilen gold gelir.
- Empty inventory, filtered-empty, full inventory, loading, error states.
- Uzun isimler ve yüksek sayılar taşmamalı.

### C04 — Shop / Royal Market

- Her oyuncuya özel 6 deterministik offer.
- Offer'lar 5 dakikalık window sonunda otomatik değişir; kalan süre görünür.
- Reroll ile hemen yenilenebilir: ilk maliyet 8 diamond, her aynı-window reroll'da +6 diamond.
- Inventory used/cap görünür; full ise buy yapılamaz ve sebebi açıklanır.
- Her offer: item art, name, Weapon/Armor/Horse, rarity, ilvl, temel statlar, Power, price, affordability, BUY.
- Satın alınmış slot window sonuna kadar SOLD görünür.
- Buy confirmation, stale shop/window değişti durumu, insufficient gold, inventory full, server error.
- Reroll CTA: maliyet, diamond bakiyesi, afford/disabled; confirmation.

Diamond Goods:

- Full Energy: 12 diamonds; enerji zaten full ise “not useful” ve sebebi.
- Protection: 8 saat, 20 diamonds; zaten shield varsa tekrar alınamaz ve sebebi.
- Diamonds kazanılır; bu ürünler para ile diamond paketi ekranı değildir.

### C05 — Army

Üst bölüm:

- Total Army Might.
- Hero Support açıklaması: Family Armoury/Bulwark/Stables bonusları bütün askerlerin Attack/Defence/Speed'ini artırır.
- Hero support Attack/Defence/Speed veya ilgili toplu etki değerleri.

Soldier strip:

- Yatay scroll.
- Her açılmış slot görünür; boş ve dolu slotlar farklıdır.
- Seçili slot açıkça işaretlenir.
- Drag ile yanlışlıkla select olmamalı; tap ile seçilir.
- En sonda Next Slot: index, cost, gereken level, free/paid, unlock CTA.
- Toplam dolu/açık slot sayısı.
- AUTO EQUIP: army scope.

Soldier mini card:

- Portrait, type/name, tier/rank, Attack, Defence, Speed, Might/Power.

Selected Soldier:

- Büyük portre.
- Name, type, tier.
- Kısa karakter/fantasy descriptor.
- Attack, Defence, Power/Might.
- 3 gear slotu; boş/dolu durum; item seçimi; başka asker/hero'dan alma confirmation.
- REROLL ve mevcut diamond cost.
- DISMISS: destructive confirmation; askerin üzerindeki gear kaybolmamalı, inventory'ye dönmeli; refund feedback.
- Boş seçili slot state: recruit yönlendirmesi.

Recruit Soldiers:

- Villager, Mercenary, Gladiator kartları.
- Her biri için cost, free-first-recruit state, mümkün tier aralığı, temel karakter farkı, RECRUIT CTA.
- İlk uygun boş slota recruit edilir.
- Boş slot yok, insufficient gold, locked slot, inventory/gear etkisi olmayan durumlar.
- Info → Recruit Odds.

### C06–C07 — Attack

İki görünüm: REVENGE ve TARGETS.

Global:

- Kendi Might değeri.
- Energy cost server'dan gelir.
- Shield durumu.
- Akış ekran içeriğine göre uzar; kart sayısı sabit varsayılmaz.
- History preview ve View All.
- Raid rules info.

Revenge:

- Her raider için ayrı kart; sayı badge'i.
- Empty state: “No scores to settle” ve revenge'in faydasını açıklar.
- Kart: portrait, crest, name, level, Might, estimated steal, steal rate, half energy cost, expiry countdown, ATTACK.
- Revenge 24 saat kullanılabilir; hedef shield'ını yok sayar; normal saldırının yarı energy'si ve daha yüksek steal oranı kullanır.

Targets:

- Matchmade gerçek oyuncu veya bot target kartları.
- Empty state: uygun level bandında/shield dışında rival yok; retry expectation.
- Kart: portrait, crest, name, level, Might, estimated steal, steal %, energy cost.
- Kendi Might vs onların Might karşılaştırma barı.
- Shielded target'ta Attack yerine shield + kalan süre.
- Aynı Kingdom üyeleri hedef olamaz.

Attack confirmation:

- Hedef adı, energy cost, mevcut energy, kazanılırsa tahmini max gold.
- Revenge ise avantajlarını açıklar.
- Destructive/danger tonlu ATTACK CTA.
- Busy state ile double raid engellenir.
- Sonuçta Battle Replay açılır; kapanınca target/history listeleri yenilenir.

History preview/full history:

- Oyuncunun başlattığı savaş: Victory vs / Defeat vs.
- Oyuncuya gelen savaş: Held off / Raided by.
- Opponent, level, ne kadar zaman önce, gold delta, result icon.
- Satıra tap → stored replay.
- Son 50 kayıt; boş state.

Raid kuralları:

- Attack level 10'da açılır.
- Benzer level bandı; level 10 altı hedeflenmez.
- Yalnız elde taşınan gold çalınır, vault değil.
- Normal steal oranı, attacker-level cap ve War Chest etkisi.
- Saldırıyı kaybetmek energy harcatır fakat ek gold kaybettirmez; defender ransom kazanır.
- Soyulan defender 30 dakika shield alır.
- Aynı target için cooldown vardır.
- Revenge 24 saat, yarım energy, yükseltilmiş steal ve shield bypass.

### D14–D17 — Battle Replay

Savaş sunucu tarafından önceden çözülmüş event log'un görsel playback'idir; UI sonuç hesaplamaz.

Mevcut combat sunumu iki “champion” figürünün dövüşüdür: her champion kendi bütün ordusunun toplam gücünü temsil eder. Attacker ilk vuruşu yapar. Speed, charge/crit/dodge'a etki eder. Defender home-ground avantajına sahiptir. Her taraf için savaş başında Fortune of War roll'u vardır.

Gerekli sahneler:

1. Versus intro: iki lord/champion, adlar, level'lar, Might karşılaştırması.
2. Fortune of War reveal: iki tarafın tek seferlik fortune sonucu anlaşılır gösterilir; oyuncuya hile hissi vermemeli.
3. Combat: round counter; iki figür; iki HP bar; attacker/defender kimliği; hit, crit, dodge, damage number, HP değişimi, death; okunabilir vuruş temposu.
4. Oyuncunun gerçek hero weapon art'ı mümkünse vuruşta görünür.
5. Skip/fast-forward düşünülebilir ama replay doğruluğunu bozmaz.
6. Victory result: gold stolen/gained, ransom, XP gained, diamonds gained varsa, rounds ve revenge bilgisi.
7. Defeat result: harcanan energy dışında sonuç, defender perspektifinde held-off/ransom anlatımı.
8. Continue ile önceki Attack ekranına dönülür.
9. Stored history replay'inde o zamanki iki ordunun/Might'ın snapshot'ı kullanılır, bugünkü değerler değil.

Battle asset seti ayrıca tasarlanmalı: arena/background, iki champion pose seti veya rig'i, weapon overlay'leri, hit/slash/impact, crit, dodge, death, HP bars, fortune visual, victory/defeat emblems, result panel, particles.

### C08–C12 — Kingdom

Kingdom'sız oyuncu ile Kingdom üyesi tamamen farklı top-level state'tir.

#### Kingdom Hall — Kingdom yok

- Rejoin cooldown varsa görünür countdown ve action kısıtı.
- Gelen invitations listesi; Accept/Decline.
- Aktif outgoing join requests; Withdraw/Cancel.
- Search field; sonuçlar.
- Suggested/recommended kingdoms.
- Kingdom card: crest, name, tag, level, members/cap, reputation, join policy, king, server'ın verdiği action.
- Join policy `open` ise JOIN; `request` ise REQUEST; already requested/pending/invited/full/cooldown durumları.
- Found a Kingdom card: level 20 ve 250,000 gold şartı; name ve en fazla 5 karakter tag girişi; confirmation; yetersizlik sebebi.
- Empty search, no recommendations, loading/error.

#### Kingdom Realm overview — Kingdom üyesi

- Kingdom crest, name, tag/motto/fantasy copy, kingdom level + XP progress.
- Edit name yalnız King.
- Renown/Reputation, Kingdom Treasury, member count/cap.
- Tabs: REALM, LORDS, WORKS, RANKS.
- Realm bonuses: toplu income ve XP gibi üyelere aktif etkiler.
- Kingdom treasury donation card; kişisel Favour sonucu açıklanmalı.
- Reputation/rank card; progress/tier.
- Lords preview + View All.
- Works preview + View All.
- Global kingdom rank preview + Rankings.

#### Lords

- Member rows: portrait, name, level, role, lifetime donated, online/offline mümkünse.
- Roller: King, Captain, Lord.
- Kendi rolün ve yetkilerin.
- King/Captain için join request listesi; Accept/Decline.
- King için join policy: OPEN / BY REQUEST.
- Invite player: name search → player preview → invite.
- Manage member: promote/demote uygun seçenekleri, crown transfer, kick/remove.
- Leave Kingdom confirmation.
- King ayrılacaksa crown succession/transfer kuralları anlaşılır olmalı.
- Empty request, full kingdom, player already in kingdom, cooldown, permission error states.

#### Works

- 8 ortak upgrade: Royal Granaries, Royal Archives, Royal Treasury, Royal Armoury, Royal Bulwark, Royal Couriers, Royal Banners, Royal Court.
- Her kart: art/icon, name, blurb, level/max, current/next benefit, cost, affordability, maxed, upgrade CTA ve izin durumu.
- Kingdom Treasury balance.
- Favour Shop:
  - Energy Potion — 40 favour — full energy.
  - Fresh Wares — 25 favour — market'i hemen restock eder.
  - Scholar's Draught — 120 favour — 2 saat +10% XP.
- Her ürün: useful/not useful, insufficient favour, reason, buy confirmation/result.

#### Ranks

- Kingdom/Player sıralama bağlamlarını anlaşılır ayır.
- En az Might, Level, Wealth board'larına erişim.
- Rank, name/avatar, level, value; current player/kingdom highlight.
- İlk 100, kendi rank'ı top 100 dışında ise mesaj.

### D01–D02 — Profile / Your Lordship

- Seçili avatar ve diğer avatar seçenekleri.
- Avatar değişimi; current “Yours” state.
- Oyuncu adı.
- Rename CTA + 100 diamond fiyat + balance; 3–16 karakter validasyonu.
- Rankings of the Lords → leaderboard.
- Build version ve signed-in username.
- Sign Out → confirmation → auth.
- Delete Account → ilk destructive warning → password confirmation → kalıcı delete.
- Delete açıklaması: lord, gold, vault, gear, soldiers, estates, diamonds ve battles silinir; oyuncu King ise crown en uzun süredir görevde olan Captain'a geçer.
- Wrong password, server error ve success state.

### D03 — Global Leaderboards

- Tabs: MIGHT, LEVEL, WEALTH.
- En iyi 100 lord.
- Row: rank, avatar, name, level, seçilen board değeri.
- İlk 3 için belirgin prestij.
- Current player row highlight.
- “You are ranked #N” veya “not among the hundred yet”.
- Loading/error/empty.

### D04 — Daily Reward

- 7 günlük takvim; ilk satır gün 1–4, ikinci satır gün 5–7; gün 7 haftanın zirvesi gibi okunmalı.
- Streak sayısı.
- Taken, Today/claimable, Ahead states.
- Reward miktarları.
- Claim CTA veya Come Back Tomorrow.
- Daily'nin diamonds'ın enerji ve protection için kullanıldığını, power satmadığını anlatan kısa copy.
- Already claimed yarış durumu.

### D05 — Stat Points

- Attack, Defence, Max Energy üç satır/kart.
- Her biri için mevcut yatırılmış değer ve bir point'in ne kazandırdığı; değerler server'dan gelir.
- `-`, planlanan miktar, `+`, `ALL` kontrolleri.
- Kalan point sayısı.
- Confirm “Spend N Points”.
- Harcamadan önce seçimler geri alınabilir; server'a gönderildikten sonra kalıcı ve taşınamaz.
- 0 point, tek point, çok point, uzun sayı states.

### D06 — Royal Treasury

- On Hand gold.
- In the Vault gold.
- Deposit fee: %10; fee yanar.
- Withdraw ücretsiz.
- Amount field.
- ALL/HALF hızlı seçimleri.
- Deposit ve Withdraw CTA'ları.
- Level 8 öncesi deposit kilitli; vault'taki mevcut gold yine withdraw edilebilir.
- Sonuç feedback'i: moved, fee, banked.
- Invalid/zero/too much amount, insufficient gold, empty vault, busy/error.

### D07 — Item Picker

- Hangi hedef için seçim yapıldığı başlıkta açık: hero veya belirli soldier + Weapon/Armor/Horse.
- Uyumlu slot türündeki item'ları listeler.
- Item name, art, rarity, ilvl, Attack/Defence/Speed, Power, current wearer.
- WEAR CTA.
- Hedefte item varsa TAKE OFF.
- Item başkasındaysa “Take it from them?” confirmation; transfer sonucu iki karakterin state'i de netleşir.
- Hiç uygun item yoksa Shop/Inventory yönlendirmesi düşünülebilir.

### D08 — Collection / Wall

- `held / total designs` progress.
- Current total luck bonus.
- Her yeni design'ın verdiği luck ve aynı slot+rarity üçlüsünü tamamlamanın set bonusu.
- “New to the Wall”: inventory'de bulunan, equipped olmayan, daha önce donate edilmemiş benzersiz design'lar.
- Donate confirmation: fiziksel item sonsuza dek gider, design kalıcı kalır.
- Slot grupları: Weapons, Armor, Horses.
- Her rarity için üç tasarımlık set; held silhouette/art, missing `?`, set complete durumu.
- Donated item'in aynı design'dan ikinci kopyası tekrar gerekmez.
- Empty/error/loading.

### D10 — Raid Rules

Server'ın güncel sayılarını kullanan okunabilir bilgi sayfası. Bölümler: Who, The Take, Losing, The Shield, One Target at a Time, Revenge, Your Kingdom. Sabit hardcode sayı yerine dinamik field yerlerini göster.

### D11–D13 — Recruit Odds ve Reroll

Recruit Odds:

- Villager/Mercenary/Gladiator ayrı satır/grup.
- 7 rarity aynı kolonlarda hizalı.
- Rank icon/roman numeral/pip + yüzde.
- Olası olmayan tier `—`.
- Odds oyuncunun level ve Collection luck'ını içerir; açıkça yaz.

Reroll:

- Hangi askerin reroll edildiği: büyük portrait, name/type, current tier, current stats/Might.
- Bir sonraki roll diamond cost ve balance.
- Tek ROLL confirmation.
- 7 tier ladder ve target seçimleri.
- AUTO ROLL: seçili minimum hedef tier'a ulaşana kadar ardışık server request; her sonucu history/animation olarak göster.
- Auto roll yalnız uygulama foreground'dayken sürer; arka plana gidince durur.
- Stop CTA.
- Durma nedenleri: hedefe ulaşıldı, diamond yetersiz, kullanıcı durdurdu, network/server error, app background.
- Her roll bağımsız ve geri alınamaz; sonuç daha düşük tier olabilir. Confirmation bunu açık söylemeli.
- Double request engeli ve current tier'ın her sonuçta yenilenmesi.

### D18–D19 — Ceremonies

Level-up Ceremony:

- “You Have Reached — Level N”.
- Kazanılan stat points.
- Kazanılan diamonds.
- Energy refilled.
- Yeni açılan sekme/sistemlerin her biri.
- Unspent points varsa SPEND THE POINTS → Stat page.
- CONTINUE.
- Bir aksiyon birden fazla level atlattıysa doğru toplamı ve son level'ı göster.

Mastery Ceremony:

- Mastery başlığı.
- Job art + job name.
- Ulaşılan collect threshold.
- Bu job için kalıcı gold bonusu.
- Continue.

Birden çok ceremony aynı anda tetiklenirse üst üste binmez; sıraya girer ve tek tek oynar.

### D20 — Legacy

- Level 60 şartı.
- Current stacks / max 10.
- Her stack için kalıcı +5% income; current ve next bonus.
- “Resets” ve “Keeps” listeleri server'dan gelen gerçek içerikle gösterilir.
- Güncel anlam: level/XP ve run progression'ın belirtilen kısımları sıfırlanırken estates/upgrades, kingdom ve diamonds korunur; prompt tasarım aşamasında API copy'sini source of truth kabul et.
- Çok güçlü ve açık irreversible warning; iki aşamalı confirmation öner.
- Available, not-at-cap, max-stacks, insufficient/invalid, processing, success states.

## 6. ASSET SİSTEMİ — HİÇBİR ŞEYİ EKSİK BIRAKMA

Yeni tasarım sıfırdan kurulacaktır. Eski medieval painting görünümünü kopyalamak zorunda değilsin. Fakat asset üretimi component sisteminden kopuk olmamalı.

Önce global asset taxonomy oluştur:

1. Brand: app icon, wordmark, crest, launch, loading.
2. Backgrounds: ana shell, her ana sekme, battle arena, auth, ceremonies, sheets/dialogs.
3. Navigation: 7 sekme × active/inactive/locked; badges; dividers; rail/bottom bar yapısı.
4. Currency: gold, diamonds, energy, XP, Might, Favour, Kingdom Treasury, reputation, Collection luck.
5. Global chrome: top/resource bars, panels, cards, frames, tabs, chips, buttons, progress bars, scroll fades, close/back/info icons.
6. Button states: normal, pressed, disabled, destructive, selected, loading. Metin asset içine bake edilmemeli; localization ve dinamik copy için canlı text olmalı.
7. Rarity: 7 tier için frame, badge, pip/rank, glow/particle varyantı; renk körlüğünde de ayrışmalı.
8. Items: en az 7 farklı weapon silhouette/art, 7 armor, 7 horse; rarity treatment item resmini boğmamalı. Oyunda aynı art farklı ad/tier'larda yeniden kullanılabilir fakat yeni production planında gerekli benzersizlik açık yazılmalı.
9. Avatars: en az 12 seçim — knight, king, queen, archer, monk, berserk, knave, herald, templar, witch, captain, princess — ayrıca target/kingdom listelerinde kullanılabilecek portre sistemi.
10. Soldiers: Villager, Mercenary, Gladiator; mini-card ve selected-large/battle kullanımı için uygun crop/pose'lar; boş slot ve locked slot.
11. Jobs: 15 job için idealde ayrı vignette; bütçe gerekiyorsa bilinçli reuse planı.
12. Estates/Holdings: 11 Family upgrade, 8 holding, 8 Kingdom work için icon/vignette ailesi.
13. Kingdom: crest family, role icons King/Captain/Lord, online/offline, invitation/request, kingdom level/reputation emblems.
14. PvP: attack/revenge, shield, target comparison, victory/defeat, history, battle FX, fortune, health.
15. Ceremonies: level burst, mastery burst, unlock reveal, particles.
16. State assets: empty inventory, no targets, no revenge, no battles, locked, offline, error, loading.

Her asset için bir manifest satırı üret:

`asset_id | ekran(lar) | amaç | format | tahmini px ölçü | alpha? | tile/9-slice? | state varyantları | dinamik text güvenli alanı | generation prompt | post-process notu`

Asset üretim kuralları:

- Dinamik isim, fiyat, sayı, timer, yüzde veya button label resmin içine gömülmez.
- Aynı component her ekranda aynı görünür ve davranır.
- Frame ve panel'lerde 9-slice/stretch güvenli bölgeleri tarif edilir.
- Her asset gerçek kullanım boyutunda okunabilirlik testine tabi tutulur.
- Transparent asset'lerde temiz alpha ve renk saçılması kontrol edilir.
- Rarity yalnız renkle ifade edilmez.
- Uzun İngilizce isimler, 4–6 haneli sayılar, milyon/milyar kısa gösterimleri ve `9+` badge test edilir.
- Asset'in hangi katmanlarının ayrı export edileceği açıkça belirtilir.
- Animasyon gerekiyorsa frame/rig/particle gereksinimi ve loop/one-shot süresi yazılır.

## 7. HER EKRAN İÇİN ZORUNLU ÇIKTI ŞABLONU

Ben bir ekran istediğimde cevabını aşağıdaki sırada ver. Hiçbir başlığı atlama.

### 1. Ekranın rolü

- Oyuncu neden buraya gelir?
- Birincil karar/aksiyon nedir?
- Oyuncu buradan nereye gider?

### 2. Giriş yolları ve çıkışlar

- Bütün entry points.
- Bütün CTA/navigation sonuçları.
- Back, close, cancel, success sonrası dönüş.

### 3. Bilgi hiyerarşisi

- Above-the-fold öncelikleri.
- Primary/secondary/tertiary bilgiler.
- Scroll sınırları ve sticky alanlar.

### 4. Wireframe

- 941 × 1672 koordinat mantığında bölüm bölüm metinsel wireframe.
- Safe area.
- Daha uzun ekran davranışı.
- Küçük ekran davranışı.
- Tek elle erişim ve minimum tap target.

### 5. Component listesi

- Her component'in adı, içeriği, ölçü davranışı, tekrar kullanımı.
- Global component mi ekrana özel mi?
- Normal/pressed/selected/disabled/loading/error durumları.

### 6. Dinamik veri alanları

- Ekranda gösterilen bütün isim, sayı, timer, yüzde ve listeler.
- Her alan için min/max/empty/long-value örneği.
- Verinin server'dan geldiğini ve UI'ın hesaplamaması gereken alanları belirt.

### 7. Interaction map

Her dokunulabilir alan için:

`kontrol → önkoşul → confirmation → request/action → loading → success → failure → sonraki ekran/state`

### 8. State matrix

En az:

- first load/skeleton
- normal
- empty
- locked
- insufficient resource
- partial content
- maxed/completed
- offline
- server error/retry
- action busy
- stale data
- long text/large number
- safe-area/tall phone

Uygun olmayan state'leri “uygulanmaz” diye işaretle; sessizce atlama.

### 9. Motion, feedback, sound ve haptics

- Giriş/çıkış.
- Press feedback.
- Resource gain/spend.
- Success/failure.
- Reduced Motion alternatifi.
- Animasyonlar bilgi vermeli; input'u gereksiz yere bloke etmemeli.

### 10. Accessibility

- Contrast.
- Dynamic text/fit stratejisi.
- Rarity'nin renk dışı göstergesi.
- Touch targets.
- Screen-reader semantic order/label önerileri.
- Reduced motion.

### 11. Asset manifest

Bu ekran için gereken bütün asset'ler; global olanları referansla, yenileri tam yaz. Tek bir ikon bile “sonra düşünülür” kalmasın.

### 12. Görsel üretim promptları

- Full-screen concept prompt.
- Ayrı background prompt.
- Her önemli foreground/component/illustration promptu.
- Negative prompt.
- Aspect ratio, kamera, ışık, palette, material, boş text alanı, alpha/export notu.
- Görsel modeller okunabilir UI text üretemediği için gerçek yazıları asset'e çizdirmeme talimatı.

### 13. Acceptance checklist

- Bütün fonksiyonlar görünür mü?
- Bütün yönlendirmeler var mı?
- Bütün state'ler çözüldü mü?
- Hiçbir dinamik text asset'e bake edildi mi?
- Long-name/large-number testleri geçti mi?
- 941×1672 ve uzun telefon çözüldü mü?
- Mevcut global design system ile tutarlı mı?
- Asset manifest eksiksiz mi?

### 14. Onay sorusu

Yalnızca şu üç seçenekle bitir:

- “Bu ekranı onayla ve sıradakine geç.”
- “Bu ekran için alternatif varyasyon üret.”
- “Belirttiğim değişikliklerle revize et.”

Ben onay vermeden sonraki ekranı tasarlama.

## 8. ÇALIŞMA PROTOKOLÜ

İlk cevabında ekran tasarlamaya başlama. Şunları yap:

1. Bu brief'i anladığını en fazla 12 maddede özetle.
2. Eksikse yalnızca görsel yönü belirlemek için gerekli soruları birer birer sor.
3. Birbirinden belirgin 3 art-direction rotası öner; her biri için mood, palette, material, typography, illustration, motion ve üretim riski ver.
4. Ben bir rota seçince önce şu global dokümanları hazırla:
   - Creative North Star
   - Design principles
   - Color tokens
   - Typography scale
   - Spacing/grid/safe-area rules
   - Component states
   - Rarity system
   - Iconography rules
   - Illustration/portrait rules
   - Motion/haptic/sound rules
   - Global navigation alternative'leri ve önerilen çözüm
5. Global sistemi onayladıktan sonra ekranları şu sırayla ele al:
   - Main Shell
   - Launch/Loading/Auth
   - Onboarding
   - Collect
   - Family
   - Stat Points
   - Treasury
   - Inventory
   - Item Picker
   - Collection
   - Shop
   - Daily Reward
   - Army
   - Recruit Odds
   - Soldier Reroll
   - Attack Revenge
   - Attack Targets
   - Battle Replay
   - Battle History
   - Raid Rules
   - While You Were Away
   - Kingdom Hall
   - Kingdom Realm
   - Kingdom Lords
   - Kingdom Works/Favour Shop
   - Kingdom Ranks
   - Profile/Avatar
   - Global Leaderboards
   - Level/Mastery Ceremonies
   - Legacy
   - Global dialogs/toasts/offline/empty/error audit
6. Bir `DESIGN COVERAGE LEDGER` tut. Her cevap sonunda bütün ekranları `not started / in progress / approved / needs revision` olarak işaretle.
7. Bir `ASSET COVERAGE LEDGER` tut. Aynı asset'i farklı adlarla çoğaltma; shared asset'leri işaretle.
8. Bir ekranda yeni ortak component doğarsa global design system kaydına ekle ve daha önce onaylanan ekranlara etkisini belirt.
9. Mekanikleri değiştiren “iyileştirme” önerilerini doğrudan tasarıma sokma. Ayrı bir `OPTIONAL PRODUCT IDEA` kutusunda sun; onaylanmazsa mevcut işlevi koru.
10. Kod üretme; benden açıkça istenmedikçe Godot/GDScript uygulamasına geçme. Buradaki amaç önce eksiksiz UX/UI ve asset üretim şartnamesidir.

## 9. KALİTE KAPILARI VE KIRMIZI ÇİZGİLER

- “Benzer ekranlar da aynı” diyerek hiçbir ekranı atlama.
- Sadece ideal/happy path tasarlama.
- Üzerinde işlem yapılan eski/stale karta ikinci kez aksiyon gönderilememeli.
- Server'ın verdiği sayıyı UI yeniden hesaplamamalı.
- Combat outcome UI tarafından simüle edilmemeli.
- Gold, XP, price, odds, reward, tax, Might, attack take ve timer alanlarının dinamik olduğunu kabul et.
- Sabit örnek copy ile gerçek dinamik field'ı birbirine karıştırma.
- Boş slot, boş liste, kilitli içerik, maxed upgrade, yetersiz para, full inventory, shielded target, no revenge, no battle, no Kingdom, pending request gibi bütün kritik states görünür olmalı.
- Görsel ihtişam bilgi okunabilirliğini ezmemeli.
- Her ana aksiyon parmakla rahat kullanılmalı.
- UI yalnız portrait referans görseli gibi değil, gerçek değişken veri ve scroll ile çalışan bir ürün gibi tasarlanmalı.
- Yeni sanat yönü eski oyunu kopyalamamalı; fakat Emperors'ın lordluk, iktidar, büyüme, risk, savunma, birlik ve prestij temalarını taşımalı.
- Oyun içi bütün gerçek metinler İngilizce olmalı; açıklamaları bana Türkçe ver.

Şimdi yalnızca çalışma protokolünün ilk adımıyla başla.

## PROMPT SONU
