---
title: How I built a private, personal Wispr Flow on my MacBook
description: The full story of building MurmurBee - the goal, my own Wispr data, picking the models, training on a MacBook Air, every experiment that worked and the ones that didn't.
date: 2026-10-27
order: 3
---

<div class="cover" aria-hidden="true">
<svg viewBox="0 0 1200 520" role="presentation">
  <g class="c-line">
    <rect x="110" y="170" width="220" height="150" rx="22"/>
    <rect x="490" y="170" width="220" height="150" rx="22"/>
    <rect x="870" y="170" width="220" height="150" rx="22"/>
  </g>
  <g class="c-honey">
    <rect x="160" y="236" width="10" height="20" rx="5"/><rect x="180" y="222" width="10" height="48" rx="5"/><rect x="200" y="214" width="10" height="64" rx="5"/>
    <rect x="220" y="228" width="10" height="36" rx="5"/><rect x="240" y="218" width="10" height="56" rx="5"/><rect x="260" y="232" width="10" height="28" rx="5"/>
  </g>
  <text class="c-sand" x="526" y="232" font-size="26">um, so</text>
  <line class="c-strike" x1="522" y1="223" x2="612" y2="223"/>
  <text class="c-ink" x="526" y="276" font-size="26">So can we…</text>
  <text class="c-ink" x="910" y="256" font-size="30">⌘V</text>
  <path class="c-trail" d="M330 245h160M710 245h160"/>
  <image href="/assets/murmurbee-bee.svg" x="1010" y="80" width="100" height="97"/>
</svg>
</div>

This is the long version. If you just want to know what MurmurBee does, [the short story is here](/blog/i-built-my-own-wispr-flow/). This one is for the curious: what I was trying to build, how I went about it, which models I picked and why, and the experiments along the way, including the ones that failed.

## The goal

I had a simple belief going in: **the best dictation model is the one trained on you.**

Not the biggest model, not the one in the cloud. The one that knows your names, your jargon, how you write emails and how you correct yourself mid-sentence. So I wanted a dictation app that was:

- **Local.** It works offline, and nothing I say leaves my Mac.
- **Free.** No subscription for something my laptop can do itself.
- **Fast.** Faster than Wispr Flow, from letting go of the key to text on screen.
- **Light.** Not another 500 MB app with a dozen background processes.
- **Personal.** Trained on *me*.

## My unfair advantage: my own data

Here's the thing that made this possible. Wispr Flow keeps a local history of everything you dictate, on your Mac. I'd been using it for ages, so I had a treasure trove of personal data sitting right there:

- **10,535 dictations**, each with Wispr's raw transcript, its cleaned-up version, and my own edit when I'd corrected it.
- **880 of them still with audio**, about 7.2 hours (Wispr only keeps recent recordings).
- The **app** I was in, and some of what was on screen.

That's a ready-made training set of exactly how one person talks and what they actually wanted typed. I exported it read-only, so Wispr's own files were never touched.

## Everything on one MacBook

I set myself one more rule: **everything happens on my laptop**, including the training. No cloud GPUs. If a MacBook Air can't do it, normal people can't use it.

- **The machine:** a MacBook Air with an M4 chip and 32 GB of memory, with my usual apps open the whole time, because that's real life.
- **Training:** Apple's [MLX](https://github.com/ml-explore/mlx) framework. First `mlx-lm` in Python, later MLX Swift inside the app itself.
- **The app:** a native Swift menu-bar app. It reads the focused app and nearby screen text through the macOS Accessibility API, and pastes with the clipboard plus ⌘V, then restores whatever was on your clipboard.

## Choosing the models

Dictation is really two jobs: **turning sound into words**, and **turning words into what you meant**. I picked a model for each.

