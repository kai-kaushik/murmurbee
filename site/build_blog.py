"""Build the blog: site/blog-src/*.md  ->  site/blog/<slug>/index.html, site/blog/index.html, site/sitemap.xml

Each post starts with a front-matter block:

    ---
    title: How MurmurBee stays on your Mac
    description: One or two sentences for search results and link previews.
    date: 2026-11-02
    draft: true        # optional; drafts are skipped
    order: 2           # optional; on the same date, higher comes first
    ---

Run from the repo:  uv run --with markdown python site/build_blog.py
"""
import datetime as dt
import html
import json
import re
from pathlib import Path

import markdown

SITE = Path(__file__).resolve().parent
SRC, OUT = SITE / "blog-src", SITE / "blog"
BASE = "https://murmurbee.com"
STYLE_V = re.search(r"styles\.css\?v=(\d+)", (SITE / "index.html").read_text()).group(1)
ANALYTICS_V = re.search(r"analytics\.js\?v=(\d+)", (SITE / "index.html").read_text()).group(1)
MAIN_V = re.search(r"main\.js\?v=(\d+)", (SITE / "index.html").read_text()).group(1)


def parse(path):
    text = path.read_text()
    m = re.match(r"---\n(.*?)\n---\n(.*)", text, re.S)
    if not m:
        raise SystemExit(f"{path.name}: missing front matter")
    meta = dict(line.split(":", 1) for line in m.group(1).splitlines() if ":" in line)
    meta = {k.strip(): v.strip() for k, v in meta.items()}
    for key in ("title", "description", "date"):
        if not meta.get(key):
            raise SystemExit(f"{path.name}: front matter needs '{key}'")
    meta["slug"] = path.stem
    meta["date"] = dt.date.fromisoformat(meta["date"])
    meta["html"] = markdown.markdown(m.group(2), extensions=["fenced_code", "tables", "smarty"])
    art = re.search(r"<svg.*?</svg>", m.group(2), re.S)  # the cover drawing doubles as the list thumbnail
    meta["thumb"] = (f'<span class="bloglist__img cover" aria-hidden="true">{art.group(0)}</span>' if art else
                     f'<img class="bloglist__img" src="/assets/og/{path.stem}.png" alt="" width="1200" height="630" loading="lazy">')
    words = len(re.sub(r"<[^>]+>", " ", meta["html"]).split())
    meta["minutes"] = max(1, round(words / 230))
    return meta


def page(title, description, canonical, body, og_type="website", image="home"):
    t, d = html.escape(title), html.escape(description)
    return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{t}</title>
  <meta name="description" content="{d}">
  <meta name="theme-color" content="#16130F">
  <link rel="canonical" href="{canonical}">
  <meta property="og:type" content="{og_type}">
  <meta property="og:url" content="{canonical}">
  <meta property="og:site_name" content="MurmurBee">
  <meta property="og:title" content="{t}">
  <meta property="og:description" content="{d}">
  <meta property="og:image" content="{BASE}/assets/og/{image}.png">
  <meta property="og:image:width" content="1200">
  <meta property="og:image:height" content="630">
  <meta property="og:image:alt" content="{t}">
  <meta name="twitter:card" content="summary_large_image">
  <meta name="twitter:title" content="{t}">
  <meta name="twitter:description" content="{d}">
  <meta name="twitter:image" content="{BASE}/assets/og/{image}.png">
  <link rel="alternate" type="application/rss+xml" title="MurmurBee blog" href="/blog/feed.xml">
  <link rel="icon" type="image/svg+xml" href="/assets/murmurbee-bee.svg">
  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
  <link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=DM+Sans:opsz,wght@9..40,400;9..40,500&family=Sora:wght@600&display=swap">
  <script>
    (function () {{
      var t = null;
      try {{ t = localStorage.getItem("mb-theme"); }} catch (e) {{}}
      if (t !== "light" && t !== "dark") t = window.matchMedia && matchMedia("(prefers-color-scheme: light)").matches ? "light" : "dark";
      document.documentElement.setAttribute("data-theme", t);
    }})();
  </script>
  <link rel="stylesheet" href="/styles.css?v={STYLE_V}">
  <script src="/main.js?v={MAIN_V}" defer></script>
  <script src="/analytics.js?v={ANALYTICS_V}" defer></script>
