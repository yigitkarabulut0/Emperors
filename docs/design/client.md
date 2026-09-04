# Emperors — Client Design

> Produced by an architecture pass on 2026-09-04 and adversarially reviewed.
> Owner decisions made *after* this document was written take precedence — see the build plan.

**Headline:** Build the Emperors client as a 720×1280 portrait Godot 4.7 UI app on the Metal-backed `mobile` renderer, with a pooled cancel-safe HTTP layer, per-domain reactive stores that hold only server-confirmed truth, and a batched optimistic action queue where the displayed number is always `confirmed + replay(pending)` — so 20 collect taps feel instant on a 200 ms link yet can never desync.

---

> Verified against the Godot 4.7.2.stable binary installed at `/Applications/Godot.app` (setting names, enum hints, class symbols extracted from the binary), against the working Godot 4.7.2 project at `/Users/yigitkarabulut/Developer/GameTest/client` (which already has a validated iOS export preset and headless test runner on this machine), and against the Godot 4.7 release notes / class reference. Every project-setting key, export-preset field and API symbol quoted below was confirmed to exist in *this* build, not recalled from memory.

---

# Emperors — Godot 4.7.2 / GDScript client architecture

## 0. The one-paragraph shape

`Emperors` is a **six-tab, portrait, server-authoritative UI application that happens to be built in a game engine**. There is no simulation loop, no physics, no world. The client's entire job is: hold a cached copy of a server snapshot, render it as lists and numbers, capture taps, and reconcile. Therefore the architecture is organised around three things and nothing else — a **networking layer** that is honest about failure, a **state store** that never lies about what the server confirmed, and an **optimistic action queue** that makes a 200 ms round trip invisible for the one verb the player performs hundreds of times a session. Everything else (theming, components, export) is craft, not architecture.

The single load-bearing decision in this document is in §8: **predictions are never folded into the confirmed base.** Display = `confirmed + replay(pending)`. Get that wrong and you ship a game that mints gold.

---

## 1. Repository layout

```
Emperors/
├── client/                       # the Godot project (project.godot lives here)
│   ├── project.godot
│   ├── export_presets.cfg
│   ├── .gitattributes
│   ├── autoload/                 # infrastructure singletons ONLY, no game logic
│   │   ├── clock.gd              # Clock   — server-corrected time
│   │   ├── cfg.gd                # Cfg     — build config, api url, flags
│   │   ├── log.gd                # Log     — ring buffer + breadcrumbs
│   │   ├── api.gd                # Api     — HTTP client (auth, retry, offline)
│   │   ├── game_state.gd         # GameState — domain stores + snapshot apply
│   │   ├── action_queue.gd       # Actions — optimistic lane
│   │   ├── session.gd            # Session — boot, login, resync, lifecycle
│   │   ├── ui.gd                 # Ui      — theme + overlay registry
│   │   ├── audio.gd              # Audio
│   │   └── haptics.gd            # Haptics
│   ├── net/
│   │   ├── api_error.gd  api_result.gd  http_transport.gd
│   ├── state/
│   │   ├── store.gd              # @abstract base
│   │   ├── wallet_store.gd  energy_store.gd  player_store.gd
│   │   ├── jobs_store.gd    inventory_store.gd  soldiers_store.gd
│   │   ├── shop_store.gd    kingdom_store.gd
│   ├── ui/
│   │   ├── Main.tscn             # main scene
│   │   ├── main.gd  safe_area.gd  tab_host.gd  tab_page.gd
│   │   ├── theme/                # ui_theme.gd, palette.gd, fmt.gd
│   │   ├── components/           # ItemCard, TierFrame, RecycleGrid, ...
│   │   ├── tabs/                 # FamilyTab.tscn … AttackTab.tscn
│   │   └── fonts/                # Cinzel*.ttf, AlegreyaSans*.ttf
│   ├── assets/                   # ONLY what the running game loads (shipped)
│   │   ├── atlas/                # sheet_items.png + sheet_items.json
│   │   ├── ui/                   # nine-patch chrome
│   │   └── audio/
│   ├── locale/emperors.csv
│   └── tests/                    # TestRunner.tscn, suites/, fakes/, fixtures/
├── art/                          # generation inputs + sliced sources (NOT shipped)
├── tools/                        # pack_atlas.py, gen_sheet.sh
├── server/                       # Go
└── admin/                        # Next.js
```

`art/` vs `assets/` matters: `assets/` is scanned and imported by Godot on every editor start. Keeping 400 intermediate PNGs out of it halves editor boot and keeps `.import` churn down. `art/` gets a `.gdignore` file — but note the godogen skill's warning: a `.gdignore` silently makes the importer skip a directory, so put one in `art/` and never anywhere near `assets/`.

---

## 2. `project.godot` — complete, annotated

`config_version=5` (confirmed: that is what 4.7.2 writes).

```ini
; Engine configuration file.
config_version=5

[application]

config/name="Emperors"
config/name_localized={"en": "Emperors"}
config/description="Build a family, raise an army, take what you can hold."
config/version="0.1.0"
config/features=PackedStringArray("4.7", "Mobile")
run/main_scene="res://ui/Main.tscn"
config/icon="res://ui/branding/icon.png"
; Android's back button must navigate tabs, not kill the app.
config/quit_on_go_back=false
; Dev and prod builds must not share user:// on desktop.
config/use_custom_user_dir=true
config/custom_user_dir_name="Emperors"
boot_splash/bg_color=Color(0.055, 0.043, 0.035, 1)
boot_splash/image="res://ui/branding/splash.png"
boot_splash/fullsize=false
boot_splash/use_filter=true
; 0 = display-limited. On ProMotion this is 120; Session throttles it to 10
; after 15 s without a touch, which is where the battery win actually is.
run/max_fps=0

[autoload]

Clock="*res://autoload/clock.gd"
Cfg="*res://autoload/cfg.gd"
Log="*res://autoload/log.gd"
Api="*res://autoload/api.gd"
GameState="*res://autoload/game_state.gd"
Actions="*res://autoload/action_queue.gd"
Session="*res://autoload/session.gd"
Ui="*res://autoload/ui.gd"
Audio="*res://autoload/audio.gd"
Haptics="*res://autoload/haptics.gd"

[display]

; Design canvas. 720 units = 393 pt on an iPhone 15/16, so 1 pt = 1.832 units
; and Apple's 44 pt minimum touch target is 81 units. House rule: 88.
window/size/viewport_width=720
window/size/viewport_height=1280
; The editor's play window on a laptop. Does NOT change the canvas.
window/size/window_width_override=450
window/size/window_height_override=800
window/size/resizable=true
window/stretch/mode="canvas_items"
window/stretch/aspect="keep_width"
window/stretch/scale=1.0
window/stretch/scale_mode="fractional"
; 1 = Portrait (DisplayServer.SCREEN_PORTRAIT)
window/handheld/orientation=1
window/energy_saving/keep_screen_on=false
window/vsync/vsync_mode=1
window/ios/hide_home_indicator=true
window/ios/hide_status_bar=true
; First edge swipe does not trigger the system gesture — stops the app switcher
; eating flicks on a list that reaches the bottom edge.
window/ios/suppress_ui_gesture=true
window/ios/allow_high_refresh_rate=true

[rendering]

renderer/rendering_method="mobile"
renderer/rendering_method.mobile="mobile"
renderer/rendering_method.web="gl_compatibility"
textures/vram_compression/import_etc2_astc=true
textures/canvas_textures/default_texture_filter=1
anti_aliasing/quality/msaa_2d=0
environment/defaults/default_clear_color=Color(0.055, 0.043, 0.035, 1)
environment/defaults/default_environment=""
2d/snap/snap_2d_transforms_to_pixel=false
2d/snap/snap_2d_vertices_to_pixel=false

[gui]

fonts/dynamic_fonts/use_oversampling=true
theme/default_font_antialiasing=1
theme/default_font_subpixel_positioning=1
theme/default_font_generate_mipmaps=false
theme/default_theme_scale=1.0
common/default_scroll_deadzone=12
timers/tooltip_delay_sec=0.0

[input_devices]

pointing/emulate_mouse_from_touch=true
pointing/emulate_touch_from_mouse=true

[audio]

buses/default_bus_layout="res://assets/audio/bus_layout.tres"
; 0 = "Ambient" (hint order: Ambient,Multi Route,Play and Record,Playback,
; Record,Solo Ambient). Ambient + mix_with_others respects the silent switch
; and lets the player keep their own music playing. Correct for an idle game.
general/ios/session_category=0
general/ios/mix_with_others=true

[internationalization]

locale/translations=PackedStringArray("res://locale/emperors.en.translation")
locale/fallback="en"

[importer_defaults]

; Reproducible imports across machines and CI. detect_3d/compress_to=0 is the
; important one: the default (1) lets Godot silently flip a UI texture to VRAM
; compression the first time it thinks it saw it in 3D, which produces a
; mystery re-import diff and softer art.
texture={
"compress/mode": 0,
"compress/high_quality": false,
"compress/lossy_quality": 0.9,
"detect_3d/compress_to": 0,
"mipmaps/generate": false,
"process/fix_alpha_border": true,
"process/premult_alpha": false,
"process/size_limit": 0
}

[debug]

gdscript/warnings/untyped_declaration=1
gdscript/warnings/unsafe_property_access=1
gdscript/warnings/unsafe_method_access=1
gdscript/warnings/unsafe_call_argument=1
gdscript/warnings/integer_division=2
gdscript/warnings/narrowing_conversion=2
; New in 4.7: per-directory warning rules. Tests and addons opt out of strict.
gdscript/warnings/directory_rules={"res://tests/": 0, "res://addons/": 0}
```

Three of these deserve a defence.

**`untyped_declaration=1` (warn).** The dominant bug class in a thin client is a `Dictionary` shape drifting from the server. Every warning here is a place where a typo in a field name becomes a silent `null`. Turning it on costs typing and saves days.

**`integer_division=2` (error).** In an economy client, `a / b` on two ints silently truncating is a currency bug.

**`max_fps=0` + idle throttle.** A UI game at 120 Hz on ProMotion feels like a native app; a UI game pinned at 60 costs the same battery for a worse feel. The actual battery problem in an idle game is the phone sitting on a desk rendering an unchanging screen. `Session` handles that in code (§6.4) rather than with a static cap.

### 2.1 Base resolution: 720 × 1280, `canvas_items`, `keep_width`

Why 720 × 1280 and not 1080 × 1920 or 390 × 844:

| Device | Aspect | Viewport under `keep_width` @720 |
|---|---|---|
| iPhone SE 3 (750×1334) | 0.562 | 720 × 1281 |
| iPhone 15/16 (1179×2556) | 0.461 | 720 × 1561 |
| iPhone 16 Pro Max (1320×2868) | 0.460 | 720 × 1564 |
| iPad 10.9" (1640×2360) | 0.695 | 720 × 1036 |
| Steam Deck portrait window | — | letterboxed (see §17) |

`keep_width` is the right aspect policy for a list-based game: width is fixed so nothing ever reflows horizontally, and the extra vertical space on a tall phone becomes **more list rows**, which is exactly the payoff you want. The design constraint that falls out is a hard one, and it should be written on the wall:

> **Everything that must always be visible fits inside 720 × 1000.** Below that is bonus rows.

720 wide is chosen over 1080 because with `canvas_items` stretch the base resolution is a *design unit system*, not a pixel budget, and 720 makes the "author art at 2×" rule exact: a 128-unit item icon ships as a 256 px source, renders at 209 px on an iPhone 15 (scale 1.6375), so it is always downsampled and always crisp. Font sizes stay in comfortable two-digit numbers. `window_width/height_override` (450 × 800) exists purely so F5 in the editor opens a window that fits on a MacBook while still stretching the 720 × 1280 canvas — it does not affect the game.

**Fixed layout metrics (units at base 720):**

| Element | Height | Notes |
|---|---|---|
| Currency bar | 120 | pinned top, inside safe area |
| Tab bar | 150 | pinned bottom, inside safe area |
| Content area | rest | `SIZE_EXPAND_FILL` |
| List row (collect job, upgrade) | 132 | ≥ 88 touch target + padding |
| Inventory grid cell | 200 × 260, 3 cols | |
| Minimum touch target | 88 × 88 | ≈ 48 pt |
| Screen gutter | 24 | |

### 2.2 Rendering method: `mobile`, with `gl_compatibility` only on web

**Decision: `rendering/renderer/rendering_method="mobile"`.**

- On iOS, Godot 4.4+ ships a **native Metal RenderingDevice driver** (`rendering/rendering_device/driver.ios`, default `metal` on arm64), so the "mobile" method is *Metal*, not MoltenVK-over-Vulkan. That is Apple's only non-deprecated GPU API. `gl_compatibility` on iOS means OpenGL ES 3.0, which Apple deprecated in 2018 and can remove in any release. Betting the primary platform on a deprecated API to preserve symmetry with a hypothetical web build is the wrong trade.
- `forward_plus` is rejected outright: it is the clustered desktop renderer, and for a canvas with zero 3D it buys nothing while costing startup time, memory for cluster/light buffers, and power.
- For web, `rendering_method.web="gl_compatibility"` is not a choice — Godot 4.7 web export is WebGL 2.0 only (4.7 added wasm64 and SIMD-by-default, but no WebGPU). One line handles it.
- The divergence risk between the two paths for a *2D UI* app is essentially zero: no compute, no 3D lighting, no HDR (we leave `display/window/hdr/request_hdr_output` off), no advanced canvas shaders beyond a scrolling-UV shimmer, which compiles identically. Guard it anyway with a CI job that boots the headless tests under `--rendering-method gl_compatibility` (§19), so the day web becomes real, the delta is already known.

`msaa_2d=0` because the UI is textured quads and 9-slices; there are no anti-aliasable vector edges, and MSAA on a phone is pure fill-rate. `default_texture_filter=1` (Linear) because every device scales by a fractional factor — Nearest would visibly alias.

---

## 3. Safe area / notch strategy

`DisplayServer.get_display_safe_area()` returns a **`Rect2i` in physical screen pixels**, implemented on iOS/Android/macOS, falling back to `screen_get_usable_rect()` elsewhere. Our UI lives in 720-wide *stretch units*. The ratio between the two changes per device, and the fallback on desktop returns the desktop work area — which would produce absurd margins.

The robust conversion is **through fractions of the screen**, so the units cancel:

```gdscript
class_name SafeArea
extends MarginContainer

## Keeps content out of the notch, the Dynamic Island and the home indicator.
##
## get_display_safe_area() speaks physical screen pixels; the UI speaks 720-wide
## stretch units, and the factor between them is different on every device. So
## the inset is computed as a *fraction of the screen* and then multiplied by
## the viewport rect — the units cancel and the same code is right on a 19.5:9
## iPhone and a 4:3 iPad.
##
## Only the content is inset. The background art deliberately runs full-bleed
## behind this node: a letterboxed strip above the notch is the single most
## obvious "this is a port" tell on iOS.

@export var extra := Vector4(24, 8, 24, 8)   ## left, top, right, bottom (units)


func _ready() -> void:
	get_tree().root.size_changed.connect(_apply)
	_apply()


func _notification(what: int) -> void:
	# Orientation and safe area can both change while backgrounded.
	if what == NOTIFICATION_APPLICATION_RESUMED:
		_apply.call_deferred()


func _apply() -> void:
	var l := extra.x
	var t := extra.y
	var r := extra.z
	var b := extra.w

	if OS.has_feature("mobile"):
		var screen := DisplayServer.screen_get_size(
			DisplayServer.window_get_current_screen())
		var vp := get_viewport_rect().size
		if screen.x > 0 and screen.y > 0:
			var safe := DisplayServer.get_display_safe_area()
			l += (float(safe.position.x) / float(screen.x)) * vp.x
			t += (float(safe.position.y) / float(screen.y)) * vp.y
			r += (float(screen.x - safe.end.x) / float(screen.x)) * vp.x
			b += (float(screen.y - safe.end.y) / float(screen.y)) * vp.y

	add_theme_constant_override("margin_left", int(l))
	add_theme_constant_override("margin_top", int(t))
	add_theme_constant_override("margin_right", int(r))
	add_theme_constant_override("margin_bottom", int(b))
```

Two consequences to design around:

1. **The background is not inset.** `Main.tscn` has a full-bleed `TextureRect` (parchment/stone) as the first child of the root, and `SafeArea` wraps only the content column. The currency bar's own panel background should also bleed to the top edge while its *text* respects the inset — do that with a `Panel` anchored full-width behind the bar rather than by moving the bar.
2. **Even with `hide_home_indicator=true`, the bottom inset is non-zero** and the tab bar must sit above it, or the last 34 pt of the tab bar becomes an accidental home-gesture zone. This is the #1 source of "the last tab button doesn't work" bug reports on iOS.

For the editor, add a debug overlay that fakes insets (`extra = Vector4(24, 108, 24, 76)`) behind a `Cfg.fake_safe_area` flag so notch layout is testable on desktop.

---

## 4. Scene tree

```
Main (Control, anchors full rect, theme = Ui.theme)
├── Backdrop (TextureRect, full-bleed, stretch=KEEP_ASPECT_COVERED)
├── SafeArea (MarginContainer)
│   └── Column (VBoxContainer, separation 0)
│       ├── CurrencyBar (PanelContainer, 120u)
│       ├── TabHost (Control, SIZE_EXPAND_FILL)   # tabs parented here
│       └── TabBar (HBoxContainer, 150u, 6 × TabButton)
├── Overlay (CanvasLayer, layer = 10)
│   ├── Modals (Control)          # item detail, confirm, recruit reveal
│   ├── Toasts (VBoxContainer)    # top-anchored, inside safe inset
│   └── Floaters (Control)        # "+250" pooled labels
└── Status (CanvasLayer, layer = 20)
    ├── OfflineBanner (Control, hidden)
    └── BlockingSpinner (ColorRect + spinner, hidden)
```

`Overlay` and `Status` are `CanvasLayer`s so modals are never clipped by a `ScrollContainer` and never inherit a tab's `visible=false`. They compute their own safe inset (a `SafeArea` child) rather than reusing the one in the column.

### 4.1 Autoloads and what each owns

Ten. Each one is *infrastructure*; none contains game rules. The rule that keeps this from becoming a god-object soup: **an autoload may depend only on autoloads listed above it.**

| # | Autoload | Owns | Depends on |
|---|---|---|---|
| 1 | `Clock` | server-corrected wall clock, `now_ms()`, injectable time source for tests | — |
| 2 | `Cfg` | api base url, build flavour, feature flags, `--api=` override | — |
| 3 | `Log` | ring buffer of the last 200 events, breadcrumbs for crash reports | Clock |
| 4 | `Api` | HTTP: transport pool, auth headers, refresh, retry, offline state, tag cancellation | Clock, Cfg, Log |
| 5 | `GameState` | the eight domain stores + `apply_snapshot()` + derived display values | Clock |
| 6 | `Actions` | the optimistic queue: predict, batch, reconcile, roll back | Api, GameState |
| 7 | `Session` | boot, login, catalog, resync, app lifecycle, fps throttle | all above |
| 8 | `Ui` | the single `Theme` instance; registry for the Overlay layer (`Ui.toast()`, `Ui.modal()`) | — |
| 9 | `Audio` | buses, voices, music, ducking | — |
| 10 | `Haptics` | `Input.vibrate_handheld` with a global off switch and a rate limit | — |

`Ui` deliberately does **not** own a `CanvasLayer`. `Main` registers its `Overlay` node with `Ui` in `_ready`, so overlays live inside the scene (respecting the safe area and the theme) while callers still get a global `Ui.toast("…")` API.

### 4.2 The six tabs: lazy-instantiate, then cache

**Decision: instantiate a tab the first time it is opened, then keep it, hidden and process-disabled.**

Rejected: preloading all six at boot (adds 6 scene instantiations + 6 first-layout passes to cold start, which is the metric that actually predicts D1 retention on mobile). Rejected: free-on-hide (throws away scroll position, which players notice immediately, and re-pays instantiation on every tab switch — the most frequent interaction in the game).

Memory is a non-argument here. Six UI tabs with list recycling are on the order of 600–900 `Control` nodes total, tens of KB of node overhead; the texture atlases dwarf them by two orders of magnitude. First paint is the real currency, so pay lazily.

```gdscript
# res://ui/tab_host.gd
class_name TabHost
extends Control

## Owns the six tabs. A tab is built the first time it is opened and then kept.
##
## Building all six at boot costs six instantiations and six first-layout passes
## on the frame the player is judging the app. Freeing on hide costs the scroll
## position, which is the thing players notice. So: build late, keep forever.

signal tab_changed(id: StringName)

const SCENES := {
	&"family":    "res://ui/tabs/FamilyTab.tscn",
	&"collect":   "res://ui/tabs/CollectTab.tscn",
	&"inventory": "res://ui/tabs/InventoryTab.tscn",
	&"shop":      "res://ui/tabs/ShopTab.tscn",
	&"soldiers":  "res://ui/tabs/SoldiersTab.tscn",
	&"attack":    "res://ui/tabs/AttackTab.tscn",
}

var current: StringName = &""

var _pages: Dictionary = {}   ## StringName -> TabPage


func open(id: StringName) -> void:
	if id == current or not SCENES.has(id):
		return

	if _pages.has(current):
		var old: TabPage = _pages[current]
		old.tab_hidden()
		old.visible = false
		old.process_mode = Node.PROCESS_MODE_DISABLED
		# Anything this tab asked for is no longer wanted. Cancelling here is
		# why flicking through all six tabs does not queue six stale responses
		# behind the one the player is waiting for.
		Api.cancel_tag(id)

	current = id
	var page: TabPage = _pages.get(id)
	if page == null:
		page = (load(SCENES[id]) as PackedScene).instantiate()
		page.set_anchors_preset(Control.PRESET_FULL_RECT)
		_pages[id] = page
		add_child(page)

	page.process_mode = Node.PROCESS_MODE_INHERIT
	page.visible = true
	page.tab_shown()
	tab_changed.emit(id)
```

### 4.3 `TabPage`: the dirty-flag contract

A hidden `Control` still receives signals. Without this base class, an inventory change repaints five off-screen tabs.

```gdscript
# res://ui/tab_page.gd
@abstract
class_name TabPage
extends Control

## Base for the six tabs.
##
## Two rules, both about work that is invisible and therefore easy to leave in:
## a hidden tab must not repaint, and a tab must not repaint twice in one frame
## because three stores changed. `mark_dirty()` enforces both — handlers call it
## instead of calling refresh(), and it coalesces to one deferred refresh.
##
## Server-fed lists (shop roll, attack opponents) additionally re-fetch in
## tab_shown(): caching the *scene* is right, caching the *data* is not.

var _dirty := true
var _queued := false


func mark_dirty() -> void:
	_dirty = true
	if not is_visible_in_tree() or _queued:
		return
	_queued = true
	_flush.call_deferred()


func _flush() -> void:
	_queued = false
	if not _dirty or not is_visible_in_tree():
		return
	_dirty = false
	refresh()


func tab_shown() -> void:
	if _dirty:
		_dirty = false
		refresh()


func tab_hidden() -> void:
	pass


@abstract func refresh() -> void
```

---

## 5. State management

### 5.1 The three rules

1. **One signal per domain, not per field.** Field-level signals produce a UI where nobody can trace what causes a repaint. A domain is small enough that repainting all of it is free and coarse enough that the inventory grid never rebuilds because energy ticked.
2. **No UI node reads `GameState` in `_process`.** Exactly two nodes in the game run `_process`: the `NumberLabel` tween (which stops itself when it arrives) and `Session`'s 10 Hz projector. Everything else is signal-driven.
3. **A prediction is never written into a store.** Stores hold only what the server confirmed. Display values are computed.

### 5.2 `Store` base

```gdscript
# res://state/store.gd
@abstract
class_name Store
extends RefCounted

## Base for every domain store.
##
## edit()/commit() exist because applying a server snapshot touches every field.
## Without them a snapshot emits `changed` twenty times, and the frame after a
## sync becomes the only one in the game that ever drops.

signal changed

var _depth := 0
var _pending := false


func edit() -> void:
	_depth += 1


func commit() -> void:
	_depth = maxi(0, _depth - 1)
	if _depth == 0 and _pending:
		_pending = false
		changed.emit()


func touch() -> void:
	if _depth > 0:
		_pending = true
	else:
		changed.emit()


@abstract func apply(snapshot: Dictionary) -> void
```

### 5.3 Two representative domain stores

