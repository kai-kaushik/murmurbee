---
title: Talking is three times faster than typing. Here's how to actually use that
description: Speech is about 3× faster than typing on a phone and well ahead of most people on a keyboard. What the research says, and how voice typing changed how I work.
date: 2026-10-27
order: 2
---

<div class="cover" aria-hidden="true">
<svg viewBox="0 0 1200 520" role="presentation">
  <text class="c-sand" x="120" y="150" font-size="30">Typing</text>
  <g class="c-sand" opacity=".55"><rect x="300" y="122" width="34" height="34" rx="8"/><rect x="344" y="122" width="34" height="34" rx="8"/><rect x="388" y="122" width="34" height="34" rx="8"/><rect x="432" y="122" width="34" height="34" rx="8"/></g>
  <text class="c-ink" x="120" y="330" font-size="30">Talking</text>
  <g class="c-honey">
    <rect x="300" y="318" width="10" height="24" rx="5"/><rect x="322" y="300" width="10" height="60" rx="5"/><rect x="344" y="288" width="10" height="84" rx="5"/><rect x="366" y="306" width="10" height="48" rx="5"/>
    <rect x="388" y="282" width="10" height="96" rx="5"/><rect x="410" y="300" width="10" height="60" rx="5"/><rect x="432" y="312" width="10" height="36" rx="5"/><rect x="454" y="294" width="10" height="72" rx="5"/>
    <rect x="476" y="286" width="10" height="88" rx="5"/><rect x="498" y="304" width="10" height="52" rx="5"/><rect x="520" y="296" width="10" height="68" rx="5"/><rect x="542" y="314" width="10" height="32" rx="5"/>
    <rect x="564" y="290" width="10" height="80" rx="5"/><rect x="586" y="302" width="10" height="56" rx="5"/><rect x="608" y="296" width="10" height="68" rx="5"/><rect x="630" y="310" width="10" height="40" rx="5"/>
    <rect x="652" y="292" width="10" height="76" rx="5"/><rect x="674" y="306" width="10" height="48" rx="5"/><rect x="696" y="300" width="10" height="60" rx="5"/><rect x="718" y="316" width="10" height="28" rx="5"/>
  </g>
  <path class="c-trail" d="M740 330c80-10 120-90 200-80s70 70 140 40"/>
  <image href="/assets/murmurbee-bee.svg" x="1040" y="230" width="110" height="107"/>
</svg>
</div>

I've noticed for a long time that I think a lot faster than I type, and I'm pretty sure most people are the same, because your brain already has the whole email ready to go and then your fingers spend the next two minutes trying to catch up. Talking just doesn't have that problem, and once I properly switched to dictating, the difference was big enough that I wanted to look into the actual research behind it.

## What the research says

The study everyone quotes comes from Stanford, the University of Washington and Baidu in 2016, where they had people enter the same everyday phrases on a phone either by typing or by speaking, and [speech came out about **three times faster** for English](https://hci.stanford.edu/research/speech/paper.html), with a 20.4% *lower* error rate on top of that.

To be fair, that comparison was against a phone keyboard, and a proper keyboard is a lot quicker, but even on a laptop most of us aren't particularly fast typists. A study of [136 million keystrokes from 168,000 people](https://userinterfaces.aalto.fi/136Mkeystrokes/) found the average was about 52 words a minute, whereas people comfortably speak at 120 words a minute or more.

<figure class="chart">
<p class="chart__title">Words per minute, roughly</p>
<div class="chart__rows">
<div class="chart__row" title="Average typing in a large online study: about 52 words per minute"><span class="chart__name">Typing</span><span class="chart__track"><i style="--v:34.7%"></i></span><span class="chart__val">~52</span></div>
<div class="chart__row is-hi" title="Normal speech: about 120 to 150 words per minute"><span class="chart__name">Talking</span><span class="chart__track"><i style="--v:100%"></i></span><span class="chart__val">120–150</span></div>
</div>
<p class="chart__note">Typing: average from Dhakal et al., CHI 2018 (136M keystrokes). Talking: typical conversational pace.</p>
</figure>

So talking ends up being somewhere between two and three times faster than typing, and that's really the whole pitch, but in my experience the speed is only half of it.

## Why it's about more than speed

The first thing I noticed is that you end up writing the way you actually think. When I type, I'm constantly editing as I go, deleting and rewording and deleting again, whereas when I talk I just say the thing, so the first draft comes out sounding a lot more like me and a lot less like a corporate memo.

Long messages also stop feeling like a chore, because that detailed reply you've been putting off for a day is really just about 90 seconds of talking, so it's much easier to send the thorough version of something rather than cutting it short because typing it all out felt like too much effort.

This next one honestly surprised me, but your prompts to AI get a lot better too. In my own testing, 18 out of 20 random dictations were prompts going into an AI assistant, and when you talk to ChatGPT or Claude you naturally give it more context, more examples and more "oh, and by the way", which means better input and better answers. And on top of all that, your hands get a break, which if you're on a keyboard eight hours a day is something your wrists will definitely thank you for.

## What used to go wrong (and doesn't anymore)

Voice typing used to be pretty painful for three reasons, really:

1. **It typed out exactly what you said**, every "um" and every false start, with no punctuation.
2. **It was slow**, so you'd sit there waiting for the text to appear, which completely kills your flow.
3. **Corrections were awkward**, so if you said the wrong day you'd have to go back and fix it by hand.

Modern dictation fixes all three of those, because a small language model now tidies things up after the speech model, so "um, so, can we move, sync the meeting to Tuesday, sorry, Wednesday" lands as "Can we sync the meeting to Wednesday?", and on a recent Mac it all happens in about a third of a second.

## How I'd get started

If you want to give it a go, this is what I'd do:

- **Pick one place to try it for a week.** Slack or email is perfect for that, since the messages are short, frequent and pretty low stakes.
- **Talk to it the way you'd talk to a friend** rather than a robot, because natural sentences actually work better than careful word-by-word dictation.
- **Don't stop to fix your mistakes**, just say "sorry" and the right thing and keep going.
- **Definitely use it for your AI prompts**, because that's where you'll feel the speed difference the most.

I built [MurmurBee](https://murmurbee.com) to do all of this on your own Mac, for free, without your voice ever leaving the machine, but honestly, whatever you end up using, I'd really recommend trying talking instead of typing for a week, because it's one of the very few productivity tips that has actually stuck for me.
