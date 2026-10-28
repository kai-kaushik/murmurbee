---
title: How I built a private, personal Wispr Flow on my MacBook
description: The full story of building MurmurBee - my own Wispr data, Parakeet on the Neural Engine, Qwen3.5-0.8B fine-tuned with LoRA in MLX, a proper evaluation protocol, synthetic data, and on-device training on a MacBook Air.
date: 2026-10-27
order: 3
---

<div class="cover" aria-hidden="true">
<svg viewBox="0 0 1200 520" role="presentation">
  <path class="c-line" d="M250 410h640"/>
  <g class="c-honey">
    <rect x="290" y="150" width="56" height="260" rx="10"/>
    <rect x="390" y="200" width="56" height="210" rx="10"/>
    <rect x="490" y="250" width="56" height="160" rx="10"/>
    <rect x="590" y="290" width="56" height="120" rx="10"/>
    <rect x="690" y="325" width="56" height="85" rx="10"/>
    <rect x="790" y="352" width="56" height="58" rx="10"/>
  </g>
  <path class="c-trail" d="M846 330c60-40 80-120 160-150"/>
  <image href="/assets/murmurbee-bee.svg" x="990" y="90" width="120" height="116"/>
</svg>
</div>

If you just want to know what MurmurBee does, I wrote [a shorter post about that here](/blog/i-built-my-own-wispr-flow/), but this one is for the people who are curious about how it actually got built, so I go through what I was aiming for, how I went about it, which models I picked and why, and the experiments along the way, including the ones that didn't work out.

## The goal

I've been working in AI for about a decade now, a good chunk of that as a computer vision engineer, and if there's one thing I've learnt over and over again it's that the best model for a job is usually the one trained on the right data, which for dictation basically means a model trained on you, on your names and your jargon and the way you write emails and correct yourself halfway through a sentence.

So what I wanted was a dictation app that was:

- **Local**, so it works offline and nothing I say ever leaves my Mac.
- **Free**, because I didn't want to pay a subscription for something my laptop should be able to do by itself.
- **Fast**, ideally faster than Wispr Flow from the moment I let go of the key to the moment the text shows up.
- **Light**, rather than yet another 500 MB app with a dozen background processes.
- **Personal**, and this was the big one, actually trained on me.

## My own data, sitting right there

What made this whole thing possible is that Wispr Flow keeps a local history of everything you dictate, and since I'd been using it for ages, I basically had a treasure trove of personal training data sitting on my laptop the whole time. It had:

- **10,535 dictations**, each with Wispr's raw transcript, its cleaned-up output and my own edit whenever I'd corrected something.
- **880 of them with audio** still attached, about 7.2 hours in total, because Wispr only keeps recent recordings.
- **The app I was in** for most rows, plus some of what was on screen.

That's a ready-made supervised dataset of exactly how one person talks and what they actually wanted typed, which is pretty much the dream. I exported it read-only, so Wispr's own files were never touched.

## Everything on one MacBook

I also gave myself one more rule, which was that everything had to happen on my laptop, training included, with no cloud GPUs at all, because if a MacBook Air can't do it then normal people won't be able to use it either. The machine was a MacBook Air with an M4 chip and 32 GB of memory, and I kept my usual apps open the whole time because that's what real life looks like.

For training I used Apple's [MLX](https://github.com/ml-explore/mlx) framework, first `mlx-lm` in Python for the research phase and later MLX Swift inside the app itself, and the app is a native Swift menu-bar app that reads the focused app and the nearby screen text through the macOS Accessibility API and pastes with the clipboard plus ⌘V, putting back whatever you had on your clipboard afterwards.

## Choosing the models

Dictation is really two separate problems, turning sound into words and then turning those words into what you actually meant, so I picked a model for each.