```gdscript
# res://state/wallet_store.gd
class_name WalletStore
extends Store

## Gold and diamonds as the server last stated them, plus the inputs needed to
## project passive tax forward.

var gold := 0
var diamonds := 0
var tax_per_sec := 0.0
var tax_cap := 0
var tax_since_ms := 0        ## server clock, when `gold` was stated


func apply(s: Dictionary) -> void:
	edit()
	gold = int(s.get("gold", gold))
	diamonds = int(s.get("diamonds", diamonds))
	tax_per_sec = float(s.get("tax_per_sec", tax_per_sec))
	tax_cap = int(s.get("tax_cap", tax_cap))
	tax_since_ms = int(s.get("tax_since_ms", tax_since_ms))
	touch()
	commit()


## What the server would say if it answered right now. Recomputed, never
## stored: folding a projection into `gold` is how a client starts believing
## its own guesses, and an 8-hour offline cap makes that guess large.
func accrued_tax(now_ms: int) -> int:
	if tax_per_sec <= 0.0 or tax_since_ms <= 0:
		return 0
	var secs := maxf(0.0, float(now_ms - tax_since_ms) / 1000.0)
	return mini(int(tax_per_sec * secs), tax_cap)
```

```gdscript
# res://state/jobs_store.gd
class_name JobsStore
extends Store

## The Collect ladder.
##
## `gold_payout` is the *resolved* payout: the server has already applied family
## upgrades, kingdom upgrades and the 25/50/100 milestone bonuses and rounded it
## the way the server rounds. The client never evaluates the formula. That one
## contract decision is what makes optimistic collect exact (§8) and lets the
## economy be retuned without a client release.

class Job extends RefCounted:
	var id := ""
	var name_key := ""
	var art_id := ""
	var unlock_level := 1
	var energy_cost := 1
	var gold_payout := 0
	var xp_payout := 0
	var count := 0
	var next_milestone := 0      ## 0 = none left
	var next_milestone_bonus := 0.0

var order: PackedStringArray = []

var _by_id: Dictionary = {}      ## String -> Job


func apply(s: Dictionary) -> void:
	edit()
	order = PackedStringArray()
	for raw in s.get("jobs", []):
		var d: Dictionary = raw
		var id := str(d.get("id", ""))
		var j: Job = _by_id.get(id)
		if j == null:
			j = Job.new()
			j.id = id
			_by_id[id] = j
		j.name_key = str(d.get("name_key", ""))
		j.art_id = str(d.get("art_id", ""))
		j.unlock_level = int(d.get("unlock_level", 1))
		j.energy_cost = int(d.get("energy_cost", 1))
		j.gold_payout = int(d.get("gold_payout", 0))
		j.xp_payout = int(d.get("xp_payout", 0))
		j.count = int(d.get("count", 0))
		j.next_milestone = int(d.get("next_milestone", 0))
		j.next_milestone_bonus = float(d.get("next_milestone_bonus", 0.0))
		order.append(id)
	touch()
	commit()


func get_job(id: String) -> Job:
	return _by_id.get(id)


## The predicted reward for the Nth *queued* collect of this job (0-based).
##
## Biased pessimistic on purpose. If this tap would cross a milestone, the
## payout after it goes up — but we keep predicting the old number, so the
## correction when the server answers is always *extra* gold. A player who sees
## a number tick up an extra 40 reads it as a bonus; a player who sees one tick
## down reads it as the game taking money back.
func predict(id: String, queued_before: int) -> Dictionary:
	var j := get_job(id)
	if j == null:
		return {}
	return {
		"gold": j.gold_payout,
		"xp": j.xp_payout,
		"energy": -j.energy_cost,
		"crosses_milestone": j.next_milestone > 0
			and j.count + queued_before + 1 >= j.next_milestone,
	}
```

### 5.4 `GameState`

```gdscript
# res://autoload/game_state.gd
extends Node

## The client's copy of the server's truth, and nothing else.
##
## `display_*()` is where predictions and projections are added on top. They are
## functions, not fields, because the moment a projection has a home in memory
## somebody writes to it.

signal snapshot_applied
signal staleness_changed(stale: bool)

var player := PlayerStore.new()
var wallet := WalletStore.new()
var energy := EnergyStore.new()
var jobs := JobsStore.new()
var inventory := InventoryStore.new()
var soldiers := SoldiersStore.new()
var shop := ShopStore.new()
var kingdom := KingdomStore.new()

## True from boot until the first live snapshot lands. The UI paints cached
## numbers immediately and dims them until this clears, which is the difference
## between a 40 ms cold start and a 900 ms one.
var stale := true


func domains() -> Dictionary:
	return {
		"player": player, "wallet": wallet, "energy": energy,
		"jobs": jobs, "inventory": inventory, "soldiers": soldiers,
		"shop": shop, "kingdom": kingdom,
	}


func apply_snapshot(s: Dictionary) -> void:
	if s.is_empty():
		return
	for key in domains():
		if s.has(key):
			(domains()[key] as Store).apply(s[key])
	if stale:
		stale = false
		staleness_changed.emit(false)
	snapshot_applied.emit()


func display_gold() -> int:
	return wallet.gold + wallet.accrued_tax(Clock.now_ms()) + Actions.gold_delta()


func display_energy() -> int:
	return clampi(
		energy.projected(Clock.now_ms()) + Actions.energy_delta(),
		0, energy.energy_max)


func display_xp() -> int:
	return player.xp + Actions.xp_delta()
```

### 5.5 Avoiding the "everything polls every frame" trap

Two numbers move on their own — gold (tax) and energy (regen) — and every screen shows both. That is exactly the shape that tempts you into `_process` in ten places.

```gdscript
# inside res://autoload/session.gd
## Pushes the two self-moving numbers at 10 Hz.
##
## Ten calls a second into two functions, instead of N screens each calling into
## the store 60 times a second. The widgets tween between pushes, so it still
## reads at the display's full rate — an interpolating consumer is what makes a
## low push rate invisible.

signal projected(gold: int, energy: int)

const PROJECT_HZ := 10.0

var _accum := 0.0
var _last_gold := -1
var _last_energy := -1


func _process(delta: float) -> void:
	_idle += delta
	if _idle > IDLE_SECONDS and Engine.max_fps != IDLE_FPS:
		Engine.max_fps = IDLE_FPS

	_accum += delta
	if _accum < 1.0 / PROJECT_HZ:
		return
	_accum = 0.0

	var g := GameState.display_gold()
	var e := GameState.display_energy()
	if g == _last_gold and e == _last_energy:
		return
	_last_gold = g
	_last_energy = e
	projected.emit(g, e)
```

The rule for reviewers: **a `_process` in `res://ui/` that is not `NumberLabel` or an explicit animation is a bug.**

---

## 6. Networking layer

`HTTPRequest` is a `Node` that carries exactly one in-flight request, and — this is the trap — **`cancel_request()` does not emit `request_completed`**, so a coroutine that `await`s the signal directly hangs forever on a cancel. And allocating one `HTTPRequest` per call leaks nodes precisely when the connection is worst and calls pile up. Both problems are solved in one place.

### 6.1 `ApiError` / `ApiResult`

```gdscript
# res://net/api_error.gd
class_name ApiError
extends RefCounted

enum Kind {
	NONE,
	OFFLINE,     ## we already know there is no route; never left the device
	NETWORK,     ## DNS / connect / TLS
	TIMEOUT,
	HTTP,        ## got a response, status >= 400
	PARSE,       ## 2xx with a body we could not read
	CANCELLED,
}

var kind: Kind = Kind.NONE
var status := 0
var code := ""          ## machine-readable, from the server envelope
var message := ""       ## English fallback; UI prefers tr("ERR_" + code)
var retry_after := 0.0


func _init(p_kind := Kind.NONE, p_status := 0, p_code := "", p_message := "") -> void:
	kind = p_kind
	status = p_status
	code = p_code
	message = p_message


func is_retryable() -> bool:
	match kind:
		Kind.NETWORK, Kind.TIMEOUT:
			return true
		Kind.HTTP:
			return status == 429 or status >= 500
		_:
			return false


func user_text() -> String:
	if not code.is_empty():
		var key := "ERR_" + code.to_upper()
		var t := tr(key)
		if t != key:
			return t
	match kind:
		Kind.TIMEOUT, Kind.NETWORK, Kind.OFFLINE:
			return tr("ERR_NO_CONNECTION")
		_:
			return tr("ERR_UNKNOWN")


func _to_string() -> String:
	return "ApiError(%s %d %s)" % [Kind.keys()[kind], status, code]
```

```gdscript
# res://net/api_result.gd
class_name ApiResult
extends RefCounted

var ok := false
var status := 0
var data: Variant = null
var headers: Dictionary = {}    ## lowercased name -> value
var error: ApiError = null
var elapsed_ms := 0


static func success(p_status: int, p_data: Variant, p_headers: Dictionary) -> ApiResult:
	var r := ApiResult.new()
	r.ok = true
	r.status = p_status
	r.data = p_data
	r.headers = p_headers
	return r


static func failure(p_error: ApiError) -> ApiResult:
	var r := ApiResult.new()
	r.ok = false
	r.error = p_error
	r.status = p_error.status
	return r


func dict() -> Dictionary:
	return data if typeof(data) == TYPE_DICTIONARY else {}


func list() -> Array:
	return data if typeof(data) == TYPE_ARRAY else []
```

### 6.2 `HttpTransport` — the pool

```gdscript
# res://net/http_transport.gd
class_name HttpTransport
extends Node

## The only place in the client that touches HTTPRequest.
##
## Three engine facts shape this file:
##   * one HTTPRequest carries one request, so concurrency needs a pool;
##   * cancel_request() does NOT emit request_completed, so a coroutine that
##     awaits the signal directly hangs forever on a cancel — hence Pending,
##     whose `done` fires on completion *and* on cancellation;
##   * a node-per-request leaks nodes exactly when the network is worst.
##
## One slot is reserved for the action lane (§8) so a slow leaderboard fetch can
## never sit in front of a collect flush.

const GENERAL_SLOTS := 4
const BODY_LIMIT := 2 * 1024 * 1024

signal _slot_released


class Pending extends RefCounted:
	signal done(result: ApiResult)

	enum State { QUEUED, RUNNING, FINISHED }

	var state: State = State.QUEUED
	var http: HTTPRequest = null
	var started_ms := 0
	var reserved := false        ## true = use the action-lane slot

	func finish(r: ApiResult) -> void:
		if state == State.FINISHED:
			return
		state = State.FINISHED
		done.emit(r)


var _general: Array[HTTPRequest] = []
var _reserved: HTTPRequest
var _leased: Dictionary = {}     ## HTTPRequest -> Pending


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	for i in GENERAL_SLOTS:
		_general.append(_make())
	_reserved = _make()


func _make() -> HTTPRequest:
	var h := HTTPRequest.new()
	h.accept_gzip = true
	h.body_size_limit = BODY_LIMIT
	# Threads keep TLS handshakes off the main thread. Not available on web.
	h.use_threads = not OS.has_feature("web")
	add_child(h)
	return h


func send(method: int, url: String, headers: PackedStringArray,
		body: String, timeout: float, pending: Pending) -> ApiResult:
	var http := await _lease(pending)
	if http == null:
		return ApiResult.failure(ApiError.new(ApiError.Kind.CANCELLED))

	pending.http = http
	pending.state = Pending.State.RUNNING
	pending.started_ms = Time.get_ticks_msec()
	http.timeout = timeout

	var on_done := func(result: int, code: int,
			raw: PackedStringArray, bytes: PackedByteArray) -> void:
		pending.finish(_to_result(result, code, raw, bytes,
			Time.get_ticks_msec() - pending.started_ms))

	http.request_completed.connect(on_done, CONNECT_ONE_SHOT)

	var err := http.request(url, headers, method, body)
	if err != OK:
		if http.request_completed.is_connected(on_done):
			http.request_completed.disconnect(on_done)
		_release(http)
		return ApiResult.failure(ApiError.new(ApiError.Kind.NETWORK, 0,
			"request_failed", "HTTPRequest.request() -> %d" % err))

	var out: ApiResult = await pending.done

	if http.request_completed.is_connected(on_done):
		http.request_completed.disconnect(on_done)
	# Deferred: on the cancel path the socket teardown finishes this frame, and
	# handing the node straight to the next caller can bounce off ERR_BUSY.
	_release.call_deferred(http)
	return out


## Aborts the socket and wakes whoever is awaiting. Safe to call twice, and safe
## to call before the request ever got a slot.
func cancel(pending: Pending) -> void:
	if pending.state == Pending.State.FINISHED:
		return
	if pending.http != null and is_instance_valid(pending.http):
		pending.http.cancel_request()
	pending.finish(ApiResult.failure(ApiError.new(ApiError.Kind.CANCELLED)))


func _lease(pending: Pending) -> HTTPRequest:
	while pending.state != Pending.State.FINISHED:
		if pending.reserved and not _leased.has(_reserved):
			_leased[_reserved] = pending
			return _reserved
		for h in _general:
			if not _leased.has(h):
				_leased[h] = pending
				return h
		await _slot_released
	return null


func _release(http: HTTPRequest) -> void:
	if not _leased.has(http):
		return
	_leased.erase(http)
	_slot_released.emit()


static func _to_result(result: int, code: int, raw: PackedStringArray,
		bytes: PackedByteArray, elapsed: int) -> ApiResult:
	if result != HTTPRequest.RESULT_SUCCESS:
		var kind := ApiError.Kind.TIMEOUT if result == HTTPRequest.RESULT_TIMEOUT \
			else ApiError.Kind.NETWORK
		return ApiResult.failure(ApiError.new(kind, 0,
			"transport_%d" % result, "transport error %d" % result))

	var headers := {}
	for line in raw:
		var i := line.find(":")
		if i > 0:
			headers[line.substr(0, i).strip_edges().to_lower()] = \
				line.substr(i + 1).strip_edges()

	var text := bytes.get_string_from_utf8()
	var parsed: Variant = JSON.parse_string(text) if not text.is_empty() else null

	if code >= 200 and code < 300:
		if not text.is_empty() and parsed == null:
			return ApiResult.failure(ApiError.new(ApiError.Kind.PARSE, code,
				"bad_json", text.substr(0, 120)))
		var r := ApiResult.success(code, parsed, headers)
		r.elapsed_ms = elapsed
		return r

	var e := ApiError.new(ApiError.Kind.HTTP, code)
	if typeof(parsed) == TYPE_DICTIONARY:
		e.code = str((parsed as Dictionary).get("code", ""))
		e.message = str((parsed as Dictionary).get("message", ""))
	if headers.has("retry-after"):
		e.retry_after = float(headers["retry-after"])
	return ApiResult.failure(e)
```

### 6.3 `Api` — auth, retry, offline, cancellation

```gdscript
# res://autoload/api.gd
extends Node

## The client's side of the backend.
##
## Everything a UI caller needs is `await Api.get_json(path)` /
## `await Api.post_json(path, body)` returning an ApiResult that is never null
## and never throws. The four things that make that true live here: a
## single-flight token refresh (five screens booting at once must not fire five
## refreshes and rotate the token out from under each other), exponential
## backoff with jitter (200 clients recovering from a blip must not retry in
## lockstep), retries gated on idempotency (a blind retry of "collect" mints
## gold), and a tag so a tab can cancel everything it asked for on the way out.

signal online_changed(online: bool)
signal auth_lost                       ## refresh failed; Session must re-login

const DEFAULT_TIMEOUT := 12.0
const MAX_ATTEMPTS := 4
const BACKOFF_BASE := 0.4
const BACKOFF_MAX := 8.0
const REFRESH_SKEW_S := 60
const OFFLINE_AFTER := 2

var online := true

var _tp                                ## HttpTransport, or a fake in tests
var _access := ""
var _access_exp := 0
var _refresh := ""
var _refreshing := false
var _failures := 0
var _tags: Dictionary = {}             ## StringName -> Array[Pending]

signal _refresh_finished(ok: bool)


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_tp = HttpTransport.new()
	add_child(_tp)


## Tests swap the transport for a scripted fake. This one seam is why retry,
## backoff, the refresh stampede and offline transitions are testable at all.
func set_transport(t) -> void:
	_tp = t


func set_tokens(access: String, refresh: String) -> void:
	_access = access
	_access_exp = _jwt_exp(access)
	_refresh = refresh


# ------------------------------------------------------------- public API ---

func get_json(path: String, query := {}, opts := {}) -> ApiResult:
	return await _call(HTTPClient.METHOD_GET, path, query, null, opts)


func post_json(path: String, body: Variant, opts := {}) -> ApiResult:
	return await _call(HTTPClient.METHOD_POST, path, {}, body, opts)


## Everything a tab asked for, dropped. Called by TabHost on the way out.
func cancel_tag(tag: StringName) -> void:
	var list: Array = _tags.get(tag, [])
	_tags.erase(tag)
	for p in list:
		_tp.cancel(p)


# ------------------------------------------------------------- plumbing -----

func _call(method: int, path: String, query: Dictionary,
		body: Variant, opts: Dictionary) -> ApiResult:
	var tag: StringName = opts.get("tag", &"")
	var needs_auth: bool = opts.get("auth", true)
	var timeout: float = opts.get("timeout", DEFAULT_TIMEOUT)
	var idem: String = str(opts.get("idempotency_key", ""))
	# A GET is safe to repeat by definition. A POST is safe to repeat only if it
	# carries a key the server can dedupe on. Nothing else gets retried.
	var retryable: bool = opts.get("retries",
		method == HTTPClient.METHOD_GET or not idem.is_empty())

	var url := Cfg.api_url + path + _encode_query(query)
	var payload := "" if body == null else JSON.stringify(body)
	var last: ApiResult = null

	for attempt in range(1, MAX_ATTEMPTS + 1):
		if needs_auth and not await _ensure_token():
			return ApiResult.failure(ApiError.new(ApiError.Kind.HTTP, 401,
				"unauthenticated", "no valid session"))

		var headers := PackedStringArray([
			"Accept: application/json",
			"X-Client: emperors-godot/" + Cfg.version,
		])
		if not payload.is_empty():
			headers.append("Content-Type: application/json")
		if needs_auth and not _access.is_empty():
			headers.append("Authorization: Bearer " + _access)
		if not idem.is_empty():
			headers.append("Idempotency-Key: " + idem)

		var pending := HttpTransport.Pending.new()
		pending.reserved = tag == &"actions"
		_track(tag, pending)
		last = await _tp.send(method, url, headers, payload, timeout, pending)
		_untrack(tag, pending)

		Clock.observe(last)

		if last.ok:
			_note_reachable()
			return last

		var e := last.error
		if e.kind == ApiError.Kind.CANCELLED:
			return last

		# One silent 401 retry: the token can expire between our check and the
		# server's, or keys can rotate. A second 401 is a real auth failure.
		if e.kind == ApiError.Kind.HTTP and e.status == 401 and needs_auth and attempt == 1:
			_access = ""
			_access_exp = 0
			continue

		if e.kind == ApiError.Kind.NETWORK or e.kind == ApiError.Kind.TIMEOUT:
			_note_unreachable()

		if not retryable or not e.is_retryable() or attempt == MAX_ATTEMPTS:
			return last

		Log.warn("retry %d %s %s" % [attempt, path, e])
		await _sleep(_backoff(attempt, e))

	return last


## Full jitter. Without it every client that dropped during the same blip comes
## back on the same millisecond and re-creates the outage.
func _backoff(attempt: int, e: ApiError) -> float:
	if e.retry_after > 0.0:
		return minf(e.retry_after, 30.0)
	var base := minf(BACKOFF_BASE * pow(2.0, attempt - 1), BACKOFF_MAX)
	return base * randf_range(0.6, 1.4)


func _sleep(seconds: float) -> void:
	await get_tree().create_timer(seconds, true, false, true).timeout


## Single-flight. Callers that arrive mid-refresh park on the signal instead of
## starting a second one; a second refresh would rotate the token and invalidate
## the first caller's brand-new one.
func _ensure_token() -> bool:
	if _refresh.is_empty() and _access.is_empty():
		return false
	var now := int(Clock.now_ms() / 1000)
	if not _access.is_empty() and _access_exp - REFRESH_SKEW_S > now:
		return true
	if _refresh.is_empty():
		return false
	if _refreshing:
		return await _refresh_finished

	_refreshing = true
	var ok := await _do_refresh()
	_refreshing = false
	_refresh_finished.emit(ok)
	if not ok:
		_access = ""
		_refresh = ""
		auth_lost.emit()
	return ok


func _do_refresh() -> bool:
	# auth:false — this call must not recurse back into _ensure_token().
	var res := await _call(HTTPClient.METHOD_POST, "/v1/auth/refresh", {},
		{"refresh_token": _refresh}, {"auth": false, "retries": true, "tag": &"auth"})
	if not res.ok:
		return false
	var d := res.dict()
	set_tokens(str(d.get("access_token", "")), str(d.get("refresh_token", _refresh)))
	Session.persist_tokens(_access, _refresh)
	return not _access.is_empty()


## Read the exp claim without verifying anything. Its only job is to schedule a
## refresh a minute early so most requests never see a 401 at all; the server is
## the thing that decides whether the token is real.
static func _jwt_exp(token: String) -> int:
	var parts := token.split(".")
	if parts.size() != 3:
		return 0
	var seg := parts[1].replace("-", "+").replace("_", "/")
	while seg.length() % 4 != 0:
		seg += "="
	var parsed = JSON.parse_string(Marshalls.base64_to_utf8(seg))
	return int((parsed as Dictionary).get("exp", 0)) \
		if typeof(parsed) == TYPE_DICTIONARY else 0


func _note_unreachable() -> void:
	_failures += 1
	if online and _failures >= OFFLINE_AFTER:
		online = false
		online_changed.emit(false)
		_heartbeat()


func _note_reachable() -> void:
	_failures = 0
	if not online:
		online = true
		online_changed.emit(true)


func _heartbeat() -> void:
	var wait := 1.0
	while not online:
		await _sleep(wait)
		wait = minf(wait * 1.8, 20.0)
		var res := await _call(HTTPClient.METHOD_GET, "/v1/ping", {}, null,
			{"auth": false, "retries": false, "timeout": 5.0})
		if res.ok:
			_note_reachable()
			Session.resync()


func _track(tag: StringName, p) -> void:
	if tag == &"":
		return
	if not _tags.has(tag):
		_tags[tag] = []
	(_tags[tag] as Array).append(p)


func _untrack(tag: StringName, p) -> void:
	if _tags.has(tag):
		(_tags[tag] as Array).erase(p)


static func _encode_query(q: Dictionary) -> String:
	if q.is_empty():
		return ""
	var parts := PackedStringArray()
	for k in q:
		parts.append("%s=%s" % [str(k).uri_encode(), str(q[k]).uri_encode()])
	return "?" + "&".join(parts)
```

### 6.4 `Clock` — server time, and why it is its own autoload

Every projection (tax accrual, energy regen, shield expiry, shop refresh countdown) is a function of *server* time. Device clocks are wrong, and on a phone they can be wrong on purpose. `Clock` also has a swappable time source, which is what makes regen and tax testable without sleeping.

```gdscript
# res://autoload/clock.gd
extends Node

## Server-corrected wall clock.
##
## Every response envelope carries `now_ms`. Half the round trip is added back
## because the server stamped it before the reply travelled. The offset is
## smoothed rather than replaced so one slow response cannot make the energy bar
## jump backwards.

var offset_ms := 0

## Tests replace this with a controllable counter. Nothing else in the client is
## allowed to call Time.get_unix_time_from_system() directly.
var source: Callable = func() -> int:
	return int(Time.get_unix_time_from_system() * 1000.0)


func now_ms() -> int:
	return source.call() + offset_ms


func observe(res: ApiResult) -> void:
	if not res.ok:
		return
	var d := res.dict()
	if not d.has("now_ms"):
		return
	var observed := int(d["now_ms"]) + res.elapsed_ms / 2 - source.call()
	offset_ms = observed if offset_ms == 0 \
		else int(lerp(float(offset_ms), float(observed), 0.25))
```

> **Server contract:** every 2xx JSON response body is an object containing `now_ms` (int, unix ms). Non-negotiable — the whole projection layer depends on it.

---

## 7. Ergonomics: what a caller actually writes

```gdscript
func _on_refresh_pressed() -> void:
	_spinner.visible = true
	var res := await Api.get_json("/v1/shop", {}, {"tag": &"shop"})
	_spinner.visible = false
	if not res.ok:
		if res.error.kind != ApiError.Kind.CANCELLED:
			Ui.toast(res.error.user_text(), Ui.ToastKind.ERROR)
		return
	GameState.shop.apply(res.dict())
```

That is the whole story: `await`, one `ApiResult`, never null, never throws, cancellation is a normal result you can ignore. Every network call site in the game looks like this.

---

## 8. Optimistic UI — the centre of the design

### 8.1 The problem, stated precisely

Tapping Collect 20 times in 3 seconds on a 200 ms connection must (a) update the number on the same frame as the touch, (b) never let the client's number exceed the server's, (c) survive a mid-burst timeout without minting or losing gold, and (d) not send 20 HTTP requests.

