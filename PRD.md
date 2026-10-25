# PRD: Local Flow (working name)

A local-first dictation app for macOS: hold a key, speak, release, and clean text appears where your cursor is. It should be as fast as Wispr Flow and as accurate, run entirely on the Mac, get better the more you use it, and install with one drag.

| | |
|---|---|
| Owner | Kai Kaushik |
| Status | Draft v1, 24 Oct 2026 |
| Platform | macOS 15+ on Apple Silicon (M1 and later). macOS 26+ adds optional extras. |
| Inputs | [How Wispr Flow is built](https://claude.ai/artifact/1SBBQNGQqwUuEsj19z63mv) teardown, a structural look at Voicebox 0.5.0 on this Mac, and model research current to Oct 2026 (sources in the appendix) |

---

## 1. The product in one paragraph

Hold **Fn** and talk. A small pill at the bottom of the screen shows the app is listening. Let go, and within half a second the text lands in whatever app you're using: punctuated, without fillers, with your "no wait, I meant Thursday" already applied, and with your names and jargon spelled correctly. Nothing leaves the Mac. When you fix a word after it's pasted, the app notices and gets it right next time. That's the whole product.

## 2. Why build this

- **Wispr Flow is excellent but cloud-bound.** Every dictation streams audio and on-screen context to Wispr's servers, and the full history is uploaded ([teardown §01, §06](https://claude.ai/artifact/1SBBQNGQqwUuEsj19z63mv)). It's also heavy: a 515 MB Electron bundle, about 13 processes and about 1.35 GB of RAM at idle on this Mac, plus a 1.2 GB SQLite file with a 1.1 GB daily backup beside it.
- **The open-source local options are bloated or fragile.** Voicebox (installed here) is really a voice-cloning and TTS studio with dictation bolted on. It ships a 528 MB Tauri app that spawns a 485 MB PyInstaller Python server over localhost HTTP, and its code includes logic for finding "orphaned" server processes. On this Mac it has 7 recordings on disk but 0 rows in its captures table, two byte-identical 49-minute runaway recordings, and a server crash a minute after those were written.
- **Local models are now good enough.** Parakeet TDT 0.6B runs on the Neural Engine at roughly 100–150× real time with about 2.1–2.5% WER on LibriSpeech clean (FluidAudio, M4 Pro). Small instruct models (Qwen3.5 0.8B/2B, Apache-2.0) can do the cleanup. On-device LoRA and DPO training works through MLX.

## 3. Goals and non-goals

### Goals
1. **Fast.** Median release-to-paste under 500 ms for a typical utterance, beating Wispr's 650 ms median measured on Kai's own history.
2. **Accurate.** At least as good as Wispr on Kai's own dictations, measured on a personal eval set (§10), not on vibes.
3. **Learns.** Fewer edits per dictation over time, with no setup from the user.
4. **Light.** One process, an app bundle under 25 MB, near-zero CPU at idle.
5. **Private.** No network calls apart from the model download and update checks. No account.
6. **Installs itself.** Drag to Applications, grant three permissions, and the app picks, downloads and warms the right models for this Mac.

### Non-goals (deliberately cut)
TTS or voice cloning, meeting notes, transcribing files, a notes or scratchpad app, cloud sync, accounts, teams, Windows or Linux, a history browser with search and tags, themes, plugins, MCP, command mode ("open Slack and..."). Every one of these is somewhere in Wispr or Voicebox and is why those apps are heavy. Each can be revisited only after v1 hits its metrics.

## 4. What we copy from Wispr, and what we change

| Wispr does (from the teardown) | We do | Why |
|---|---|---|
| Streams Opus audio to the cloud while the key is held, so release only has to finish the job | **Transcribe and clean locally *while you talk*.** Chunk the audio at natural pauses, transcribe each chunk as it finishes, and clean finished sentences in the background. Release only processes the last chunk. | This is the single most important idea in Wispr. Kai's dictations average 33 s, and no model cleans 33 s of text in 500 ms from a cold start. |
| `/warmup` before dictation | Keep models resident and pre-warmed. Cache the cleanup model's system prompt (KV cache) at launch. Compile the ANE model during onboarding. | The first CoreML ANE compile takes about 15 s. Pay that once, never on a dictation. |
| `Init` message carries on-screen context, dictionary and name | A context snapshot on key-down: frontmost app, window title, text before the cursor, selected text and dictionary terms. It feeds both ASR biasing and the cleanup prompt. | Context steers spelling before the first word. |
| Swift helper: CGEventTap for Fn, Accessibility reads, lazy-clipboard paste | **The whole app is that Swift helper.** No Electron, no IPC. | Wispr needed Electron for its UI and a native helper for everything that matters. We keep only the helper. |
| Lazy pasteboard item + Cmd+V; the target app requesting data confirms the paste; old clipboard restored | Copy exactly. Fall back to AX `setValue` and then to synthetic typing if the paste isn't confirmed. | Proves the side effect, and never clobbers the clipboard. |
| History row stores asrText, formattedText, pastedText, editedText, edit distance, default and fallback outputs, model origin | Copy the schema (§9), keep it local, and use it to train the user's own model. | Edits are free labels. The `origin` column makes every model change measurable. |
| Fine-tuned Llama 8B formatters on Baseten; Canto ASR trained with SFT + GRPO on opted-in corrections | A small fine-tuned cleanup model on device, plus a per-user LoRA trained on that user's own corrections, gated by a local shadow eval. | The same loop, at personal scale. |
| Streaming first, REST fallback, records which path served each request | Neural cleanup first, rules-only fallback if the model is slow or fails, and every row records which path served it. | Never block the user on the LLM. |

From Voicebox, the anti-patterns to avoid: a Python sidecar, a localhost HTTP boundary, multiple processes, unbounded recordings, writing files without a DB row, and shipping features unrelated to dictation.

## 5. User experience

### 5.1 Core interactions (all of v1)
| Action | Result |
|---|---|
| **Hold Fn**, speak, release | Text is inserted at the cursor. |
| **Double-tap Fn** | Hands-free mode. Tap Fn again to stop and insert. |
| **Esc** while recording | Cancel. Nothing is inserted and nothing is saved. |
| **Fn + Ctrl** (configurable) | Re-paste the last result, for when focus moved or the paste failed. |
| Menu bar icon | Status, last 20 dictations (click to copy), Dictionary, Settings, Quit. |

Hotkeys are rebindable. During onboarding we detect Fn, and if macOS's "Press 🌐 to show emoji" setting is on, we tell the user how to turn it off. If they'd rather keep it, we offer Right Option as the hold key.

### 5.2 The pill
A small capsule centred above the Dock. It's a non-activating `NSPanel`, so it never steals focus.
- **Listening:** a live waveform from the mic level.
- **Finishing:** a short shimmer, usually under 0.5 s.
- **Done:** fades out. If the paste couldn't be confirmed, it shows "Copied. Press ⌘V" and leaves the text on the clipboard.
- **No speech heard:** a gentle shake, and nothing is inserted.

### 5.3 Settings (one window, one screen)
- Hotkey
- Microphone (default: system default, prefers a built-in mic over a Bluetooth headset, as Wispr does, to avoid the drop to HFP audio quality)
- Language (Auto / English / one of 25 European languages)
- Cleanup level: **Off**, **Light** (punctuation, fillers, self-corrections) or **Polished** (also tone and formatting per app)
- Learn from my edits (on by default)
- Launch at login
- Storage: keep audio for N days (default 0, text only), and "Delete everything"

That's the entire settings surface.

### 5.4 Dictionary
A simple list of words and phrases, each with an optional "sounds like" alias (for example: `Northwind` ← "kai gen", "caygen"). Entries come from three places:
- Words the user adds.
- **Auto-learned** entries, tagged as such, created when the user corrects a word after pasting (§8).
- A one-time import from Contacts names (opt in).

Plus replacements, for example "my email" → the user's email.

## 6. Functional requirements

**P0 (v1 cannot ship without these)**

| # | Requirement |
|---|---|
| F1 | A global hold-to-talk hotkey (Fn by default) through a listen-only `CGEventTap`. It works in every app, including full-screen apps and secure fields. In secure fields we refuse to record and show a lock in the pill. |
| F2 | Audio capture with AVAudioEngine at 16 kHz mono, a 300 ms pre-roll ring buffer so the first syllable isn't clipped, and a hard cap of 10 minutes per dictation, so no runaway recordings. |
| F3 | Silero VAD drops silence and leading/trailing noise. If there's no speech, nothing is inserted. |
| F4 | Local ASR (Parakeet TDT via FluidAudio on the ANE), transcribing chunks at VAD pauses while the key is held. |
| F5 | A context snapshot on key-down (app bundle ID, window title, roughly 500 characters before the cursor, selected text) through Accessibility. If AX isn't available, degrade quietly. |
| F6 | The cleanup pipeline from §7.3: rules → skip gate → LLM → validator. Fallback is rules-only output. |
| F7 | Insertion with a lazy pasteboard + Cmd+V and confirmation, then clipboard restore. Fallback is AX `setValue` and then CGEvent typing. Re-paste-last on its hotkey. |
| F8 | Local SQLite history (§9), with atomic writes: a row exists before any audio file does. |
| F9 | The dictionary, with ASR biasing (FluidAudio CTC custom vocabulary) and post-ASR alias replacement. |
| F10 | First-run setup (§11): permissions, picking a model by RAM, a resumable checksummed download, ANE pre-warm and a test dictation. |
| F11 | Signed and notarized DMG, Sparkle auto-update, launch at login. |

**P1 (fast follow)**

| # | Requirement |
|---|---|
| F12 | Edit capture: re-read the target field after insertion to record what the user changed (§8.1). |
| F13 | Auto-learned dictionary entries from edits. |
| F14 | Few-shot personalisation: retrieve similar past (raw → final) pairs for this app into the cleanup prompt. |
| F15 | Per-app styles inferred from the bundle ID (Slack and Messages casual; Mail and Docs formal; terminals and IDEs literal, with code identifiers preserved and no sentence-casing of commands). |
| F16 | Nightly on-device LoRA/DPO training with a shadow-eval gate and rollback (§8.3). |
| F17 | Import Kai's Wispr history as a training and eval seed (§10.2). Personal use only. |

**P2 (later, only if metrics justify)**
- An "Accurate" ASR mode using Qwen3-ASR-1.7B for 16 GB+ Macs.
- A live partial transcript in the pill.
- Apple Foundation Models as a no-download cleanup fallback on macOS 26+.
- Spoken formatting commands ("new paragraph", "bullet point").

## 7. Architecture

### 7.1 Language decision: native Swift, not Rust

You asked for Rust "or something like that". Having looked at it, **Swift is the better choice for a Mac-only app, and it's just as efficient**: compiled, no garbage collector, no runtime, no webview. The work that matters here is all Apple-native:

| Need | Swift | Rust |
|---|---|---|
| ANE inference for Parakeet (CoreML) | FluidAudio, used by VoiceInk, Spokenly and Hex | Needs a Swift/ObjC bridge, or falls back to Metal via transcribe.cpp (no ANE, and no documented hotword biasing) |
| LLM inference + LoRA training | MLX Swift (mlx-swift-lm, including LoRA training) | Bindings exist but are less mature; MLX is Apple's first-class Swift/Python project |
| CGEventTap, Accessibility, NSPasteboard lazy items, NSPanel | First-class APIs | `objc2` FFI everywhere; `rdev` reportedly crashes on macOS 14+ off the main thread |
| Apple Foundation Models / SpeechAnalyzer (macOS 26) | Direct | Swift bridge required (Handy does exactly this) |
| UI | SwiftUI/AppKit, a few MB | Tauri = a webview + JS frontend, which is the bloat we're avoiding |

Handy (Tauri + Rust) is the best cross-platform reference, and even it ships a Swift bridge for Apple features. Since we're Mac-only, writing everything in Swift removes the bridge, the webview and a whole class of FFI bugs. **Decision: Swift 6, SwiftUI for the two small windows, AppKit for the panel, one process, `LSUIElement` (no Dock icon).** If Windows ever matters, revisit with Rust plus transcribe.cpp.

### 7.2 Components (one process, one binary)

```
 Fn down ─▶ HotkeyMonitor ──▶ Session ──┬─▶ ContextSnapshot (AX)
                                        ├─▶ AudioCapture ─▶ VAD ─▶ Chunker
                                        │                            │ (chunk at each pause)
                                        │                     ASREngine (Parakeet, ANE)
                                        │                            │ raw text per chunk
                                        │                     Cleaner (rules → gate → LLM on GPU)
 Fn up ───▶ finalize last chunk ────────┘                            │ cleaned text
                                                              Inserter (lazy paste, confirm)
                                                                     │
                                       Store (SQLite) ◀── row ───────┤
                                       EditWatcher ◀── re-read field ┘
                                       Learner (idle/nightly) ─▶ dictionary, few-shot index, LoRA adapter
```

- **ASR runs on the ANE and the LLM runs on the GPU**, so they don't compete. Chunk N+1 transcribes while chunk N is being cleaned.
- **Concurrency:** Swift actors, one per engine. The UI is never blocked.
- **Memory:** models are memory-mapped. An "unload after 15 min idle" setting (default off on 16 GB+, on for 8 GB) frees about 1.5 GB, with a roughly 2 s reload on the next key press.

### 7.3 The cleanup pipeline

1. **Rules (always, under 5 ms):** dictionary alias replacement, filler removal ("um", "uh", "like," with care), spacing and capitalisation, spoken punctuation, number/email/URL normalisation.
2. **Skip gate:** if the utterance is short (under about 8 words) and the rules found nothing to fix, paste the rules output. This covers a large share of quick replies and keeps them under 150 ms.
3. **LLM:** a fine-tuned small model with a fixed system prompt (cached KV), the context snapshot, the current app's style, 3–5 retrieved examples of the user's own past corrections, and the raw text. It outputs only the cleaned text.
   - **Incremental:** sentences that finish while the user is still talking get cleaned in the background. On release, we clean the last chunk together with the previous sentence, so cross-boundary self-corrections still work ("...on Tuesday. No, actually Thursday").
   - **Fast decoding:** cleanup output is mostly a copy of its input, which makes it ideal for prompt-lookup (n-gram) speculative decoding. Expect roughly 2–3× faster generation; verify in M0.
4. **Validator:** reject the LLM output and fall back to the rules output if it is more than X% shorter or longer than the input, adds content (answers a question instead of transcribing it), or misses a deadline (1.5 s by default). Log which path won.

### 7.4 Models

| | 8 GB Macs | 16 GB+ Macs (Kai's M4 32 GB) |
|---|---|---|
| ASR | **Parakeet TDT 0.6B** via FluidAudio CoreML/ANE: v2 if English only, v3 for 25 languages. ~0.6–0.9 GB, ~100×+ real time | Same default. P2: Qwen3-ASR-1.7B (MLX 5-bit, ~1.9 GB, best open avg WER 5.40, 52 languages, context-promptable) as "Accurate" mode |
| ASR biasing | FluidAudio CTC keyword spotter (Parakeet 110M CTC) with dictionary terms and aliases | Same |
| VAD | Silero (FluidAudio) | Same |
| Cleanup LLM | **Qwen3.5-0.8B**, our fine-tune, 4-bit, ~0.5 GB, MLX Swift | **Qwen3.5-2B**, our fine-tune, 4-bit, ~1.3 GB. Try 4B on 32 GB only if it fits the latency budget |
| Fallback | Rules only. On macOS 26+ with Apple Intelligence on: Foundation Models (P2) | Same |
| Total download | ~1.2 GB | ~2 GB |

**Candidates to benchmark in M0 before locking these in:**
- Parakeet Ultra: a post-trained v3 with a CoreML port. The vendor reports 5.80 vs 6.26 avg WER, but that's not independently verified.
- Gemma 4 E2B (Apache-2.0) as the alternative cleanup base.
- Apple SpeechAnalyzer: no download, but weaker on long conversational speech in Argmax's test.

**Licences:**
- Parakeet: CC-BY-4.0 (attribution in the About box).
- Qwen3.5: Apache-2.0.
- FluidAudio: Apache-2.0.
- MLX: MIT.
- Avoid: LFM (revenue cap), Superwhisper S1-mini (custom licence), Nemotron (OpenMDW), Granite "-nc".

Note: Thinking mode must be disabled on Qwen3.5.

### 7.5 Base cleanup model training (one time, offline, done by us)

Fine-tune Qwen3.5-0.8B and 2B on about 50–100k pairs:
- **Synthetic:** a large model generates disfluent "spoken" versions of clean text (fillers, restarts, self-corrections, spoken numbers and emails, lists dictated aloud, code identifiers), across app styles. The training input is the messy version; the target is the clean original.
- **Real:** Kai's own Wispr history, asrText → final text (see §10.2). This is personal data, used for Kai's own model and eval only, and not redistributed.

The input format carries a control header (`app=slack style=casual level=polished`) so one model serves every style; S1-mini follows the same design. Train with mlx-lm (LoRA, then fuse) on Kai's M4. Ship the fused 4-bit weights as the downloadable base.

## 8. Learning over time

This is the same loop as Wispr's, at personal scale and entirely on device. Four layers, from instant to nightly.

### 8.1 Capturing the signal
After inserting, **EditWatcher** re-reads the focused element through Accessibility three times: when focus leaves the field, after 30 s, and after 2 minutes. It diffs the result against what we pasted, limited to the inserted span (we know its range from the caret position at insert time). That produces `editedText` and `editDistance`. A "Copy" from the history menu followed by a paste counts as "accepted". Unreadable fields (some Electron or web inputs) yield no signal and are skipped. We never guess.

### 8.2 Layers
| Layer | When | What changes | Signal |
|---|---|---|---|
| L0 Dictionary auto-learn | Immediately | A single-word correction where the replacement sounds similar to what was heard (phonetic plus edit distance check) becomes a dictionary entry with an alias, tagged *Auto-learned*. It's removed if never matched in 30 days. | The edit diff |
| L1 ASR biasing | Next dictation | Dictionary terms feed the CTC spotter. FluidAudio works best with 1–50 terms, so we pass the top 50 by recency and by relevance to the context snapshot (for example, Slack channel members). | Dictionary + context |
| L2 Few-shot retrieval | Next dictation | The 3–5 most similar past (raw → final) pairs from the same app go into the prompt. Similarity is a small local embedding, or BM25 to start. | Accepted + edited rows |
| L3 Personal adapter | Nightly, on power, idle, once there are ≥200 new rows | A LoRA SFT on (raw → final) pairs, then DPO with the user's edit as *chosen* and our output as *rejected* (mlx-lm-lora, or a Swift port). | Edits as preferences |

### 8.3 The shadow gate (stolen from Wispr)
Every candidate adapter is scored against a held-out 10% of the user's own edited rows, using normalised edit distance to the user's final text. It's promoted only if it beats the current adapter by a margin and doesn't regress on a fixed "golden" set (§10). The previous adapter is kept for one-click rollback. Every row records `cleanupOrigin` (base model + adapter version), so improvement is visible week over week.

### 8.4 Is this "reinforcement learning"?
In practice, the right approach at personal scale is **preference learning (DPO) from edits**, which is the offline, stable cousin of RL. The reward is clear: minimise how much the user edits. Once there are thousands of rows, GRPO with reward = −edit distance against the user's final text is a straightforward extension using the same data and the same gate. Wispr uses GRPO for Canto with fleet-wide data. With one user's data, DPO is more sample-efficient and much less likely to drift. ASR fine-tuning per user is out of scope for v1; biasing (L1) gives most of that win at a fraction of the risk.

## 9. Data model (SQLite, via GRDB)

```
dictations
  id, createdAt, durationMs, appBundleId, windowTitle
  asrText            -- raw ASR output
  rulesText          -- after rules layer
  cleanedText        -- final inserted text
  cleanupPath        -- skip | llm | fallback_rules | fallback_timeout
  asrOrigin          -- e.g. parakeet-tdt-v2@fa0.17
  cleanupOrigin      -- e.g. qwen3.5-2b-lf1+adapter-2026-11-03
  insertMethod       -- lazy_paste | ax_set | typed | clipboard_only
  insertConfirmed    -- bool
  editedText, editDistance, editCapturedAt
  latencyMs_total, latencyMs_asrFinal, latencyMs_cleanup
  audioPath NULL     -- only if the user opted into audio retention
dictionary(id, phrase, aliases[], source: user|auto|contacts, hits, lastHitAt)
adapters(id, createdAt, baseModel, trainRows, evalScore, status: candidate|active|retired)
```

Storage stays small: text only by default, roughly 1 KB per row, so 10k dictations is about 10 MB, against Wispr's 1.2 GB. WAL mode, weekly `VACUUM`, no full-database daily backups.

## 10. How we measure "accurate"

### 10.1 Metrics
| Metric | Target v1 | How |
|---|---|---|
| Release-to-paste latency p50 / p90 | ≤ 500 ms / ≤ 1.2 s (Wispr on Kai's history: 650 ms / 1.36 s) | `latencyMs_total` |
| Short utterance (< 8 words) p50 | ≤ 200 ms | Same |
| Edit rate (% dictations edited) | ≤ Wispr's rate on Kai's history, falling month over month | `editedText IS NOT NULL` |
| Normalised edit distance | Beats Wispr on the golden set | §10.2 |
| ASR WER (golden audio) | ≤ 6% | §10.2 |
| Paste confirmed | ≥ 99% | `insertConfirmed` |
| Idle CPU / app RSS excluding models | ~0% / < 80 MB | Instruments |
| Crash-free sessions | ≥ 99.9% | Local crash log, no telemetry |

### 10.2 The golden set, from Kai's Wispr history
Kai's local `flow.sqlite` holds about 10.5k dictations with Wispr's asrText, formatted and edited text. That makes three assets:
1. **Cleanup eval:** feed Wispr's asrText into our cleaner and compare with Kai's final text. That's a direct head-to-head on the formatting stage.
2. **Training seed** for the base fine-tune (§7.5).
3. **ASR eval:** if any audio is retained (to be checked), compare WER directly. If not, Kai records 100 natural dictations, which takes about 30 minutes, as the ASR golden set.

All of this stays on Kai's machine.

## 11. Install and first run

**Target: under 3 minutes from download to first dictation, with no terminal.**

1. Download a signed, notarized DMG (~15 MB) from the site, or `brew install --cask localflow`. Drag to Applications.
2. Launch. A single onboarding window with four steps and a check mark for each:
   - **Microphone:** the system prompt.
   - **Accessibility:** a deep link to System Settings. The app detects the grant live and continues.
   - **Input Monitoring** (needed for the Fn event tap): deep link, detected live.
   - **Models:** "This Mac: M4, 32 GB → Standard pack (2 GB)." A progress bar downloads from Hugging Face over a resumable connection with SHA-256 verification and a mirror fallback, into `~/Library/Application Support/LocalFlow/models`. While it downloads, the user reads a 3-line "how to use" card.
3. **Warm up and test:** compile the ANE model (~15 s, shown as "Tuning for your Mac"), then "Hold Fn and say: *Hi, I'm testing this, um, on Tuesday, no, Wednesday*." Show the before and after. Done.
4. It lives in the menu bar and launches at login by default.

**Updates:** Sparkle, with signed appcasts. Model updates are versioned separately and downloaded in the background, and they go through the same shadow gate before becoming the default.

**Offline install:** an optional "Full DMG" that bundles the Standard model pack (~2 GB), for air-gapped or slow networks.

## 12. Privacy and security

- **Network:** model downloads and update checks only, to pinned hosts. A "Network" line in Settings states this plainly.
- **No telemetry by default.** Opt-in anonymous crash reports only.
- **Secure fields:** detected through AX `AXSecureTextField`. We refuse to record.
- **Storage:** audio is not stored by default. Text history lives in the app's own container with FileVault-level protection. "Delete everything" wipes the DB, adapters and the dictionary.
- Hardened runtime, notarized, minimal entitlements (audio input, plus Accessibility and Input Monitoring granted through TCC).

## 13. Milestones

| Milestone | Scope | Exit criteria |
|---|---|---|
| **M0 Spike** (1 wk) | CLI benchmarks on Kai's M4 and on a base 8 GB M1/M2: Parakeet v2/v3/Ultra WER and latency on the golden audio; Qwen3.5 0.8B/2B and Gemma 4 E2B tokens/s, TTFT and prompt-lookup speedup; Apple FM latency and guardrail hits on 200 real dictations | Model table §7.4 locked with measured numbers |
| **M1 Core loop** (2 wk) | Hotkey, capture, VAD, chunked ASR, rules cleanup, lazy-paste insert, pill, SQLite | Kai uses it all day with cleanup "Light (rules)"; paste confirmed ≥ 99% |
| **M2 Neural cleanup** (2 wk) | Base fine-tune trained on synthetic data + Kai's history; incremental cleanup; validator; per-app style | Beats Wispr on the cleanup golden set; p50 ≤ 500 ms |
| **M3 Learning** (2 wk) | EditWatcher, auto-dictionary, few-shot retrieval, nightly LoRA/DPO with shadow gate | Edit rate visibly falls over 2 weeks of Kai's use |
| **M4 Ship** (1 wk) | Onboarding, model downloader, Sparkle, notarized DMG, Homebrew cask | A non-technical tester installs and dictates in under 3 minutes |

## 14. Risks and open questions

| Risk | Mitigation |
|---|---|
| Cleanup LLM too slow on base M1 for long utterances | Incremental cleanup while talking, prompt-lookup decoding, 0.8B model on low-end hardware, a 1.5 s deadline with rules fallback |
| Parakeet has weak punctuation and occasional single-word hallucinations (Superwhisper's docs say so) | The cleanup layer handles punctuation; the VAD + minimum-duration gate stops single-word ghosts |
| AX can't read some fields (Electron/web), so no edit signal | Learn only from fields that are readable; plenty of signal comes from native apps, Slack and browsers' standard inputs |
| Fn key conflicts (emoji picker, Globe shortcuts) | Detect during onboarding, guide the user, offer an alternative key |
| CTC biasing capped around 50 terms | Pick terms per dictation by context relevance |
| Personal adapter drifts or overfits | Shadow gate, golden set, rollback, minimum row count |
| Apple ships systemwide on-device cleanup dictation (announced for iOS 27; macOS unconfirmed) | Our edge is personal learning, speed and per-app context. Watch WWDC27 |

**Open questions for Kai:**
1. Does Wispr's local DB keep any audio, or only text? This decides whether we get a free ASR golden set.
2. Name and distribution: personal tool first, or public from day one? This affects signing, the website and support.
3. Should "Polished" mode be allowed to change wording (tone rewrite), or only fix form? Wispr does change wording in some apps.
4. Is English plus European languages enough for v1, or do we need Hindi or Japanese early? Japanese would push Qwen3-ASR into P0.

## Appendix: sources

- Wispr teardown: https://claude.ai/artifact/1SBBQNGQqwUuEsj19z63mv (Wispr Flow 1.6.1174; Baseten customer story; Wispr Canto post)
- Open ASR Leaderboard (updated 22 Oct 2026): https://huggingface.co/spaces/hf-audio/open_asr_leaderboard
- FluidAudio benchmarks and custom vocabulary: https://docs.fluidinference.com/reference/benchmarks, https://docs.fluidinference.com/asr/custom-vocabulary, https://github.com/FluidInference/FluidAudio
- Soniqo Apple Silicon ASR benchmarks: https://soniqo.audio/benchmarks
- Argmax on SpeechAnalyzer: https://www.argmaxinc.com/blog/apple-and-argmax
- mlx-lm LoRA: https://github.com/ml-explore/mlx-lm/blob/main/mlx_lm/LORA.md; mlx-lm-lora (DPO/GRPO): https://github.com/Goekdeniz-Guelmez/mlx-lm-lora
- Apple Foundation Models adapter toolkit status: https://developer.apple.com/apple-intelligence/foundation-models-adapter/
- Wispr dictionary auto-learn behaviour: https://wispr.notion.site/Dictionary-1992ebdc733481a08064efd983f19f0f
- Handy (Tauri reference): https://github.com/cjpais/Handy; transcribe.cpp: https://github.com/handy-computer/transcribe.cpp
- S1-mini design reference: https://betterstack.com/community/guides/ai/s1-mini/
- Local observations (this Mac, 24 Oct 2026): Voicebox 0.5.0 bundle and data layout; Wispr Flow 1.6.1253 bundle, process count and data directory sizes. No user content read.
