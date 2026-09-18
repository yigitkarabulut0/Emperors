import json, sys, html

items = json.load(open(sys.argv[1]))
out = sys.argv[2]

TEMPLATE = r"""<title>Emperors Tablo Kitapçığı II</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Cinzel:wght@600;700&family=EB+Garamond:ital,wght@0,400;0,500;0,600;1,400&family=IBM+Plex+Mono:wght@400;500&display=swap">
<style>
:root {
  --ground: #EDF0F3;
  --panel: #FFFFFF;
  --panel-2: #F5F7F9;
  --ink: #0F1B26;
  --ink-2: #3E4C59;
  --ink-3: #6B7886;
  --rule: #D5DCE3;
  --gold: #8F6A1C;
  --gold-soft: #E9DDBF;
  --crimson: #9C2327;
  --crimson-soft: #F4DCDC;
  --emerald: #23703A;
  --emerald-soft: #D8EDDD;
  --steel: #4E6A85;
  --code-bg: #F2F4F6;
  --shadow: 0 1px 2px rgba(15, 27, 38, .06), 0 6px 20px rgba(15, 27, 38, .06);
  color-scheme: light;
}
@media (prefers-color-scheme: dark) {
  :root:not([data-theme="light"]) {
    --ground: #0B151F;
    --panel: #15222F;
    --panel-2: #1B2B3B;
    --ink: #F1E9DA;
    --ink-2: #C9C0AF;
    --ink-3: #8E9AA6;
    --rule: #263849;
    --gold: #E3BE62;
    --gold-soft: #3A3120;
    --crimson: #E0565A;
    --crimson-soft: #3B1C1F;
    --emerald: #5FC27A;
    --emerald-soft: #16301F;
    --steel: #8FA9C2;
    --code-bg: #0F1B27;
    --shadow: 0 1px 2px rgba(0, 0, 0, .3), 0 8px 24px rgba(0, 0, 0, .25);
    color-scheme: dark;
  }
}
:root[data-theme="dark"] {
  --ground: #0B151F;
  --panel: #15222F;
  --panel-2: #1B2B3B;
  --ink: #F1E9DA;
  --ink-2: #C9C0AF;
  --ink-3: #8E9AA6;
  --rule: #263849;
  --gold: #E3BE62;
  --gold-soft: #3A3120;
  --crimson: #E0565A;
  --crimson-soft: #3B1C1F;
  --emerald: #5FC27A;
  --emerald-soft: #16301F;
  --steel: #8FA9C2;
  --code-bg: #0F1B27;
  --shadow: 0 1px 2px rgba(0, 0, 0, .3), 0 8px 24px rgba(0, 0, 0, .25);
  color-scheme: dark;
}

* { box-sizing: border-box; }
body {
  background: var(--ground);
  color: var(--ink);
  font: 400 18px/1.55 "EB Garamond", Garamond, "Times New Roman", serif;
  padding-inline: 16px;
  padding-block: 0 64px;
}
.wrap { max-width: 820px; margin: 0 auto; }
h1, h2, h3 { font-family: Cinzel, "Trajan Pro", Georgia, serif; text-wrap: balance; margin: 0; }
.mono, code { font-family: "IBM Plex Mono", ui-monospace, Menlo, monospace; }

/* masthead */
header.top { padding-block: 40px 20px; display: grid; gap: 10px; }
.eyebrow { font: 500 12px/1 "IBM Plex Mono", monospace; letter-spacing: .14em; text-transform: uppercase; color: var(--steel); }
h1 { font-size: clamp(30px, 5vw, 42px); font-weight: 700; color: var(--gold); letter-spacing: .02em; }
.lede { color: var(--ink-2); max-width: 64ch; margin: 0; }

/* sticky progress + filters */
.bar {
  position: sticky; top: 0; z-index: 5;
  background: color-mix(in srgb, var(--ground) 92%, transparent);
  backdrop-filter: blur(6px);
  border-bottom: 1px solid var(--rule);
  padding-block: 12px;
  display: grid; gap: 10px;
}
.progress { display: flex; align-items: center; gap: 12px; }
.progress .track { flex: 1; height: 6px; border-radius: 3px; background: var(--rule); overflow: hidden; }
.progress .fill { height: 100%; width: 0; background: var(--gold); transition: width .25s ease; }
.progress .count { font: 500 13px/1 "IBM Plex Mono", monospace; color: var(--ink-2); font-variant-numeric: tabular-nums; white-space: nowrap; }
.chips { display: flex; flex-wrap: wrap; gap: 8px; }
.chip {
  font: 600 13px/1 Cinzel, Georgia, serif; letter-spacing: .06em;
  padding: 9px 14px; border-radius: 4px; cursor: pointer;
  border: 1px solid var(--rule); background: var(--panel); color: var(--ink-2);
}
.chip[aria-pressed="true"] { background: var(--crimson); border-color: var(--crimson); color: #FBF3E6; }
.chip:focus-visible, button:focus-visible, input:focus-visible, summary:focus-visible { outline: 2px solid var(--gold); outline-offset: 2px; }

/* review */
section.review { padding-block: 28px 8px; display: grid; gap: 14px; }
h2 { font-size: 22px; font-weight: 700; color: var(--ink); letter-spacing: .03em; }
.findings { display: grid; gap: 10px; margin: 0; padding: 0; list-style: none; }
.findings li { display: grid; grid-template-columns: 92px 1fr; gap: 12px; align-items: baseline; }
.tag { font: 500 11px/1.6 "IBM Plex Mono", monospace; letter-spacing: .08em; text-transform: uppercase; padding: 2px 8px; border-radius: 3px; text-align: center; }
.tag.ok { background: var(--emerald-soft); color: var(--emerald); }
.tag.fix { background: var(--crimson-soft); color: var(--crimson); }
.tag.new { background: var(--gold-soft); color: var(--gold); }
.findings p { margin: 0; color: var(--ink-2); }
.findings strong { color: var(--ink); font-weight: 600; }

/* entries */
h2.group { padding-block: 30px 12px; display: flex; align-items: baseline; gap: 12px; }
h2.group .n { font: 500 13px/1 "IBM Plex Mono", monospace; color: var(--ink-3); }
.list { display: grid; gap: 14px; }
article.entry {
  background: var(--panel); border: 1px solid var(--rule); border-radius: 6px;
  box-shadow: var(--shadow);
  padding: 18px 20px; display: grid; gap: 12px;
}
article.entry.done { opacity: .62; }
article.entry.done .file { text-decoration: line-through; text-decoration-color: var(--ink-3); }
.head { display: grid; grid-template-columns: auto 1fr auto; gap: 12px; align-items: start; }
.head input[type="checkbox"] { width: 22px; height: 22px; margin: 3px 0 0; accent-color: var(--emerald); cursor: pointer; }
.file { font: 500 15px/1.3 "IBM Plex Mono", monospace; color: var(--gold); word-break: break-all; }
.title { font-size: 19px; font-weight: 600; color: var(--ink); line-height: 1.3; }
.prio { font: 500 11px/1.6 "IBM Plex Mono", monospace; letter-spacing: .08em; text-transform: uppercase; padding: 2px 8px; border-radius: 3px; white-space: nowrap; }
.prio.p1 { background: var(--crimson-soft); color: var(--crimson); }
.prio.p2 { background: var(--gold-soft); color: var(--gold); }
.prio.p3 { background: var(--panel-2); color: var(--ink-3); }
dl.meta { display: grid; grid-template-columns: 64px 1fr; gap: 6px 12px; margin: 0; }
dl.meta dt { font: 500 11px/1.9 "IBM Plex Mono", monospace; letter-spacing: .1em; text-transform: uppercase; color: var(--steel); }
dl.meta dd { margin: 0; color: var(--ink-2); }
dl.meta code { font-size: 14px; color: var(--ink); background: var(--code-bg); padding: 0 4px; border-radius: 3px; }
.actions { display: flex; flex-wrap: wrap; gap: 10px; }
button.copy {
  font: 700 14px/1 Cinzel, Georgia, serif; letter-spacing: .08em;
  padding: 13px 18px; border-radius: 4px; cursor: pointer;
  border: 1px solid color-mix(in srgb, var(--emerald) 70%, #000);
  background: var(--emerald); color: #F6FBF6;
}
button.copy.alt { background: var(--panel); color: var(--ink); border-color: var(--rule); }
button.copy[data-state="ok"] { background: var(--gold); border-color: var(--gold); color: #1B1712; }
details.prompt { border-top: 1px solid var(--rule); padding-top: 10px; }
details.prompt summary { cursor: pointer; font: 500 13px/1.4 "IBM Plex Mono", monospace; color: var(--ink-3); }
pre {
  margin: 10px 0 0; padding: 14px; border-radius: 4px; background: var(--code-bg); color: var(--ink);
  font: 400 12.5px/1.55 "IBM Plex Mono", ui-monospace, monospace;
  white-space: pre-wrap; word-break: break-word; max-height: 360px; overflow: auto;
}
.hidden-by-filter { display: none; }

.toast {
  position: fixed; left: 50%; bottom: 24px; transform: translateX(-50%);
  background: var(--ink); color: var(--ground); padding: 10px 16px; border-radius: 4px;
  font: 500 14px/1.3 "IBM Plex Mono", monospace; max-width: calc(100% - 32px);
  opacity: 0; pointer-events: none; transition: opacity .2s ease;
}
.toast.show { opacity: 1; }

footer.end { padding-block: 36px 0; color: var(--ink-3); font-size: 16px; display: grid; gap: 8px; }
footer.end ul { margin: 0; padding-left: 20px; }

@media (max-width: 520px) {
  body { font-size: 17px; }
  .findings li { grid-template-columns: 1fr; gap: 4px; }
  .findings .tag { justify-self: start; }
  .head { grid-template-columns: auto 1fr; }
  .head .prio { grid-column: 2; justify-self: start; }
  dl.meta { grid-template-columns: 1fr; gap: 2px; }
  dl.meta dd { margin-bottom: 6px; }
}
@media (prefers-reduced-motion: reduce) { * { transition: none !important; } }
</style>

<div class="wrap">
  <header class="top">
    <div class="eyebrow">Emperors · Emperors_Design_Pack incelemesi · 15 Eylül 2026</div>
    <h1>Tablo Kitapçığı II</h1>
    <p class="lede">74 tablonun hepsine baktım; çoğu olduğu gibi oyuna girecek. Aşağıda düzeltilmesi gereken 21 ve oyunda hiç tablosu olmayan, şu an sade duran sayfalar için 12 prompt var. Her kart bir resim: <strong>Promptu kopyala</strong>'ya bas, ChatGPT'ye yapıştır, “Ekle” satırındaki resimleri iliştir.</p>
  </header>

  <div class="bar" role="region" aria-label="İlerleme ve süzgeç">
    <div class="progress">
      <div class="track" aria-hidden="true"><div class="fill" id="fill"></div></div>
      <span class="count" id="count">0 / 0 üretildi</span>
    </div>
    <div class="chips" role="group" aria-label="Süzgeç">
      <button class="chip" id="f-all" data-filter="all" aria-pressed="true">Tümü</button>
      <button class="chip" id="f-p1" data-filter="p1" aria-pressed="false">Önce</button>
      <button class="chip" id="f-p2" data-filter="p2" aria-pressed="false">Sonra</button>
      <button class="chip" id="f-p3" data-filter="p3" aria-pressed="false">İsteğe bağlı</button>
      <button class="chip" id="f-left" data-filter="left" aria-pressed="false">Kalanlar</button>
    </div>
  </div>

  <section class="review" aria-labelledby="review-h">
    <h2 id="review-h">Paketten ne çıktı</h2>
    <ul class="findings">
      <li><span class="tag ok">Tamam</span><p><strong>74 / 74 tablo geldi.</strong> Boyutlar boru hattına uygun: ekranlar 941×1672, haritalar 1086×1448, bosslar 1586×992. Tırnaklı kelimeler doğru, EMPTY plakalar boş, 8 girişli menü ve üç hap her ekranda aynı.</p></li>
      <li><span class="tag fix">Sekmeler</span><p>Saldırı alt ekranlarında başlık ve sekme şeridi farklı yükseklikte, krallık alt ekranlarında üst kısım üç ayrı biçimde, <code>road.png</code>'de sekme sırası <code>deeds.png</code>'nin tersi. Tek boy sekme sayfası: <code>tabs_sheet_a/b</code>.</p></li>
      <li><span class="tag fix">Menü</span><p>SHOP ve INVENTORY'nin yanık hali hiçbir tabloda yok: <code>rail_lit_sheet</code>.</p></li>
      <li><span class="tag fix">Haritalar</span><p>Aşama sayısı tutmuyor: 02 → 13 düğüm, 03 → 11, 04 → 11 ve ara boss yok, 05 → 14, 06 → 13, 07 → 13 ve ara boss yok, 08 → ara boss 7. sırada, 10 → 13. Yalnız 09 doğru. Haritalar düğümsüz gelecek; işaretleri oyun yerleştirecek.</p></li>
      <li><span class="tag fix">Atlar</span><p>Çerçeveli ve renkli arka planlı; silah ve zırh gibi temiz olmalı.</p></li>
      <li><span class="tag fix">Boss</span><p>Kara Şövalye'nin arkasında haçlı kilise yanıyor ve oyuncunun aslan armasını taşıyor. Garrow ve Ulgrim'de kan (isteğe bağlı).</p></li>
      <li><span class="tag fix">Durumlar</span><p>42 ek ekran (<code>art/states</code>) boyama değil SVG taslağı; müzik, ses, titreşim, dil, bulut kaydı gibi oyunda olmayan şeyler içeriyor. Sanat olarak kullanılmayacak.</p></li>
      <li><span class="tag new">Eksik</span><p>Savaş ekranı, seviye ve ustalık törenleri, Sıralamalar, Hazine, Stat puanları, Savaş geçmişi, “Sen yokken”, Koleksiyon, krallık salonu, giriş ekranı ve bilgi sayfaları şu an lacivert levha üstüne yazı.</p></li>
    </ul>
  </section>

  <h2 class="group" id="fix-h">Düzeltmeler <span class="n" id="fix-n"></span></h2>
  <div class="list" id="fix"></div>

  <h2 class="group" id="new-h">Yeni sayfalar <span class="n" id="new-n"></span></h2>
  <div class="list" id="new"></div>

  <h2 class="group" id="more-h">Ek istekler — 3. tur <span class="n" id="more-n"></span></h2>
  <div class="list" id="more"></div>

  <footer class="end">
    <p>Teslim: yeni ve düzeltilmiş tabloları <code>~/Downloads/Emperors_Design_Pack_2/</code> klasörüne, buradaki adlarla koy. Paketteki eskilerin üzerine yazma. Pakette olmayan ek resimler (<code>collect.png</code>, <code>army.png</code>, <code>kingdom.png</code>, <code>launch.png</code>) aynı klasörün <code>references/</code> altında.</p>
    <p>Göndermeden önce bak:</p>
    <ul>
      <li>Sekme ve menü sayfalarında bütün plakalar aynı boyda, kelimeler aynı harf boyunda.</li>
      <li>Haritaların yolunda hiçbir işaret yok; yol aşağının ortasından girip yukarının ortasından çıkıyor.</li>
      <li>Zafer Yolu'nun üç parçası alt alta konunca yol kesintisiz, kenarlar aynı sise eriyor.</li>
      <li>Atların arkasında çerçeve ya da renkli zemin yok.</li>
    </ul>
  </footer>
</div>
<div class="toast" id="toast" role="status" aria-live="polite"></div>

<script id="data" type="application/json">__DATA__</script>
<script>
(function () {
  var items = JSON.parse(document.getElementById("data").textContent);
  var KEY = "emperors-briefs-2-done";
  var done = {};
  try { done = JSON.parse(localStorage.getItem(KEY) || "{}") || {}; } catch (e) { done = {}; }
  function save() { try { localStorage.setItem(KEY, JSON.stringify(done)); } catch (e) {} }

  var PRIO = { 1: ["p1", "Önce"], 2: ["p2", "Sonra"], 3: ["p3", "İsteğe bağlı"] };
  var toastEl = document.getElementById("toast"), toastTimer = null;
  function toast(msg) {
    toastEl.textContent = msg; toastEl.classList.add("show");
    clearTimeout(toastTimer); toastTimer = setTimeout(function () { toastEl.classList.remove("show"); }, 2600);
  }
  function inline(md) {
    var esc = md.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
    return esc.replace(/`([^`]+)`/g, "<code>$1</code>");
  }
  function selectText(el) {
    var r = document.createRange(); r.selectNodeContents(el);
    var s = window.getSelection(); s.removeAllRanges(); s.addRange(r);
  }
  function copy(text, btn, pre, details) {
    function ok() {
      btn.dataset.state = "ok"; var label = btn.textContent; btn.textContent = "Kopyalandı";
      setTimeout(function () { btn.dataset.state = ""; btn.textContent = label; }, 1800);
      toast("Kopyalandı — ChatGPT'ye yapıştır");
    }
    function fail() {
      details.open = true; selectText(pre);
      toast("Kopyalama izni yok: metin seçildi, ⌘C ile kopyala");
    }
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(ok, function () {
        details.open = true; selectText(pre);
        try { if (document.execCommand("copy")) { ok(); return; } } catch (e) {}
        fail();
      });
    } else {
      details.open = true; selectText(pre);
      try { if (document.execCommand("copy")) { ok(); return; } } catch (e) {}
      fail();
    }
  }
  function promptBlock(entry, label, text, alt, idx) {
    var wrap = document.createElement("div");
    var actions = document.createElement("div"); actions.className = "actions";
    var btn = document.createElement("button"); btn.type = "button";
    btn.className = "copy" + (alt ? " alt" : ""); btn.id = "copy-" + entry.id + "-" + idx;
    btn.textContent = label;
    actions.appendChild(btn);
    var det = document.createElement("details"); det.className = "prompt";
    var sum = document.createElement("summary"); sum.textContent = (alt ? "Yedek promptu göster" : "Promptu göster") + " · " + text.length.toLocaleString("tr-TR") + " karakter";
    var pre = document.createElement("pre"); pre.textContent = text;
    det.appendChild(sum); det.appendChild(pre);
    btn.addEventListener("click", function () { copy(text, btn, pre, det); });
    wrap.appendChild(actions); wrap.appendChild(det);
    return wrap;
  }
  function render() {
    var counts = { fix: 0, new: 0, more: 0 };
    items.forEach(function (it) {
      counts[it.group]++;
      var art = document.createElement("article"); art.className = "entry"; art.dataset.prio = "p" + it.prio; art.id = "e-" + it.id;
      var head = document.createElement("div"); head.className = "head";
      var cb = document.createElement("input"); cb.type = "checkbox"; cb.id = "done-" + it.id;
      cb.setAttribute("aria-label", it.file + " üretildi");
      cb.checked = !!done[it.id];
      var mid = document.createElement("div");
      mid.innerHTML = '<div class="file">' + inline(it.file) + '</div><div class="title">' + inline(it.title) + '</div>';
      var pr = document.createElement("span"); pr.className = "prio " + PRIO[it.prio][0]; pr.textContent = PRIO[it.prio][1];
      head.appendChild(cb); head.appendChild(mid); head.appendChild(pr);
      var dl = document.createElement("dl"); dl.className = "meta";
      dl.innerHTML = "<dt>Neden</dt><dd>" + inline(it.why) + "</dd><dt>Ekle</dt><dd>" + inline(it.attach) + "</dd>";
      art.appendChild(head); art.appendChild(dl);
      art.appendChild(promptBlock(it, "Promptu kopyala", it.prompt, false, 0));
      if (it.fallback) art.appendChild(promptBlock(it, "Yedek prompt (sıfırdan)", it.fallback, true, 1));
      if (cb.checked) art.classList.add("done");
      cb.addEventListener("change", function () {
        if (cb.checked) done[it.id] = true; else delete done[it.id];
        art.classList.toggle("done", cb.checked); save(); progress(); applyFilter();
      });
      document.getElementById(it.group).appendChild(art);
    });
    document.getElementById("fix-n").textContent = counts.fix + " tablo";
    document.getElementById("new-n").textContent = counts.new + " tablo";
    document.getElementById("more-n").textContent = counts.more + " tablo";
  }
  function progress() {
    var n = items.filter(function (it) { return done[it.id]; }).length;
    document.getElementById("count").textContent = n + " / " + items.length + " üretildi";
    document.getElementById("fill").style.width = (100 * n / items.length) + "%";
  }
  var current = "all";
  function applyFilter() {
    items.forEach(function (it) {
      var el = document.getElementById("e-" + it.id);
      var show = current === "all" || current === "p" + it.prio || (current === "left" && !done[it.id]);
      el.classList.toggle("hidden-by-filter", !show);
    });
  }
  document.querySelectorAll(".chip").forEach(function (c) {
    c.addEventListener("click", function () {
      current = c.dataset.filter;
      document.querySelectorAll(".chip").forEach(function (o) { o.setAttribute("aria-pressed", o === c ? "true" : "false"); });
      applyFilter();
    });
  });
  render(); progress(); applyFilter();
})();
</script>
"""

data = json.dumps([{k: it[k] for k in ("id", "group", "prio", "file", "title", "why", "attach", "prompt") } | ({"fallback": it["fallback"]} if it.get("fallback") else {}) for it in items], ensure_ascii=False)
data = data.replace("</", "<\\/")
open(out, "w").write(TEMPLATE.replace("__DATA__", data))
print("wrote", out, len(TEMPLATE) + len(data))
