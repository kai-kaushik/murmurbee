---
title: I got fed up with Wispr Flow, so I built my own over a weekend
description: How I built MurmurBee, a free, open-source Wispr Flow alternative that runs entirely on my Mac. Offline, about twice as fast, and every experiment along the way.
date: 2026-10-27
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

So one weekend I tried to build my own. Speech-to-text models had quietly become tiny and fast enough to run on a laptop, and I wanted to know: can a MacBook Air do what Wispr does, with nothing leaving the machine?

Turns out, mostly yes. Here's how it went, including the bits that didn't work.

## The idea: two tiny models and a key

MurmurBee does three things:

1. **You hold a key and talk.** Right ⌥ or fn, in any app.
2. **A tiny speech-to-text model** turns your voice into words on the Mac's Neural Engine.
3. **A small local LLM** (0.8 billion parameters, small enough to run on a laptop) tidies it up: removes the "um"s, follows your corrections, formats lists and emails, and pastes it where your cursor is.

No servers. No account. After the first model download it works with the Wi‑Fi off.

## Experiment 1: is speech recognition even fast enough?

This was the first thing I measured, and the answer surprised me. Transcribing the last 8 seconds of audio took **40 to 64 milliseconds**, at every dictation length. Speech recognition on a modern Mac is effectively free.

Accuracy was the real gap. On raw recognition, my local model got **96.8%** of words right against Wispr's **98.1%**. Almost all of the difference was names and jargon. "Claude" became "claw". My dictionary words got mangled. Not a speed problem, a vocabulary problem.

<figure class="chart">
<p class="chart__title">Raw speech recognition: words right out of 100</p>
<div class="chart__rows">
<div class="chart__row" title="Wispr Flow: 98.1 words right per 100"><span class="chart__name">Wispr Flow</span><span class="chart__track"><i style="--v:98.1%"></i></span><span class="chart__val">98.1</span></div>
<div class="chart__row is-hi" title="MurmurBee: 96.8 words right per 100"><span class="chart__name">MurmurBee</span><span class="chart__track"><i style="--v:96.8%"></i></span><span class="chart__val">96.8</span></div>
</div>
<p class="chart__note">10 of my real dictations, scored against a neutral answer key built from three speech models. Before any clean-up or personal training.</p>
</figure>

## Experiment 2: just ask a small model to clean it up

The obvious move: take an off-the-shelf small model, give it a good prompt, done.

It was a disaster, and a funny one. The tiny model read my dictation as a *chat message* and replied to it. I'd dictate a prompt for Claude and it would helpfully answer "I'm ready to help!" instead of cleaning my words. Its output was literally worse than the raw transcript.

A bigger model (2 billion parameters) behaved better, but on long dictations it took **over 2 seconds**. Wispr takes about 0.65. Not good enough.

The fix was a design change, not a bigger model: **clean the dictation in small chunks while you're still talking.** By the time you let go of the key, most of the work is done.

## Experiment 3: teach it my dictionary (it got worse)

Wispr lets you keep a dictionary of names. So I fed mine straight into the speech model to bias it towards those words.

Errors went *up*, from 20.6% to 23.0%. It started hearing my dictionary everywhere: "Slack" became "Stacy" eight times, "right" became "Rich" twelve times. Lesson learned. Vocabulary belongs in the clean-up step, where the model can see the context, not in the ears.

## Experiment 4: train it on me

This is where it got good. Wispr keeps a local history of everything you've dictated, so I had 10,535 of my own dictations with the before and after. I fine-tuned the small model on them, and it learned the things that make dictation feel smart:

- **Self-corrections.** "Let's meet Tuesday, sorry, Wednesday" becomes "Let's meet Wednesday."
- **Lists and emails**, laid out properly.
- **Sign-offs and names** from whatever's on screen.

I also made every classic mistake. I tested on dictations the model had already seen. I shuffled my data and accidentally leaked answers into the test. Each time, I fixed it, locked the test set away, and re-ran everything. All of it is in [the experiment log](https://github.com/kai-kaushik/murmurbee/blob/main/docs/EXPERIMENTS.md), warts and all.

## Experiment 5: a model anyone can use

My personal model can't be published. It's full of my emails. So I trained a **general model on 12,000 made-up dictations** (invented people, invented companies, all generated for about $11.50) and checked it against my real voice.

It landed within about 2 points of my personal model, and halved the error of the untrained one. That's the model MurmurBee downloads on first run.

## Experiment 6: let everyone train their own

Then the fun part. MurmurBee can import your Wispr Flow history and **train a personal model on your Mac, overnight**. Nothing leaves the machine.

In my tests the best personal model made **up to 45% fewer mistakes** than the general model. Not every run is that good, so the app tests each new model against the one you use and only switches if it's actually better.

## So, is it better than Wispr Flow?

For what it does, for me: yes. Here's how they compared on the same MacBook Air:

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
- **Free and open source.** You can read every line, and you'll always know which model you're running.

Where Wispr still wins: it has way more features. iPhone, teams, syncing, styles, more languages. Its raw speech recognition is a touch more accurate out of the box. MurmurBee does one thing: turns what you say into what you meant, in any app on your Mac. It just does that one thing fast, for free, and privately.

## Try it

MurmurBee is free for any Apple Silicon Mac on macOS 15 or later. [Download it here](https://murmurbee.com), or poke around [the code on GitHub](https://github.com/kai-kaushik/murmurbee). If you import your Wispr history and train your own model, tell me how it goes. I'd love to know.