**For speech, NVIDIA's Parakeet TDT 0.6B**, run as CoreML on the Mac's **Neural Engine** through [FluidAudio](https://github.com/FluidInference/FluidAudio). The Neural Engine is a part of the chip that mostly sits idle, so recognition doesn't fight the GPU. I tried three versions:

| Version | Disagreement with Wispr | Error rate vs my final text | Time for the last 8 s of audio |
|---|---|---|---|
| v2 | 6.2% | 20.6% | ~55 ms |
| v3 | 5.7% | 21.8% | ~59 ms |
| **Ultra** | **5.5%** | 21.3% | ~61 ms |

Ultra won, narrowly. It also understands 25 European languages, which is a nice bonus.

**For clean-up, a small language model.** I tried Qwen3.5 at 0.8B and 2B parameters, and Google's Gemma 4 E2B, all 4-bit in MLX. I ended up with the smallest, **Qwen3.5-0.8B**, plus a LoRA adapter trained on my data. Small enough to answer in a couple of hundred milliseconds, and small enough to train on a laptop overnight.

Here's how it all fits together:

<figure class="flow" aria-label="Pipeline: hold the key and listen, Parakeet transcribes each chunk on the Neural Engine, Qwen3.5-0.8B cleans it up using screen context, then the text is pasted at the cursor. Your edits feed the dictionary.">
<p class="flow__ctx"><b>Screen context</b>, read on-device through Accessibility: the app, names on screen, text around the cursor, selection, URL, local time</p>
<ol class="flow__steps">
<li class="flow__step"><span class="flow__n">1</span><span class="flow__t">Listen</span><span class="flow__d">Hold right ⌥ or fn. Audio is cut into chunks at natural pauses.</span><span class="flow__m">16 kHz, while held</span></li>
<li class="flow__step"><span class="flow__n">2</span><span class="flow__t">Transcribe</span><span class="flow__d">Parakeet TDT 0.6B on the Neural Engine, via CoreML.</span><span class="flow__m">~40–60 ms per chunk</span></li>
<li class="flow__step is-ctx"><span class="flow__n">3</span><span class="flow__t">Clean up</span><span class="flow__d">Qwen3.5-0.8B (4-bit) plus a LoRA adapter, in MLX on the GPU.</span><span class="flow__m">while you talk</span></li>
<li class="flow__step"><span class="flow__n">4</span><span class="flow__t">Paste</span><span class="flow__d">Clipboard plus ⌘V, verified, then your clipboard is restored.</span><span class="flow__m">~0.31 s after release</span></li>
</ol>
<p class="flow__learn"><b>Learning:</b> corrections you make after a paste go into your dictionary, and your history can train a personal adapter overnight</p>
</figure>

Now the fun part: how I actually got there, step by step.

## Step 1: is speech recognition even fast enough?

This was the first thing I had to know. If transcription took a second, the whole idea was dead.

It took **39 to 64 milliseconds** to transcribe the last 8 seconds of audio, at every dictation length. A 7-minute ramble took 1.7 seconds in one go. So the answer was: if you transcribe in chunks while someone's still talking, speech recognition is basically free at the moment they let go.

Accuracy was the real gap. Most of my errors were names and jargon: "Claude" became "claw", ChatGPT got mangled, colleagues' surnames came out wrong. Not a speed problem, a vocabulary problem.

## Step 2: can a small model just… clean it up?

My first instinct: give an off-the-shelf small model a good prompt and see what happens.

It was a disaster, and a really funny one. The tiny model read my dictations as **chat messages and replied to them**. I'd dictate a prompt meant for Claude, and it would answer "I'm ready to help!" instead of tidying my words. That's a real problem, because 18 of my 20 test dictations were prompts going into an AI assistant. Its output was literally worse than the raw transcript.

Rewriting the prompt as "you are a transcription cleaner, not an assistant, keep every word" fixed the behaviour:

| Model | Error rate (raw transcript: 0.149) | Short | Medium | Long |
|---|---|---|---|---|
| Qwen3.5-0.8B | 0.161 | 169 ms | 393 ms | 829 ms |
| Qwen3.5-2B | **0.129** | 380 ms | 814 ms | 2.26 s |
| Gemma 4 E2B | 0.130 | 394 ms | 855 ms | 2.81 s |

The bigger models were more accurate but way too slow on long dictations (Wispr takes about 0.65 seconds). The small one was quick but still no better than doing nothing. That pushed me into two decisions that shaped everything after:

1. **Clean up in small chunks while you're still talking**, so there's almost nothing left to do at the end.
2. **Make the small model good by training it**, rather than reaching for a bigger one.

## Step 3: teaching it my dictionary (it backfired)

Wispr lets you keep a dictionary of names, so I fed my 54 words straight into the speech model to nudge it towards them.

Errors went **up**, from 20.6% to 23.0%, and it got four times slower. It started hearing my dictionary everywhere: "Slack" became "Stacy" eight times, and "right" became "Rich" twelve times. Most of the words it missed weren't even in my dictionary.

Lesson: vocabulary belongs in the clean-up step, where the model can see the context, not in the ears. I dropped this idea entirely.

## Step 4: a fair way to keep score

At this point I realised my scoring was biased. I was comparing everything against "my final text", but when I hadn't edited a dictation, my final text *was* Wispr's output. Of course Wispr looked good.

So I built a neutral answer key: three independent speech models (Wispr, Parakeet and Qwen3-ASR-1.7B, which I used only as a referee) each transcribed the same recordings, and the majority won.

<figure class="chart">
<p class="chart__title">Raw speech recognition vs the neutral key: words right out of 100</p>
<div class="chart__rows">
<div class="chart__row" title="Wispr Flow: 98.1"><span class="chart__name">Wispr Flow</span><span class="chart__track"><i style="--v:98.1%"></i></span><span class="chart__val">98.1</span></div>
<div class="chart__row is-hi" title="Parakeet Ultra: 96.8"><span class="chart__name">Parakeet Ultra</span><span class="chart__track"><i style="--v:96.8%"></i></span><span class="chart__val">96.8</span></div>
<div class="chart__row" title="Qwen3-ASR-1.7B: 96.9"><span class="chart__name">Qwen3-ASR</span><span class="chart__track"><i style="--v:96.9%"></i></span><span class="chart__val">96.9</span></div>
</div>
<p class="chart__note">10 recordings, 748 words. Caveats: Wispr is one of the three voters, and it had screen context.</p>
</figure>

Wispr's speech model leads by about 1.3 points, partly because it sees your screen, which helps with names. That told me where to spend my effort: **context**, not a bigger speech model.

## Step 5: training it on me

This is where it all came together. I fine-tuned Qwen3.5-0.8B with LoRA on my own history: the raw transcript plus which app I was in as the input, and my edit (or Wispr's output, if I hadn't edited) as the answer.

The first version was a huge jump on short and medium dictations. Errors on short ones halved (0.052 → **0.024**), and it was about twice as fast as the 2B model. When I plugged it into the app, release-to-paste was **112 to 388 milliseconds** on dictations up to 31 seconds long, against Wispr's 650 ms on my history.

Then I gave it more to learn:

- **Screen context:** names on screen and the text before the cursor.
- **Structure:** lists, emails and quotes, built from my own sentences.
- **Self-corrections:** 994 real ones from my history ("Tuesday, sorry, Wednesday"), plus 900 built ones.

It got much better at corrections. But it also got worse on longer dictations, and that's when I had to stop and look hard at how I was testing.

## Step 6: where I'd been fooling myself

I audited my own setup, and honestly, it wasn't pretty:

| Check | What I found |
|---|---|
| Test recordings kept out of training | ✅ |
| Near-duplicates leaking into training | ✅ none above 63% similarity |
| Validation stable between runs | ❌ adding data reshuffled it, so the model had seen some "validation" examples |
| Behaviour tests independent of training | ❌ drawn from the validation set, so contaminated |
| Test set only used for final numbers | ❌ I'd been picking models with it |
| Test set measures genuinely new dictations | ❌ random dates, mixed in with training data |
| Enough data to be confident | ❌ only 20 recordings, no error bars |

So I rebuilt the whole setup:

- **A split that never moves:** each example goes to training or validation by a hash of its content.
- **A dev set** of 80 recordings, for choosing between models.
- **A test set split by time:** every recording made after a cut-off date, never trained on, only scored at milestones.
- **Behaviour tests** (corrections, lists, emails, sign-offs) built from sentences held out of training.
- **95% confidence intervals** on every headline number.
- **A rule written down in advance:** a new model only ships if it beats the old one on dev *and* test, without getting worse at anything.

It's slower to work this way. But it's the only way I'd trust the numbers I'm showing you here.

## Step 7: real life breaks benchmarks

Using it for real emails exposed bugs no test had caught:

- A **duplicated list item** where two chunks met ("2. Implementation / 3. Implementation").
- **Unformatted sign-offs**, because a length check counted words by spaces, so "Regards,\nKai" looked like one word and got rejected.
- **Wrong names**, because reading the whole window picked up Gmail's menu labels instead of the email I was writing.

The fixes were in the app, not the model: proper word counting, list de-duplication and renumbering, and **reading the screen nearest-first**, from the field you're typing in outwards, skipping menus and toolbars. I also added **learning from edits**: after pasting, the app quietly watches the field for up to a minute, notices if you fix a name, and adds it to your dictionary.

## Step 8: corrections, emails and the screen

With a proper test setup, I retrained more gently (a lower learning rate with a warm-up), which fixed the regression on longer dictations. Self-corrections improved enormously:

<figure class="chart">
<p class="chart__title">Self-correction error on the test set (lower is better)</p>
<div class="chart__rows">
<div class="chart__row" title="Before: 0.490"><span class="chart__name">Before</span><span class="chart__track"><i style="--v:100%"></i></span><span class="chart__val">0.490</span></div>
<div class="chart__row is-hi" title="After: 0.074"><span class="chart__name">After</span><span class="chart__track"><i style="--v:15.1%"></i></span><span class="chart__val">0.074</span></div>
</div>
<p class="chart__note">Emails laid out correctly also went from 31 to 39 out of 40.</p>
</figure>

Then I gave the model **everything the app can see**:

- your name, locale, time zone and local time (no GPS)
- the website you're on
- your selected text, and the text before and after the cursor
- names and words from the screen

In training I randomly left each of these out now and then, so the model copes when the app can't read something. I added targeted examples for misheard names, misheard sign-offs and spoken times:

| Test | Before | After |
|---|---|---|
| Fixing a misheard name | 0.168 | **0.080** |
| Misheard sign-off name | 0.120 | **0.043** |
| Spoken times ("nine thirty") | 0.075 | **0.018** |
| A correction, then more speech | 0.098 | **0.035** |

That became my personal model.

## Step 9: a model anyone can download

My personal model is full of my emails, so I can't publish it. For everyone else, I trained a **general model on 12,000 made-up dictations**: invented people, invented companies, nine English-speaking locales, 36 kinds of jobs, and 14 behaviours, from lists and emails to code and terminal commands. GPT-5-mini wrote the clean version first, then a messy speech-style version of it. The whole dataset cost about **$11.50**.

<figure class="chart">
<p class="chart__title">Error rate on my real test recordings (lower is better)</p>
<div class="chart__rows">
<div class="chart__row" title="Untrained Qwen3.5-0.8B: 0.528"><span class="chart__name">Untrained</span><span class="chart__track"><i style="--v:100%"></i></span><span class="chart__val">0.528</span></div>
<div class="chart__row is-hi" title="General model, made-up data only: 0.232"><span class="chart__name">General model</span><span class="chart__track"><i style="--v:43.9%"></i></span><span class="chart__val">0.232</span></div>
<div class="chart__row" title="My personal model: 0.210"><span class="chart__name">My model</span><span class="chart__track"><i style="--v:39.8%"></i></span><span class="chart__val">0.210</span></div>
</div>
<p class="chart__note">72 recordings. The general model has never seen my data, yet lands within about 2 points of my own model.</p>
</figure>

One trap I nearly fell into: the training numbers kept improving all the way to the end, but on real speech the best version was **less than halfway through**. After that, it was learning GPT's idea of how people talk, not how people actually talk.

## Step 10: training on your Mac, overnight

The last piece was the one I was most excited about: letting *anyone* train their own model, inside the app, on their own Mac.

**How it works:**

- MurmurBee imports your Wispr Flow history (read-only) and its own history.
- It takes up to 6,000 recent examples, and your hand-edited ones count three times.
- It trains a LoRA adapter on the general model in MLX Swift, and pauses whenever you're dictating.
- It runs in a separate background process, so if macOS's GPU watchdog interrupts a long training step (it happens), the app itself never crashes, and training picks up from the last checkpoint.
- **The safety net:** your newest dictations are held back as a test. The new model is only switched on if it beats the one you're using.

**The result:**

<figure class="chart">
<p class="chart__title">Error rate on 150 held-back dictations (lower is better)</p>
<div class="chart__rows">
<div class="chart__row" title="General model: 0.174"><span class="chart__name">General model</span><span class="chart__track"><i style="--v:100%"></i></span><span class="chart__val">0.174</span></div>
<div class="chart__row is-hi" title="Trained on my Mac, best run: 0.093"><span class="chart__name">Trained on me</span><span class="chart__track"><i style="--v:53.4%"></i></span><span class="chart__val">0.093</span></div>
</div>
<p class="chart__note">The best personal model trained inside the app made 47% fewer mistakes than the general one.</p>
</figure>

Not every training run turns out that well, which is exactly why the safety net exists: you only ever get a model that's better than the one you had.

## Where it landed

| | MurmurBee | Wispr Flow 1.6 |
|---|---|---|
| Release to text (median) | **0.31 s** | 0.65 s |
| App size | **70 MB** (+ ~1 GB of models, once) | 515 MB |
| Background processes | **1** | 13 |
| Raw speech accuracy | 96.8% | **98.1%** |
| Works offline | **Yes** | No |
| Price | **Free, open source** | Subscription |

## What I learned

- **Your own data beats a bigger model.** A 0.8-billion-parameter model trained on my history does what I need better than much bigger general ones.
- **Context is the secret ingredient.** Knowing the app, the names on screen and what's already written fixed more errors than any model upgrade.
- **Measure honestly, or you'll fool yourself.** Most of my early wins shrank once I tested properly. The ones left are the ones I trust.
- **A laptop is enough.** Everything here, training included, ran on a MacBook Air with my other apps open.

## Finally

So I made this, and for me it works much better in a bunch of ways: it's faster, it's lighter, it works on a plane, and it knows my words. I wanted everyone to be able to use it at no cost, so I turned it into a proper Mac app, fully free, and added a way to train the model on your own Mac and make it yours with the click of a button.

I hope you enjoy it. [Download MurmurBee here](https://murmurbee.com), and the code is all [on GitHub](https://github.com/kai-kaushik/murmurbee) if you want to poke around.

And if you like it and you're feeling generous, [buy me a coffee](https://ko-fi.com/kaikaushik) with the little cup button on the website. Feeling selfish? Don't! No hard feelings. It's free either way.