For speech recognition I went with NVIDIA's **Parakeet TDT 0.6B**, running as CoreML on the Mac's **Neural Engine** through [FluidAudio](https://github.com/FluidInference/FluidAudio). The Neural Engine mostly sits idle on a Mac, so running ASR there means it never competes with the GPU, which matters once you also want a language model and training running on the same machine. I compared three versions of it:

| Version | Disagreement with Wispr | WER vs my final text | Latency, last 8 s of audio |
|---|---|---|---|
| v2 | 6.2% | 20.6% | ~55 ms |
| v3 | 5.7% | 21.8% | ~59 ms |
| **Ultra** | **5.5%** | 21.3% | ~61 ms |

Ultra won by a small margin, and it also covers 25 European languages, which was a nice bonus.

For the clean-up step I wanted a small language model, so I tried Qwen3.5 at 0.8B and 2B parameters and Google's Gemma 4 E2B, all quantised to 4-bit in MLX, and in the end I went with the smallest one, **Qwen3.5-0.8B**, with a LoRA adapter trained on my data on top. It's small enough to respond in a couple of hundred milliseconds and small enough to fine-tune on a laptop overnight, and as you'll see, with the right data it ended up being more than enough.

This is how it all fits together:

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

With that in place, here's how I actually got there, step by step.

## Step 1: is on-device ASR fast enough?

This was the first thing I needed to know, because if transcription took a second the whole idea was dead on arrival. It turned out to take **39 to 64 milliseconds** to transcribe the last 8 seconds of audio, at every dictation length, and even a 7-minute ramble took 1.7 seconds in one go. So as long as you transcribe in chunks while someone is still talking, speech recognition is basically free at the moment they let go of the key.

The real gap was accuracy, and when I looked at the errors they were almost all names and jargon, so "Claude" turned into "claw", ChatGPT got mangled and colleagues' surnames came out wrong, which told me it wasn't a speed problem at all but a vocabulary and context problem.

## Step 2: zero-shot clean-up with a prompt

My first instinct was to give an off-the-shelf small model a good prompt and see how far that got me, and the answer was not very far, but in a pretty funny way. The 0.8B model treated my dictations as chat messages and replied to them, so I'd dictate a prompt meant for Claude and it would cheerfully answer "I'm ready to help!" instead of cleaning up my words, which is a real problem when 18 of my 20 test dictations were prompts going into an AI assistant. Its WER was actually worse than leaving the raw transcript alone.

Reframing the task in the prompt as a transcription cleaner rather than an assistant, with an instruction to keep every word, fixed the behaviour:

| Model | WER (raw transcript: 0.149) | Short p50 | Medium p50 | Long p50 |
|---|---|---|---|---|
| Qwen3.5-0.8B | 0.161 | 169 ms | 393 ms | 829 ms |
| Qwen3.5-2B | **0.129** | 380 ms | 814 ms | 2.26 s |
| Gemma 4 E2B | 0.130 | 394 ms | 855 ms | 2.81 s |

The bigger models were more accurate but far too slow on long dictations, considering Wispr takes about 0.65 seconds, and the small one was quick but no better than doing nothing. That led to the two decisions that shaped everything after it:

1. **Run the clean-up on small chunks while the user is still talking**, so there's almost nothing left to do at key release.
2. **Make the small model good through fine-tuning**, instead of reaching for a bigger one.

## Step 3: acoustic vocabulary biasing

Wispr lets you keep a dictionary of names, so I tried feeding my 54 dictionary terms into the speech model through a CTC keyword spotter to bias recognition towards them, and it actually made things worse. WER went up from 20.6% to 23.0%, latency went from about 240 to 840 ms, and it started hallucinating my dictionary everywhere, so "Slack" became "Stacy" eight times and "right" became "Rich" twelve times. On top of that, most of the words the model was missing weren't in my dictionary in the first place.

The takeaway was that vocabulary belongs in the clean-up step, where the model can see the surrounding context, rather than in the acoustic model, so I dropped biasing completely.

## Step 4: removing label bias from the evaluation

Early on I realised there was a bias baked into my labels, because I was scoring everything against my final text, and for any dictation I hadn't edited, my final text simply was Wispr's output, so any comparison with Wispr was tilted in its favour. To get around that I built a neutral reference by majority vote across three independent ASR systems on the raw audio (Wispr, Parakeet and Qwen3-ASR-1.7B, which I only ever used as a referee), and scored everyone against that.

<figure class="chart">
<p class="chart__title">Raw speech recognition vs the neutral key: words right out of 100</p>
<div class="chart__rows">
<div class="chart__row" title="Wispr Flow: 98.1"><span class="chart__name">Wispr Flow</span><span class="chart__track"><i style="--v:98.1%"></i></span><span class="chart__val">98.1</span></div>
<div class="chart__row is-hi" title="Parakeet Ultra: 96.8"><span class="chart__name">Parakeet Ultra</span><span class="chart__track"><i style="--v:96.8%"></i></span><span class="chart__val">96.8</span></div>
<div class="chart__row" title="Qwen3-ASR-1.7B: 96.9"><span class="chart__name">Qwen3-ASR</span><span class="chart__track"><i style="--v:96.9%"></i></span><span class="chart__val">96.9</span></div>
</div>
<p class="chart__note">10 recordings, 748 words. Caveats: Wispr is one of the three voters, and it had screen context.</p>
</figure>

Wispr's speech model leads by about 1.3 points, and part of that comes from it seeing your screen, which helps a lot with names. That pointed me straight at where to spend my effort, which was context rather than a bigger acoustic model.

## Step 5: fine-tuning on my own history

This is where it all started coming together. I fine-tuned Qwen3.5-0.8B with LoRA (16 layers) on my history, using the raw transcript plus an app header as the input and my edit, or Wispr's output if I hadn't edited it, as the target.

The first adapter was a big jump on short and medium dictations, with WER on short ones dropping from 0.052 to **0.024**, at roughly half the latency of the 2B model, and once I plugged it into the app, release-to-paste came in at **112 to 388 milliseconds** on dictations up to 31 seconds long, against Wispr's median of 650 ms on my history.

From there I kept widening the training data, adding screen context (names on screen and the text before the cursor), structured examples like lists, emails and quotes built from my own sentences, and self-corrections, both 994 real ones from my history ("Tuesday, sorry, Wednesday") and 900 synthetic ones. Self-correction error dropped a lot, but longer dictations regressed, most likely because I'd resumed training with a fresh optimiser at full learning rate and no warm-up, which shakes an adapter early on. That was also the point where I decided the project needed a much stricter evaluation protocol before I trusted any more numbers.

## Step 6: a proper evaluation protocol

A weekend prototype can get away with a quick test set, but once I knew I wanted to publish numbers, I rebuilt the evaluation the way I'd want to see it done at work, so I audited my own setup with the same eye I'd use reviewing someone else's work, and man, there was a lot to tighten up. My validation split could shift whenever I added data, my behaviour tests were drawn from that same validation pool, and twenty test clips with no error bars just isn't enough to make claims on. So I locked it all down:

| Piece | How it works |
|---|---|
| Train / validation split | Deterministic, by a hash of each example's content, so adding data never moves an example between splits |
| Dev set | 80 stratified clips, used only for checkpoint and model selection |
| Test set | A temporal hold-out: every clip recorded after a fixed cut-off date, never trained on, scored only at milestones |
| Leakage control | Near-duplicates (over 80% similarity) are kept in the same split, and dev and test sentences are excluded from all synthetic training data |
| Behaviour suites | Corrections, lists, emails, sign-offs and continuations, generated from held-out sentence pools |
| Statistics | Bootstrap 95% confidence intervals on every headline number |
| Promotion rule | Written down in advance: a model only ships if it beats the current one on dev and test with no suite regressions |

It's slower to work this way, but it's the only way I'd stand behind the numbers in this post.

## Step 7: what real use catches that benchmarks don't

Using it for real emails turned up a few bugs that no benchmark had caught:

- **A list item got duplicated across a chunk boundary** ("2. Implementation / 3. Implementation").
- **Sign-offs came out unformatted**, because a length check counted words by spaces, so "Regards,\nKai" looked like a single word and got rejected.
- **Names came out wrong**, because reading the whole window picked up Gmail's menu labels instead of the email I was actually writing.

All of those were fixed in the app rather than the model, with proper whitespace-aware word counting, list de-duplication and renumbering, and nearest-first screen reading that starts at the field you're typing in and works outwards while skipping menus and toolbars. I also added learning from edits, where the app quietly watches the field for up to a minute after pasting, diffs your corrections and adds any corrected names to your dictionary.

## Step 8: corrections, emails and full screen context

With the new protocol in place I retrained more gently, with a 3e-5 peak learning rate, a 200-step warm-up and cosine decay, and I started scoring long dictations the way the app actually processes them, in chunks with the already-written text as context. That kept the self-correction gains without the earlier regression, and the behaviour gains held up on the held-out test suites.

<figure class="chart">
<p class="chart__title">Self-correction error on the test set (lower is better)</p>
<div class="chart__rows">
<div class="chart__row" title="Before: 0.490"><span class="chart__name">Before</span><span class="chart__track"><i style="--v:100%"></i></span><span class="chart__val">0.490</span></div>
<div class="chart__row is-hi" title="After: 0.074"><span class="chart__name">After</span><span class="chart__track"><i style="--v:15.1%"></i></span><span class="chart__val">0.074</span></div>
</div>
<p class="chart__note">Emails laid out correctly also went from 31 to 39 out of 40.</p>
</figure>

After that I gave the model everything the app can see, so the prompt now carries:

- your name, locale, time zone and local time (no GPS)
- the URL when you're in a browser
- your selected text, and the text before and after the cursor
- names and words from the screen, as vocabulary

During training each of those fields gets dropped 10 to 20% of the time so the model copes gracefully when the app can't read something, and I added targeted examples for misheard names, misheard sign-off names and spoken times:

| Test suite (WER) | Before | After |
|---|---|---|
| Fixing a misheard name | 0.168 | **0.080** |
| Misheard sign-off name | 0.120 | **0.043** |
| Spoken times ("nine thirty") | 0.075 | **0.018** |
| A correction, then more speech | 0.098 | **0.035** |

That became my personal model.

## Step 9: a general model trained on synthetic data

My personal model is trained on my emails, so publishing it was never an option, and for everyone else I trained a **general model on 12,000 synthetic dictations**. I generated them with GPT-5-mini from seeded scenario cards covering invented people and companies, nine English-speaking locales, 36 kinds of jobs and 14 behaviours, from lists and emails to code, terminal commands and instruction-like text that has to be cleaned rather than obeyed. The generator writes the clean target first and then derives a noisy, ASR-style transcript from it, and the whole dataset cost about **$11.50**.

<figure class="chart">
<p class="chart__title">Error rate on my real test recordings (lower is better)</p>
<div class="chart__rows">
<div class="chart__row" title="Untrained Qwen3.5-0.8B: 0.528"><span class="chart__name">Untrained</span><span class="chart__track"><i style="--v:100%"></i></span><span class="chart__val">0.528</span></div>
<div class="chart__row is-hi" title="General model, made-up data only: 0.232"><span class="chart__name">General model</span><span class="chart__track"><i style="--v:43.9%"></i></span><span class="chart__val">0.232</span></div>
<div class="chart__row" title="My personal model: 0.210"><span class="chart__name">My model</span><span class="chart__track"><i style="--v:39.8%"></i></span><span class="chart__val">0.210</span></div>
</div>
<p class="chart__note">72 recordings. The general model has never seen my data, yet lands within about 2 points of my own model.</p>
</figure>

The interesting part was the distribution shift. Validation loss on the synthetic data kept going down right to the end of training, but on real speech the best checkpoint was at step 2,000 out of 5,000, and after that the model was getting better at GPT's idea of a transcript rather than real ASR output, so I early-stopped on the real dev set instead of the synthetic one.

## Step 10: training on your Mac, overnight

The last piece, and honestly the one I was most excited about, was letting anyone train their own model inside the app, on their own Mac. The way it works is:

- **Data:** MurmurBee imports your Wispr Flow history (read-only) along with its own history, and takes up to 6,000 recent examples, with your hand edits weighted three times.
- **Training:** a LoRA adapter (rank 8, 16 layers) on top of the general model in MLX Swift, with an answer-only loss, a short warm-up and a cosine schedule, which pauses whenever you start dictating.

Training runs in a separate background process with a checkpoint every 200 steps, because macOS's GPU watchdog can occasionally kill a long Metal command buffer, and that should never take the app down with it. Your newest dictations are held out as a test set, and the new model is only switched on if it beats the one you're already using, which acts as a safety net.

<figure class="chart">
<p class="chart__title">Error rate on 150 held-back dictations (lower is better)</p>
<div class="chart__rows">
<div class="chart__row" title="General model: 0.174"><span class="chart__name">General model</span><span class="chart__track"><i style="--v:100%"></i></span><span class="chart__val">0.174</span></div>
<div class="chart__row is-hi" title="Trained on my Mac, best run: 0.093"><span class="chart__name">Trained on me</span><span class="chart__track"><i style="--v:53.4%"></i></span><span class="chart__val">0.093</span></div>
</div>
<p class="chart__note">The best personal model trained inside the app made 47% fewer mistakes than the general one.</p>
</figure>

Not every training run turns out that well, which is exactly why that gate exists, so you only ever end up with a model that's better than the one you had.

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

- **Your own data beats a bigger model.** A 0.8-billion-parameter model trained on my history does what I need better than much larger general-purpose ones.
- **Context is the secret ingredient.** Knowing the app, the names on screen and what's already written fixed more errors than any model upgrade did.
- **Measuring properly matters.** The numbers I'm showing here are the ones that survived a strict protocol, which is why I trust them.
- **A laptop really is enough.** Everything in this post, training included, ran on a MacBook Air with my other apps open, which is maybe the most fun one.

## Finally

So I made this, and for me it works much better in a bunch of ways, it's faster, it's lighter, it works on a plane and it knows my words. I wanted everyone to be able to use it at no cost, so I turned it into a proper Mac app, fully free, and added a way to train the model on your own Mac and make it yours with the click of a button.

I hope you enjoy it. You can [download MurmurBee here](https://murmurbee.com), and the code is all [on GitHub](https://github.com/kai-kaushik/murmurbee) if you want to poke around.

And if you like it and you're feeling generous, [buy me a coffee](https://ko-fi.com/kaikaushik) with the little cup button on the website, and if you're feeling selfish, don't, no hard feelings, it's free either way.
