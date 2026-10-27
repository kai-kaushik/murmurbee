---
title: Building a local Wispr Flow alternative - the full experiment report
description: Every experiment behind MurmurBee, in detail. Parakeet on the Neural Engine, Qwen3.5-0.8B fine-tuned with LoRA in MLX, evaluation mistakes, synthetic data, and on-device training on a MacBook Air.
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

This is the long version. If you just want to know what MurmurBee is, [the short story is here](/blog/i-built-my-own-wispr-flow/). This post is the lab notebook, cleaned up: what I tried, the exact models and settings, the numbers, and the mistakes I made along the way. Everything ran on one MacBook Air (M4, 32 GB) with other apps open, because that's where people will actually use it.

The raw log, with every table, is [in the repo](https://github.com/kai-kaushik/murmurbee/blob/main/docs/EXPERIMENTS.md).

## The goal

Match the bit of Wispr Flow I actually use, entirely on-device:

1. Hold a key, talk, let go.
2. Get clean, well-formatted text pasted at the cursor, in any app.
3. Do it in well under a second, with nothing leaving the Mac.

Wispr is the baseline throughout. I ran Wispr Flow 1.6 on the same Mac and used its own logged output and latency for the same dictations.

## The data

Wispr keeps a local SQLite history. I exported mine read-only: **10,535 dictations with text**, of which **880 still had audio** (about 7.2 hours, 16 kHz; Wispr only keeps recent audio). Each row has Wispr's raw transcript, its formatted output, my edit if I made one, the app, and some screen context.

That history turned out to be the single most valuable thing in the project. It's a ready-made training set of how one specific person talks and what they wanted typed.

## The architecture

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

- **Speech recognition:** NVIDIA **Parakeet TDT 0.6B** (v2, then v3, then Ultra) as CoreML on the **Apple Neural Engine**, via [FluidAudio](https://github.com/FluidInference/FluidAudio).
- **Clean-up:** **Qwen3.5-0.8B**, 4-bit, running in **MLX Swift** on the GPU, with a LoRA adapter.
- **App:** a native Swift menu-bar app. It reads the focused app and nearby screen text through the Accessibility API, and pastes with the clipboard plus ⌘V, verifying the paste and restoring your previous clipboard.

## E01: is local speech recognition fast enough?

Parakeet v2 on the Neural Engine, model loaded once and warmed, on a fixed 20-clip test set.

| Measure | Result |
|---|---|
| Latency, last 8 s of audio | 39–64 ms at every clip length |
| Latency, whole clip | 41–56 ms short, 124–431 ms for 40–77 s, 1.66 s for 425 s |
| WER vs my final text | 20.6% (Wispr's raw transcript: 17.8%) |

Speech recognition is effectively free at key release, as long as you transcribe in chunks while the user talks. The accuracy gap was almost entirely names and jargon: Claude → "claw", ChatGPT, my colleagues' surnames.

## E02–E03: can a small model clean up with just a prompt?

Qwen3.5-0.8B and 2B, then Gemma 4 E2B, all MLX 4-bit, temperature 0, cached system prompt.

The first prompt failed in a way I didn't expect. The 0.8B model treated dictations as **chat messages and replied to them**: "I'm ready to help", "Can we do that?". That's a real risk, because 18 of my 20 test dictations were prompts going into an AI assistant. Its WER (0.34) was worse than the raw transcript (0.149).

Reframing it as "a transcription cleaner, not an assistant, keep every word" fixed the behaviour:

| Model | WER (raw: 0.149) | Short p50 | Medium p50 | Long p50 |
|---|---|---|---|---|
| Qwen3.5-0.8B | 0.161 | 169 ms | 393 ms | 829 ms |
| Qwen3.5-2B | **0.129** | 380 ms | 814 ms | 2.26 s |
| Gemma 4 E2B | 0.130 | 394 ms | 855 ms | 2.81 s |

2B-class models help but are far too slow on long input, and the 0.8B still doesn't beat the raw transcript. Two decisions came out of this: **clean up in chunks while the user is still talking**, and **make the 0.8B good through fine-tuning** rather than scaling up.

## E04: Parakeet v3 and Ultra

| Model | Disagreement with Wispr raw | WER vs final | Last-8 s latency |
|---|---|---|---|
| v2 | 6.2% | 20.6% | ~55 ms |
| v3 | 5.7% | 21.8% | ~59 ms |
| **Ultra** | **5.5%** | 21.3% | ~61 ms |

Ultra (Moondream's post-train of v3) became the default. On 20 clips the differences are directional, not significant. It also covers 25 European languages, which is why MurmurBee understands more than English.

## E05: acoustic vocabulary biasing (it made things worse)

I fed my 54-term Wispr dictionary into a CTC keyword spotter to bias recognition.

- **Default thresholds:** WER went from 20.6% to **23.0%**, latency from ~240 to ~840 ms, and it hallucinated my dictionary everywhere: Slack → "Stacy" ×8, right → "Rich" ×12.
- **Strict thresholds:** neutral at best.

Most missed words weren't in the dictionary at all. Vocabulary belongs in the clean-up prompt, fed by what's on screen, so acoustic biasing was dropped.

## E06: a neutral answer key

Scoring against "my final text" is biased towards Wispr: when I didn't edit, my final text *is* Wispr's output. So I built a neutral key for 10 clips by majority vote of three independent recognisers on the raw audio: Wispr, Parakeet Ultra, and **Qwen3-ASR-1.7B** as a referee (used only for answer keys, never in the app).

<figure class="chart">
<p class="chart__title">Raw recognition vs the neutral key: words right out of 100</p>
<div class="chart__rows">
<div class="chart__row" title="Wispr Flow: 98.1"><span class="chart__name">Wispr Flow</span><span class="chart__track"><i style="--v:98.1%"></i></span><span class="chart__val">98.1</span></div>
<div class="chart__row is-hi" title="Parakeet Ultra: 96.8"><span class="chart__name">Parakeet Ultra</span><span class="chart__track"><i style="--v:96.8%"></i></span><span class="chart__val">96.8</span></div>
<div class="chart__row" title="Qwen3-ASR-1.7B: 96.9"><span class="chart__name">Qwen3-ASR</span><span class="chart__track"><i style="--v:96.9%"></i></span><span class="chart__val">96.9</span></div>
</div>
<p class="chart__note">10 clips, 748 reference words. Caveats: Wispr is one of the voters, and it had screen context.</p>
</figure>

Wispr's speech model leads by about 1.3 points, and it had screen context, which helps with names. The likely way to close that gap is context, not a bigger speech model.

## E07–E10: fine-tuning the 0.8B on my history

**Setup:** LoRA on 16 layers of Qwen3.5-0.8B with `mlx-lm`, batch 1–2, max sequence 768–1,024 tokens, gradient checkpointing. Inputs are the raw transcript plus an app header; targets are my edit if I made one, otherwise Wispr's output.

**v1 (E07)** was a huge win on short and medium input (short WER 0.052 → **0.024**, medium 0.127 → **0.093**) at about half the latency of the 2B. The fused model hit 157 ms short and 352 ms medium. But it fell apart on long input: repetition loops and dropped content. It was underfit there, because training inputs were capped at 300 words.

**E08, the first real app:** release-to-paste of **112–388 ms** on dictations up to 31 seconds, against Wispr's median of 650 ms on my history. The first build looked slow (1.3–1.5 s) until I found the time was a paste-confirmation timeout, not the models.

**v2 data (E09)** added screen context (app, vocabulary, text before the cursor), continuations, and structure built from my own sentences: lists, emails and quotes. **E10** added self-corrections: 994 real ones Wispr had applied in my history, plus 900 built ones ("Tuesday, sorry, Wednesday"). Self-correction error fell from 0.38 to 0.25. But medium and long dictations regressed badly.

## The evaluation audit (where I'd been fooling myself)

At this point I audited my own setup, and it wasn't pretty:

| Check | Status |
|---|---|
| Test clips excluded from training | ✅ |
| Near-duplicate leakage | ✅ max similarity 0.63 |
| Validation stable across runs | ❌ adding data reshuffled the split, so E10's validation overlapped E09's training data |
| Behaviour suites independent of training | ❌ drawn from validation, so contaminated |
| Test set used only for final numbers | ❌ I'd been picking models with it, which makes it a dev set |
| Test set measures new dictations | ❌ random dates, interleaved with training data |
| Enough data | ❌ n = 20, no confidence intervals |

So from E11 on:

- **Hash-based train/validation split**, so adding data never moves examples.
- **Dev set** (80 clips) for choosing checkpoints.
- **Test set**, a **time split**: every clip recorded after a cut-off date, never trained on, scored only at milestones.
- **Near-duplicates** (similarity > 0.8) kept in the same split.
- **Behaviour suites** generated from held-out sentence pools.
- **Bootstrap 95% confidence intervals** on every headline number.
- **A pre-registered promotion rule:** better on dev *and* test, with no suite regression.

## E11: real-use failures, fixed in the app

Live email dictations exposed bugs that no benchmark had:

- A **duplicated list item** across a chunk boundary ("2. Implementation / 3. Implementation").
- **Unformatted sign-offs**, caused by a length check that counted words by spaces, so "Regards,\nKai" looked like one word and was rejected.
- **Wrong names**, because whole-window screen reading picked up Gmail's menu labels instead of the compose window.

The fixes were in the app, not the model: proper whitespace word counts, list de-duplication and renumbering, and **nearest-first screen reading** (from the focused field outwards, skipping menus and toolbars). I also added **learning from edits**: the app watches the field for up to 60 seconds after pasting, diffs your corrections, and adds corrected names to the dictionary. It learned a colleague's name from the first time I corrected it.

## E12: retraining on locked splits

Gentler schedule: lr 3e-5 peak (E10 used 1e-4 with no warm-up), 200-step warm-up, cosine decay, 3,000 steps at batch 1. The first attempt died with a Metal out-of-memory error at step ~135, with a Node process eating 5.8 GB. Halving the batch fixed it.

<figure class="chart">
<p class="chart__title">Self-correction suite on the test split (WER, lower is better)</p>
<div class="chart__rows">
<div class="chart__row" title="Before E12: 0.490"><span class="chart__name">Before</span><span class="chart__track"><i style="--v:100%"></i></span><span class="chart__val">0.490</span></div>
<div class="chart__row is-hi" title="E12 step 3,000: 0.074"><span class="chart__name">E12</span><span class="chart__track"><i style="--v:15.1%"></i></span><span class="chart__val">0.074</span></div>
</div>
<p class="chart__note">Email layout also went from 31 to 39 of 40. Clip WER was a statistical tie (0.214 vs 0.222, overlapping CIs).</p>
</figure>

Behaviours improved massively, but clip WER was a tie, so by my own rule it **wasn't auto-promoted**. The lesson: I was scoring long clips as one input, which isn't how the app works. From E13 on, clips are scored **the way the app processes them**: cut into ~25-word chunks, each cleaned with the already-written text as context.

## E13: full screen context (prompt v3)

The prompt gained everything the app can see, with each field dropped 10–20% of the time in training so the model copes when a field is missing:

- your **name**, **locale**, **time zone** and **local time** (no GPS)
- the **URL** in browsers
- **selected text**, and the text **before and after** the cursor
- names and words from the screen, as **vocabulary**

New targeted data covered misheard names (776), misheard sign-off names (400) and spoken times (400). Results on the test suites:

| Test suite (WER) | Before | E13 |
|---|---|---|
| Name fix | 0.168 | **0.080** |
| Misheard sign-off | 0.120 | **0.043** (34/34 laid out right) |
| Spoken time | 0.075 | **0.018** |
| Correction, then more speech | 0.098 | **0.035** |

This became **v4**, my personal model.

## E14: a model anyone can download

My personal models are trained on my emails, so they can't be published. For the public download I generated **12,000 synthetic dictations** with `gpt-5-mini` from seeded "scenario cards": invented speakers across 9 English locales and 36 roles, 14 behaviours (self-corrections including hard negatives, lists, emails, code and terminal, numbers, instruction-like text that must be cleaned and not obeyed). The generator writes the clean target first and derives a noisy ASR-style transcript from it. Cost: about **$11.50**.

<figure class="chart">
<p class="chart__title">WER on my real test clips (lower is better)</p>
<div class="chart__rows">
<div class="chart__row" title="Untuned Qwen3.5-0.8B: 0.528"><span class="chart__name">Untuned base</span><span class="chart__track"><i style="--v:100%"></i></span><span class="chart__val">0.528</span></div>
<div class="chart__row is-hi" title="Public model (synthetic data only): 0.232"><span class="chart__name">Public model</span><span class="chart__track"><i style="--v:43.9%"></i></span><span class="chart__val">0.232</span></div>
<div class="chart__row" title="My personal model: 0.210"><span class="chart__name">My model</span><span class="chart__track"><i style="--v:39.8%"></i></span><span class="chart__val">0.210</span></div>
</div>
<p class="chart__note">n = 72. The public model has never seen my data and gets within about 2 points of my personal model.</p>
</figure>

One trap: synthetic validation loss kept falling all the way to step 5,000, but on real speech the **best checkpoint was step 2,000**. After that the model was learning GPT's idea of a transcript rather than real ASR output. On the public synthetic suite it's far better than my personal model on other people's kinds of dictation (code 0.197 vs 1.183, numbers 0.127 vs 0.660).

## E15: training a personal model inside the app

The last step was moving training out of Python and into the app, so anyone can do it overnight.

**How it works:**

- Import your Wispr Flow history (read-only), plus MurmurBee's own history.
- Up to 6,000 recent examples; your hand edits count 3×.
- LoRA rank 8 on 16 layers of the public model, Adam, batch 1, **answer-only loss**, in MLX Swift.
- Learning rate 5e-5 with a 60-step warm-up and cosine decay to 10%.
- Training **pauses while you dictate**, and runs in a **separate helper process**. macOS's GPU watchdog can kill a long Metal command buffer, and that should never take down the app.
- **A held-out gate:** your newest *independent* dictations (from Wispr or hand-edited, never the current model's own output) are held back. The new model is only installed if it beats the one you use.

**Bugs found along the way:**

- At lr 1e-4 training diverged (loss 0.36 → 1.76 in 30 steps).
- A first n=60 result (44% fewer errors) shrank on n=150. I corrected the claim.
- The GPU watchdog crashed the whole app. That's why training moved to a helper process with checkpoints every 200 steps.
- Resuming after a crash restored the weights but reset Adam's moment estimates. MLX Swift's `Adam` keeps its state private, so I wrote my own with saveable state. A run killed with `kill -9` and resumed now matches an uninterrupted run exactly.

**Results** on 150 held-out dictations (lower is better):

| Model | Held-out WER |
|---|---|
| General model, no personal training | 0.174 |
| v4 (my Python-trained personal model) | 0.109 |
| On-device, 1,200 steps, lr 2e-5 | 0.128 |
| On-device, 1,200 steps, lr 5e-5 cosine, edits 3× | 0.116 / 0.119 (two seeds) |
| **On-device, 2,400 steps, best run** | **0.093** |

The best on-device run made **47% fewer mistakes** than the general model. But the honest headline is the spread: the same 2,400-step recipe ranged from **0.093 to 0.164** across seeds. That's bigger than any setting I changed. One run is a coin flip around v4, so the gate matters more than the recipe. Picking the best of three late snapshots on a 60-dictation validation set didn't fix the variance either: 60 dictations is too few to tell snapshots apart.

## Where it landed

| | MurmurBee | Wispr Flow 1.6 |
|---|---|---|
| Release to text (median) | **0.31 s** | 0.65 s |
| App size | **70 MB** (+ ~1 GB of models, once) | 515 MB |
| Background processes | **1** | 13 |
| Raw recognition accuracy | 96.8% | **98.1%** |
| Works offline | **Yes** | No |
| Price | **Free, open source** | Subscription |

## What I'd do next

- **Reduce run-to-run variance:** average several runs, or ensemble the adapters, instead of trusting one.
- **A bigger validation set** for snapshot selection, so it isn't picking noise.
- **A blind A/B against Wispr's clean-up**, scored only on dictations I edited, which is the only fair head-to-head.
- **Streaming speech recognition**, to shave the last few tens of milliseconds.

If you want to dig in, the code, the scripts and the full log are all [on GitHub](https://github.com/kai-kaushik/murmurbee). And if you try training your own model, I'd genuinely love to see your numbers.
