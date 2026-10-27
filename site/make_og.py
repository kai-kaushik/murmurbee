"""Link-preview images (1200x630 PNG) for the homepage and every blog post, rendered with headless Chrome.

    uv run --with markdown python site/make_og.py

Writes site/assets/og/home.png and site/assets/og/<slug>.png. build_blog.py points each post's og:image at its file.
"""
import html
import subprocess
import tempfile
from pathlib import Path

from build_blog import SRC, parse

SITE = Path(__file__).resolve().parent
OUT = SITE / "assets" / "og"
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
BEE = (SITE / "assets" / "murmurbee-mark.svg").as_uri()
SMALL_BEE = (SITE / "assets" / "murmurbee-bee.svg").as_uri()

TEMPLATE = """<!doctype html><html><head><meta charset="utf-8">
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=DM+Sans:opsz,wght@9..40,500&family=Sora:wght@600&display=block">
<style>
  html, body {{ margin: 0; width: 1200px; height: 630px; overflow: hidden; }}
  body {{ background: #16130F; color: #F7EFE0; font-family: "DM Sans", sans-serif; position: relative; }}
  .brand {{ position: absolute; left: 72px; top: 64px; display: flex; align-items: center; gap: 14px;
           font: 600 34px/1 "Sora", sans-serif; letter-spacing: -0.04em; }}
  .brand img {{ width: 52px; }}
  .brand b {{ color: #F8BE34; font-weight: 600; }}
  h1 {{ position: absolute; left: 72px; right: {right}px; bottom: {bottom}px; margin: 0;
        font: 600 {size}px/1.04 "Sora", sans-serif; letter-spacing: -0.045em; text-wrap: balance; }}
  .sub {{ position: absolute; left: 72px; bottom: 64px; font-size: 26px; color: #C9BBA3; }}
  .mark {{ position: absolute; right: 56px; top: 64px; width: 360px; }}
  .rule {{ position: absolute; left: 72px; right: 72px; bottom: 116px; height: 2px; background: #3A322A; }}
</style></head><body>
  <div class="brand"><img src="{small_bee}" alt=""><span>Murmur<b>Bee</b></span></div>
  <img class="mark" src="{bee}" alt="">
  <h1>{title}</h1>
  <div class="rule"></div>
  <div class="sub">{sub}</div>
</body></html>"""


def render(name, title, sub, size=76, right=440, bottom=150):
    OUT.mkdir(parents=True, exist_ok=True)
    page = TEMPLATE.format(title=title, sub=html.escape(sub), size=size, right=right, bottom=bottom,
                           bee=BEE, small_bee=SMALL_BEE)
    with tempfile.NamedTemporaryFile("w", suffix=".html", delete=False) as f:
        f.write(page)
    target = OUT / f"{name}.png"
    subprocess.run([CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars", "--force-device-scale-factor=1",
                    "--window-size=1200,630", "--virtual-time-budget=8000", "--allow-file-access-from-files",
                    f"--screenshot={target}", Path(f.name).as_uri()], check=True, capture_output=True)
    print("wrote", target.relative_to(SITE))


def main():
    render("home", "Just murmur.<br>It writes.", "Free, private dictation for Mac. murmurbee.com", size=104)
    for p in map(parse, SRC.glob("*.md")):
        if p.get("draft", "").lower() == "true":
            continue
        n = len(p["title"])
        size = 76 if n < 50 else 64 if n < 75 else 56
        render(p["slug"], html.escape(p["title"]), "murmurbee.com/blog", size=size, right=72, bottom=150)


if __name__ == "__main__":
    main()