</head>
<body>
  <a class="skip-link" href="#main">Skip to content</a>
  <header class="nav" id="top">
    <div class="nav__inner wrap">
      <a class="brand" href="/" aria-label="MurmurBee home">
        <img class="brand__mark" src="/assets/murmurbee-bee.svg" alt="" width="34" height="33">
        <span class="wordmark">Murmur<span class="wordmark__bee">Bee</span></span>
      </a>
      <nav class="nav__links" aria-label="Primary">
        <a href="/#features">Features</a>
        <a href="/#how">How it works</a>
        <a href="/#faq">FAQ</a>
        <a href="/blog/" aria-current="{'page' if '/blog/' == canonical.removeprefix(BASE) else 'false'}">Blog</a>
      </nav>
      <div class="nav__end">
        <button class="theme-toggle" type="button" data-theme-toggle aria-label="Switch to light theme">
          <svg class="i-sun" viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="4.2"/><path d="M12 2.5v2.2M12 19.3v2.2M4.6 4.6l1.6 1.6M17.8 17.8l1.6 1.6M2.5 12h2.2M19.3 12h2.2M4.6 19.4l1.6-1.6M17.8 6.2l1.6-1.6"/></svg>
          <svg class="i-moon" viewBox="0 0 24 24" aria-hidden="true"><path d="M20.2 14.6A8.5 8.5 0 0 1 9.4 3.8a8.5 8.5 0 1 0 10.8 10.8z"/></svg>
        </button>
        <a class="btn btn--honey btn--sm" href="https://github.com/kai-kaushik/murmurbee/releases/latest/download/MurmurBee.dmg"><span>Download<span class="hide-sm"> for Mac</span></span></a>
      </div>
    </div>
  </header>
  <main id="main">
{body}
  </main>
  <footer class="footer">
    <div class="wrap footer__inner">
      <a class="brand" href="/" aria-label="MurmurBee home">
        <img class="brand__mark" src="/assets/murmurbee-bee.svg" alt="" width="28" height="27" loading="lazy">
        <span class="wordmark">Murmur<span class="wordmark__bee">Bee</span></span>
      </a>
      <p class="footer__copy">Made with <span role="img" aria-label="love">❤️</span> by Kai</p>
      <a class="footer__gh" href="https://github.com/kai-kaushik/murmurbee" rel="noopener">GitHub</a>
    </div>
  </footer>
</body>
</html>
"""


def nice(d):
    return f"{d.day} {d:%B %Y}"


def main():
    posts = sorted((p for p in map(parse, SRC.glob("*.md")) if p.get("draft", "").lower() != "true"),
                   key=lambda p: (p["date"], int(p.get("order", 0))), reverse=True)
    OUT.mkdir(exist_ok=True)
    # remove pages of posts that were deleted or turned back into drafts
    live = {p["slug"] for p in posts}
    for d in OUT.iterdir():
        if d.is_dir() and d.name not in live and (d / "index.html").exists():
            (d / "index.html").unlink()
            d.rmdir()
    for p in posts:
        url = f"{BASE}/blog/{p['slug']}/"
        ld = '<script type="application/ld+json">' + json.dumps({
            "@context": "https://schema.org", "@type": "BlogPosting", "headline": p["title"],
            "description": p["description"], "datePublished": str(p["date"]),
            "author": {"@type": "Person", "name": "Kai"}, "mainEntityOfPage": url,
        }).replace("</", "<\\/") + "</script>"
        body = f"""    <article class="post wrap">
      <a class="post__back" href="/blog/">All posts</a>
      <h1 class="post__title">{html.escape(p['title'])}</h1>
      <p class="post__meta"><time datetime="{p['date']}">{nice(p['date'])}</time>, {p['minutes']} min read</p>
      <div class="post__body">
{p['html']}
      </div>
    </article>
    {ld}"""
        d = OUT / p["slug"]
        d.mkdir(exist_ok=True)
        (d / "index.html").write_text(page(f"{p['title']} | MurmurBee", p["description"], url, body, "article", p["slug"]))

    items = "\n".join(
        f"""        <li class="bloglist__item">
          <a class="bloglist__link" href="/blog/{p['slug']}/">
            {p['thumb']}
            <span class="bloglist__title">{html.escape(p['title'])}</span>
            <span class="bloglist__desc">{html.escape(p['description'])}</span>
            <time class="bloglist__date" datetime="{p['date']}">{nice(p['date'])}</time>
          </a>
        </li>""" for p in posts) or '        <li class="bloglist__empty">The first post is on its way.</li>'
    body = f"""    <section class="blog wrap">
      <h1 class="blog__title">Blog</h1>
      <p class="blog__lead">Notes from building MurmurBee: what worked, what didn’t, and the numbers behind it.</p>
      <ul class="bloglist">
{items}
      </ul>
    </section>"""
    (OUT / "index.html").write_text(page("Blog | MurmurBee", "Notes from building MurmurBee, a free, open-source dictation app that runs entirely on your Mac.", f"{BASE}/blog/", body))

    rss = "\n".join(f"""  <item><title>{html.escape(p['title'])}</title><link>{BASE}/blog/{p['slug']}/</link>
    <guid>{BASE}/blog/{p['slug']}/</guid><pubDate>{p['date']:%a, %d %b %Y} 09:00:00 +0000</pubDate>
    <description>{html.escape(p['description'])}</description></item>""" for p in posts)
    (OUT / "feed.xml").write_text(f"""<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0"><channel><title>MurmurBee blog</title><link>{BASE}/blog/</link>
<description>Notes from building MurmurBee.</description>
{rss}
</channel></rss>
""")

    urls = [f"{BASE}/"] + ([f"{BASE}/blog/"] if posts else []) + [f"{BASE}/blog/{p['slug']}/" for p in posts]
    (SITE / "sitemap.xml").write_text('<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n'
                                      + "".join(f"  <url><loc>{u}</loc></url>\n" for u in urls) + "</urlset>\n")
    print(f"{len(posts)} post(s) built")


if __name__ == "__main__":
    main()
