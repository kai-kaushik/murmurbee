#!/usr/bin/env python3
"""Generate MurmurBee logo concepts with OpenAI or OpenRouter image models.
Usage: OPENAI_API_KEY=... python3 brand/gen_logo.py     (or OPENROUTER_API_KEY=...)
Writes PNGs to brand/concepts/."""
import base64, json, os, pathlib, urllib.request

OUT = pathlib.Path(__file__).parent / "concepts"
OUT.mkdir(exist_ok=True)
BASE = ("App icon for 'MurmurBee', a private voice-dictation Mac app. A very cute, chubby little honey bee "
        "with big friendly eyes, tiny translucent wings and soft honey-yellow (#F4B23C) and near-black stripes, "
        "flying happily at the end of a looping dotted flight trail that gently undulates like a sound wave. "
        "Dark warm charcoal background (#16130F) inside a rounded-square macOS icon. Minimal, premium, "
        "clean flat vector style, crisp shapes, no text, centered, generous padding.")
STYLES = {
    "flat":    "Geometric flat vector, kawaii proportions, like a premium Apple Design Award app icon.",
    "soft3d":  "Soft 3D clay render with gentle lighting and subtle depth, still simple and iconic.",
    "line":    "Elegant single-weight line illustration with honey fills, editorial and refined.",
    "sticker": "Bold rounded sticker style with thick friendly outlines, playful and charming.",
}

def openai(prompt):
    req = urllib.request.Request("https://api.openai.com/v1/images/generations",
        data=json.dumps({"model": os.environ.get("IMG_MODEL", "gpt-image-1"), "prompt": prompt,
                         "size": "1024x1024", "n": 1}).encode(),
        headers={"Authorization": f"Bearer {os.environ['OPENAI_API_KEY']}", "Content-Type": "application/json"})
    return base64.b64decode(json.load(urllib.request.urlopen(req, timeout=300))["data"][0]["b64_json"])

def openrouter(prompt):
    req = urllib.request.Request("https://openrouter.ai/api/v1/chat/completions",
        data=json.dumps({"model": os.environ.get("IMG_MODEL", "openai/gpt-5-image"), "modalities": ["image", "text"],
                         "messages": [{"role": "user", "content": prompt}]}).encode(),
        headers={"Authorization": f"Bearer {os.environ['OPENROUTER_API_KEY']}", "Content-Type": "application/json"})
    url = json.load(urllib.request.urlopen(req, timeout=300))["choices"][0]["message"]["images"][0]["image_url"]["url"]
    return base64.b64decode(url.split(",", 1)[1])

gen = openai if os.environ.get("OPENAI_API_KEY") else openrouter
for name, style in STYLES.items():
    try:
        (OUT / f"{name}.png").write_bytes(gen(f"{BASE} {style}"))
        print("ok", name)
    except Exception as e:
        print("fail", name, getattr(e, "read", lambda: str(e))()[:300])
