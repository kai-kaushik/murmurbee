---
title: Privacy
description: What MurmurBee and murmurbee.com collect, and what they don't. The app keeps your voice and text on your Mac.
date: 2026-10-28
---

The short version is that the MurmurBee app keeps your voice and your text on your Mac, and this website uses a little anonymous analytics, plus cookies only if you say OK.

## The MurmurBee app

- **Your voice and your text stay on your Mac.** Speech recognition and clean-up run on the Mac itself. Audio is never saved to disk, and there's no account and no MurmurBee server.
- **Your history, dictionary and personal model** are stored only on your Mac, in `~/Library/Application Support/MurmurBee`, and you can delete your history at any time in the app.
- **The app only connects to the internet for three things:**
  - **Downloading its models** the first time you run it, from GitHub and Hugging Face. The clean-up model is checked against a fixed checksum before it's used.
  - **Checking for updates**, by reading a small file on murmurbee.com. Updates are signed, and the app verifies them before installing.
  - **Sending feedback**, only when you write a message and press Send. It sends exactly what you typed, your email if you add one, and the app and macOS versions, to PostHog's EU servers. Nothing else, and no device identifiers.
- **Importing your Wispr Flow history** reads Wispr's local database on your Mac, read-only. Nothing is uploaded.

## This website

- **Before you answer the cookie banner,** PostHog (hosted in the EU) counts page views and clicks without cookies and with IP addresses discarded, so the statistics are anonymous and nothing is stored on your device.
- **If you click "Nah",** PostHog stops completely and Google Analytics never loads.
- **If you click "OK",** PostHog uses cookies so it can recognise return visits, records anonymous session replays to help me improve the site, and Google Analytics loads.
- **Fonts** come from Google Fonts, and the "Buy me a coffee" button is a plain link to Ko-fi.
- Your choice is remembered in your browser. To change it, clear this site's data and you'll be asked again.

## Contact

Questions about any of this? Open an issue on [GitHub](https://github.com/kai-kaushik/murmurbee/issues), or use "Send feedback" in the app.
