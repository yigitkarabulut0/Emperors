#!/usr/bin/env python3
"""Apply Emperors' patches to the vendored godogen asset-gen skill.

Idempotent: re-running after scripts/vendor-asset-gen.sh is safe.

1. Lazy `xai_sdk` import — we have no XAI_API_KEY, and a top-level import makes
   every Gemini call fail before it starts.
2. `--model` defaults to gemini (grok is unusable for us) and a new
   `--gemini-model` flag selects Nano Banana Pro for hero refs vs flash for bulk.
3. requirements.txt without onnxruntime-gpu / nvidia-cudnn (no Apple Silicon wheels).
4. rembg_matting.py:312 NameError — `bg_color` was never bound in main().
"""
import pathlib, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
T = ROOT / ".claude/skills/asset-gen/tools"
changed = []

def sub(path, old, new, label, marker=None):
    p = T / path
    s = p.read_text()
    if (marker or new) in s:
        print(f"  = {label} (already applied)"); return
    if old not in s:
        print(f"  ! {label}: anchor not found — MANUAL REVIEW", file=sys.stderr); return
    p.write_text(s.replace(old, new, 1))
    changed.append(label); print(f"  + {label}")

# --- 1. lazy xai import -------------------------------------------------------
sub("asset_gen.py", "import requests\nimport xai_sdk\nfrom google import genai",
    "import requests\nfrom google import genai", "lazy xai: drop top-level import")
s = (T/"asset_gen.py").read_text()
if "import xai_sdk  # lazy" not in s:
    s = s.replace("        client = xai_sdk.Client()",
                  "        import xai_sdk  # lazy: only needed for the Grok backend\n        client = xai_sdk.Client()")
    (T/"asset_gen.py").write_text(s); changed.append("lazy xai: import at call sites"); print("  + lazy xai: import at call sites")
else:
    print("  = lazy xai: import at call sites")

# --- 2. gemini default + model selector ---------------------------------------
sub("asset_gen.py",
    'GEMINI_MODEL = "gemini-3.1-flash-image-preview"',
    'GEMINI_MODEL = "gemini-3.1-flash-image"          # "Nano Banana 2" — bulk sheets\n'
    'GEMINI_MODEL_PRO = "gemini-3-pro-image"          # "Nano Banana Pro" — hero style refs\n'
    'GEMINI_MODELS = {"flash": GEMINI_MODEL, "pro": GEMINI_MODEL_PRO}',
    "gemini: add pro model")
sub("asset_gen.py",
    "    response = client.models.generate_content(\n        model=GEMINI_MODEL,",
    "    response = client.models.generate_content(\n"
    "        model=GEMINI_MODELS[getattr(args, 'gemini_model', 'flash')],",
    "gemini: honour --gemini-model")
sub("asset_gen.py",
    '''p_img.add_argument("--model", choices=["gemini", "grok"], default="grok",
                       help="Backend: grok (2¢, fast, simple images) or gemini (5-15¢, precise prompt following). Default: grok.")''',
    '''p_img.add_argument("--model", choices=["gemini", "grok"], default="gemini",
                       help="Backend: gemini (5-15¢, precise) or grok (2¢, imprecise). Default: gemini (Emperors has no XAI key).")
    p_img.add_argument("--gemini-model", choices=["flash", "pro"], default="flash",
                       help="Gemini image model: flash (Nano Banana 2, bulk sheets) or pro (Nano Banana Pro, hero style refs). Default: flash.")''',
    "gemini: default backend + --gemini-model flag")

# --- 2b. accurate per-model cost table ----------------------------------------
# Verified against ai.google.dev/gemini-api/docs/pricing on 2026-09-04:
#   gemini-3.1-flash-image  0.5K $0.045 | 1K $0.067 | 2K $0.101 | 4K $0.151
#   gemini-3-pro-image      1K/2K $0.134 | 4K $0.24
sub("asset_gen.py",
    'GEMINI_COSTS = {"512": 5, "1K": 7, "2K": 10, "4K": 15}',
    'GEMINI_COSTS = {"512": 5, "1K": 7, "2K": 10, "4K": 15}          # flash, cents\n'
    'GEMINI_PRO_COSTS = {"512": 13, "1K": 13, "2K": 13, "4K": 24}    # pro, cents',
    "gemini: pro cost table")
