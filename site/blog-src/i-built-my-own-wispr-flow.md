---
title: I got fed up with Wispr Flow, so I built my own over a weekend
description: Why I built MurmurBee, a free, open-source Wispr Flow alternative that runs entirely on my Mac, and what it does - screen context, corrections, personal training, all offline.
date: 2026-10-27
order: 4
---

<div class="cover" aria-hidden="true">
<svg viewBox="0 0 1200 520" role="presentation">
  <rect class="c-line" x="300" y="110" width="520" height="320" rx="22"/>
  <path class="c-line" d="M250 452h620l-34 26H284z"/>
  <rect class="c-bar" x="452" y="248" width="216" height="64" rx="32"/>
  <circle class="c-honey" cx="512" cy="280" r="7"/><circle class="c-sand" cx="560" cy="280" r="7" opacity=".5"/><circle class="c-sand" cx="608" cy="280" r="7" opacity=".5"/>
  <path class="c-trail" d="M668 270c90-40 120-130 210-120s60 90 10 100-40-80 40-110 90-20 130-50"/>
  <image href="/assets/murmurbee-bee.svg" x="1010" y="40" width="130" height="126"/>
</svg>
</div>

I've dictated more than 10,000 things into Wispr Flow. Emails, Slack messages, long rambling prompts to Claude. I genuinely love the idea: hold a key, talk like a normal human, and clean text appears wherever your cursor is.

But a few things kept bugging me.

- **It didn't always get *my* words right.** Names, jargon, the stuff I actually say every day.
- **It needed the internet.** On a train, on bad hotel Wi‑Fi, on a plane: no dictation. Your voice goes to their servers first.
- **I never knew when the model changed.** Some weeks it felt sharper, some weeks it didn't, and there was no way to tell why.
- **And honestly? I didn't want to pay a subscription** for something my Mac should be able to do by itself.

Speech-to-text models have quietly become tiny and fast enough to run on a laptop. So one weekend I tried to build my own, with one rule: nothing leaves the Mac.

It's called MurmurBee, and it's free.

## What it does

**Hold a key, talk, let go.** Right ⌥ or fn, in any app: Slack, Gmail, Notion, your terminal, ChatGPT. A little flow bar shows it's listening, and you can drag it anywhere along the edge of your screen. Let go, and clean text is pasted where your cursor is, usually in about a third of a second. Your clipboard is put back exactly how it was.

**It writes what you meant, not what you said.** "Um, so, can we move, sync the meeting to Tuesday, sorry, Wednesday?" becomes "Can we sync the meeting to Wednesday?". It drops the "um"s, follows your corrections ("sorry", "I mean", "actually"), and adds punctuation and capitals.

**It knows where you are.** This is my favourite part. MurmurBee reads a little context from your screen, on your Mac, to get things right:

- **Which app you're in.** Emails get proper paragraphs and a sign-off. A Slack message stays casual.
- **Names on screen.** Replying to an email from Siobhan? It spells "Siobhan", even if it heard "shiv on".
- **What's already written.** It reads the text around your cursor, so a sentence or a numbered list carries on naturally instead of starting over.
- **Your selected text, the website you're on, and your local time,** for the little details that make text feel right.

**It formats things properly.** Say a list out loud and you get a list. Dictate an email and you get paragraphs and a sign-off. Spoken times like "nine thirty" come out as 9:30.

**It learns your words.** Fix a name after it's pasted, and MurmurBee notices and adds it to your dictionary automatically. You can add words by hand too.

**It works offline.** After a one-time model download, turn the Wi‑Fi off and it carries on. Your voice and your text never leave your Mac. There's no account and no server.

**It keeps a history.** Everything you've dictated is searchable in the app, stored only on your Mac, and deletable whenever you like.

## Bring your Wispr history with you

If you've used Wispr Flow, your whole dictation history is sitting on your Mac. MurmurBee can import it (read-only, it never touches Wispr's files) and then **train a personal model on your Mac, overnight**. It learns how *you* talk: your names, your phrasing, how you like emails laid out.

In my tests, the best personal model made **up to 45% fewer mistakes** than the general one. Not every training run is that good, so MurmurBee tests each new model against the one you're using and only switches if it's actually better. You never get a worse model.

## How I got here (the short version)

It took a lot of experiments, and plenty of them failed:

- **Speech recognition turned out to be the easy part.** Transcribing the last few seconds of audio takes 40–64 milliseconds on a MacBook Air.
- **Off-the-shelf small models were a disaster.** The tiny one read my dictations as chat messages and replied "I'm ready to help!" instead of cleaning them up.
- **Teaching the speech model my dictionary made it worse.** It started hearing "Stacy" instead of "Slack".
- **Fine-tuning on my own history is what made it good.** That's where it learned corrections, lists, emails and names.
- **I made every evaluation mistake in the book**, then fixed them and re-ran everything.

If you like the nerdy details, the exact models, settings and results are in [how I built it](/blog/how-i-built-murmurbee/).

## So, is it better than Wispr Flow?

For what it does, for me: yes. On the same MacBook Air:

<figure class="chart">
<p class="chart__title">Time from letting go of the key to text on screen (median, seconds)</p>
<div class="chart__rows">
<div class="chart__row" title="Wispr Flow: 0.65 seconds"><span class="chart__name">Wispr Flow</span><span class="chart__track"><i style="--v:100%"></i></span><span class="chart__val">0.65 s</span></div>
<div class="chart__row is-hi" title="MurmurBee: 0.31 seconds"><span class="chart__name">MurmurBee</span><span class="chart__track"><i style="--v:47.7%"></i></span><span class="chart__val">0.31 s</span></div>
</div>
<p class="chart__note">MacBook Air M4, October 2026. MurmurBee 0.1.1, Wispr Flow 1.6.</p>
</figure>

<figure class="chart">
<p class="chart__title">App size (MB)</p>
<div class="chart__rows">
<div class="chart__row" title="Wispr Flow: 515 MB"><span class="chart__name">Wispr Flow</span><span class="chart__track"><i style="--v:100%"></i></span><span class="chart__val">515</span></div>
<div class="chart__row is-hi" title="MurmurBee: 70 MB"><span class="chart__name">MurmurBee</span><span class="chart__track"><i style="--v:13.6%"></i></span><span class="chart__val">70</span></div>
</div>
<p class="chart__note">Plus about 1 GB of models that MurmurBee downloads once. Wispr runs its models on its servers.</p>
</figure>

- **About twice as fast**, from letting go of the key to text on screen.
- **Seven times smaller**, and one background process instead of thirteen.
- **Works offline.** Your voice never leaves your Mac.
- **Free and open source.** You can read every line, and you'll always know exactly which model you're running.

Where Wispr still wins: it has way more features. iPhone, teams, syncing, styles, more languages. Its raw speech recognition is a touch more accurate out of the box (98.1 words right out of 100, against 96.8). MurmurBee does one thing: turns what you say into what you meant, in any app on your Mac. It just does that one thing fast, for free, and privately.

## Try it

MurmurBee is free for any Apple Silicon Mac on macOS 15 or later. [Download it here](https://murmurbee.com), or poke around [the code on GitHub](https://github.com/kai-kaushik/murmurbee). If you import your Wispr history and train your own model, tell me how it goes. I'd love to know.
