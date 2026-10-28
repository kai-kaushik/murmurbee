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

I've dictated more than 10,000 things into Wispr Flow at this point, emails, Slack messages and a lot of long, rambling prompts to Claude, and I genuinely love the idea of it, because being able to hold a key, talk like a normal human and have clean text show up wherever your cursor is just feels like how computers should work.

But over time a few things kept bugging me:

- **It didn't always get my words right**, especially names and the jargon I use every day.
- **It needed the internet**, so on a train, on dodgy hotel Wi‑Fi or on a plane I just couldn't dictate, because your voice has to go to their servers first.
- **I never really knew when they changed the model**, so some weeks it felt sharper and some weeks it didn't, with no way of knowing why.
- **And honestly, I didn't want to keep paying a subscription** for something my Mac should be perfectly capable of doing by itself.

Speech-to-text models have quietly become small and fast enough to run on a laptop over the last year or so, so one weekend I decided to try building my own, with one rule, which was that nothing leaves my Mac. It's called MurmurBee, and it's completely free.

## What it does

You hold a key, talk and let go, and that's pretty much it. It works with the right ⌥ key or fn, in any app, whether that's Slack, Gmail, Notion, your terminal or ChatGPT, and a little flow bar shows you it's listening, which you can drag anywhere along the edge of your screen. When you let go, clean text gets pasted wherever your cursor is, usually in about a third of a second, and your clipboard is put back exactly how it was.

It writes what you meant rather than what you literally said, so "Um, so, can we move, sync the meeting to Tuesday, sorry, Wednesday?" comes out as "Can we sync the meeting to Wednesday?". It drops the filler words, follows your corrections when you say things like "sorry", "I mean" or "actually", and adds the punctuation and capital letters for you.

My favourite part, though, is that it knows where you are, because MurmurBee reads a little bit of context from your screen, all on your Mac, to get things right:

- **Which app you're in**, so emails get proper paragraphs and a sign-off while a Slack message stays casual.
- **Names on screen**, so if you're replying to an email from Siobhan, it spells "Siobhan" even if what it heard sounded like "shiv on".
- **What's already written**, because it reads the text around your cursor, so a sentence or a numbered list carries on naturally instead of starting over.
- **Your selected text, the website you're on and your local time**, which take care of the little details that make the text feel right.

It also formats things properly, so if you say a list out loud you get a list, if you dictate an email you get paragraphs and a sign-off, and spoken times like "nine thirty" come out as 9:30.

It learns your words as you go, because if you fix a name after it's pasted, MurmurBee notices and adds it to your dictionary automatically, and you can add words by hand too. It works completely offline after a one-time model download, so you can turn the Wi‑Fi off and it just carries on, and your voice and text never leave your Mac since there's no account and no server involved at all. And it keeps a history of everything you've dictated, which you can search, which is stored only on your Mac and which you can delete whenever you like.

## Bring your Wispr history with you

If you've been using Wispr Flow, your whole dictation history is already sitting on your Mac, and MurmurBee can import it (read-only, so it never touches Wispr's files) and then train a personal model on your Mac overnight, so it learns how you talk, your names, your phrasing and how you like your emails laid out.

In my tests the best personal model made **up to 45% fewer mistakes** than the general one. Not every training run turns out that well, so MurmurBee tests each new model against the one you're currently using and only switches over if it's actually better, which means you never end up with a worse model.

## How I got here

It took a fair few experiments to get here, and plenty of them didn't work out. Speech recognition turned out to be the easy part, since transcribing the last few seconds of audio takes somewhere between 40 and 64 milliseconds on a MacBook Air. Off-the-shelf small models, on the other hand, were a bit of a disaster at first, because the tiny one I tried read my dictations as chat messages and replied "I'm ready to help!" instead of cleaning them up, which was honestly pretty funny. Biasing the speech model towards my dictionary made it worse, since it started hearing "Stacy" every time I said "Slack", and in the end what made the biggest difference was fine-tuning the model on my own history, because that's where it learned corrections, lists, emails and names.

If you're into the more technical side of things, I wrote up the models, the training setup, the evaluation protocol and the results in [how I built it](/blog/how-i-built-murmurbee/).

## So, is it better than Wispr Flow?

For what it does, and for me, I'd say yes. This is how the two compared on the same MacBook Air:

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

So for me it comes down to this:

- **It's about twice as fast** from letting go of the key to text on screen.
- **It's around seven times smaller**, with one background process instead of thirteen.
- **It works offline**, so your voice never leaves your Mac.
- **It's free and open source**, so you can read every line of it and you'll always know exactly which model you're running.

To be fair to Wispr, it still wins on features, with an iPhone app, teams, syncing, styles and more languages, and its raw speech recognition is a touch more accurate out of the box (98.1 words right out of 100, against 96.8 for MurmurBee). MurmurBee really just does one thing, which is turning what you say into what you meant, in any app on your Mac, but it does that one thing fast, for free and privately.

## Try it

MurmurBee is free for any Apple Silicon Mac running macOS 15 or later, and you can [download it here](https://murmurbee.com) or have a poke around [the code on GitHub](https://github.com/kai-kaushik/murmurbee). If you import your Wispr history and train your own model, I'd genuinely love to hear how it goes for you.