sub("asset_gen.py",
    "        cost = GEMINI_COSTS[size]",
    "        cost = (GEMINI_PRO_COSTS if getattr(args, 'gemini_model', 'flash') == 'pro'\n"
    "                else GEMINI_COSTS)[size]",
    "gemini: charge pro rates when --gemini-model pro")

# --- 3. requirements without CUDA ---------------------------------------------
req = T / "requirements.txt"
want = "google-genai\nrequests\nnumpy\npillow\nrembg\nonnxruntime\n"
if req.read_text() != want:
    req.write_text(want); changed.append("requirements: CPU-only, no xai/pymatting"); print("  + requirements: CPU-only, no xai/pymatting")
else:
    print("  = requirements")

# --- 4. rembg bg_color NameError ----------------------------------------------
sub("rembg_matting.py",
    """    # Process
    out = remove_background(img, img_pil, regime=args.mode,
                            bg_thresh=args.bg_thresh, fg_thresh=args.fg_thresh)""",
    """    # Process
    # Sample the background colour here so the QA preview can reuse it; passing it
    # in as an override also avoids sampling twice. (Upstream bug: `bg_color` was a
    # local inside remove_background(), so the --preview branch raised NameError.)
    bg_color = sample_bg_color(img)
    out = remove_background(img, img_pil, regime=args.mode,
                            bg_thresh=args.bg_thresh, fg_thresh=args.fg_thresh,
                            bg_color_override=bg_color)""",
    "rembg: fix --preview NameError",
    marker="bg_color = sample_bg_color(img)")

# --- 5. alpha floor -----------------------------------------------------------
# Background pixels keep their computed alpha_color no matter what --bg-thresh is
# set to, so a generated background that is not perfectly uniform leaves a
# low-alpha haze across the whole frame — a visible square halo on a dark game
# panel. --bg-thresh cannot fix this: it reclassifies pixels, it never zeroes
# them. An explicit floor does.
sub("rembg_matting.py",
    "    alpha[alpha < 0.01] = 0.0",
    "    alpha[alpha < args_alpha_floor] = 0.0",
    "rembg: alpha floor (kill background haze)")
sub("rembg_matting.py",
    "                      bg_color_override: np.ndarray | None = None) -> np.ndarray:",
    "                      bg_color_override: np.ndarray | None = None,\n"
    "                      args_alpha_floor: float = 0.01) -> np.ndarray:",
    "rembg: alpha floor parameter")
sub("rembg_matting.py",
    '    parser.add_argument("--bg-thresh", type=float, default=None,',
    '    parser.add_argument("--alpha-floor", type=float, default=0.06,\n'
    '                   help="Zero any alpha below this. Raise to kill background haze "\n'
    '                        "from a non-uniform generated background; lower to keep soft edges. Default: 0.06.")\n'
    '    parser.add_argument("--bg-thresh", type=float, default=None,',
    "rembg: --alpha-floor flag")
sub("rembg_matting.py",
    "    out = remove_background(img, img_pil, regime=args.mode,\n"
    "                            bg_thresh=args.bg_thresh, fg_thresh=args.fg_thresh,\n"
    "                            bg_color_override=bg_color)",
    "    out = remove_background(img, img_pil, regime=args.mode,\n"
    "                            bg_thresh=args.bg_thresh, fg_thresh=args.fg_thresh,\n"
    "                            bg_color_override=bg_color,\n"
    "                            args_alpha_floor=args.alpha_floor)",
    "rembg: thread alpha floor into main()")

print(f"\n{len(changed)} patch(es) applied." if changed else "\nAlready fully patched.")
