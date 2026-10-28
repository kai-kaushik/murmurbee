"""Writes the Sparkle update feed (site/appcast.xml) for one release:
    python3 make_appcast.py <version> <build> '<sparkle:edSignature="..." length="...">'"""
import datetime as dt
import sys

version, build, sig = sys.argv[1], sys.argv[2], sys.argv[3]
url = f"https://github.com/kai-kaushik/murmurbee/releases/download/v{version}/MurmurBee.dmg"
date = dt.datetime.now(dt.timezone.utc).strftime("%a, %d %b %Y %H:%M:%S +0000")
print(f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>MurmurBee</title>
    <link>https://murmurbee.com/appcast.xml</link>
    <item>
      <title>MurmurBee {version}</title>
      <pubDate>{date}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>https://github.com/kai-kaushik/murmurbee/releases/tag/v{version}</sparkle:releaseNotesLink>
      <enclosure url="{url}" type="application/octet-stream" {sig} />
    </item>
  </channel>
</rss>""")