### 8.2 Two lanes

| Lane | Actions | Pattern |
|---|---|---|
| **A — optimistic** | `collect`, `spend_stat_point` | predicted instantly, batched, coalesced, reconciled |
| **B — authoritative** | `recruit_soldier`, `buy_slot`, `buy_shop_item`, `attack`, `buy_upgrade`, `found_kingdom` | single-flight, that one widget goes busy, result animates in |

The dividing line is not "how important" — it is **frequency and determinism**. Predict an action the player does more than once a second *and* whose outcome is a pure function of state the client already has. Recruit rolls a random tier; predicting a dice roll means showing a legendary and taking it away. Attack rolls combat. Shop purchase races other buyers. All of those *want* a reveal beat anyway — the round trip is the drama, not the latency.

### 8.3 The three mechanisms

**(1) Display = confirmed + replay(pending).** A prediction is never written into a store. `WalletStore.gold` only ever changes when the server says so. `GameState.display_gold()` adds the pending deltas. Consequence: a wrong prediction costs exactly one correction and can never accumulate drift, because there is no accumulator.

**(2) Resolved payouts, not formulas.** The server ships `gold_payout` already multiplied by family upgrades, kingdom upgrades and milestone bonuses, and already rounded. The client's "prediction" is a table lookup, so it cannot diverge by a rounding rule. This is the single highest-leverage contract decision in the project: it makes prediction exact, and it lets the economy be retuned server-side with no client release.

**(3) Predict pessimistically.** When a queued tap would cross a 25/50/100 milestone, keep predicting the *old* payout. Corrections are then always positive. A number that ticks up an extra 40 when the server answers reads as a bonus; a number that ticks down reads as the game taking money back. This asymmetry is free and it is worth a lot.

Plus two safety rails: **the energy gate** (the client refuses to queue a tap it cannot afford, using `display_energy()` which already nets out pending spend — so the queue is self-limiting and the server rarely has to reject anything), and **per-batch idempotency keys** (a retry after a timeout cannot double-spend, which is what makes retrying a currency-minting POST safe at all).

### 8.4 `Actions`

```gdscript
# res://autoload/action_queue.gd
extends Node

## Client-side prediction with server reconciliation, for the taps that happen
## faster than the network can answer.
##
## Collect is the whole game's verb: hundreds of taps a session, often five a
## second. A round trip per tap on a 200 ms link makes the button feel broken,
## and 20 unbatched POSTs make the server miserable for no gain.
##
## The shape:
##   * a tap is validated locally, appended to _pending, and drawn immediately;
##   * the displayed number is always confirmed + replay(pending) — a prediction
##     never touches a store, so a bad guess costs one correction and can never
##     accumulate into drift;
##   * one batch is in flight at a time, up to BATCH_MAX intents, under a single
##     idempotency key, so replaying it after a timeout cannot double-spend;
##   * the server answers with applied_through + a fresh snapshot; everything at
##     or below that sequence leaves _pending and the display is recomputed.
##
## Random-outcome actions are deliberately absent. Predicting a dice roll is how
## you show someone a legendary and then take it away.

signal pending_changed
signal rejected(seq: int, code: String)
signal reconciled(gold_delta: int)

const BATCH_MAX := 32
const COALESCE := 0.12       ## one RTT dominates; this just merges a burst
const MAX_PENDING := 120     ## more than the server could plausibly owe us

var _seq := 0
var _session_id := ""
var _pending: Array[Dictionary] = []
var _inflight: Array[Dictionary] = []
var _sending := false
var _scheduled := false

# Running sums instead of walking the arrays: these are read at 10 Hz by the
# projector and on every repaint of every screen that shows a currency.
var _d_gold := 0
var _d_xp := 0
var _d_energy := 0
var _d_job_counts: Dictionary = {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_session_id = Crypto.new().generate_random_bytes(8).hex_encode()
	Api.online_changed.connect(func(on: bool):
		if on and not _pending.is_empty():
			_schedule())


func gold_delta() -> int:   return _d_gold
func xp_delta() -> int:     return _d_xp
func energy_delta() -> int: return _d_energy
func queued_for_job(id: String) -> int: return int(_d_job_counts.get(id, 0))
func pending_count() -> int: return _pending.size() + _inflight.size()


## Returns false when the tap is refused locally — no energy, unknown job, or
## the queue is already absurd. A refused tap must shake and buzz, never be a
## silent no-op: a button that sometimes does nothing is the worst outcome here.
func collect(job_id: String) -> bool:
	var job := GameState.jobs.get_job(job_id)
	if job == null:
		return false
	if pending_count() >= MAX_PENDING:
		return false
	if GameState.player.level < job.unlock_level:
		return false
	if GameState.display_energy() < job.energy_cost:
		return false

	var p := GameState.jobs.predict(job_id, queued_for_job(job_id))
	_seq += 1
	var action := {
		"seq": _seq,
		"kind": "collect",
		"job_id": job_id,
		"at_ms": Clock.now_ms(),
		"predict": {
			"gold": int(p["gold"]),
			"xp": int(p["xp"]),
			"energy": int(p["energy"]),
		},
	}
	_pending.append(action)
	_add(action, 1)
	pending_changed.emit()
	_schedule()
	return true


func _add(a: Dictionary, sign: int) -> void:
	var p: Dictionary = a["predict"]
	_d_gold += sign * int(p.get("gold", 0))
	_d_xp += sign * int(p.get("xp", 0))
	_d_energy += sign * int(p.get("energy", 0))
	var jid := str(a.get("job_id", ""))
	if not jid.is_empty():
		_d_job_counts[jid] = int(_d_job_counts.get(jid, 0)) + sign


func _schedule() -> void:
	if _scheduled or _sending:
		return
	_scheduled = true
	await get_tree().create_timer(COALESCE, true, false, true).timeout
	_scheduled = false
	_flush()


func _flush() -> void:
	if _sending or _pending.is_empty() or not Api.online:
		return
	_sending = true

	var take := mini(BATCH_MAX, _pending.size())
	_inflight = _pending.slice(0, take)
	_pending = _pending.slice(take)

	var body := {
		"batch_id": "%s:%d" % [_session_id, int(_inflight[0]["seq"])],
		"actions": _inflight.map(func(a: Dictionary) -> Dictionary:
			return {"seq": a["seq"], "kind": a["kind"], "job_id": a.get("job_id", "")}),
	}

	var res := await Api.post_json("/v1/actions", body, {
		"tag": &"actions",
		"idempotency_key": str(body["batch_id"]),
		"timeout": 10.0,
	})

	if res.ok:
		_ack(res.dict())
	else:
		_fail(res.error)

	_sending = false
	if not _pending.is_empty():
		# Straight back out: at steady state the send rate is one batch per RTT,
		# no matter how fast the player taps.
		_flush.call_deferred()


func _ack(body: Dictionary) -> void:
	var before := GameState.display_gold()

	var through := int(body.get("applied_through", 0))
	for a in _inflight.duplicate():
		if int(a["seq"]) <= through:
			_drop(a)

	# Rejections come back individually so the UI can say *why*. In practice a
	# rejected collect is an energy race with the player's other device.
	for raw in body.get("rejected", []):
		var r: Dictionary = raw
		var seq := int(r.get("seq", -1))
		for a in _inflight.duplicate():
			if int(a["seq"]) == seq:
				_drop(a)
		rejected.emit(seq, str(r.get("code", "unknown")))

	# Anything left in _inflight was neither applied nor rejected: the server
	# never saw it. Put it back at the front, ahead of newer taps.
	if not _inflight.is_empty():
		_pending = _inflight + _pending
		_inflight = []

	GameState.apply_snapshot(body.get("state", {}))
	pending_changed.emit()

	var delta := GameState.display_gold() - before
	if delta != 0:
		reconciled.emit(delta)


func _drop(a: Dictionary) -> void:
	_inflight.erase(a)
	_add(a, -1)


func _fail(e: ApiError) -> void:
	if e.kind == ApiError.Kind.CANCELLED or e.is_retryable():
		# The batch carries an idempotency key, so replaying it is safe even if
		# the server did apply it before the connection dropped. That key is the
		# entire reason a currency-minting POST can be retried at all.
		_pending = _inflight + _pending
		_inflight = []
		pending_changed.emit()
		return

	# A non-retryable 4xx means the server refused the batch outright. Guessing
	# which of 32 intents was bad is how you invent currency: drop them all and
	# take the server's word.
	Log.error("action batch refused: %s" % e)
	for a in _inflight.duplicate():
		_drop(a)
	_inflight = []
	pending_changed.emit()
	Session.resync()
	Ui.toast(tr("ERR_SYNC_RESET"), Ui.ToastKind.ERROR)
```

### 8.5 What the player sees

- **Tap → 0 frames of latency.** `collect()` returns `true`, the `CollectJobRow` fires its own local "+2 gold" floater and a 90 ms punch scale, `Haptics.impact(LIGHT)` buzzes, `Audio.sfx("collect")` plays. The currency bar's target moves on the next 10 Hz push and the `NumberLabel` rolls to it.
- **20 taps in 3 s → 3–4 HTTP requests** (one per RTT), each an atomic batch.
- **A correct prediction → no visible event at all** when the batch lands. This is the goal state, and with resolved payouts it is the 99.9% case.
- **A milestone crossing → the counter jumps up.** Deliberate: predicted low, corrected high, drawn as a gold "+bonus!" floater with a chime.
- **A rejection or a gold loss (you got attacked between snapshots) → the `NumberLabel` *tweens* down over 350 ms** and a red `-X` floater explains it. Never a snap. A snapping number is indistinguishable from a bug.
- **Offline → taps still work locally** up to the queue cap, the offline banner shows, and the queue flushes the moment the heartbeat reconnects.

### 8.6 Server contract for `POST /v1/actions`

```jsonc
// request
{
  "batch_id": "a3f1c9d2e8b04f17:41",
  "actions": [
    {"seq": 41, "kind": "collect", "job_id": "grapes"},
    {"seq": 42, "kind": "collect", "job_id": "grapes"}
  ]
}
// response 200
{
  "now_ms": 1788881234567,
  "applied_through": 42,
  "rejected": [],                       // [{"seq": 43, "code": "insufficient_energy"}]
  "state": { "wallet": {...}, "energy": {...}, "jobs": {...}, "player": {...} }
}
```

Server-side requirements that follow: process the batch **in `seq` order, atomically, in one transaction**; store `batch_id` in a dedupe table with a 24 h TTL and return the *original* response on a replay; stop at the first rejection and report the rest as unprocessed rather than skipping over it; and always echo a fresh partial snapshot of the domains the batch touched.

---

## 9. Theming

### 9.1 Build the `Theme` in code

A `.tres` gives live editor preview; a builder script gives readable diffs, derived colours and a single palette constant. For a solo dev plus AI assistants, the diffs win — a merged `.tres` theme is a nightmare, and half the point of this project is that changes are reviewable. `Ui.theme = UiTheme.build()` at startup; `Main` sets it on the root `Control` and it propagates to every descendant.

Variants use `theme_type_variation`, never per-node overrides:
`PrimaryButton`, `DangerButton`, `GhostButton`, `TabButton`, `ItemCard`, `RowPanel`, `H1`, `H2`, `Body`, `Caption`, `Number`, `TierName`.

### 9.2 Which node types get styled

| Type | Styled with | Why |
|---|---|---|
| `Button` (all 5 states) | `StyleBoxTexture` | interaction states belong to the theme system |
| `PanelContainer` / `Panel` | `StyleBoxTexture` | container chrome |
| `ScrollContainer` | `StyleBoxEmpty` | Godot's default panel + scroll boxes fight custom art |
| `VScrollBar` | slim `StyleBoxFlat` grabber, empty track | a decorated scrollbar on a phone is noise |
| `Label` | colours + font sizes | |
| `ProgressBar` | `StyleBoxTexture` bg + fill | XP and energy bars |
| `LineEdit` | `StyleBoxTexture` | kingdom name, invite codes |
| `AcceptDialog` / `ConfirmationDialog` | not used — we ship our own modal | native dialogs are desktop-shaped |
| Item frames, banners, ribbons | **`NinePatchRect` nodes** | decoration you position, not a state machine |

**The `NinePatchRect` vs `StyleBoxTexture` rule:** anything with interaction states goes in the `Theme` as a `StyleBoxTexture`; anything that is pure decoration is a `NinePatchRect` node. Both 9-slice identically; the difference is who owns the state.

### 9.3 Fonts

Two families, both SIL OFL, both commercially safe:

- **Cinzel SemiBold** — display. Roman engraved capitals; reads as carved stone, which is the medieval register we want without the illegibility of blackletter. Titles, tab labels, tier names, button captions.
- **Alegreya Sans (Regular / Bold)** — everything else. Humanist, warm, designed for long-form reading, holds up at small sizes on a phone. Body copy, stats, and all numbers.

Rejected: `MedievalSharp`/`UnifrakturCook` as a body face (decorative blackletter at 26 units on a 1179 px screen is unreadable, and this game is *made of* numbers). Cinzel is the flavour; Alegreya Sans is the workhorse.

Numbers get **tabular figures** via `FontVariation`, otherwise a counter rolling from 1,199 to 1,200 visibly reflows:

```gdscript
static func numerals() -> FontVariation:
	var fv := FontVariation.new()
	fv.base_font = BODY_BOLD
	# tnum = tabular figures, lnum = lining. Without tnum every currency counter
	# in the game jitters horizontally as it ticks.
	fv.opentype_features = {"tnum": 1, "lnum": 1}
	return fv
```

**Dynamic sizing across aspect ratios is a non-problem**, and that is the payoff of `canvas_items` stretch: fonts scale with the canvas, so a 30-unit label is the same physical size on an SE and a 16 Pro Max. What changes between devices is *available height*, not text size. Godot 4.5+ per-viewport font oversampling (`gui/fonts/dynamic_fonts/use_oversampling=true`) re-rasterises glyphs at the device's true pixel density, so text is crisp at any scale factor — **do not enable MSDF** for UI fonts; MSDF exists for extreme zoom and costs sharpness at the 20–30 unit sizes that make up 90% of this UI.

Sizes at base 720 (≈ 1 pt = 1.832 units):

| Variation | Units | ≈ pt | Use |
|---|---|---|---|
| `H1` | 48 | 26 | screen titles |
| `H2` | 36 | 20 | section headers, item names |
| `Number` | 34 | 18.5 | currency bar, stat values |
| `Body` | 30 | 16 | list rows, descriptions |
| `Caption` | 24 | 13 | secondary/dim text |
| `TabButton` | 22 | 12 | tab labels |

### 9.4 Palette and the epic/mystic conflict

The brief specifies `epic=purple` and `mystic=purple`. That is not shippable as stated: hue alone cannot carry a seven-step ladder, and it fails for the ~8% of men with a colour vision deficiency regardless of tuning.

