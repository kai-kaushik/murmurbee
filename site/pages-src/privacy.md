---
title: Privacy
description: What MurmurBee and murmurbee.com collect, and what they don't. The app keeps your voice and text on your Mac.
date: 2026-10-28
---

The short version is that the MurmurBee app keeps your voice and your text on your Mac, and this website uses a little anonymous analytics, plus cookies only if you say OK.

## Who's responsible

MurmurBee is made by Kai Kaushik, an individual developer based in the United Kingdom, who is the data controller for the small amount of personal data described below. You can reach me about anything privacy-related at [kaikaushik1995@gmail.com](mailto:kaikaushik1995@gmail.com).

## The MurmurBee app

- **Your voice and your text stay on your Mac.** Speech recognition and clean-up run on the Mac itself. Audio is never saved to disk, and there's no account and no MurmurBee server.
- **Your history, dictionary and personal model** are stored only on your Mac, in `~/Library/Application Support/MurmurBee`. I never see them. You can delete your history at any time in the app, and removing that folder removes everything.
- **The app only connects to the internet for three things:**
  - **Downloading its models** the first time you run it, from GitHub and Hugging Face. Every file is checked against fixed checksums built into the app before it's used.
  - **Checking for updates**, by reading a small file on murmurbee.com once a day. Updates are signed, and the app verifies the signature before installing anything.
  - **Sending feedback**, only when you write a message and press Send. It sends exactly what you typed, your email if you choose to add one, and the app and macOS versions. No device identifiers and nothing from your history.
- **Importing your Wispr Flow history** reads Wispr's local database on your Mac, read-only. Nothing is uploaded anywhere.

## This website

| What | When | Purpose | Legal basis |
|---|---|---|---|
| Anonymous page views and clicks (PostHog, no cookies, IP addresses discarded) | Before you answer the cookie banner | Understanding how the site is used | Legitimate interests |
| PostHog cookies and session replays | Only after you click OK | Understanding return visits and improving the site | Consent |
| Google Analytics cookies | Only after you click OK | Website statistics and search performance | Consent |
| Nothing | After you click "Nah" | | |

- Your choice is remembered in your browser's local storage. To change your mind, clear this site's data and the banner will ask again.
- Fonts are loaded from Google Fonts, which means your browser fetches them from Google's servers. The "Buy me a coffee" button opens Ko-fi's tipping panel when you click it; nothing from Ko-fi loads before that, and once open, Ko-fi's own privacy policy applies inside the panel.

## Who processes data for me

- **PostHog** (website analytics and app feedback), hosted in the European Union.
- **Google** (Google Analytics, only after you click OK, and Google Fonts), which may process data in the United States under Google's standard contractual clauses and its certification under the EU-US and UK-US data frameworks.
- **Vercel** hosts this website and keeps standard server logs for security and reliability.
- **GitHub** and **Hugging Face** serve the app's downloads and see the requests your Mac makes to them, as with any download.

## How long data is kept

Analytics data is kept only as long as it's useful for understanding how the site is used, and never longer than the retention periods set in PostHog and Google Analytics. Feedback messages are kept as long as I need them to read and act on them. Anything you ask me to delete, I'll delete.

## Your rights

You can ask me for a copy of any personal data I hold about you, to correct it, or to delete it, and you can withdraw consent to cookies at any time by clearing this site's data. Just email [kaikaushik1995@gmail.com](mailto:kaikaushik1995@gmail.com). If you're unhappy with how I've handled your data, you can also complain to the UK Information Commissioner's Office at [ico.org.uk](https://ico.org.uk) or to your local data protection authority.

## Children

MurmurBee and this website aren't aimed at children under 13, and I don't knowingly collect data from them.

## Changes

If this policy changes, I'll update it here and change the date at the top.