**Proposal (needs the owner's sign-off):** keep both in the purple family, but separate them on **luminance + material + motion**, not hue.

| Tier | Base | Frame material | Extra |
|---|---|---|---|
| common | `#9AA3AD` gray | plain iron | — |
| uncommon | `#4FBF63` green | bronze | — |
| rare | `#3D8BFD` blue | steel | — |
| **epic** | `#A855F7` bright purple | polished silver, violet gem | — |
| legendary | `#F2B31C` gold | gold filigree | soft static glow |
| **mystic** | `#6D28D9` deep royal purple | dark obsidian, carved runes | `#E879F9` magenta rim + a slow moving sheen — **the only tier in the game that animates** |
| special | `#E5484D` red | crimson lacquer | — |

And a hard rule that makes the whole ladder robust: **tier is never communicated by colour alone.** Every `ItemCard` and `SoldierCard` shows (a) the tier-specific frame art, (b) a row of 1–7 pips, and (c) the localised tier name. Colour is reinforcement, not signal.

### 9.5 `UiTheme` (abridged, real)

```gdscript
# res://ui/theme/palette.gd
class_name Palette

enum Tier { COMMON, UNCOMMON, RARE, EPIC, LEGENDARY, MYSTIC, SPECIAL }

const TIER_COLOR := {
	Tier.COMMON:    Color("9aa3ad"),
	Tier.UNCOMMON:  Color("4fbf63"),
	Tier.RARE:      Color("3d8bfd"),
	Tier.EPIC:      Color("a855f7"),
	Tier.LEGENDARY: Color("f2b31c"),
	Tier.MYSTIC:    Color("6d28d9"),
	Tier.SPECIAL:   Color("e5484d"),
}
const TIER_KEY := ["TIER_COMMON", "TIER_UNCOMMON", "TIER_RARE", "TIER_EPIC",
	"TIER_LEGENDARY", "TIER_MYSTIC", "TIER_SPECIAL"]

## Mystic's rim light. Epic and mystic are both "purple" per the brief, so they
## are separated by luminance, frame material and motion instead of hue —
## and by pips and a spelled-out name, because a purple/purple pair fails for
## colour-blind players no matter how the hues are tuned.
const MYSTIC_RIM := Color("e879f9")

const INK       := Color("f2e6cf")   ## parchment white
const INK_DIM   := Color("b3a58c")
const INK_FAINT := Color("7a6f5c")
const GOLD      := Color("f2b31c")
const DIAMOND   := Color("7ee8f2")
const ENERGY    := Color("6fd66f")
const DANGER    := Color("e5484d")
const BG        := Color("0e0b09")

static func tier_color(t: int) -> Color:
	return TIER_COLOR.get(clampi(t, 0, 6), TIER_COLOR[Tier.COMMON])

static func tier_frame(t: int) -> Texture2D:
	return load("res://assets/ui/frame_%d.png" % clampi(t, 0, 6))

static func tier_name(t: int) -> String:
	return tr(TIER_KEY[clampi(t, 0, 6)])
```

```gdscript
# res://ui/theme/ui_theme.gd
class_name UiTheme

## One theme for the whole game, built in code.
##
## In code rather than as a .tres so the palette lives in one readable place and
## so a theme change is a readable diff. Variants (PrimaryButton, ItemCard, H1…)
## are theme *type variations*, not per-node overrides: a per-node override is
## invisible in the theme and has to be re-found in every scene that copied it.

const DISPLAY   := preload("res://ui/fonts/Cinzel-SemiBold.ttf")
const BODY      := preload("res://ui/fonts/AlegreyaSans-Regular.ttf")
const BODY_BOLD := preload("res://ui/fonts/AlegreyaSans-Bold.ttf")

const PATCH := 28      ## nine-patch margin of the 128 px chrome textures


static func build() -> Theme:
	var t := Theme.new()
	t.default_font = BODY
	t.default_font_size = 30

	# --- Panels -----------------------------------------------------------
	t.set_stylebox("panel", "PanelContainer", box("panel", 20, 14))
	t.set_stylebox("panel", "Panel", box("panel", 20, 14))

	# --- Buttons ----------------------------------------------------------
	# Pressed is a different texture, not a tint: the press must read as the
	# surface moving, not the colour changing.
	t.set_stylebox("normal",   "Button", box("btn"))
	t.set_stylebox("hover",    "Button", box("btn_hover"))
	t.set_stylebox("pressed",  "Button", box("btn_down"))
	t.set_stylebox("focus",    "Button", box("btn_hover"))
	t.set_stylebox("disabled", "Button", box("btn_off"))
	t.set_font("font", "Button", DISPLAY)
	t.set_font_size("font_size", "Button", 30)
	t.set_color("font_color",          "Button", Palette.INK)
	t.set_color("font_hover_color",    "Button", Color.WHITE)
	t.set_color("font_pressed_color",  "Button", Palette.GOLD)
	t.set_color("font_disabled_color", "Button", Palette.INK_FAINT)
	t.set_constant("h_separation", "Button", 12)

	_variation(t, &"PrimaryButton", &"Button")
	t.set_stylebox("normal",  "PrimaryButton", box("btn_gold"))
	t.set_stylebox("hover",   "PrimaryButton", box("btn_gold"))
	t.set_stylebox("pressed", "PrimaryButton", box("btn_gold_down"))
	t.set_color("font_color", "PrimaryButton", Color("221703"))

	_variation(t, &"TabButton", &"Button")
	t.set_stylebox("normal",  "TabButton", StyleBoxEmpty.new())
	t.set_stylebox("hover",   "TabButton", StyleBoxEmpty.new())
	t.set_stylebox("pressed", "TabButton", box("tab_active", 16, 6))
	t.set_font_size("font_size", "TabButton", 22)

	_variation(t, &"ItemCard", &"Button")
	t.set_stylebox("normal",  "ItemCard", box("card"))
	t.set_stylebox("hover",   "ItemCard", box("card_hover"))
	t.set_stylebox("pressed", "ItemCard", box("card_hover"))

	# --- Labels -----------------------------------------------------------
	t.set_color("font_color", "Label", Palette.INK)
	for spec in [
		[&"H1", DISPLAY, 48, Palette.INK],
		[&"H2", DISPLAY, 36, Palette.INK],
		[&"Body", BODY, 30, Palette.INK],
		[&"Caption", BODY, 24, Palette.INK_DIM],
	]:
		_variation(t, spec[0], &"Label")
		t.set_font("font", spec[0], spec[1])
		t.set_font_size("font_size", spec[0], spec[2])
		t.set_color("font_color", spec[0], spec[3])

	_variation(t, &"Number", &"Label")
	t.set_font("font", "Number", numerals())
	t.set_font_size("font_size", "Number", 34)
	t.set_color("font_color", "Number", Palette.INK)

	# --- Scrolling --------------------------------------------------------
	t.set_stylebox("panel",  "ScrollContainer", StyleBoxEmpty.new())
	t.set_stylebox("scroll", "VScrollBar", StyleBoxEmpty.new())
	t.set_stylebox("grabber", "VScrollBar", _flat(Color(1, 1, 1, 0.16), 4))
	t.set_stylebox("grabber_highlight", "VScrollBar", _flat(Color(1, 1, 1, 0.28), 4))

	# --- Bars -------------------------------------------------------------
	t.set_stylebox("background", "ProgressBar", box("bar_bg", 12, 0))
	t.set_stylebox("fill",       "ProgressBar", box("bar_fill", 12, 0))

	return t


static func numerals() -> FontVariation:
	var fv := FontVariation.new()
	fv.base_font = BODY_BOLD
	# tnum: without tabular figures every counter in the game jitters sideways
	# as it rolls, which is the one thing an idle game must not do.
	fv.opentype_features = {"tnum": 1, "lnum": 1}
	return fv


static func _variation(t: Theme, name: StringName, base: StringName) -> void:
	t.add_type(name)
	t.set_type_variation(name, base)


static func box(tex: String, pad_x := 24, pad_y := 14) -> StyleBoxTexture:
	var sb := StyleBoxTexture.new()
	var path := "res://assets/ui/%s.png" % tex
	sb.texture = load(path) if ResourceLoader.exists(path) \
		else load("res://assets/ui/panel.png")
	for side in ["left", "right", "top", "bottom"]:
		sb.set("texture_margin_" + side, PATCH)
	sb.content_margin_left = pad_x
	sb.content_margin_right = pad_x
	sb.content_margin_top = pad_y
	sb.content_margin_bottom = pad_y
	return sb


static func _flat(c: Color, radius: int) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = c
	sb.set_corner_radius_all(radius)
	return sb
```

---

## 10. Reusable components

Build these once, in this order. Everything else in the game is an arrangement of them.

| Component | Base node | Notes |
|---|---|---|
| `TierFrame` | `Control` | `NinePatchRect` + optional shimmer `ColorRect` (mystic only) + pip row |
| `ItemCard` | `Button` (`ItemCard` variation) | grid cell; `bind(item)` |
| `ItemSlot` | `Button` | one of a soldier's 3 slots; empty state shows a ghost weapon/armor/horse glyph |
| `SoldierCard` | `PanelContainer` | portrait + tier + 3 `ItemSlot`s + combined power |
| `CollectJobRow` | `Button` | icon, name, cost, payout, milestone progress; owns its own floater + punch |
| `UpgradeRow` | `PanelContainer` | name, current→next effect, cost, buy button with affordability state |
| `CurrencyBar` | `PanelContainer` | 3 × (`TextureRect` + `NumberLabel`) + XP bar + level pip |
| `NumberLabel` | `Label` (`Number`) | exponential-approach tween; the only `_process` in the UI |
| `AnimatedBar` | `ProgressBar` | tweened `value`, plus a slower "ghost" fill behind for damage/spend |
| `Floater` | `Label` | pooled "+250"; spawned into `Overlay/Floaters` |
| `Toast` | `PanelContainer` | queued, max 3 stacked, 2.4 s |
| `ConfirmDialog` | `Control` | our own modal; native `AcceptDialog` is desktop-shaped |
| `RecycleGrid` | `ScrollContainer` | virtualised inventory grid |
| `SkeletonRow` | `Control` | shimmer placeholder while `GameState.stale` |
| `Reveal` | `Control` | the recruit / shop-purchase reveal beat (lane B's payoff) |

### 10.1 `ItemCard`

Root is a `Button` with `theme_type_variation = &"ItemCard"` so press/hover/focus/disabled come free; the decoration children all set `mouse_filter = MOUSE_FILTER_IGNORE`.

```gdscript
# res://ui/components/item_card.gd
class_name ItemCard
extends Button

## One item in a grid or slot.
##
## A Button root rather than a PanelContainer + hidden hitbox: press, hover,
## focus and disabled are theme states, and hand-rolling them is how a UI ends
## up with four slightly different press animations.
##
## bind() is idempotent and allocation-free — RecycleGrid calls it every time a
## cell scrolls into view, so it must never load or instantiate anything.

signal long_pressed(item: Dictionary)

const LONG_PRESS := 0.45

@onready var _frame: NinePatchRect = %Frame
@onready var _shimmer: ColorRect   = %Shimmer
@onready var _icon: TextureRect    = %Icon
@onready var _name: Label          = %Name
@onready var _pips: HBoxContainer  = %Pips
@onready var _atk: Label           = %Atk
@onready var _def: Label           = %Def
@onready var _equipped: TextureRect = %EquippedPip

var item: Dictionary = {}

var _held := 0.0


func _ready() -> void:
	custom_minimum_size = Vector2(200, 260)
	# Item names come from the server as ids we resolve ourselves, but this also
	# guards the day someone renders a player-authored name in a card.
	_name.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	set_process(false)


func bind(data: Dictionary) -> void:
	item = data
	var tier := int(data.get("tier", 0))

	_frame.texture = Palette.tier_frame(tier)
	_shimmer.visible = tier == Palette.Tier.MYSTIC
	_icon.texture = ItemArt.icon(str(data.get("art_id", "")))

	_name.text = tr(str(data.get("name_key", "")))
	_name.add_theme_color_override("font_color", Palette.tier_color(tier))

	_atk.text = Fmt.number(int(data.get("attack", 0)))
	_def.text = Fmt.number(int(data.get("defense", 0)))
	_equipped.visible = bool(data.get("equipped", false))

	for i in _pips.get_child_count():
		var pip := _pips.get_child(i) as TextureRect
		pip.visible = i <= tier
		pip.modulate = Palette.tier_color(tier)

	tooltip_text = ""


func _gui_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch or event is InputEventMouseButton:
		set_process(event.is_pressed())
		_held = 0.0


func _process(delta: float) -> void:
	_held += delta
	if _held >= LONG_PRESS:
		set_process(false)
		Haptics.impact(Haptics.Strength.MEDIUM)
		long_pressed.emit(item)
```

### 10.2 `RecycleGrid` — does Godot need view recycling?

**Yes, above roughly 120 cells — and no, below it.** A 500-item inventory built naively is 500 `ItemCard`s × ~9 `Control`s = ~4,500 nodes. On an iPhone that is tens of milliseconds in the first `sort_children` pass alone, plus a permanent per-frame container cost and ~500 draw batches. Under ~120 cells, none of that is measurable and the complexity is not worth it. So: `CollectTab` (≈20 rows), `SoldiersTab` (≤ ~40), `ShopTab` (6–12) use plain `VBoxContainer`/`GridContainer`. `InventoryTab` and the attack-opponent list use `RecycleGrid`.

The trick that makes it simple: **the cells are not in a container.** A container would fight the manual positioning. The `ScrollContainer`'s single child is an empty `Control` sized to the full content height (so the scrollbar is honest), and the pooled cells are absolutely positioned inside it.

```gdscript
# res://ui/components/recycle_grid.gd
class_name RecycleGrid
extends ScrollContainer

## Virtualised grid. Godot ships no view recycling.
##
## 500 items as 500 ItemCards is ~4,500 Controls: the first layout pass alone is
## tens of milliseconds on a phone and every sort_children afterwards walks all
## of them. Below ~120 cells this is not worth the complexity — build them all.
## Above it, this.
##
## The cells are deliberately NOT children of a container: a container would
## fight the manual positioning. The single child is an empty Control sized to
## the true content height so the scrollbar tells the truth, and a pool of
## visible cells is positioned inside it by hand.
##
## Rebinding happens only when the first visible row changes, so scrolling
## *within* a row costs nothing.

signal cell_activated(index: int, data: Variant)

@export var columns := 3
@export var row_height := 260.0
@export var gap := Vector2(16, 16)
@export var cell_scene: PackedScene

var _data: Array = []
var _canvas: Control
var _cells: Array[Control] = []
var _first_row := -1
var _cell_width := 200.0


func _ready() -> void:
	horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	follow_focus = true                       ## keyboard/gamepad on desktop
	_canvas = Control.new()
	_canvas.name = "Canvas"
	_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(_canvas)
	get_v_scroll_bar().value_changed.connect(func(_v: float) -> void: _sync())
	resized.connect(_relayout)


func set_data(rows: Array) -> void:
	_data = rows
	_first_row = -1
	_relayout()


func _relayout() -> void:
	if size.x <= 0.0:
		return
	_cell_width = (size.x - gap.x * (columns - 1)) / float(columns)
	var rows := ceili(float(_data.size()) / float(columns))
	_canvas.custom_minimum_size.y = maxf(0.0, rows * (row_height + gap.y) - gap.y)

	# Two rows of slack: one entering, one leaving.
	var need := columns * (ceili(size.y / (row_height + gap.y)) + 2)
	while _cells.size() < need:
		var c := cell_scene.instantiate() as Control
		c.set_meta("index", -1)
		if c.has_signal("pressed"):
			c.connect("pressed", func() -> void:
				var i := int(c.get_meta("index", -1))
				if i >= 0 and i < _data.size():
					cell_activated.emit(i, _data[i]))
		_canvas.add_child(c)
		_cells.append(c)
	while _cells.size() > need:
		_cells.pop_back().queue_free()

	_first_row = -1
	_sync()


func _sync() -> void:
	var pitch := row_height + gap.y
	var first := maxi(0, int(scroll_vertical / pitch) - 1)
	if first == _first_row:
		return
	_first_row = first

	for i in _cells.size():
		var index := first * columns + i
		var cell := _cells[i]
		if index >= _data.size():
			cell.visible = false
			cell.set_meta("index", -1)
			continue
		cell.visible = true
		cell.set_meta("index", index)
		cell.size = Vector2(_cell_width, row_height)
		cell.position = Vector2(
			(index % columns) * (_cell_width + gap.x),
			float(index / columns) * pitch)
		cell.call("bind", _data[index])
```

Two constraints this imposes, both worth accepting: **uniform row height** (variable heights make the offset math O(n) and the scrollbar dishonest — if a design needs mixed heights, use a section per height class), and **`bind()` must be allocation-free** (no `load()`, no `instantiate()`; hence the `ItemArt` atlas in §12).

### 10.3 `NumberLabel` and floaters

```gdscript
# res://ui/components/number_label.gd
class_name NumberLabel
extends Label

## A number that never jumps.
##
## The only node in the UI allowed to run _process, and it stops itself the
## moment it arrives. Idle games live and die on the counter: gold that snaps
## from 1,200 to 1,450 reads as a repaint; gold that rolls reads as earning it.
## It is also what lets the store push at 10 Hz and still look like 120.

@export var seconds := 0.35
@export var prefix := ""

var _target := 0
var _shown := 0.0


func set_value(v: int, animate := true) -> void:
	_target = v
	if not animate or absi(v - int(_shown)) > 1_000_000_000:
		_shown = float(v)
		_paint()
		set_process(false)
		return
	set_process(true)


func _process(delta: float) -> void:
	var diff := float(_target) - _shown
	if absf(diff) < 0.5:
		_shown = float(_target)
		_paint()
		set_process(false)
		return
	# Exponential approach: frame-rate independent, and it decelerates, which is
	# what makes a counter read as "settling" rather than "sliding".
	_shown += diff * (1.0 - exp(-delta / maxf(seconds, 0.01) * 4.0))
	_paint()


func _paint() -> void:
	text = prefix + Fmt.number(int(round(_shown)))
```

```gdscript
# res://ui/theme/fmt.gd
class_name Fmt

## Every number the player sees goes through here.
##
## The abbreviation threshold is where a grouped number stops fitting the
## currency bar, not where it stops being readable — 1,234 is clearer than 1.2K
## and fits; 1,234,567 does not.

const UNITS := ["", "K", "M", "B", "T", "Qa", "Qi", "Sx"]


static func number(n: int) -> String:
	if absi(n) < 10_000:
		return grouped(n)
	var f := float(n)
	var tier := 0
	while absf(f) >= 1000.0 and tier < UNITS.size() - 1:
		f /= 1000.0
		tier += 1
	var s := ("%.1f" % f) if absf(f) < 100.0 else ("%.0f" % f)
	return s.trim_suffix(".0") + tr("UNIT_" + str(tier))


static func grouped(n: int) -> String:
	var sign_s := "-" if n < 0 else ""
	var digits := str(absi(n))
	var out := ""
	var c := 0
	for i in range(digits.length() - 1, -1, -1):
		out = digits[i] + out
		c += 1
		if c % 3 == 0 and i > 0:
			out = tr("SEP_THOUSANDS") + out
	return sign_s + out


static func duration(seconds_left: int) -> String:
	if seconds_left >= 3600:
		return "%dh %02dm" % [seconds_left / 3600, (seconds_left % 3600) / 60]
	if seconds_left >= 60:
		return "%dm %02ds" % [seconds_left / 60, seconds_left % 60]
	return "%ds" % maxi(0, seconds_left)
```

`SEP_THOUSANDS` and `UNIT_0..7` go through `tr()` because both are locale-specific — a German build wants `1.234` and a French one `1 234`.

**Floaters** are pooled (16) in `Overlay/Floaters`: an idle game spawns several a second, and `queue_free()`-ing a `Label` per tap is the one place this UI could actually generate GC pressure.

---

## 11. An example tab, end to end

```gdscript
# res://ui/tabs/collect_tab.gd
class_name CollectTab
extends TabPage

## The Collect ladder.
##
## ~20 rows, so no recycling: below ~120 cells the virtualisation costs more
## than it saves. Rows are created once and rebound, because the list's *shape*
## only changes on level-up while its *numbers* change on every tap.

@onready var _rows_box: VBoxContainer = %Rows

var _rows: Dictionary = {}   ## job_id -> CollectJobRow

const ROW := preload("res://ui/components/CollectJobRow.tscn")


func _ready() -> void:
	GameState.jobs.changed.connect(mark_dirty)
	# Level gates unlocks, so the row list changes shape on level-up.
	GameState.player.changed.connect(mark_dirty)
	Actions.rejected.connect(_on_rejected)


func tab_shown() -> void:
	super()
	# The scene is cached; the data is not. Jobs are cheap and always in the
	# snapshot, so this is only here to catch a tab opened while stale.
	if GameState.stale:
		Session.resync()


func refresh() -> void:
	var seen := {}
	var index := 0
	for job_id in GameState.jobs.order:
		var job := GameState.jobs.get_job(job_id)
		if job == null:
			continue
		var row: CollectJobRow = _rows.get(job_id)
		if row == null:
			row = ROW.instantiate()
			row.collect_requested.connect(_on_collect)
			_rows[job_id] = row
			_rows_box.add_child(row)
		_rows_box.move_child(row, index)
		row.bind(job, GameState.player.level)
		seen[job_id] = true
		index += 1

	for id in _rows.keys():
		if not seen.has(id):
			(_rows[id] as Node).queue_free()
			_rows.erase(id)


func _on_collect(job_id: String) -> void:
	var job := GameState.jobs.get_job(job_id)
	if job == null:
		return

	# Actions owns the decision. The tab only reacts, so the affordability rule
	# lives in exactly one place and the UI cannot drift from it.
	if not Actions.collect(job_id):
		var row: CollectJobRow = _rows.get(job_id)
		if row:
			row.refuse()                      ## shake + dim the energy pip
		Haptics.impact(Haptics.Strength.HEAVY)
		Audio.sfx("denied")
		Ui.toast(tr("ERR_INSUFFICIENT_ENERGY"), Ui.ToastKind.WARN)
		return

	# Local, immediate, zero frames of latency. This is the whole point.
	var row2: CollectJobRow = _rows.get(job_id)
	if row2:
		row2.punch()
		Ui.floater("+%s" % Fmt.number(job.gold_payout),
			row2.reward_anchor(), Palette.GOLD)
	Haptics.impact(Haptics.Strength.LIGHT)
	Audio.sfx("collect")


## A rejection is nearly always an energy race with the player's other device.
## Say so; a silent rollback of a number the player watched go up is the single
## most confusing thing this UI can do.
func _on_rejected(_seq: int, code: String) -> void:
	if not is_visible_in_tree():
		return
	Ui.toast(tr("ERR_" + code.to_upper()), Ui.ToastKind.WARN)
```

```gdscript
# res://ui/components/collect_job_row.gd
class_name CollectJobRow
extends Button

## One rung of the Collect ladder.
##
## The row draws its own feedback rather than waiting for the store: the tap has
## to land on the same frame as the touch, and the currency bar is 900 units
## away at the top of the screen. Local punch + local floater, global counter.

signal collect_requested(job_id: String)

@onready var _icon: TextureRect     = %Icon
@onready var _name: Label           = %Name
@onready var _cost: Label           = %Cost
@onready var _payout: Label         = %Payout
@onready var _milestone: ProgressBar = %Milestone
@onready var _milestone_text: Label  = %MilestoneText
@onready var _lock: Control          = %Lock
@onready var _anchor: Control        = %RewardAnchor

var job_id := ""


func _ready() -> void:
	custom_minimum_size.y = 132
	pressed.connect(func() -> void: collect_requested.emit(job_id))
	Session.projected.connect(_on_projected)


func bind(job: JobsStore.Job, level: int) -> void:
	job_id = job.id
	_icon.texture = ItemArt.icon(job.art_id)
	_name.text = tr(job.name_key)
	_cost.text = str(job.energy_cost)
	_payout.text = Fmt.number(job.gold_payout)

	var locked := level < job.unlock_level
	_lock.visible = locked
	disabled = locked
	modulate.a = 0.45 if locked else 1.0
	if locked:
		_milestone.visible = false
		_milestone_text.text = tr("JOB_UNLOCKS_AT").format({"level": job.unlock_level})
		return

	_milestone.visible = job.next_milestone > 0
	if job.next_milestone > 0:
		_milestone.max_value = float(job.next_milestone)
		_milestone.value = float(job.count)
		_milestone_text.text = "%d / %d  (+%d%%)" % [
			job.count, job.next_milestone, int(job.next_milestone_bonus * 100.0)]
	else:
		_milestone_text.text = tr("JOB_MASTERED")

	_refresh_affordability(GameState.display_energy())


func _on_projected(_gold: int, energy: int) -> void:
	if is_visible_in_tree() and not _lock.visible:
		_refresh_affordability(energy)


func _refresh_affordability(energy: int) -> void:
	var job := GameState.jobs.get_job(job_id)
	if job == null:
		return
	var afford := energy >= job.energy_cost
	_cost.add_theme_color_override("font_color",
		Palette.ENERGY if afford else Palette.DANGER)


func reward_anchor() -> Vector2:
	return _anchor.global_position


## 90 ms punch. Short enough to survive five taps a second without queueing up.
func punch() -> void:
	var tw := create_tween()
	tw.tween_property(self, "scale", Vector2(0.965, 0.965), 0.045)
	tw.tween_property(self, "scale", Vector2.ONE, 0.045)


func refuse() -> void:
	var tw := create_tween()
	# offset_transform_position (new in 4.7) moves the row without the parent
	# VBoxContainer fighting it back into place, which is what happens if you
	# animate `position` inside a container.
	offset_transform_enabled = true
	tw.tween_property(self, "offset_transform_position", Vector2(10, 0), 0.04)
	tw.tween_property(self, "offset_transform_position", Vector2(-10, 0), 0.06)
	tw.tween_property(self, "offset_transform_position", Vector2.ZERO, 0.04)
```

Godot 4.7's `offset_transform_*` on `Control` is genuinely the right tool here: it translates/rotates/scales a control **without affecting container layout**, which is exactly the CSS-transform behaviour that shake and punch animations need inside a `VBoxContainer`. Before 4.7 this needed a wrapper node.

---

## 12. Assets and the import pipeline

### 12.1 Generation → shipped texture

```
1. asset_gen.py image --model gemini --size 2K --aspect-ratio 1:1 \
     --prompt "6x6 grid of medieval RPG item icons on a solid #FF00FF background, …" \
     -o art/sheets/items_01.png                       # 10c per 2K sheet
2. grid_slice.py art/sheets/items_01.png -o art/sliced/items_01/ \
     --grid 6x6 --names "sword_iron,sword_steel,…"
3. rembg_matting.py --batch art/sliced/items_01/ -o art/clean/items_01/
4. tools/pack_atlas.py art/clean/ -o client/assets/atlas/items   # png + json
```

Three facts about the toolchain that will otherwise cost a day each: `--model gemini` must be passed on **every** call (the default is grok and there is no xAI key); **never** prompt for a transparent background (the model draws a checkerboard — prompt a solid key colour and matte it); and `rembg_matting.py --preview` in single-image mode raises `NameError` at `asset-gen/tools/rembg_matting.py:312`, so use `--batch`. Its `requirements.txt` pins `onnxruntime-gpu` + `nvidia-cudnn-cu12`, which have **no Apple Silicon wheels** — install plain `onnxruntime` in the venv instead.

Economics: 1K is 7c, 2K is 10c. A single 2K sheet holding 36 icons is 0.28c per icon; 36 separate 1K calls would be 252c. **Always generate sheets, never single icons.** Style-lock every subsequent sheet with `--image` pointed at the first approved sheet.

### 12.2 Atlasing

`pack_atlas.py` emits `items.png` (2048², bin-packed) + `items.json` (`{"sword_iron": [x, y, w, h], …}`). At runtime one autoload-free static class builds `AtlasTexture`s:

```gdscript
# res://ui/item_art.gd
class_name ItemArt

## One texture, N regions. 400 separate PNGs would be 400 load() calls, 400
## texture binds and 400 .import files; this is one of each. It also lets
## ItemCard.bind() be allocation-free, which RecycleGrid depends on.

static var _sheet: Texture2D
static var _regions: Dictionary = {}
static var _cache: Dictionary = {}


static func _ensure() -> void:
	if _sheet != null:
		return
	_sheet = load("res://assets/atlas/items.png")
	var f := FileAccess.open("res://assets/atlas/items.json", FileAccess.READ)
	if f:
		var parsed = JSON.parse_string(f.get_as_text())
		if typeof(parsed) == TYPE_DICTIONARY:
			_regions = parsed


static func icon(art_id: String) -> Texture2D:
	_ensure()
	if _cache.has(art_id):
		return _cache[art_id]
	if not _regions.has(art_id):
		return _sheet
	var r: Array = _regions[art_id]
	var at := AtlasTexture.new()
	at.atlas = _sheet
	at.region = Rect2(r[0], r[1], r[2], r[3])
	at.filter_clip = true
	_cache[art_id] = at
	return at
```

### 12.3 Import presets

`[importer_defaults]` in `project.godot` (§2) is the baseline for **every** texture: `compress/mode=0` (Lossless), no mipmaps, `detect_3d/compress_to=0`.

Then override, by hand in the Import dock and committed via the `.import` file, for the **two or three big atlases only**:

| Asset class | mode | high_quality | mipmaps | Why |
|---|---|---|---|---|
| UI chrome (nine-patches, ~20 files, ≤128²) | 0 Lossless | — | off | tiny; 9-slice edges must stay razor sharp |
| Fonts | n/a | — | off | oversampling handles scale; mipmaps blur small text |
| **Item / soldier / job atlases (2048²)** | **2 VRAM Compressed** | **true** | off | 16 MB RGBA8 → 4 MB ASTC 4×4 on iOS. On a phone that is the difference that matters. |
| Backdrops (1024×2048) | 2 VRAM Compressed | true | off | large, low-frequency; artifacts invisible |
| Icons used at exactly one size | 0 Lossless | — | off | |

`rendering/textures/vram_compression/import_etc2_astc=true` is what makes VRAM mode resolve to **ASTC 4×4 on iOS** (high quality) and ETC2 on older Android; Godot picks the best variant the device reports at runtime. Mipmaps stay **off** everywhere: nothing in this UI is minified below 1:1, and mipmaps cost 33% more VRAM plus visible softening.

### 12.4 Keeping `.import` churn out of git

- **Commit** `*.import` and `*.uid`. They carry the `uid://` that `.tscn` files reference; losing them breaks every scene. **Gitignore** `client/.godot/` (the actual binary churn).
- `.gitattributes`: `*.import text eol=lf`, `*.tscn text eol=lf`, `*.tres text eol=lf`, `*.png binary`.
- `[importer_defaults]` makes imports byte-identical across machines and CI — without it, two devs' Import-dock settings produce different `.import` files for the same PNG and every asset commit fights.
- **Never regenerate an asset under a new filename.** Overwrite in place. A delete+add regenerates the `uid`, which rewrites every `.tscn` that referenced it.
- CI gate: run `godot --headless --path client --import`, then `git diff --exit-code -- client/`. If an import changed, the build fails and the dev must commit it — which is what keeps the tree honest.

---

## 13. Persistence on device

```
user://
  install.key          32 random bytes, plaintext
  session.dat          ENCRYPTED: refresh_token, access_token, exp, player_id
  settings.cfg         ConfigFile: audio, haptics, reduced_motion, last_tab
  cache/catalog.json   + catalog.etag
  cache/snapshot.json  last snapshot — display only
  logs/client.log      ring buffer, attached to a bug report
```

```gdscript
# res://autoload/session.gd (extract)

const KEY_PATH := "user://install.key"
const SESSION_PATH := "user://session.dat"


## A random per-install pass for the token file. This is obfuscation, not
## security, and it should be called that: anyone with the device can read the
## app container and this file. The real defences are elsewhere — access tokens
## live minutes, refresh tokens rotate on use, and the server can revoke both.
## OS.get_unique_id() is deliberately NOT the key: on iOS it is
## identifierForVendor, which rotates on reinstall, so it would silently lock
## the player out of their own cached token.
func _install_key() -> String:
	if FileAccess.file_exists(KEY_PATH):
		var f := FileAccess.open(KEY_PATH, FileAccess.READ)
		if f:
			var k := f.get_as_text().strip_edges()
			if k.length() == 64:
				return k
	var key := Crypto.new().generate_random_bytes(32).hex_encode()
	var out := FileAccess.open(KEY_PATH, FileAccess.WRITE)
	if out:
		out.store_string(key)
	return key


func persist_tokens(access: String, refresh: String) -> void:
	var f := FileAccess.open_encrypted_with_pass(
		SESSION_PATH, FileAccess.WRITE, _install_key())
	if f == null:
		Log.warn("could not write session")
		return
	f.store_string(JSON.stringify({
		"access": access, "refresh": refresh,
		"exp": Api._access_exp, "player_id": GameState.player.id,
	}))


func _load_tokens() -> Dictionary:
	if not FileAccess.file_exists(SESSION_PATH):
		return {}
	var f := FileAccess.open_encrypted_with_pass(
		SESSION_PATH, FileAccess.READ, _install_key())
	if f == null:
		# Reinstall, corruption, or a key we can no longer derive. Not an error
		# worth surfacing — the only cost is one login round trip.
		return {}
	var parsed = JSON.parse_string(f.get_as_text())
	return parsed if typeof(parsed) == TYPE_DICTIONARY else {}
```

**Nothing on disk is trusted as gameplay truth.** `cache/snapshot.json` exists purely so the first frame after launch shows *something* — it is applied with `GameState.stale = true`, which dims the numbers and shows a thin progress line, and the first live snapshot overwrites it. That is worth roughly 800 ms of perceived cold start.

On iOS set `user_data/accessible_from_files_app=false` and `accessible_from_itunes_sharing=false`: the local data is disposable, and exposing it invites tampering reports.

---

## 14. Audio

Deliberately small. Bus layout `res://assets/audio/bus_layout.tres`:

```
Master
├── Music   (one AudioStreamPlayer, looping)
├── SFX     (8 pooled voices, round-robin with oldest-steal)
└── UI      (3 voices: tap, denied, toast — never throttled)
```

Three rules:

1. **`UI` is its own bus and is never throttled.** A tap sound that gets swallowed by a burst of SFX makes the button feel broken — which is the exact failure this whole design is fighting.
2. **Throttle per sound name.** `collect` fires five times a second; without a ~45 ms floor between two instances it phases into one flat tone and clips. Add ±10% pitch jitter for the same reason.
3. **Ducking is one tween, not a compressor.** On a "big" event (attack won, mystic drop) tween `Music`'s bus volume −5 dB over 120 ms, hold 500 ms, restore over 400 ms. `AudioServer.set_bus_volume_db(AudioServer.get_bus_index("Music"), db)`.

iOS session: `audio/general/ios/session_category=0` (**Ambient**) + `mix_with_others=true`. Ambient respects the physical silent switch and lets the player keep Spotify running — for an idle game people play *while* listening to something else, "Playback" (which stops their music and ignores the mute switch) is actively hostile.

Volume sliders are linear 0–1 in the UI and converted with `linear_to_db()` at the bus, so no caller has to remember audio is logarithmic. Music is a single Lyria-3 loop; a second track can crossfade later via two players.

---

## 15. iOS export

### 15.1 `export_presets.cfg` (verified 4.7.2 field names)

Two presets, so a dev build and a store build can coexist on the same phone.

```ini
[preset.0]

name="iOS Dev"
platform="iOS"
runnable=true
advanced_options=true
dedicated_server=false
custom_features=""
export_filter="all_resources"
include_filter=""
exclude_filter="tests/*, tools/*, art/*"
export_path="../build/ios/dev/Emperors.ipa"
patches=PackedStringArray()
encryption_include_filters=""
encryption_exclude_filters=""
seed=0
encrypt_pck=false
encrypt_directory=false
script_export_mode=2

[preset.0.options]

application/app_store_team_id="JS3GR55886"
application/bundle_identifier="com.karabulut.emperors.dev"
application/signature=""
application/short_version="0.1.0"
application/version="1"
application/min_ios_version="15.0"
application/targeted_device_family=0
application/code_sign_identity_debug="Apple Development"
application/export_method_debug=1
application/code_sign_identity_release="Apple Development"
application/export_method_release=1
application/icon_interpolation=4
application/launch_screens_interpolation=4
application/export_project_only=false
application/delete_old_export_files_unconditionally=true
application/generate_simulator_library_if_missing=true
architectures/arm64=true
capabilities/access_wifi=false
capabilities/push_notifications=false
capabilities/performance_gaming_tier=false
capabilities/performance_a12=false
user_data/accessible_from_files_app=false
user_data/accessible_from_itunes_sharing=false
privacy/camera_usage_description=""
privacy/microphone_usage_description=""
privacy/photolibrary_usage_description=""
storyboard/use_launch_screen_storyboard=true
storyboard/image_scale_mode=0
storyboard/use_custom_bg_color=true
storyboard/custom_bg_color=Color(0.055, 0.043, 0.035, 1)
icons/iphone_120x120="res://ui/branding/icon_120.png"
icons/iphone_180x180="res://ui/branding/icon_180.png"
icons/app_store_1024x1024="res://ui/branding/icon_1024.png"
icons/spotlight_40x40="res://ui/branding/icon_40.png"
icons/spotlight_80x80="res://ui/branding/icon_80.png"
icons/settings_58x58="res://ui/branding/icon_58.png"
icons/settings_87x87="res://ui/branding/icon_87.png"
icons/notification_40x40="res://ui/branding/icon_40.png"
icons/notification_60x60="res://ui/branding/icon_60.png"

[preset.1]

name="iOS Store"
platform="iOS"
runnable=false
export_path="../build/ios/store/Emperors.ipa"
exclude_filter="tests/*, tools/*, art/*"
script_export_mode=2
; …same options, with:
;   application/bundle_identifier="com.karabulut.emperors"
;   application/code_sign_identity_release="Apple Distribution"
;   application/export_method_release=0        ; App Store
```

Notes on specific fields:

- `app_store_team_id="JS3GR55886"` — confirmed from `security find-identity` on this machine (`Apple Development: YIGIT KARABULUT (JS3GR55886)`). The existing StarDrift preset has a *different* team (`5C2NRK938T`); do not copy it.
- `targeted_device_family=0` — enum hint is `iPhone,iPad,iPhone & iPad`, so `0` = iPhone only. Correct for v1: shipping an iPad build means designing a 4:3 layout, which is a separate project.
- `min_ios_version="15.0"` — Godot 4.4+'s Metal driver wants A8+; 15.0 covers everything worth supporting in 2026 and keeps the deployment target off the deprecated end.
- `storyboard/custom_bg_color` **must equal** `application/boot_splash/bg_color` and `rendering/environment/defaults/default_clear_color`. Three different places, one colour. Any mismatch is a visible flash on every launch.
- `script_export_mode=2` (binary tokens) — smaller and not trivially readable. It is not security; the server is.
- `encrypt_pck=false` — PCK encryption on a thin client protects nothing (there are no secrets in it) and complicates debugging.

### 15.2 Signing in Xcode

The `.ipa` path builds and signs headlessly. When you need the Xcode project (IAP, push, native plugins, TestFlight, Instruments):

1. Set `application/export_project_only=true`, `export_path="../build/ios/Emperors.xcodeproj"`, export.
2. `open build/ios/Emperors.xcodeproj`
3. Target **Emperors** → **Signing & Capabilities** → tick *Automatically manage signing* → **Team: YIGIT KARABULUT (JS3GR55886)**. Xcode provisions `com.karabulut.emperors.dev` on the spot.
4. If the identifier is already taken, change `application/bundle_identifier` in Godot (not in Xcode — the next export overwrites Xcode).
5. Select the connected iPhone as the destination → ⌘R.
6. On the phone, first run only: **Settings → General → VPN & Device Management → trust the developer**, and **Settings → Privacy & Security → Developer Mode → On** (required since iOS 16; the phone reboots).

**Never edit the generated Xcode project by hand.** Godot regenerates it. Anything persistent goes in the export preset, in `capabilities/additional`, or in a Godot iOS plugin.

### 15.3 The fastest edit-test loop

**Tier 1 — the editor (95% of the work).** `godot --path client`, F5. The window is 450×800 (from `window_*_override`) stretching the 720×1280 canvas. Sub-second iteration. With `pointing/emulate_touch_from_mouse=true`, drag-scroll and press behaviour match the phone. Add a `Cfg.fake_safe_area` toggle so notch layout is verifiable here. Point at a local Go server with `godot --path client -- --api=http://localhost:8080`.

**Tier 2 — one-click deploy (daily sanity, ~40 s).** Godot 4.7's iOS exporter drives **`xcrun devicectl`** (confirmed in the binary: `devicectl install:`, `devicectl launch:`, `--terminate-existing`) and can also use `ios-deploy` (Editor Settings → **Export → iOS → Ios Deploy**). Prerequisites: `runnable=true` on the preset, phone connected by USB and trusted, Developer Mode on, `editor/deploy_with_remote_debug` enabled. Press the iPhone icon in the editor toolbar: Godot exports → signs with "Apple Development" → installs → launches, and `print()`/errors stream back into the editor Output panel over the network. This is the loop; use it.

**Tier 3 — Xcode (weekly / when native).** Re-export from Godot, ⌘R in Xcode. Only the `.pck` changed, so the engine binary is not recompiled: ~20 s. Needed for Instruments, IAP sandbox testing, push, and TestFlight.

**What to actually check on device, since Tier 1 covers the rest:** safe-area truth, touch target sizes with a real thumb, scroll fling feel, ProMotion smoothness, thermal/battery over a 20-minute session, and how the app looks coming back from background after 8 hours (the offline-tax path).

---

## 16. Android later — the concrete delta

Nothing in this architecture is iOS-specific; the work is toolchain, not code.

1. `brew install --cask temurin@17` (Godot 4.7 requires JDK 17), then Android command-line tools + `sdkmanager "platform-tools" "platforms;android-35" "build-tools;35.0.0" "cmdline-tools;latest"`.
2. Editor Settings → Export → Android: Java SDK Path, Android SDK Path. Generate the debug keystore.
3. Editor → **Manage Export Templates** → download 4.7.2 templates (only `ios.zip` is present today). Or use **GABE** (Godot Android Build Environment) — standalone Android exporting became stable in 4.7 and removes the SDK setup entirely.
4. Add an Android preset: package `com.karabulut.emperors`, `gradle_build/use_gradle_build=true` (needed for Play Billing), min SDK 24, target 35.
5. Code deltas — three, all small:
   - handle `NOTIFICATION_WM_GO_BACK_REQUEST` in `Main` (close modal → previous tab → confirm-quit on the root tab); `application/config/quit_on_go_back=false` is already set;
   - `SafeArea` already handles Android cutouts (`get_display_safe_area()` is implemented there too), but Android additionally exposes `get_display_cutouts()` for the punch-hole shape — worth using for landscape-ish foldables only;
   - `display/window/frame_pacing/android/enable_frame_pacing=true` (Swappy).
6. Assets: nothing. `import_etc2_astc=true` already produces ETC2/ASTC for Android.
7. Billing: Godot's Google Play Billing plugin on the client; the Go server validates receipts against Google's API exactly as it will for App Store receipts. Design the server's IAP verification with two providers from day one.

## 17. Steam / desktop later

1. Download macOS/Windows/Linux templates; add three presets.
2. **Aspect policy flips.** On desktop, `keep_width` would show a comically wide 720-unit column on a 16:9 monitor. Switch to letterboxing at boot:

```gdscript
# in Main._ready()
if OS.has_feature("pc"):
	var w := get_window()
	w.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_KEEP
	w.min_size = Vector2i(405, 720)
	w.size = Vector2i(576, 1024)
```
`CONTENT_SCALE_ASPECT_KEEP` pillarboxes the portrait canvas. Fill the bars with a tiling stone/parchment texture rather than black — cheap, and it turns the constraint into art direction.

3. **Focus navigation.** Every `Button` gets `focus_mode = FOCUS_ALL`, `focus_neighbor_*` is wired per screen, `ScrollContainer.follow_focus = true` (already set on `RecycleGrid`), and `ui_up/down/left/right/accept/cancel` are mapped. Do this incrementally now — retrofitting focus order across six tabs later is miserable, and the theme already has hover and focus styleboxes that mobile simply never triggers.
4. Steamworks via the **GodotSteam** GDExtension (achievements, overlay, rich presence). Steam Deck runs the Linux build letterboxed; acceptable, and Deck players are not the target.
5. A genuinely better desktop layout is two columns above aspect 1.0 (list + detail pane instead of a modal). Real design work — scope it separately, don't half-do it.

---

## 18. Localization readiness (v1 English)

Six rules, all cheap now and expensive later.

1. **No player-visible English literal in a `.tscn`.** Put the key in `text` (`TAB_FAMILY`) — Godot auto-translates `Control.text` through `tr()` at runtime, so the scene is already localised. `res://locale/emperors.csv` is imported to `emperors.en.translation`.
2. **The server returns ids, never display strings.** `{"job_id": "grapes", "name_key": "JOB_GRAPES_NAME"}`, and the client resolves it. This is a localisation requirement *and* a separation-of-concerns win: the Go server never learns what a job is called.
3. **Errors carry a `code`**, and the client renders `tr("ERR_" + code.to_upper())`, falling back to the server's English `message` when there is no key (see `ApiError.user_text()`). New server errors degrade gracefully instead of showing a blank string.
4. **Player-generated text must opt out of translation.** Any `Label` showing a player name, kingdom name or chat string sets `auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED`. Otherwise a player who names themselves "Attack" renders as the translated word. This bug is invisible in an English-only build and ships to production.
5. **Numbers are localised too.** `SEP_THOUSANDS` and `UNIT_0..7` go through `tr()` (§10.3).
6. **Test expansion before it is real.** Set `internationalization/pseudolocalization/override=true` with `expansion_ratio=0.4` and walk all six tabs. German runs ~35% longer than English; a `Label` with a fixed width and no `autowrap_mode` will clip. Fix them while the screens are being built, not during a localisation sprint.

Font caveat to record now: **Cinzel has no Cyrillic or CJK.** For RU/JP/KR the display font must be swapped, so `UiTheme` should read the display face from a per-locale constant rather than a hardcoded `preload`, and `allow_system_fallback` should stay on for the body font.

---

## 19. Testability

Yes — and the API client and state store are testable **completely headlessly, with no sockets and no sleeping**, which is what makes them worth testing at all. Two design seams make it work:

- `Api.set_transport()` — retries, backoff, the refresh stampede, offline transitions and cancellation are all *timing* behaviours. Against a real socket they are coin flips. Against a scripted fake they are assertions.
- `Clock.source` — tax accrual, energy regen and shield expiry are functions of time. Injecting the clock turns a 30-minute test into a 3-millisecond one.

```
client/tests/
  TestRunner.tscn          # a Node scene, not a --script MainLoop
  test_runner.gd
  fakes/fake_transport.gd  fakes/fake_clock.gd
  suites/net_test.gd  store_test.gd  actions_test.gd  ui_smoke_test.gd
  fixtures/*.json          # emitted by the Go server: `make fixtures`
```

Run it as a **scene**, not `--script`: autoload globals (`Api`, `GameState`, …) are only registered as identifiers when the project boots normally, and booting normally also means the tests exercise the real configuration.

```bash
godot --headless --path client --import
godot --headless --path client res://tests/TestRunner.tscn -- --suite=actions
# and once more under the web renderer, to keep that path honest:
godot --headless --path client --rendering-method gl_compatibility res://tests/TestRunner.tscn
```

```gdscript
# res://tests/fakes/fake_transport.gd
class_name FakeTransport
extends Node

## Stands in for HttpTransport.
##
## This file is the reason Api takes a transport instead of newing HTTPRequest.
## Every interesting failure in the networking layer is a race — a 401 arriving
## mid-refresh, a timeout on a batch the server already applied, a cancel that
## lands between lease and send — and against a real socket you can only hope to
## see them. Here they are three lines of script.

var queued: Array[ApiResult] = []
var sent: Array[Dictionary] = []
var latency := 0.0


func expect(r: ApiResult) -> void:
	queued.append(r)


func send(method: int, url: String, headers: PackedStringArray,
		body: String, _timeout: float, pending) -> ApiResult:
	sent.append({"method": method, "url": url, "headers": headers, "body": body})
	if latency > 0.0:
		await get_tree().create_timer(latency, true, false, true).timeout
	if pending.state == HttpTransport.Pending.State.FINISHED:
		return ApiResult.failure(ApiError.new(ApiError.Kind.CANCELLED))
	if queued.is_empty():
		return ApiResult.failure(ApiError.new(ApiError.Kind.NETWORK, 0, "unscripted"))
	return queued.pop_front()


func header(index: int, name: String) -> String:
	for h in (sent[index]["headers"] as PackedStringArray):
		if h.to_lower().begins_with(name.to_lower() + ":"):
			return h.split(":", true, 1)[1].strip_edges()
	return ""
```

**The eight tests that must exist before the first TestFlight build.** Every one of them guards a bug that costs real money or real trust:

1. `test_batch_survives_a_timeout_without_double_spending` — script `[TIMEOUT, SUCCESS]`; assert both requests carry the **same** `Idempotency-Key` and that gold advanced exactly once.
2. `test_refresh_is_single_flight` — fire five concurrent authed calls with an expired token; assert exactly one `POST /v1/auth/refresh` in `sent`.
3. `test_prediction_never_writes_a_store` — queue 20 collects, assert `GameState.wallet.gold` is unchanged, then apply a snapshot and assert `display_gold()` equals the server's number exactly.
4. `test_rejection_rolls_back_exactly_one_action` — server rejects seq 7; assert the display drops by precisely that action's predicted gold and `rejected` fires once.
5. `test_unacknowledged_actions_are_requeued_in_order` — `applied_through` covers 3 of 5; assert the remaining 2 go back to the **front** of `_pending`, ahead of newer taps.
6. `test_energy_gate_refuses_without_a_request` — assert `Actions.collect()` returns `false` and `FakeTransport.sent` is empty.
7. `test_cancel_wakes_the_awaiting_coroutine` — the hang described in §6. Assert the call returns a `CANCELLED` result within one frame.
8. `test_offline_after_two_failures_and_recovers_on_heartbeat` — assert `online_changed(false)`, then `(true)`, and that `Session.resync()` ran.

Plus a **UI smoke suite**: instantiate each of the six tabs, apply `fixtures/snapshot_new_player.json` and `snapshot_late_game.json`, call `refresh()`, assert key labels are non-empty. This catches broken `%UniqueName` paths and null `@onready`s, which are otherwise found on a phone.

**Contract fixtures are the anti-drift mechanism.** The Go server gets a `make fixtures` target that serialises real snapshot responses into `client/tests/fixtures/`. Client tests load them. When the server changes a field name, a client test fails in CI on the same PR — instead of on a phone, three days later.

**CI** (GitHub Actions, `macos-latest` or a Linux container with Godot headless):

```yaml
- run: godot --headless --path client --import
- run: git diff --exit-code -- client/     # imports must be committed
- run: godot --headless --path client res://tests/TestRunner.tscn 2>&1 | tee out.txt
- run: "! grep -qE 'SCRIPT ERROR|ERROR:' out.txt"
```

The `grep` is not elegant, but GDScript has no error hook and a `push_error` that nobody reads is the most common way a Godot project rots.

---

## 20. Build order

| # | Milestone | Contents | Proves |
|---|---|---|---|
| 1 | **Skeleton** | `project.godot`, `Main.tscn`, `SafeArea`, `TabHost`, 6 empty tabs, `UiTheme` with placeholder art | Runs on the iPhone via one-click deploy, correct safe area, tabs switch |
| 2 | **Plumbing** | `Clock`, `Cfg`, `Log`, `ApiError/Result`, `HttpTransport`, `Api`, `FakeTransport`, tests 1/2/7/8 | The network layer is correct *before* any UI depends on it |
| 3 | **State** | `Store` + 8 domains, `GameState`, snapshot cache, `Session` boot, stale-paint | Cold start paints in <100 ms; snapshot applies |
| 4 | **Currency + Collect** | `CurrencyBar`, `NumberLabel`, `Fmt`, `Floater`, `CollectJobRow`, `Actions`, tests 3/4/5/6 | **The core loop feels instant.** Ship a build and tap it for ten minutes. |
| 5 | **Real art** | Gemini sheets → slice → matte → atlas → `ItemArt`; real nine-patches; tier frames | The theme survives contact with real textures |
| 6 | **Inventory + Soldiers** | `ItemCard`, `TierFrame`, `RecycleGrid`, `ItemSlot`, `SoldierCard`, equip flow | 500 items scroll at full frame rate |
| 7 | **Lane B** | `Reveal`, `ConfirmDialog`, shop, recruit, buy-slot, upgrades | Pessimistic path, reveal beat |
| 8 | **Attack + Kingdom** | opponent list, combat result screen, shield timer, kingdom tab | |
| 9 | **Polish** | audio, haptics, ducking, toasts, offline banner, pseudolocalisation pass, focus order | |
| 10 | **Ship** | Store preset, icons, launch storyboard, privacy manifest, TestFlight | |

Milestone 4 is the gate. If the collect loop does not feel instant on a real phone on a real network, nothing later matters — go back to §8 rather than forward to §6.

---

## 21. Things that will bite, and where

| Trap | Where it shows up | Guard |
|---|---|---|
| `cancel_request()` never emits `request_completed` | a tab switch hangs a coroutine forever; leaks a pool slot per switch | `Pending.done` (§6.2), test 7 |
| Prediction folded into `wallet.gold` | slow drift, then a big correction, then a support ticket | display is a function (§5.4), test 3 |
| Blind retry of `POST /v1/actions` | duplicated gold on a flaky network | idempotency key gated on it (§6.3), test 1 |
| Refresh stampede on boot | five refreshes rotate the token; four callers get 401 | single-flight `_ensure_token` (§6.3), test 2 |
| Client re-deriving the payout formula | a rounding difference shows the wrong number on every tap | server ships resolved payouts (§5.3) |
| Hidden tabs repainting | frame drops that only happen after visiting all six tabs | `TabPage.mark_dirty` (§4.3) |
| `get_display_safe_area()` on desktop | the desktop *work area* becomes the inset; huge margins | `OS.has_feature("mobile")` guard (§3) |
| Splash colour mismatch (3 places) | a white flash on every single launch | all three set to `#0E0B09` |
| Missing `tnum` on the currency font | the counter jitters sideways as it rolls | `FontVariation` (§9.3) |
| `auto_translate_mode` on player names | a player named "Attack" renders translated | disabled on user-data labels (§18) |
| `detect_3d/compress_to=1` | UI textures silently switch to VRAM compression; mystery diffs | `[importer_defaults]` sets `0` (§2) |
| `rembg_matting.py --preview` single-image | `NameError` at `rembg_matting.py:312` | use `--batch` (§12.1) |
| `onnxruntime-gpu` in the skill's requirements | no Apple Silicon wheel; pip fails | install plain `onnxruntime` (§12.1) |
| Tab bar under the home indicator | "the last tab button doesn't work" | bottom inset applied (§3) |

---

## Critical Files for Implementation

- `/Users/yigitkarabulut/Developer/Emperors/client/autoload/action_queue.gd` — the optimistic lane; the single most important file in the client
- `/Users/yigitkarabulut/Developer/Emperors/client/net/http_transport.gd` — pooled `HTTPRequest` with cancel-safe `Pending`; every other network bug traces back here
- `/Users/yigitkarabulut/Developer/Emperors/client/autoload/api.gd` — auth refresh, retry/backoff, offline, tag cancellation
- `/Users/yigitkarabulut/Developer/Emperors/client/autoload/game_state.gd` — domain stores + `display_*()` derivation; the confirmed/predicted boundary
- `/Users/yigitkarabulut/Developer/Emperors/client/project.godot` — resolution, stretch, renderer, importer defaults; wrong here and everything downstream is wrong

Reference material already on this machine, worth reading before writing a line:
- `/Users/yigitkarabulut/Developer/GameTest/client/project.godot` and `export_presets.cfg` — a validated Godot 4.7.2 portrait/iOS configuration
- `/Users/yigitkarabulut/Developer/GameTest/client/autoload/api.gd` — house GDScript style, and the single-`HTTPRequest` queue this design replaces
- `/Users/yigitkarabulut/Developer/GameTest/client/tests/test_runner.gd` — the headless scene-based test runner pattern, proven working here
- `/Users/yigitkarabulut/Developer/godogen-src/asset-gen/SKILL.md` — the sheet → slice → matte pipeline and its known bugs

---

## Key decisions

- **Display = confirmed + replay(pending). A prediction is NEVER written into a store; `GameState.display_gold()` is a function that adds the pending queue's deltas on top of the last server snapshot.**
  - Rejected: Applying optimistic deltas directly to `WalletStore.gold` and subtracting them again on server ack (the common 'apply then correct' pattern).
  - Why: There is no accumulator, so a wrong prediction costs exactly one correction and can never drift. The 'apply then correct' pattern accumulates rounding and lost-ack errors until the client is minting gold — which in a game with a real-money hard currency is a business risk, not a bug.
- **The server ships RESOLVED payouts (`gold_payout` already multiplied by family/kingdom/milestone bonuses and already rounded), not formulas. The client's prediction is a table lookup.**
  - Rejected: Shipping multipliers and having the client evaluate the same economy formula the server does.
  - Why: Two implementations of one rounding rule will diverge, and the divergence surfaces as a wrong number on every single tap. It also means the economy can be retuned server-side with zero client releases — which matters enormously for a live idle game.
- **Predict pessimistically: when a queued tap would cross a 25/50/100 milestone, keep predicting the OLD payout.**
  - Rejected: Predicting the post-milestone payout for accuracy.
  - Why: Corrections then only ever add gold. A counter that ticks up an extra 40 reads as a bonus; one that ticks down is indistinguishable from the game taking money back. The asymmetry is free.
- **Two action lanes. Optimistic+batched for high-frequency deterministic actions (collect, stat points); pessimistic single-flight with a reveal animation for random-outcome actions (recruit, shop buy, attack).**
  - Rejected: Optimistic prediction for everything, with rollback on mismatch.
  - Why: Predicting a dice roll means showing someone a legendary and taking it away. Those actions also *want* the round trip — the wait is the drama, not the latency. The dividing line is frequency plus determinism, not importance.
- **`rendering/renderer/rendering_method="mobile"` with a one-line `.web="gl_compatibility"` override.**
  - Rejected: `gl_compatibility` everywhere for web/iOS symmetry; or `forward_plus`.
  - Why: Godot 4.4+ ships a native Metal RenderingDevice driver (default on iOS arm64), so `mobile` means Metal — Apple's only non-deprecated GPU API. `gl_compatibility` on iOS is OpenGL ES 3.0, deprecated since 2018. `forward_plus` is the clustered desktop renderer and buys nothing for a canvas with zero 3D. Godot 4.7 web is WebGL2-only anyway, so the override is unavoidable and costs one line.
- **720×1280 base with `stretch/mode=canvas_items` and `stretch/aspect=keep_width`; the hard design constraint is that everything essential fits in 720×1000.**
  - Rejected: 1080×1920 base, or 390×844 to design directly in iOS points, or `keep`/`expand` aspect.
  - Why: `keep_width` fixes horizontal layout forever and turns extra phone height into extra list rows — exactly right for a list-based game. 720 makes the 'author art at 2×' rule exact and keeps the iPad-safe 4:3 height (1036) as the binding constraint. 720 units = 393 pt, so Apple's 44 pt touch minimum is a clean 88 units.
- **Safe-area insets are computed as FRACTIONS of the physical screen, then multiplied by the viewport rect — and only applied when `OS.has_feature("mobile")`.**
  - Rejected: Converting `get_display_safe_area()` pixels to canvas units via a scale factor derived from window size.
  - Why: The pixel↔unit factor differs per device and per stretch mode; ratios make the units cancel, so one code path is correct on a 19.5:9 iPhone and a 4:3 iPad. The mobile guard matters because on desktop the call falls back to `screen_get_usable_rect()` — the desktop work area — producing absurd margins.
- **Tabs are lazily instantiated on first open, then cached hidden with `PROCESS_MODE_DISABLED`; `Api.cancel_tag(id)` fires on tab exit.**
  - Rejected: Preloading all six at boot, or freeing on hide.
  - Why: Preloading adds six instantiations and six first-layout passes to the frame the player is judging the app on. Freeing throws away scroll position, which players notice on every switch. Six UI tabs are trivial memory next to the texture atlases, so pay lazily and keep.
- **One `changed` signal per domain store (eight of them), plus a single 10 Hz projector for the two self-moving numbers (tax gold, regen energy). No UI node may read GameState in `_process`.**
  - Rejected: Field-level signals, or a single global `state_changed`, or letting each screen poll the store per frame.
  - Why: A domain is small enough that repainting all of it is free and coarse enough that the inventory grid never rebuilds because energy ticked. Field-level signals make repaints untraceable. The 10 Hz push plus an interpolating `NumberLabel` looks like 120 Hz while doing 1/6th the work.
- **`Api` takes an injectable transport and `Clock` takes an injectable time source; tests run fully headless with a scripted `FakeTransport`.**
  - Rejected: Testing the network layer against a local Go server, or not testing it.
  - Why: Every interesting failure here is a race — a 401 mid-refresh, a timeout on a batch the server already applied, a cancel between lease and send. Against a real socket you can only hope to observe them. Injecting the clock also turns a 30-minute energy-regen test into 3 ms.
- **View recycling (`RecycleGrid`) only above ~120 cells, implemented with absolutely-positioned cells inside a plain sized `Control` — deliberately NOT inside a container.**
  - Rejected: Recycling everywhere, or a plain `GridContainer` everywhere.
  - Why: 500 items naively is ~4,500 Controls: tens of ms in the first layout pass on an iPhone plus permanent per-frame container cost. Below ~120 the complexity is not worth it. Cells must be outside a container because a container fights manual positioning; the sized empty child keeps the scrollbar honest.
- **Theme built in GDScript (`UiTheme.build()`) using `theme_type_variation` for variants, not an authored `.tres` and not per-node overrides.**
  - Rejected: A `.tres` theme resource authored in the editor.
  - Why: A merged `.tres` theme is unreviewable and a nightmare to resolve; a builder script gives readable diffs and derived colours from one palette constant. Type variations keep every variant visible in one file, whereas per-node overrides have to be re-found in every scene that copied them.
- **Resolve the epic/mystic purple conflict by separating on luminance, frame material and motion rather than hue — epic `#A855F7` polished silver, mystic `#6D28D9` obsidian with an `#E879F9` rim and the game's only animated shimmer — plus a hard rule that tier is never signalled by colour alone (pips + spelled-out name always present).**
  - Rejected: Reassigning mystic to a non-purple hue, or shipping both as purple as literally specified.
  - Why: Hue alone cannot carry a seven-step ladder and fails for ~8% of men regardless of tuning. This honours the owner's stated 'both purple' while keeping the tiers instantly distinguishable, and the pips/name rule makes the whole ladder robust rather than just this one pair.
- **Cinzel SemiBold for display, Alegreya Sans for body and all numbers (with `tnum` tabular figures via `FontVariation`); font oversampling on, MSDF off.**
  - Rejected: A decorative blackletter (MedievalSharp/UnifrakturCook) as the body face; MSDF fonts for scale-independence.
  - Why: This game is made of numbers on a phone — a decorative face at 26 units is unreadable. Cinzel carries the medieval register in headings only. Without `tnum` every currency counter jitters sideways as it rolls. Godot 4.5+ per-viewport oversampling already gives crisp text at any scale; MSDF exists for extreme zoom and costs sharpness at exactly the 20–30 unit sizes that are 90% of this UI.
- **Refresh/session tokens stored in `user://session.dat` encrypted with a random per-install key from `user://install.key` — explicitly documented as obfuscation, not security. `OS.get_unique_id()` is deliberately not used as key material.**
  - Rejected: Deriving the key from `OS.get_unique_id()`, or a Keychain GDExtension.
  - Why: On iOS `get_unique_id()` is `identifierForVendor`, which rotates on reinstall — using it would silently lock players out of their own cached token. The real defence is short-lived access tokens plus server-side refresh rotation and revocation; a Keychain plugin is a native dependency that buys little on top of the app sandbox.
- **One-click deploy via `xcrun devicectl` (confirmed present in the 4.7.2 binary) with remote debug is the device loop; the Xcode project is only generated for IAP/push/Instruments/TestFlight.**
  - Rejected: Making the exported Xcode project the primary iteration path.
  - Why: One-click is ~40 s and streams `print()` back to the editor Output. 95% of the work is UI layout, which is faster in the editor at 450×800; device time should be spent on the things only a device can answer — safe area, thumb reach, fling feel, thermals, and the 8-hour-background offline-tax path.

## Risks flagged

- The whole optimistic design rests on the server publishing RESOLVED per-job payouts (already multiplied and rounded) plus `now_ms` in every response envelope. If the Go server ships multipliers instead and expects the client to evaluate the economy formula, prediction becomes approximate and every collect tap shows a subtly wrong number. This must be agreed with the server design before milestone 4.
- If collect payouts ever gain randomness (crits, rare drops), exact prediction breaks. The mitigations are all worse than the constraint: a server-supplied RNG stream the client replays is fragile, and predicting the base then animating a bonus is a different UX. Decide 'collect is deterministic' now and write it down.
- Server-side idempotency for `POST /v1/actions` (store `batch_id`, replay the original response for 24h) is not optional — it is the only thing that makes retrying a gold-minting POST safe. If it is not implemented before the first flaky-network session, players will duplicate gold and it will be discovered by the players, not by us.
- `HTTPRequest.cancel_request()` not emitting `request_completed` is a silent hang, not a crash. If the `Pending` wrapper is ever bypassed (e.g. someone adds a 'quick' HTTPRequest for one endpoint), tab-switching will leak pool slots until the client stops making requests, and it will look like a server problem.
- Godot 4.7's Metal driver on iOS is comparatively young (native Metal landed in 4.4, with reported perf regressions on some Apple Silicon in 4.4). A 2D UI game is close to the least demanding possible workload, but budget a day to validate on the oldest target device and keep `rendering_device/driver.ios="vulkan"` as a documented fallback.
- iOS `identifierForVendor` rotates on reinstall, so device-based login loses accounts. Sign in with Apple is effectively required before launch (Apple mandates it if any other third-party login is offered). The server's account model must support multiple credentials per player from day one or this becomes a migration.
- The `keep_width` aspect policy means the iPad viewport is only 720×1036 tall. Any screen that grows past 1000 units of essential content will be broken on iPad and on short devices before anyone notices on an iPhone 16 Pro. Needs a CI screenshot check or a discipline that will slip.
- `RecycleGrid` requires uniform row height and an allocation-free `bind()`. Both are easy to violate later (a card that `load()`s a texture, a 'featured item' row that is taller). Violations show up as scroll stutter on a phone, not in the editor.
- The godogen asset-gen toolchain has two confirmed defects on this machine: `rembg_matting.py --preview` raises NameError at line 312 in single-image mode, and `requirements.txt` pins `onnxruntime-gpu`/`nvidia-cudnn-cu12`, which have no Apple Silicon wheels. The art pipeline will fail on first run until both are worked around.
- Only `ios.zip` export templates are present for 4.7.2. Any web, desktop or Android work is blocked on downloads that are ~1 GB and occasionally rate-limited — not hard, but it will surprise someone on the day they need it.
- Three separate places must carry the identical background colour (`application/boot_splash/bg_color`, `rendering/environment/defaults/default_clear_color`, `storyboard/custom_bg_color`). Any drift is a visible flash on every single launch, and it is the kind of thing that gets fixed in two of the three places.
- Localization-readiness rules (server returns ids, `auto_translate_mode` disabled on player-generated text, no English literals in scenes) are nearly free now and very expensive later — but they are pure discipline with no compile-time enforcement, and an English-only build gives zero feedback when they are violated.

## Questions raised for the owner

- Is the Collect payout fully deterministic, or do you want crits / rare bonus drops on collect? Exact client prediction depends on determinism. If you want randomness, we need to decide now between (a) no randomness on collect, (b) the server sends a replayable RNG seed, or (c) collect shows the base payout instantly and animates a surprise bonus when the response lands. This changes §8 materially.
- Epic and mystic are both specified as purple. Proposed resolution: epic = bright purple #A855F7 on polished silver; mystic = deep royal purple #6D28D9 on carved obsidian with a magenta #E879F9 rim and the game's only animated shimmer — plus tier always spelled out with 1–7 pips so colour is never the sole signal. Do you accept this, or would you rather move mystic off purple entirely (e.g. void-black with a violet core)?
- Should shop items and recruited soldiers be revealed with an animation (card flip / chest open) or appear instantly? This determines whether those actions get a blocking 'reveal' beat, and it is the main reason they sit in the pessimistic lane rather than the optimistic one.
- What is the intended session shape — many short sessions or long ones? It decides whether the idle FPS throttle (drop to 10 fps after 15 s without a touch) is a battery win or an annoyance, and whether tab state should survive a background/foreground cycle or always resync.
- Is Kingdom (clan) in v1 or a later release? It is the only tab with real-time-ish social data (invites, member list, reputation leaderboard) and may want push notifications and a different refresh cadence than a plain snapshot — which affects whether we need any WebSocket/SSE path at all, or whether pure request/response is sufficient for launch.
- Do you want a single account tied to the device (fast onboarding, but progress is lost on reinstall because iOS rotates identifierForVendor), or Sign in with Apple from day one? Apple effectively requires Sign in with Apple once any other third-party login exists, and retrofitting a multi-credential account model server-side is far more work than building it now.
- iPhone-only for v1, or does iPad need to work at launch? `targeted_device_family=0` (iPhone) is assumed. iPad's 4:3 aspect gives only 720×1036 of vertical canvas and would ideally get a different layout, not a stretched phone UI.
- What is the intended item count ceiling in inventory — dozens, hundreds, or thousands? Below ~120 the grid does not need recycling at all; in the low thousands we additionally need server-side pagination and filtering rather than shipping the whole inventory in the snapshot.
- Confirm the Apple team to use is JS3GR55886 (the identities on this machine) and the bundle identifier scheme `com.karabulut.emperors` / `com.karabulut.emperors.dev`. The existing StarDrift preset on this machine references a different team (5C2NRK938T), so one of them is wrong for this project.
- Is Steam/desktop a real roadmap item or a maybe? If real, focus-order and keyboard/gamepad navigation should be wired incrementally from milestone 1 (cheap now, miserable to retrofit across six tabs). If it is a maybe, we skip it and accept the later cost.

---

# Adversarial review — verdict: needs-revision


## BLOCKER (5)

### `Actions._ack()` and `Actions._fail()` both do `_pending = _inflight + _pending` where both are `Array[Dictionary]`. In GDScript 4 the `+` operator on arrays returns an **untyped** `Array` (Variant `OP_ADD` builds a bare `Array`), and assigning that to a typed variable raises the runtime error whose format string is present in this binary: `Trying to assign an array of type "%s" to a variable of type "Array[%s]".` (godotengine/godot#72948).

**Breaks because:** Player taps Collect 20×; the batch POST times out. `_fail()` runs, hits `_pending = _inflight + _pending`, and dies with a runtime error at that line. `_inflight` is never cleared, `_sending` is left `true` (the assignment is before `_sending = false`? no — it is inside `_fail`, so `_sending=false` still runs, but `_inflight` still holds 32 actions and `_pending` is unchanged). The 32 predicted actions stay summed into `_d_gold`/`_d_energy` forever, so `display_gold()` is permanently inflated by gold the server never granted, and it is never re-sent. This is the single path the whole §8 design exists to protect, and it is also exactly what test 5 (`test_unacknowledged_actions_are_requeued_in_order`) asserts — so the design ships a test that cannot pass.

**Fix:** Never use `+` on typed arrays. Replace both sites with:
```gdscript
var merged: Array[Dictionary] = []
merged.assign(_inflight)
merged.append_array(_pending)
_pending = merged
_inflight.clear()
```
(`Array.assign()` performs the element-wise typed copy; `append_array` preserves the destination's type.) Grep the whole client for `] + ` on typed arrays before milestone 4.

### `Fmt.number()`, `Fmt.grouped()`, `Fmt.duration()` and `Palette.tier_name()` are `static func` and call `tr()`. `tr()` is a non-static `Object` method. The binary contains the exact diagnostic: `Cannot call non-static function "%s()" from the static function "%s()".`

**Breaks because:** `res://ui/theme/fmt.gd` and `res://ui/theme/palette.gd` fail to parse. Every script that `preload`s or references `Fmt`/`Palette` — `NumberLabel`, `ItemCard`, `CollectJobRow`, `CurrencyBar` — fails to load with it. The project does not boot. This is not a subtle bug; it is a hard parse error in the two most-referenced utility classes in the design.

**Fix:** Use `TranslationServer.translate()` (a static singleton call, confirmed present as `translate` in this build) in every static context:
```gdscript
static func grouped(n: int) -> String:
    ...
    out = TranslationServer.translate(&"SEP_THOUSANDS") + out
```
and `TranslationServer.translate(TIER_KEY[...])` in `Palette.tier_name()`. Note `TranslationServer.translate()` does not apply pseudolocalization the way `Object.tr()` does, so if §18.6's pseudoloc pass must cover separators, call `TranslationServer.pseudolocalize()` behind a `Cfg` flag. Also hoist the lookup: `Fmt.number()` runs per frame inside `NumberLabel._paint()` at up to 120 Hz on three counters — cache `SEP_THOUSANDS` and `UNIT_0..7` into a static `Array[String]` refreshed on `TranslationServer.translation_changed` (or on locale change) rather than looking them up per digit group.

### §2 sets `debug/gdscript/warnings/integer_division=2` (error) and then the document's own code performs integer division in at least six places: `Clock.observe()` → `res.elapsed_ms / 2`; `Api._ensure_token()` → `int(Clock.now_ms() / 1000)`; `RecycleGrid._sync()` → `float(index / columns)`; `Fmt.duration()` → `seconds_left / 3600`, `(seconds_left % 3600) / 60`, `seconds_left / 60`.

**Breaks because:** Warning level 2 = treat as error. On first editor open, `clock.gd`, `api.gd`, `recycle_grid.gd` and `fmt.gd` all fail to compile with `Integer division. Decimal part will be discarded.` promoted to an error. Nothing runs. The author never opened the project with these settings.

**Fix:** Either (a) keep `integer_division=2` — which is the right call for an economy client — and fix every site explicitly: `res.elapsed_ms / 2.0`, `Clock.now_ms() / 1000.0`, `floori(float(index) / float(columns))`, `floori(seconds_left / 3600.0)`; or (b) annotate the deliberate ones with `@warning_ignore("integer_division")`. Do (a). Add a CI step `godot --headless --path client --check-only --script <each .gd>` (or simply fail the build on `SCRIPT ERROR` in `--import`, which §19 already greps for) so this class of self-contradiction cannot recur.

### `TabHost.open()` cancels the wrong tab's requests: inside `if _pages.has(current):` it calls `Api.cancel_tag(id)` — `id` is the tab being **entered**, not `current`, the tab being left.

**Breaks because:** The stated guarantee ("flicking through all six tabs does not queue six stale responses behind the one the player is waiting for") is exactly inverted. Player opens Inventory (fires a slow `/v1/inventory` under tag `&"inventory"`), then taps Shop: `cancel_tag(&"shop")` runs — a no-op — and the Inventory request stays in flight, holding one of the 4 general transport slots and eventually applying a stale snapshot. Meanwhile, if the incoming tab had a legitimately in-flight request from a *previous* visit that the user is waiting on, it is killed. Flicking all six tabs leaves up to six live requests, which with only 4 general slots means the last two block behind them.

**Fix:** `Api.cancel_tag(current)` — move it before `current = id`. While there, guard against the tag being re-registered by the entering tab in the same frame by cancelling before `page.tab_shown()` is called (it already is).

### `HttpTransport.cancel()` cannot wake a request that is still **queued**. `_lease()` parks on `await _slot_released`, which is emitted only by `_release()`. `cancel()` sets `pending.state = FINISHED` and emits `pending.done`, but nothing is listening to `done` yet — the coroutine is suspended inside `_lease`, not on `await pending.done`.

**Breaks because:** All 4 general slots busy with 12 s-timeout requests; a fifth call (say the Shop fetch) is queued; the player switches tabs and `cancel_tag` fires. The caller's `await Api.get_json(...)` does not return for up to 12 seconds. §19's test 7 (`test_cancel_wakes_the_awaiting_coroutine` … "within one frame") fails for the queued case, which is the case the pool exists to create. §21 lists this exact hang class as a trap the design supposedly guards.

**Fix:** One line in `cancel()`, after `pending.finish(...)`: `_slot_released.emit()`. A spurious wake is harmless because `_lease`'s `while pending.state != Pending.State.FINISHED` re-checks and returns `null`. Add an assertion in test 7 that covers both the QUEUED and RUNNING states.


## MAJOR (15)

### The whole transport is built on `HTTPRequest`, which does **not** reuse connections. Godot's own documentation states HTTPRequest closes and reopens a connection for every request (even redirecting to the same host:port); connection reuse requires the lower-level `HTTPClient`. The binary contains `Connection: close` and no keep-alive handling.

**Breaks because:** Every batch POST pays a fresh TCP handshake + TLS handshake. On a 200 ms RTT cellular link that is ~2 extra RTT for TLS 1.3 (≈400 ms) or ~3 for TLS 1.2 (≈600 ms) *on top of* the stated 200 ms. So §8.5's "20 taps in 3 s → 3–4 HTTP requests (one per RTT)" is wrong — at ~600 ms per batch you get ~5 sequential batches and reconciliation lags 3× longer than modelled. Worse for lane B: the "reveal beat" for recruit/attack/shop-buy is 600–900 ms of dead air, not 200 ms, and §8.2's justification ("the round trip is the drama, not the latency") was costed against the wrong number. It also triples the cost of the offline heartbeat and every tab fetch. This is the design's headline claim resting on a false premise about the engine.

**Fix:** Replace `HTTPRequest` with a persistent `HTTPClient` per lane inside `HttpTransport`, keeping the same `Pending`/`ApiResult` surface so nothing above §6 changes:
- Hold two `HTTPClient` instances (action lane + general lane). On first use, `connect_to_host(host, port, TLSOptions)`; poll `poll()` from `_process` until `STATUS_CONNECTED`.
- Issue `request(method, path, headers, body)`, poll to `STATUS_BODY`, accumulate `read_response_body_chunk()`.
- Only reconnect when `get_status()` is `STATUS_DISCONNECTED`/`STATUS_CONNECTION_ERROR`, or the server sends `Connection: close`.
- Cancellation becomes `client.close()` + reconnect, which is honest and instant.
This removes the `_lease`/`_slot_released` machinery entirely (see the over-engineering note) and is *less* code than the pool. If that is too much for milestone 2, keep `HTTPRequest` but re-cost §8: state the batch RTT as ~600 ms, raise `COALESCE` to ~0.20 s (batching more per handshake is now strictly better), and put a persistent `WebSocketPeer` for the action lane on the roadmap before soft launch.

### `application/min_ios_version="15.0"` with `rendering_method="mobile"` and `capabilities/performance_a12=false`. Godot 4.7's own system-requirements table says exported projects need **iOS 16.0 for Forward+/Mobile with Metal**, iOS 15.0 only for Forward+/Mobile with **Vulkan**, and lists **Apple A12 (iPhone XR/XS)** as the GPU floor for those renderers (A7 for Compatibility). The doc's claim that "Godot 4.4+'s Metal driver wants A8+" is wrong by four generations.

**Breaks because:** Two separate failures. (1) On an iOS 15 device the Metal driver is unavailable, so the app silently runs `mobile` over MoltenVK/Vulkan — the exact thing §2.2 argues the whole renderer decision avoids. (2) iOS 16 still supports iPhone 8/8 Plus/X (A11), and `min_ios_version=15.0` additionally admits A9/A10 devices. With `performance_a12=false` the App Store will offer the build to all of them, and the `mobile` renderer is not supported there — launch failure or a black screen, discovered as one-star reviews rather than in testing.

**Fix:** Set `application/min_ios_version="16.0"` **and** `capabilities/performance_a12=true` (both keys are present in this build; the latter writes `UIRequiredDeviceCapabilities = arm64e`, so the store will not offer the app below A12). Explicitly pin `rendering/rendering_device/driver.ios="metal"` in `project.godot` rather than relying on the auto-selection order, and document `"vulkan"` as the one-line rollback — the doc's own risk list already asks for that but never puts the key in the file. If the business wants iOS 15/A11 coverage, that is a different decision: it means shipping `gl_compatibility` on iOS, and it should be made explicitly, not inherited by accident.

### The `export_presets.cfg` is presented as "verified 4.7.2 field names" but contains five keys that do not exist in this build, and omits every icon slot 4.7.2 actually added. Absent from the binary: `storyboard/use_launch_screen_storyboard`, `application/launch_screens_interpolation`, `application/generate_simulator_library_if_missing`, `icons/spotlight_40x40`, `capabilities/push_notifications` (the real key is `entitlements/push_notifications`). Present in 4.7.2 but missing from the preset: `icons/icon_1024x1024`, `icons/icon_1024x1024_dark`, `icons/icon_1024x1024_tinted`, `icons/ios_128x128`, `icons/ios_136x136`, `icons/ios_192x192`, `icons/notification_76x76`, `icons/notification_114x114`, `application/liquid_glass_icon`, `application/app_category`, `application/provisioning_profile_uuid_debug/_release`, `application/provisioning_profile_specifier_debug/_release`, `entitlements/game_center`, `entitlements/increased_memory_limit`. All five stale keys appear verbatim in `/Users/yigitkarabulut/Developer/GameTest/client/export_presets.cfg` — they were copied from a preset last written by an older Godot, not read out of 4.7.2.

**Breaks because:** The stale keys are inert noise (Godot drops unknown preset entries on next save), but the *missing* ones are not. On Xcode 26.3 / iOS 26.2 SDK, an App Store submission in 2026 needs the dark and tinted 1024 icon variants and the Liquid Glass icon; `application/liquid_glass_icon` exists in this build with a dedicated failure path (`Could not export liquid glass icon:`). Shipping without them means either an export error or an App Store rejection at exactly the point (milestone 10) where the schedule has no slack. The missing provisioning-profile fields mean the headless release export in §15.1 cannot sign without Xcode intervention, contradicting §15.2's "the .ipa path builds and signs headlessly".

**Fix:** Regenerate the preset from the 4.7.2 editor rather than hand-authoring it: create the two presets in the Export dialog, fill them, and commit what Godot writes. Then verify against the option list by name. Concretely: delete the five stale keys; add `icons/icon_1024x1024`, `_dark`, `_tinted`, `icons/ios_128x128/136x136/192x192`, `icons/notification_76x76/114x114`, `application/liquid_glass_icon`, `application/app_category`; use `entitlements/push_notifications` if notifications are wanted (see missing coverage); and set `application/provisioning_profile_specifier_release` for the store preset. Drop the false "confirmed to exist in *this* build" claim from the document header — it is the sentence that made the rest of the file trusted without checking.

### §9.4's resolution of the epic/mystic conflict does not achieve the separation it claims. Measured WCAG contrast on the document's own `BG #0E0B09`: mystic `#6D28D9` = **2.76:1** (fails the 4.5:1 AA text minimum and even the 3:1 non-text minimum); epic `#A855F7` vs mystic `#6D28D9` = **1.80:1**; and — unnoticed by the doc — rare `#3D8BFD` vs epic `#A855F7` = **1.19:1**, a worse luminance pair than the one it set out to fix.

**Breaks because:** `ItemCard.bind()` applies `Palette.tier_color(tier)` directly as the item-name `font_color`. A mystic item's name is dark violet on near-black at 2.76:1 — effectively unreadable on a phone outdoors, and the game's rarest non-special tier is the one that disappears. The stated design principle ("separated on luminance + material + motion, not hue") is quantitatively false as specified: 1.80:1 is not a luminance separation. The pips-and-name fallback rule is good and does rescue *identification*, but not legibility of the name itself.

**Fix:** Split the roles. Keep `#6D28D9` as a *fill/frame* colour only, and introduce a separate `TIER_TEXT` map used for anything rendered as type. For mystic use the rim colour `#E879F9` (7.97:1 on `#0E0B09` — verified), which also becomes mystic's recognisable identity and makes the epic/mystic pair 1.60:1 → comfortably distinct. For the rare/epic collision, lift epic to a lighter violet (target ≥3:1 against `#3D8BFD`, e.g. `#C79BFF` at ~7.0:1 on bg) or push rare darker. Then add a build-time check: a small GDScript test in `tests/suites/` that computes WCAG contrast for every `TIER_COLOR` against `Palette.BG` and against each adjacent tier, and fails under 4.5:1 / 3:1 respectively. That turns a taste argument into a regression test and is ~30 lines.

### `Api._do_refresh()` passes `{"retries": true}` on the refresh POST with no idempotency key, while §13 states refresh tokens rotate on use. `_call` will retry it up to `MAX_ATTEMPTS = 4` times on any network/timeout/5xx.

**Breaks because:** Classic refresh-rotation race. The server receives the refresh, rotates the token, and the response is lost to a dropped cellular connection. `_call` retries with the same — now consumed — refresh token. The server rejects it (401, non-retryable), `_do_refresh` returns false, `_ensure_token` clears both tokens and emits `auth_lost`. The player is logged out of an idle game by a single dropped packet, and because §13 stores nothing else, they land on a login screen. This will happen to a meaningful fraction of a mobile user base every day.

**Fix:** Two changes, both needed. Client: give the refresh call an idempotency key derived from the refresh token itself (`"idempotency_key": _refresh.sha256_text().substr(0, 32)`) so a retry is deduped, and cap it at 2 attempts. Server (add to the §8.6 contract section): implement a rotation grace window — when refresh token *N* is consumed and rotated to *N+1*, keep *N* valid for 60 s and return the *same* `N+1` pair for a repeat presentation of *N*. Presentation of *N* after the grace window is a genuine reuse and should revoke the family. This is the standard OAuth refresh-token-rotation reuse-detection pattern and it must be in the Go design before milestone 2, not after.

### Lane B actions that cost energy (`attack`) are not reflected in `GameState.display_energy()`, which only nets `Actions.energy_delta()` — a lane-A-only sum.

**Breaks because:** Player has 8 energy. They tap Attack (cost 5, lane B, single-flight, ~600 ms round trip given the TLS finding). While the reveal animation plays, `display_energy()` still reads 8, so `Actions.collect()`'s gate happily queues a 4-energy collect. The server applies the attack first, leaving 3, and rejects the collect. §8's stated invariant — "the queue is self-limiting and the server rarely has to reject anything" — is violated by the one other verb in the game that spends the same pool, and the player sees an unexplained rollback plus a toast.

**Fix:** Add a reservation API to `Actions` and fold it into the projection:
```gdscript
var _reservations: Dictionary = {}   # int handle -> {energy:int, gold:int}
var _next_reservation := 0
func reserve(energy: int, gold := 0) -> int:
    _next_reservation += 1
    _reservations[_next_reservation] = {"energy": energy, "gold": gold}
    pending_changed.emit()
    return _next_reservation
func release(handle: int) -> void:
    if _reservations.erase(handle): pending_changed.emit()
func energy_delta() -> int:
    var r := 0
    for v in _reservations.values(): r -= int(v["energy"])
    return _d_energy + r
```
Every lane-B call site wraps itself: `var h := Actions.reserve(cost)` before `await`, `Actions.release(h)` in a `defer`-equivalent after the result (success or failure — the snapshot in the response supersedes it). Do the same for gold on shop purchases and soldier recruitment so two rapid buys cannot both pass an affordability check.

### `spend_stat_point` is assigned to lane A (§8.2) but lane A cannot express it. `Actions` has no `spend_stat_point()` method; `_add()` only sums `gold`/`xp`/`energy`; and `_flush()`'s body mapper emits exactly `{"seq", "kind", "job_id"}` — there is no field for which stat was chosen.

**Breaks because:** Implementing it as designed sends `{"seq": 7, "kind": "spend_stat_point", "job_id": ""}` — the server cannot tell Attack from Defense from Max Energy. And spending a stat point into Max Energy changes `energy.energy_max`, which is the upper clamp in `display_energy()` — so a predicted stat point cannot be predicted without also predicting the clamp. It also fails the doc's own lane criterion: a player spends a handful of stat points per level, not "more than once a second".

**Fix:** Move `spend_stat_point` to lane B. It has a natural confirm dialog (`ConfirmDialog` is already in the component list), it is irreversible, and it is low frequency. Lane A then has exactly one verb — `collect` — which is what the rest of §8 actually assumes and lets `_flush`'s body mapper stay as written. If a future action does belong in lane A, generalise by giving each action a `payload: Dictionary` that `_flush` merges, and give `_add()` a table of predicted deltas keyed by field name rather than three hardcoded ones.

### §8.6 requires the server to "stop at the first rejection and report the rest as unprocessed", and `_ack()` requeues that unprocessed tail at the **front** of `_pending`, after which `_flush()` immediately re-sends it (`_flush.call_deferred()`).

**Breaks because:** When the rejection cause persists — the common case, since §8.4 says a rejected collect is an energy race with another device that is still draining the pool — the next batch's head is rejected for the same reason, and only one action drains per round trip. 32 queued actions become 32 sequential HTTP requests. Combined with the no-keep-alive finding, that is 32 TLS handshakes over roughly 20 seconds, hammering the server precisely while it is telling the client to stop. There is no backoff on consecutive rejections anywhere in `Actions`.

**Fix:** Two guards. (1) On any rejection, drop the entire remaining `_inflight` tail of the same `kind` rather than requeuing it, then `Session.resync()` once — the server's snapshot is authoritative about what is affordable and re-deriving from it is cheaper and more correct than replaying. (2) Add a consecutive-rejection counter that gates `_flush` behind a growing delay (`0.5 s × 1.8^n`, capped at 10 s), reset on any batch that applies at least one action. Alternatively change the server contract so a batch processes *all* intents and returns a per-seq result array (applied / rejected+code) instead of `applied_through` + stop-at-first — that removes the tail concept entirely and is strictly simpler on both sides. If you do that, keep `applied_through` only as a monotonic watermark for the dedupe table.

### The `Session` idle-FPS throttle in §5.5 is one-way and the chosen value fights §8. `_idle += delta` is never reset, `Engine.max_fps` is never restored to 0, and `IDLE_FPS = 10` is asserted in §2's commentary.

**Breaks because:** 15 seconds after launch — before the player has finished reading the Collect list — the app drops to 10 fps and stays there for the rest of the session. At 10 fps, a touch is processed up to 100 ms after it lands and the punch/floater feedback appears up to 100 ms late. §8's entire premise ("tap → 0 frames of latency") is destroyed by the battery optimisation two sections earlier, and the 10 Hz projector plus `NumberLabel` tweens run at 10 fps so counters visibly step instead of rolling. Milestone 4's gate ("does the collect loop feel instant") fails for reasons nobody will connect to §5.5.

**Fix:** Make it two-way, event-driven, and less aggressive. In `Main`, override `_input(event)` (or `_unhandled_input`) and call `Session.note_activity()` on any `InputEventScreenTouch`/`InputEventMouseButton`, which sets `_idle = 0.0` and restores `Engine.max_fps = 0`. Raise `IDLE_FPS` to 24 (still ~80% of the ProMotion battery win, but input latency stays ≤42 ms). Suppress the throttle entirely while `Actions.pending_count() > 0` or a tween/reveal is active. Better still for an idle game: instead of `Engine.max_fps`, set `OS.low_processor_usage_mode = true` with `low_processor_usage_mode_sleep_usec`, which wakes on input rather than on a fixed clock.

### The passive-tax settlement contract is never stated, and `WalletStore` as written silently loses tax income during active play. `accrued_tax()` is computed from `tax_since_ms`, which `apply()` overwrites from every snapshot — including the partial snapshots §8.6 says accompany every action-batch ack, i.e. roughly every 200–600 ms while the player is tapping.

**Breaks because:** Unless the Go server folds accrued tax into `gold` and advances `tax_since_ms` on *every* snapshot it emits, each collect ack resets the accrual clock and the player's tax income is thrown away for the entire duration of an active session. Since Collect and tax are both gold sources in the stated hybrid model, this is a currency leak in the player's favour's opposite direction — they simply never receive the income the Family/Kingdom upgrades they paid for are supposed to produce, and it is invisible in testing because nobody watches a 0.3 gold/s trickle while tapping.

**Fix:** Write the invariant into the §8.6 contract explicitly: *every* snapshot's `wallet.gold` is settled through `wallet.tax_since_ms`, and `tax_since_ms` is always the server timestamp at which `gold` was computed. Add a client test with the injected `Clock`: apply a snapshot at t=0 with `tax_per_sec=1.0`, advance the fake clock 10 s, apply an action ack whose `gold` is `+10` and whose `tax_since_ms` is `t+10000`, and assert `display_gold()` moved by exactly `10 + collect_payout` — not `collect_payout`. Also decide now whether tax auto-settles or requires a claim (see missing coverage); the client shape differs.

### Economy: the collect ladder as carried into this design produces a dominant strategy of never leaving the first job. The brief's example is linear (Grapes 1 energy → 2 gold, Strawberries 2 → 4: a flat 2 gold per energy), and per-job milestone bonuses (+5/+10/+15% at 25/50/100) are permanent and job-local. §11's `CollectJobRow` and §5.3's `predict()` bake both in without comment.

**Breaks because:** Energy is the binding constraint (one pool, shared with Attack), so the only figure that matters is gold-per-energy. A fully mastered Grapes yields 2.30 gold/energy; a freshly unlocked Strawberries yields 2.00. Unlocking a higher job is a strict downgrade until you re-grind 100 collects, and since milestones cap at 100 (`next_milestone = 0` → `JOB_MASTERED`), the entire collect meta-progression is exhausted in a single sitting for a single job. The Collect tab — the game's primary gold source and primary verb — has no long-term progression at all, and level-gated unlocks read as punishments.

**Fix:** Two server-side table changes, no client change needed (this is the payoff of the resolved-payout contract, and it is worth saying so). (1) Make gold-per-energy superlinear in rung index: `energy_cost(n) = round(1.6^n)`, `gold(n) = round(2 * energy_cost(n) * 1.12^n)`. That is +12% gold/energy per rung, so a brand-new job beats a fully mastered previous job (+15%) after two rungs, and the ladder is a real ladder. (2) Replace the terminating 25/50/100 milestone table with an unbounded geometric one — 25/50/100/250/500/1k/2.5k/5k/10k/25k… at +5% each with a soft cap on the multiplier (e.g. `1 + 0.05 * ln(1 + milestones_hit)`), so mastery is a long tail rather than a 15-minute errand. The client already carries `next_milestone`/`next_milestone_bonus` and needs no release; retire the `JOB_MASTERED` string, which encodes the wrong assumption. Do this before milestone 4, because milestone 4 is where the loop is judged on a real phone.

### Economy: `attack` steals 3% of the defender's *current* gold with no cap, no floor, and no power-relative scaling, and the 30-minute shield triggers only on the defender's loss.

**Breaks because:** (a) The dominant defensive strategy is to hold zero gold — spend into upgrades/shop/soldiers the instant you have enough. Once players learn that (days, not weeks), the PvP economy self-extinguishes: attacks yield ~nothing, so the only reason to spend energy on Attack is kingdom reputation, and Attack stops being a gold source at all. (b) Before that, the dominant offensive strategy is to scan the opponent list for the fattest wallet; a whale who logs off with a large bank is a farm for every attacker who reaches them before the first loss triggers the shield — attacks are concurrent, so N attackers can all land before any shield exists. (c) It also interacts badly with §8: `display_gold()` can drop by 3% between snapshots while the player is mid-burst, and §8.5's "tween down over 350 ms with a red floater" will fire on a player who never opened the Attack tab.

**Fix:** Server-side, but it changes the AttackTab spec so decide it now. Steal = `min(0.03 * defender_gold, K * attacker_income_per_hour)` with K ≈ 0.5 — this caps whale-farming at something proportional to the attacker's own economy. Add a floor paid from a server-side raid pool (funded by a small tax on all gold generation) so attacking a zero-gold player still returns something, keeping Attack a live verb. Start the 30-minute shield on the defender's *first loss in a window* and make it also suppress concurrent in-flight attacks resolved after it starts. Client-side consequences to spec in §20 milestone 8: the opponent card must show the *expected* steal (server-computed, resolved, same contract as `gold_payout`) so players are not fishing blind, and the shield countdown needs the 1 Hz tick mechanism that does not currently exist (see below).

### §10.1's `ItemCard.bind()` calls `Palette.tier_frame(tier)`, which is `load("res://assets/ui/frame_%d.png" % ...)` — a string format plus a `ResourceLoader` lookup on every bind — directly violating §10.2's stated hard requirement that `bind()` be allocation-free with "no `load()`, no `instantiate()`", which `RecycleGrid` depends on. §10.2 lists the violation of this exact rule as a project risk.

**Breaks because:** Every row-boundary crossing in the inventory rebinds all ~15 pooled cells, so a fling through a 500-item inventory issues thousands of `load()` calls and `%`-format allocations. `load()` on a cached resource still takes the ResourceLoader lock and hashes the path. Combined with the unconditional `add_theme_color_override()` per bind (which invalidates the Label's theme cache and propagates `NOTIFICATION_THEME_CHANGED`), this is exactly the scroll stutter §10.2 warns about — and it will not reproduce in the editor.

**Fix:** Preload the seven frames into a static constant array in `Palette`: `const TIER_FRAMES := [preload("res://assets/ui/frame_0.png"), … preload("res://assets/ui/frame_6.png")]`, and make `tier_frame()` an index. Same treatment for `ItemArt` — it already caches `AtlasTexture`s, which is right. For the colour override, cache the last-bound tier on the card and skip `add_theme_color_override` when it is unchanged; or better, pre-create seven `LabelSettings` resources and assign `_name.label_settings`, which is a single property write with no theme invalidation.

### Atlas capacity does not add up. §12.2 specifies a single `items.png` at 2048² and `ItemArt`'s docstring says it replaces "400 separate PNGs". At §2.1's own "author art at 2×" rule a 128-unit icon is a 256 px source, so a 2048² page holds 64 icons — not 400. There is also no ASTC block-alignment or padding rule in `pack_atlas.py`, while §12.3 sets the item atlases to VRAM Compressed (ASTC 4×4 on iOS).

**Breaks because:** 400 icons at 256² needs ~6.5 pages of 2048², or ~1.6 pages at 4096² (which is above the safe mobile texture budget for a single UI atlas). `ItemArt.icon()` looks up a single `_sheet`, so as soon as the second page exists the whole class needs rewriting — after `ItemCard`, `RecycleGrid`, `SoldierCard` and `CollectJobRow` all depend on it. Separately, ASTC compresses in 4×4 blocks: if a packed region's origin or size is not a multiple of 4, neighbouring icons share compression blocks and bleed into each other, and bilinear filtering (`default_texture_filter=1`) samples across the seam. `AtlasTexture.filter_clip` clamps UVs but cannot undo a shared compression block.

**Fix:** Make `items.json` page-aware from day one: `{"sword_iron": {"page": 0, "rect": [x, y, w, h]}, …}` plus a `"pages": ["items_0.png", "items_1.png"]` list, and have `ItemArt` hold `_sheets: Array[Texture2D]`. It is five extra lines now and a refactor of six files later. In `pack_atlas.py`, snap every region origin and size up to a multiple of 4 and add ≥4 px of transparent (or edge-extended) padding between regions; assert the invariant and fail the pack if violated. Also reconcile §12.1's `--grid 6x6` at `--size 2K`: that yields 341 px cells, which is fine for a 128-unit icon but means one generated sheet ≠ one shipped atlas page — keep `art/sheets/` (generation grids) and `assets/atlas/` (packed pages) conceptually separate, which the repo layout already does.

### `CollectJobRow.punch()` and `refuse()` call `create_tween()` on every invocation with no `kill()` of the previous tween, and `punch()` animates `scale` rather than the 4.7 `offset_transform_scale` the same file uses for `refuse()`.

**Breaks because:** §8.1's target is five taps a second; `punch()` is 90 ms, so two or three tweens animate `scale` concurrently. Godot does not cancel prior tweens on the same property — the last one to finish wins, and if a tween is killed mid-flight by node reordering (`_rows_box.move_child` in `CollectTab.refresh()`) the row is left at `Vector2(0.965, 0.965)` permanently. Separately, a `Control`'s `scale` pivots at `pivot_offset`, which defaults to `(0, 0)` — so the row shrinks toward its top-left corner rather than its centre, which reads as a glitch rather than a press.

**Fix:** Hold the tween: `var _fx: Tween` and start each effect with `if _fx and _fx.is_valid(): _fx.kill()`. Use the 4.7 API the document already discovered (all seven `offset_transform_*` properties are confirmed present in this binary):
```gdscript
func punch() -> void:
    if _fx and _fx.is_valid(): _fx.kill()
    offset_transform_enabled = true
    offset_transform_pivot_ratio = Vector2(0.5, 0.5)
    _fx = create_tween()
    _fx.tween_property(self, "offset_transform_scale", Vector2(0.965, 0.965), 0.045)
    _fx.tween_property(self, "offset_transform_scale", Vector2.ONE, 0.045)
```
That pivots at the row centre and, unlike `scale`, is guaranteed not to feed back into the `VBoxContainer`'s layout — which is the reason §11 reached for `offset_transform_position` in `refuse()` in the first place.


## MINOR (9)

### §16's Android plan contains two factual errors. (a) It claims GABE "removes the SDK setup entirely" as an alternative to installing the Android SDK on this Mac. GABE is an on-device companion app distributed through Google Play and the Meta Horizon Store that lets the *Android editor* perform Gradle exports on an Android/XR device — it does nothing for a macOS desktop workflow, and this 4.7.2 binary still errors `A valid Java SDK path is required in Editor Settings.` (b) It specifies `min SDK 24`; Godot 4.7's system requirements list Android 9.0 (API 28) for the Forward+/Mobile renderers, and 7.0 (API 24) only for Compatibility.

**Breaks because:** (a) sends whoever does the Android port down a path that cannot work from this machine, and it is presented as a way to skip the JDK 17 + SDK install that the environment notes flag as missing. (b) produces a build that installs on Android 7/8 devices and then fails to initialise the `mobile` renderer — the Android mirror of the iOS A12 problem above.

**Fix:** Delete the GABE alternative from step 3, or re-scope it accurately: "GABE is only relevant if we ever want to export from an Android device; it does not replace the desktop SDK." Set `gradle_build/min_sdk=28` and `target_sdk=35`. Keep the JDK 17 requirement (correct) and the frame-pacing setting (`display/window/frame_pacing/android/enable_frame_pacing` confirmed present).

### §19's CI line `godot --headless --path client --rendering-method gl_compatibility res://tests/TestRunner.tscn` is claimed to "keep that path honest" for the future web build. `--headless` is defined in this binary as `--display-driver headless --audio-driver Dummy`, and the headless display server runs `RasterizerDummy`.

**Breaks because:** No shaders are compiled and no rasterizer code runs, so the job cannot detect any GL-compatibility divergence. It is a green check that means nothing, which is worse than no check — it will be cited as coverage the first time a web build breaks.

**Fix:** Delete the line. If web ever becomes real, validate it the only way that works: an actual web export loaded in a headless Chromium (Playwright) with console errors treated as failures, or a Linux CI runner with `xvfb-run` and a software GL (`LIBGL_ALWAYS_SOFTWARE=1`) running the non-headless binary. Until then, note in §2.2 that the GL path is unvalidated and that `rendering_method.web` is a placeholder, which is honest and costs nothing.

### §19's `FakeTransport` does not implement `cancel(pending)`, but `Api.cancel_tag()` calls `_tp.cancel(p)` unconditionally.

**Breaks because:** Test 7 (`test_cancel_wakes_the_awaiting_coroutine`) — the test that guards the §21 trap the design is proudest of catching — crashes with `Invalid call. Nonexistent function 'cancel' in base 'Node (fake_transport.gd)'` instead of asserting anything.

**Fix:** Add to `FakeTransport`:
```gdscript
func cancel(pending) -> void:
    if pending.state == HttpTransport.Pending.State.FINISHED: return
    pending.finish(ApiResult.failure(ApiError.new(ApiError.Kind.CANCELLED)))
```
Better: extract the transport surface into an `@abstract class_name Transport extends Node` with `@abstract func send(...)` and `@abstract func cancel(...)` (the `@abstract` annotation is confirmed available on both classes and functions in 4.7.2), and have both `HttpTransport` and `FakeTransport` extend it. Then `Api._tp` can be typed `Transport` instead of untyped — which also removes one of the ~8 `untyped_declaration` warnings the design's own strict-warnings policy would flag on day one.

### `GameState.apply_snapshot()` clears `stale` on the first snapshot of any kind, including the partial `state` blob that §8.6 attaches to every action-batch ack.

**Breaks because:** The boot sequence paints `cache/snapshot.json` with `stale = true` (dimmed numbers, skeleton rows). If the first thing that lands is an action ack carrying only `wallet`/`energy`/`jobs`/`player`, `stale` clears and the Inventory, Shop, Soldiers and Kingdom tabs immediately present day-old disk cache as live truth — including a shop roll that expired and prices that may have changed. §13's promise that "nothing on disk is trusted as gameplay truth" is broken by the fast path.

**Fix:** Have the server mark full snapshots: `{"full": true, …}`, and gate the clear on it — `if stale and bool(s.get("full", false)):`. Keep per-domain freshness too: give `Store` a `stamped_ms` field set in `apply()`, and let `TabPage.tab_shown()` re-fetch when its domain's stamp is older than a per-domain TTL (shop 30 s, opponents 60 s, inventory 5 min). That also subsumes the ad-hoc "server-fed lists re-fetch in `tab_shown()`" rule in §4.3, which is currently discipline rather than mechanism.

### §9.5 styles the active tab via the `pressed` stylebox on the `TabButton` variation (`t.set_stylebox("pressed", "TabButton", box("tab_active", 16, 6))`), but nothing sets `toggle_mode = true` or groups the six buttons.

**Breaks because:** On a plain `Button`, `pressed` is shown only while the finger is down. The active-tab indicator flashes during the tap and vanishes — the tab bar never shows which tab you are on, which for a six-tab app is the single most important piece of persistent state in the UI.

**Fix:** Make the six tab buttons `toggle_mode = true`, put them in a shared `ButtonGroup`, and have `TabHost.tab_changed` set `button_pressed` on the matching one. Then also style `hover_pressed` (otherwise the active tab loses its background on hover, which matters on desktop later) and set `focus` to the same box as `pressed` so §17's focus navigation does not double-highlight.

### Optimistic XP can cross a level boundary with no handling. `display_xp()` adds `Actions.xp_delta()` to `player.xp`, but level, `xp_next`, granted stat points and `energy_max` are all confirmed-only, and `display_energy()` clamps to the stale `energy.energy_max`.

**Breaks because:** A burst of collects that levels the player up shows the XP bar in the `CurrencyBar` filling past 100% (or clamping at full and sitting there) while the level pip does not move, for the whole batch round trip. When the ack lands, the level jumps, XP snaps back to near zero, and the "you gained a stat point" moment — the main reason to care about XP — arrives ~600 ms late and unannounced. If the level-up raised `energy_max`, `display_energy()` was clamping to the old maximum, so regen appeared to stall.

**Fix:** Clamp the prediction at the boundary and let the confirmation carry the celebration: `display_xp()` returns `mini(player.xp + Actions.xp_delta(), player.xp_next - 1)`. Have `GameState` emit a `leveled_up(new_level, points_granted)` signal when a snapshot raises `player.level`, and let `CurrencyBar` play the fill-to-full → burst → reset sequence off that. Recompute `display_energy()`'s clamp from the snapshot's `energy_max`, which the level-up snapshot will already carry.

### `GameState.domains()` constructs a fresh 8-entry `Dictionary` on every call, and `apply_snapshot()` calls it once for the loop plus once per matched key.

**Breaks because:** With §8.6's partial snapshot on every action ack, `apply_snapshot()` runs every 200–600 ms during a tapping burst, allocating 5–9 dictionaries each time for no reason. It is small, but it is in the hottest path in the game and it is free to fix.

**Fix:** Build the map once in `_ready()` into a `var _domains: Dictionary` and return that (or iterate it directly). Type it `Dictionary[String, Store]` — typed dictionaries are available in 4.7 and would also satisfy the `untyped_declaration` policy §2 argues for.

### Several smaller self-contradictions and dead configuration: §5.1 states "exactly two nodes in the game run `_process`" while §10.1's `ItemCard` uses `_process` for long-press detection; `gui/timers/tooltip_delay_sec=0.0` makes tooltips *instant* rather than disabled (on a touch UI with `emulate_mouse_from_touch=true` this can surface tooltips on press); `exclude_filter="tests/*, tools/*, art/*"` lists `tools/` and `art/`, which per §1's layout live outside `client/` and are therefore not in `res://` at all; `Api`'s `opts` dictionary has no way to pass request headers, so §13's `cache/catalog.etag` can never be sent as `If-None-Match`; and `settings.cfg` persists `reduced_motion` which nothing in the design consumes, though §9.4 makes mystic "the only tier in the game that animates".

**Breaks because:** None is individually severe, but each is a place where a stated rule and the code disagree, which is how a codebase stops being reviewable — and §9's whole justification for a code-built theme was reviewability.

**Fix:** Replace `ItemCard`'s `_process` with a one-shot `SceneTreeTimer` or a `Timer` child started on press and cancelled on release, and amend §5.1 to "no `_process` in `res://ui/` outside `NumberLabel`". Set `tooltip_delay_sec` high (e.g. `9999.0`) or leave it default. Trim the export `exclude_filter` to `tests/*` and note that `art/`/`tools/` are excluded by living outside the project. Add `opts.headers: PackedStringArray` to `Api._call` and merge it after the built-ins, then wire the catalog ETag. Have `Ui` read `reduced_motion` and expose `Ui.motion_scale: float` (0.0 or 1.0) that `TierFrame`'s shimmer, `Floater`, `punch()` and `NumberLabel.seconds` all multiply by.

### Over-engineering that will slow milestone 2 without buying anything: the 5-node `HTTPRequest` pool with a reserved lane and the `_lease`/`_slot_released` handshake; and `Store.edit()/commit()`'s re-entrancy depth counter, whose only caller is `apply()` and which always runs the exact sequence `edit() → touch() → commit()`.

**Breaks because:** The pool is the source of the cancel-hang blocker above and, per the keep-alive finding, is the wrong abstraction entirely — it multiplies TLS handshakes rather than amortising them. A thin client with two lanes has at most 2–3 requests in flight; the pool solves a contention problem that does not exist while creating a scheduling problem that does. The depth counter is ~15 lines and a state variable of dead generality that a reviewer must nonetheless reason about on every store.

**Fix:** Collapse `HttpTransport` to two persistent `HTTPClient` connections (action lane, general lane) as described above; the `Pending` wrapper and `ApiResult` surface stay, `_lease`/`_release`/`_slot_released`/`GENERAL_SLOTS` all disappear. For `Store`, replace `edit/commit/touch` with a single `func apply(s: Dictionary) -> void` that ends in `changed.emit()`, and drop `touch()` — nothing in the design mutates a store field outside `apply()`, which is precisely the invariant §5.1 rule 3 is enforcing. If a batched-edit case ever appears, add it then.


## Missing coverage

- **IAP / diamonds — entirely absent.** The brief makes Diamonds a real-money hard currency spent on energy refills, protection shields, shop rerolls and premium packs. The client architecture has `WalletStore.diamonds` and a `CurrencyBar` slot and nothing else: no `Billing` autoload, no StoreKit plugin decision, no purchase state machine (product fetch → purchase → server receipt validation → grant → restore), no lane assignment for diamond spends, and no mention in the §20 build order. Godot 4.7 ships no first-party IAP; you need a GDExtension/iOS plugin (StoreKit 2 wrappers exist as third-party assets and must be built and vendored), which affects `export_presets.cfg`, the Xcode-project workflow and the CI. Notably the reference project this design cites, `/Users/yigitkarabulut/Developer/GameTest/client/project.godot`, already autoloads `Billing` and `Ads` — the precedent was on disk and was not carried across. Decide the plugin now (it is a native dependency and therefore a schedule risk), and define the server contract: `POST /v1/iap/verify {platform, product_id, receipt}` → grant + fresh snapshot, idempotent on the transaction id, with Apple App Store Server API v2 verification server-side and a two-provider shape from day one.
- **Local/push notifications — mentioned only as a disabled export flag, and via a key that does not exist.** For an idle game the retention loop is "energy is full", "your 8-hour offline cap is reached", "your shield expires in 5 minutes". Godot has no built-in local-notification API, so this is a second native plugin decision, and it must be made before the export config is frozen (`entitlements/push_notifications` is the real key in 4.7.2; `capabilities/push_notifications` in the preset does nothing). Also missing: the App Store privacy manifest entries and the `NSUserNotificationsUsageDescription`-adjacent Info.plist work, which §20 milestone 10 gestures at in three words.
- **The offline-tax "welcome back" moment.** The hybrid idle model with an 8-hour cap is one of the brief's headline decisions, and the entire client design for it is `WalletStore.accrued_tax()`. There is no resume flow (what happens on `NOTIFICATION_APPLICATION_RESUMED` after 8 hours: resync, then what?), no claim/reveal modal, no component in §10, no milestone in §20, and no decision on whether tax auto-settles or is claimed. In the genre this modal is the single highest-value retention *and* monetisation surface ("double your offline earnings"). It also determines the `WalletStore` shape: auto-settle needs `tax_since_ms`; claim needs a separate `tax_bank` field the client never zeroes itself.
- **Server-time countdowns have no delivery mechanism.** Shop refresh (5 min), attack shield (30 min), energy-full ETA, and kingdom cooldowns all need a ~1 Hz tick driven by `Clock.now_ms()`. §5.1 forbids `_process` in `res://ui/` outside `NumberLabel`, and `Session.projected(gold, energy)` carries only the two currency values. So as designed there is no legal way to draw a ticking timer. Add `Session.tick_1hz` (or a `CountdownLabel` component that subscribes to it and formats with `Fmt.duration`), and specify that expiry is always recomputed from `Clock.now_ms()` versus a server `expires_at_ms`, never from a local countdown that drifts across a background/foreground cycle.
- **Lane B's response envelope is unspecified.** §8.6 defines `POST /v1/actions` precisely and then leaves every lane-B endpoint (`recruit_soldier`, `buy_slot`, `buy_shop_item`, `attack`, `buy_upgrade`, `found_kingdom`) with no contract. They must all carry `now_ms` (the whole projection layer depends on it per §6.4) and a partial snapshot of every domain they touch — `buy_upgrade` in particular changes `jobs.gold_payout`, so without a `jobs` snapshot in the response the Collect tab silently shows pre-upgrade payouts until the next resync, and §8's "prediction is a table lookup" quietly becomes wrong. They also need idempotency keys: a retried `buy_shop_item` on a flaky network must not charge twice, and unlike `/v1/actions` no key is specified.
- **Authentication and the account model.** §13 stores and encrypts tokens; nothing designs how they are obtained. There is no login flow, no first-run device-bootstrap, no Sign in with Apple (which Apple requires if any other third-party login is offered, and which the design's own risk list names but never specs), no account recovery, and no logout. `Api.auth_lost` is emitted and nothing is documented as handling it. This is milestone-2 work that the milestone table does not contain.
- **`Session.resync()` is called from four places (`Api._heartbeat`, `Actions._fail`, `CollectTab.tab_shown`, the offline-recovery path) and never defined.** Full or partial? Does it debounce — `_heartbeat` and `_fail` can both fire within a frame? Does it show `BlockingSpinner`? Does it clear `stale` first? It is load-bearing for the correctness story and it is a hole.
- **Pagination.** The attack opponent list, the kingdom member roster, the kingdom reputation leaderboard, and a late-game inventory all need cursors. `Api.get_json(path, query, opts)` has no cursor plumbing, `RecycleGrid.set_data()` takes a complete `Array` and recomputes total height from `_data.size()`, and there is no loading-sentinel row. Retrofitting incremental loading into `RecycleGrid` after `InventoryTab` and `AttackTab` are built means rewriting `_relayout`/`_sync`. Add now: `set_data(rows, total_count)` with an unknown-tail mode, and a `needs_page(next_index)` signal fired when the pool approaches the end of loaded data.
- **The Kingdom system is one table cell.** The brief makes it a full pillar — founding for a large gold sum, invites, member list with attack-immunity rules, its own upgrade tree benefiting all members, per-attack reputation accrual, and a cross-kingdom leaderboard. §20 milestone 8 gives it four words alongside all of Attack. `KingdomStore` is listed and never shown. At minimum, spec the store shape and the four screens (summary card on Family, member roster, upgrade tree, leaderboard) before estimating, because the leaderboard is the only place pagination, server-time ranking and a non-player-owned data set meet.
- **No telemetry or crash/log egress.** `Log` maintains a 200-event ring buffer "for crash reports" and `user://logs/client.log` exists, but nothing uploads either, and there is no crash reporter integration (which on iOS means either a native plugin or accepting Xcode Organizer only). For a server-authoritative economy you also want client-side funnel events (tap → batch → ack latency, rejection codes by frequency) — the `reconciled`/`rejected` signals are the natural hooks and are currently emitted to nobody. Decide whether v1 ships blind; if it does, say so explicitly rather than implying `Log` covers it.

## Corrected recommendations

## What is genuinely sound — verified, not conceded

Before the corrections, these hold up and should not be reworked:

- **`offset_transform_*` on `Control` is real in 4.7.2.** All seven properties (`offset_transform_enabled/position/position_ratio/rotation/scale/pivot/pivot_ratio/visual_only`) are in `/Applications/Godot.app/Contents/MacOS/Godot`. Using it to shake a row inside a `VBoxContainer` is correct and is the right tool.
- **`debug/gdscript/warnings/directory_rules` is real and new**, and the `res://`-prefix rule the doc implies is enforced by the engine (`Paths in the project setting "debug/gdscript/warnings/directory_rules" keys must start with the "res://" prefix.`).
- **Every project-setting key in §2 except none exists**: `application/run/max_fps`, `application/config/quit_on_go_back`, `display/window/size/window_width_override`, `display/window/ios/{hide_home_indicator,hide_status_bar,suppress_ui_gesture,allow_high_refresh_rate}`, `display/window/stretch/scale_mode`, `gui/fonts/dynamic_fonts/use_oversampling`, `gui/common/default_scroll_deadzone`, `rendering/renderer/rendering_method.{mobile,web}`, `rendering/textures/vram_compression/import_etc2_astc`, `internationalization/pseudolocalization/{override,expansion_ratio}`. `audio/general/ios/session_category` has hint order `Ambient,Multi Route,Play and Record,Playback,Record,Solo Ambient`, so `0` is Ambient — the reasoning about the silent switch and mixing is right. `display/window/handheld/orientation=1` is Portrait.
- **Web is WebGL2-only in 4.7**; no WebGPU. The `rendering_method.web="gl_compatibility"` override is indeed forced, not chosen.
- **`cancel_request()` really does not emit `request_completed`**, and the `Pending` wrapper is the right shape for it (it just needs the queued-state fix).
- **The safe-area ratio conversion is correct.** On iOS both `DisplayServer.screen_get_size()` and `get_display_safe_area()` are in physical pixels, and `get_viewport_rect().size` is in stretch units, so the fractions cancel. The `OS.has_feature("mobile")` guard against the desktop `screen_get_usable_rect()` fallback is a real bug avoided.
- **`targeted_device_family=0` = iPhone** (hint `iPhone,iPad,iPhone & iPad`) and **`export_method` `0`=App Store / `1`=Development** (hint `App Store,Development,Ad-Hoc,Enterprise`). `icon_interpolation=4` = Lanczos. `storyboard/image_scale_mode` hint is `Same as Logo,Center,Scale to Fit,Scale to Fill,Scale`.
- **`@abstract` syntax is right**, on both classes and functions (`A function must either have a ":" followed by a body, or be marked as "@abstract".`).
- **`xcrun devicectl` one-click deploy is in the binary.** Only `4.7.2.stable/ios.zip` is installed, exactly as claimed.
- **Every godogen fact checks out**: `--model` defaults to `grok`; `GEMINI_MODEL = "gemini-3.1-flash-image-preview"` is hardcoded at `asset_gen.py:72`; `requirements.txt` pins `onnxruntime-gpu` and `nvidia-cudnn-cu12==9.*`; and `rembg_matting.py:312` references `bg_color`, which is local to `remove_background()` at line 169 — a genuine `NameError` in the single-image `--preview` path. `grid_slice.py` does accept arbitrary `--grid` and `--names`.
- **The viewport table is arithmetically correct** (SE3 → 1281, iPhone 15/16 → 1561, 16 Pro Max → 1564, iPad 10.9 → 1036), as is the 1 pt = 1.832 unit conversion and the 88-unit touch target.
- **`NumberLabel`'s exponential approach is frame-rate independent** and correctly parenthesised.
- **The three load-bearing architectural decisions are right and should be kept**: display = `confirmed + replay(pending)` with no accumulator; server-resolved payouts rather than client-side formula evaluation; and pessimistic milestone prediction so corrections are always positive. Those three are the reason the rest is worth fixing rather than replacing.

---

## Corrections, in the order they must be applied

### A. Before anything compiles (milestone 1–2, half a day)

1. **`Fmt` / `Palette`: replace `tr()` with `TranslationServer.translate()`** in all four static functions, and cache `SEP_THOUSANDS` + `UNIT_0..7` in a static array refreshed on locale change rather than looking them up inside `NumberLabel._paint()` at 120 Hz.
2. **Fix the six integer divisions** (`Clock.observe`, `Api._ensure_token`, `RecycleGrid._sync`, three in `Fmt.duration`) using `/ 2.0`, `/ 1000.0`, `floori(float(a) / float(b))`. Keep `integer_division=2`.
3. **`TabHost.open`: `Api.cancel_tag(current)`**, not `id`.
4. **Replace both `_inflight + _pending` sites** with `assign()` + `append_array()`.

### B. Transport rework (milestone 2, ~1.5 days — do it before any UI depends on it)

`HTTPRequest` cannot keep a connection alive. Rebuild `HttpTransport` on two persistent `HTTPClient` instances behind the same `Pending`/`ApiResult` surface, so §6.3 and everything above it is unchanged:

```gdscript
class_name HttpTransport
extends Node

## Two persistent HTTPClient lanes. HTTPRequest reconnects (and re-TLS-handshakes)
## on every call, which on cellular costs 2 extra RTT per batch — unacceptable for
## a design whose whole thesis is latency.

class Lane extends RefCounted:
    var client := HTTPClient.new()
    var host := ""
    var port := 443
    var busy: Pending = null
    var buf := PackedByteArray()

var _action: Lane
var _general: Lane
var _queue: Array = []            ## Pending waiting for the general lane

func _process(_d: float) -> void:
    _pump(_action)
    _pump(_general)
```

Rules: connect once per lane (`connect_to_host` + poll to `STATUS_CONNECTED`); issue `request()`; poll to `STATUS_BODY` accumulating `read_response_body_chunk()`; only reconnect on `STATUS_DISCONNECTED`/`STATUS_CONNECTION_ERROR` or a `Connection: close` response header; cancellation is `client.close()` + immediate `pending.finish(CANCELLED)`, which is instant and cannot hang. `GENERAL_SLOTS`, `_lease`, `_release` and `_slot_released` all disappear along with the blocker they caused.

If the schedule cannot absorb this in milestone 2, keep `HTTPRequest`, apply the one-line `_slot_released.emit()` in `cancel()`, and **re-cost §8**: batch RTT is ~600 ms not 200 ms, so raise `COALESCE` to `0.20` (more taps per handshake is now strictly better) and rewrite §8.5's "20 taps in 3 s → 3–4 HTTP requests, one per RTT" to match reality. Put the `HTTPClient` rework on the roadmap before soft launch.

### C. Action-queue correctness (milestone 4)

- Move `spend_stat_point` to **lane B**. Lane A has one verb: `collect`.
- Add `Actions.reserve(energy, gold) -> int` / `release(handle)` and include reservations in `energy_delta()` / `gold_delta()`. Every lane-B call site wraps itself.
- Change the rejection contract: the server processes **all** intents in the batch and returns `results: [{seq, ok, code}]` rather than `applied_through` + stop-at-first. Keep `applied_through` only as a monotonic dedupe watermark. This removes the "unprocessed tail" concept and with it the 32-round-trip amplification. If the stop-at-first shape must stay, then on any rejection drop the whole remaining `_inflight` and `Session.resync()` once, and gate `_flush` behind `0.5 * 1.8^n` backoff on consecutive all-rejected batches.
- Clamp `display_xp()` to `player.xp_next - 1`; add a `GameState.leveled_up(new_level, points)` signal and drive the celebration off the confirmation.
- Persist nothing of `_pending` for now, but **document** that an app kill while offline discards queued taps, and make the offline banner say so. If you later persist the queue, persist `_session_id` with it or the idempotency keys are meaningless.

### D. Server contract additions (agree with the Go design before milestone 4)

Add to §8.6, all non-negotiable because the client's projection layer depends on them:

- Every 2xx body is an object with `now_ms` — **including all lane-B endpoints**, which currently have no contract at all.
- Every snapshot's `wallet.gold` is **settled through** `wallet.tax_since_ms`. Write the invariant down and test it with the injected `Clock`.
- Full snapshots carry `"full": true`; `GameState.stale` only clears on those.
- Every lane-B endpoint accepts an `Idempotency-Key` and dedupes on it for 24 h, returning the original response on replay — same rule as `/v1/actions`.
- Refresh-token rotation keeps the previous token valid for a 60 s grace window and returns the same new pair on repeat presentation; reuse after the window revokes the family.
- `buy_upgrade` responses include a `jobs` snapshot, or resolved payouts silently go stale.

### E. iOS export (fix before the first TestFlight, not at milestone 10)

- `application/min_ios_version="16.0"` **and** `capabilities/performance_a12=true`. Godot 4.7 requires iOS 16 for Metal and A12 for Forward+/Mobile.
- Pin `rendering/rendering_device/driver.ios="metal"` in `project.godot`; document `"vulkan"` as the one-line rollback.
- Regenerate `export_presets.cfg` from the 4.7.2 editor. Remove `storyboard/use_launch_screen_storyboard`, `application/launch_screens_interpolation`, `application/generate_simulator_library_if_missing`, `icons/spotlight_40x40`, `capabilities/push_notifications`. Add `icons/icon_1024x1024`, `_dark`, `_tinted`, `icons/ios_128x128/136x136/192x192`, `icons/notification_76x76/114x114`, `application/liquid_glass_icon`, `application/app_category`, and the `provisioning_profile_*` fields for the release preset.
- Drop the "every field confirmed to exist in *this* build" claim from the document header.

### F. Palette (before milestone 5, when real art is generated against it)

Split colour roles and add a test. Measured on the doc's own `BG #0E0B09`:

| tier | swatch | vs bg | verdict |
|---|---|---|---|
| common `#9AA3AD` | | 7.68:1 | ok |
| uncommon `#4FBF63` | | 8.37:1 | ok |
| rare `#3D8BFD` | | 5.89:1 | ok |
| epic `#A855F7` | | 4.96:1 | ok, but **1.19:1 vs rare** |
| legendary `#F2B31C` | | 10.50:1 | ok |
| **mystic `#6D28D9`** | | **2.76:1** | **fails AA text and the 3:1 UI floor** |
| special `#E5484D` | | 5.01:1 | ok |

Introduce `TIER_TEXT` alongside `TIER_COLOR`. Mystic's text/identity colour becomes `#E879F9` (7.97:1); `#6D28D9` stays as fill/frame only. Lift epic toward `#C79BFF` (or darken rare) so rare↔epic clears 3:1. Then add `tests/suites/palette_test.gd` that computes WCAG contrast for every tier against `Palette.BG` (≥4.5:1) and against every other tier (≥3:1) and fails the build — this converts §9.4's "needs the owner's sign-off" from an open question into a checkable constraint the owner can sign off against.

### G. Economy (server tables only — no client release, which is the payoff of the resolved-payout contract; agree before milestone 4)

1. **Superlinear ladder**: `energy_cost(n) = round(1.6^n)`, `gold(n) = round(2 * energy_cost(n) * 1.12^n)`. A new rung beats a fully mastered previous rung after two steps, so unlocking is a reward rather than a downgrade.
2. **Unbounded milestones**: 25/50/100/250/500/1k/2.5k/5k/10k/25k… at +5% each with a soft cap (`1 + 0.05 * ln(1 + hits)`). The client already carries `next_milestone`/`next_milestone_bonus`; retire the `JOB_MASTERED` string.
3. **Attack**: steal `= min(0.03 * defender_gold, 0.5 * attacker_income_per_hour)`, plus a floor from a server-funded raid pool so zero-gold targets still pay something. Shield starts on the defender's first loss in a window and suppresses attacks resolved after it starts. The opponent card must display the **server-resolved expected steal**, same contract shape as `gold_payout`.
4. **Decide and write down**: collect is deterministic (no crits, no drops) forever; and passive tax auto-settles into `gold` on every snapshot versus accrues into a claimable `tax_bank`. The second determines whether you get a "welcome back" modal, which is the genre's highest-value retention surface and is currently missing entirely.

### H. Revised build order

Insert into §20 rather than appending:

| # | change |
|---|---|
| 2 | Transport rework (§B) lands here, **before** any UI depends on it. Add auth/login flow — currently absent. |
| 3 | `Session.resync()` specified; `stale` gated on `"full"`; per-domain `stamped_ms` TTLs. |
| **3.5 (new)** | **Resume flow + offline-tax claim modal.** This is the hybrid idle model's core moment and it is a milestone, not polish. |
| 4 | Gate unchanged and correct — but add tests for tax-across-acks and lane-B energy reservation. |
| 6 | `RecycleGrid` gains page-aware `set_data(rows, total_count)` + `needs_page` from the start. |
| **7.5 (new)** | **IAP**: StoreKit plugin vendored, `Billing` autoload, `POST /v1/iap/verify` with App Store Server API v2 validation. Native dependency ⇒ start the spike at milestone 2, not milestone 8. |
| **9.5 (new)** | **Local notifications** (energy full / offline cap / shield expiry). Second native plugin; the export config must be frozen with `entitlements/push_notifications` before milestone 10. |

The gate stays milestone 4, and it is the right gate — but it should now be judged against a realistic ~600 ms batch RTT (or against the reworked `HTTPClient` transport), not the 200 ms the document assumes.

---

## Sources

- [Godot 4.7 system requirements](https://docs.godotengine.org/en/4.7/about/system_requirements.html) — iOS 16.0 for Metal, iOS 15.0 for Vulkan, Apple A12 for Forward+/Mobile, Android 9.0 for Forward+/Mobile
- [HTTPRequest — Godot Engine documentation](https://docs.godotengine.org/en/stable/classes/class_httprequest.html) and [HTTPClient](https://docs.godotengine.org/en/4.4/classes/class_httpclient.html) — connection reuse requires `HTTPClient`
- [Typed arrays aren't working with `+=` · godotengine/godot#72948](https://github.com/godotengine/godot/issues/72948) — array `+` returns untyped `Array`
- [Creating games entirely on Android! – Godot Engine](https://godotengine.org/article/gabe-stable-release/) — GABE is an on-device companion app
- [Exporting for the Web — Godot 4.7](https://docs.godotengine.org/en/4.7/tutorials/export/exporting_for_web.html) — WebGL2 only
- [godot-store-kit (StoreKit 2)](https://github.com/atlasapplications/godot-store-kit) and [godot-ios-plugins InAppStore](https://github.com/godot-sdk-integrations/godot-ios-plugins/blob/master/plugins/inappstore/README.md) — third-party IAP options
- Local verification: `/Applications/Godot.app/Contents/MacOS/Godot` (4.7.2.stable.official.ed1daf0bf) symbol/setting extraction; `/Users/yigitkarabulut/Developer/GameTest/client/export_presets.cfg` (source of the stale preset keys); `/Users/yigitkarabulut/Developer/godogen-src/asset-gen/tools/{asset_gen.py,rembg_matting.py,grid_slice.py}`; `~/Library/Application Support/Godot/export_templates/4.7.2.stable/` (only `ios.zip`)