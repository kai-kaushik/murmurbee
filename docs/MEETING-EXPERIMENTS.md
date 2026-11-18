# Meeting notes: experiment log

A lab notebook for one question: can a Mac take Granola-style meeting notes (a transcript that knows who said what,
then a good summary) with every model running locally? Same rules as the dictation log (`EXPERIMENTS.md`): each
experiment records the question, exactly what ran, the numbers, and what was concluded, including what went wrong.
Hypotheses are written down **before** each experiment runs, so the write-up can show predictions next to results.

Scripts live in `scripts/meetings/`, raw outputs in `bench/meetings/`.

## Fixed setup

| | |
|---|---|
| Hardware | MacBook Air, Apple M4 (10-core), 32 GB, macOS 26.6. Other apps running throughout |
| Speech recognition | Parakeet TDT Ultra (the model MurmurBee ships; a post-train of NVIDIA Parakeet TDT 0.6B v3), CoreML via FluidAudio (commit c79c410), Neural Engine |
| Diarization | FluidAudio (same commit): offline pyannote-community-1 pipeline (CoreML), Sortformer, LS-EEND |
| Summaries | Small instruction-tuned LLMs through MLX (mlx-lm 0.32.2), 4-bit |
| Scoring | pyannote.metrics 4 (DER), meeteval 0.4.3 (WER, cpWER), Whisper's English text normaliser (from transformers) on both sides |

## Data

**Test set: the official AMI test split**, 16 meetings (EN2002a–d, ES2004a–d, IS1009a–d, TS3003a–d), the split NeMo,
pyannote and FluidAudio publish on. AMI Meeting Corpus, University of Edinburgh, CC BY 4.0. Each meeting is 3–5 people
in a room, about 15–50 minutes, in English, with many non-native speakers. Three audio views are used:

- **Mix**: all headset microphones summed into one channel (`Mix-Headset.wav`). Stands in for a recording of a meeting
  where everyone is in one stream.
- **Individual headsets**: one close-talking microphone per participant (`Headset-N.wav`). Each picks up a little of
  the people sitting nearby.
- **Simulated call** (built from the headsets, see M02): one participant plays "you" and their headset is the mic
  channel; the other headsets summed play the system-audio channel, i.e. what a call app would play back.

**Answer keys, and their biases:**

- *Speaker segments*: pyannote's AMI setup (`only_words` RTTMs and scoring regions, test split), built from AMI's
  word-level timings, which are themselves a forced alignment, so segment edges are approximate (a ±0.25 s collar
  absorbs this). FluidAudio's published tables use a different forced alignment, so their DER is not exactly
  comparable with this log's; on one meeting both scorers were run on the same output and agreed (66.1% vs 66.1%).
- *Words*: AMI's manual word-level transcripts. Hand-made, but with AMI's own conventions (disfluencies, partial words,
  spellings of letters and numbers), so WER is computed after normalisation and the normaliser is part of the result.
- *Summaries*: AMI's human-written abstractive summaries (abstract, decisions, actions, problems), written by
  annotators after the meeting. One person's view of what mattered, not the only right summary.

**AMI is not a video call.** People sit in one room, talk over each other more than on a call, and there is no call
app's echo cancellation or compression. The simulated call is cleaner than reality in some ways (no network dropouts
or codec) and harder in others: more overlap, and AMI's headsets pick up the people sitting next to the wearer, so
"your" mic hears some of the others and the call audio hears some of you. That bleed is measured in M02 and dealt with
in M04. M06 checks the conclusions on real calls.

## Methodology rules

1. **Never tune on the test set.** Any threshold or setting is chosen on AMI dev meetings, then reported once on the 16
   test meetings. A number tuned on test is labelled as such.
2. **Three DER conventions, all reported.** (a) *Comparable*: ±0.25 s collar, overlapped speech not scored, which is
   how FluidAudio and many AMI tables report. (b) *Strict*: ±0.25 s collar, overlap scored; the one that matches what
   a user sees. (c) *Full*: no collar, overlap scored, as pyannote publishes. Gotcha: pyannote.metrics' `collar` is the
   total width removed around a boundary, so ±0.25 s is `collar=0.5`; passing 0.25 silently halves it. Pooled over
   all scored time, not averaged per meeting.
3. **"Who said what" is scored on words, not just segments.** cpWER (concatenated minimum-permutation WER) scores the
   transcript per speaker, so it punishes both wrong words and words given to the wrong person; a word credited to
   the wrong person costs two errors (missing from one speaker, extra for another). Plain *WER* ignores speakers:
   ORC-WER with the output collapsed into one stream. (Exact ORC-WER over four output streams is exponential and ran
   out of memory on a single 17-minute meeting.)
4. **Speed and memory are measured on the M4 Air** with the model loaded once, as real-time factor (seconds of audio
   per second of compute, "RTFx") and peak resident memory.
5. **Summaries are judged by a referee model that never writes summaries**, against the AMI reference and against
   the transcript (for claims the meeting doesn't support), and a sample is checked by hand.
6. **Privacy:** real meetings (M06) are Kai's own, and only aggregates are published, never transcripts or summaries.

## Plan

| | Question | Prediction (written before running) |
|---|---|---|
| M01 | How well does local diarization work on one mixed channel, and how fast is it on an Air? | Offline pipeline reproduces FluidAudio's published ~10–11% comparable DER; strict DER is much higher (20%+) because overlap is common in AMI. RTFx well above 50 |
| M01b | Added after M01. Does moving each speaker change to the nearest pause between words fix the offline diarizer's boundary errors? | Offline cpWER falls 2–4 points (95% of its wrongly attributed words are within 1 s of a turn change); Sortformer, whose errors are mostly words outside any segment, gains less than 1 point |
| M02 | How much does recording "you" on a separate channel help? | Large drop in errors: everything you say is attributed correctly for free, and diarization has one fewer speaker to separate. Expect strict DER and cpWER to fall by a third or more |
| M03 | How good is the transcript, words and speakers together? | Parakeet Ultra WER on AMI headset audio in the low-to-mid teens; cpWER a few points above WER on the simulated call, much higher on the mix |
| M04 | Speaker bleed: what happens when "your" mic also hears the call through laptop speakers, and what fixes it? | Without a fix, other people's words show up twice and some are credited to you; a reference-based filter removes most of it |
| M05 | Can a small local model write a good summary of an hour-long meeting, and how long does it take? | A 4–8B model at 4-bit gets most decisions and action items, with occasional made-up owners or dates; a few tens of seconds to two minutes on the Air |
| M05b | Added after M05; run inside M09 (refuted: 1 of 15 flags right). Does a referee that sees only the relevant transcript passages, and must quote one, judge faithfulness reliably? | Agreement with my hand labels rises from about half to 85%+ on unsupported flags; Qwen3.5 4B notes have under 10% truly unsupported statements |
| M08 | Added after M05, whose best notes model covered 64% of the human summary on the six shorter test meetings and 40% on the six longer ones (the longer ones don't have more summary items). Do notes written per part of the meeting, then merged, cover more than one pass over the whole transcript? | With parts of about 10 minutes, Qwen3.5 4B's coverage rises 5–10 points over M05's single pass, mostly on the longer meetings (closing at least half of the 24-point gap); notes get longer; total time rises by no more than half |
| M08b | Added after M08, whose part notes covered 8–11 points more than one pass but lost it all in the merge, while being 2–2.5× longer. Is it the parts or just the length? (a) A merge that only removes repeats; (b) one pass asked for thorough notes | (a) keeps coverage within 3 points of the unmerged 20-minute part notes (62% on dev) at under 750 words; (b) closes most of the gap too: at matched length, chunking adds no more than 3 points over one pass |
| M06 | Do the conclusions hold on real calls (process taps + mic, live)? | Yes for capture and attribution; echo handling matters more than on AMI |
| M07 | Added after M02. Live notes: how much accuracy does transcribing during the call cost, and how far behind does the text run? | Streaming speech recognition plus streaming Sortformer lands within 2–4 points of the batch cpWER, with text appearing under 2 s after it is said; a clean-up pass after the call recovers the gap |
| M10b | Added after M10, where typed notes were covered about half the time and a typed line nobody said became a decision. Typed notes now appear word for word under their own heading, added by the app, and the model is told to use them only to choose what to cover. Does that stop it stating them as fact? | The line nobody said appears in the model's notes in at most 1 of 4 meetings; at least 5 of the 12 typed points are still covered |
| M09 | Added after M06c, where Saluki 27B and Gemma 4 26B-A4B wrote the most faithful notes on call 1. Do they beat Qwen3.5 4B on AMI test too, judged by a referee that wrote none of them? | Saluki and Gemma cover at least 5 points more of the human summaries than Qwen3.5 4B (51%) and have half its rate of truly unsupported statements; Poodle 4B is within 3 points of Qwen3.5 4B on coverage, with slightly fewer unsupported statements |
| M11 | Added after Kai's first real call through the app, whose notes said an account was connected when the call made clear it wasn't. Does telling the model to say whether attempts worked, and never to copy secrets, fix that call's notes? | With the new lines, the notes say the connection didn't work or was left for later, and copy no sign-in code; on 2 AMI dev meetings notes stay within 20% of their length |
| M10 | Added while building notes into the app, where you can type during a call. Does the notes model cover what you typed, and what does it do with a typed note the transcript doesn't support? | Of 12 points typed across 4 AMI dev meetings, chosen because notes written without typing missed them, at least 10 appear in the notes with typing; notes grow by no more than 15%; a typed note that isn't in the transcript is kept in at least 3 of 4 meetings, and gets invented detail added in at least 1 |

## Experiments

### M01: one mixed channel, four diarizers (30 Oct)

- **Question:** how well does local diarization work when the whole meeting is in one stream, and how fast is it?
- **Prediction:** the offline pipeline reproduces ~10–11% comparable DER; strict DER 20%+; RTFx well above 50.
- **Setup** (`scripts/meetings/run_m01.sh`, `evaluate_m01.py`, outputs in `bench/meetings/m01/`):
  - 16 test meetings, `Mix-Headset.wav`, 9.06 h of audio. Every model loaded once, then run over all 16 files.
  - Diarizers, all FluidAudio defaults, no speaker count given:
    - *offline*: the pyannote-community-1 pipeline (segmentation, WeSpeaker embeddings, VBx clustering);
    - *sortformer*: streaming Sortformer v2.1, high-context config. The whole-file ("offline") Sortformer was tried
      first and scored 66% DER on one meeting, matching FluidAudio's own benchmark and its documented limitation
      (each 30 s window is diarized on its own, so speakers get mixed up across a long meeting);
    - *lseend*: LS-EEND, the general DIHARD-3 model;
    - *lseend-ami*: LS-EEND fine-tuned on AMI's training meetings. **In-domain**, so shown for reference only.
  - Transcript: Parakeet Ultra over the whole file (FluidAudio's sliding window), word timings. Each word is given
    the diarized speaker it overlaps most, or the nearest one.
- **Results:**

| Diarizer | DER comparable | DER strict | DER full | miss* | false alarm* | confusion* | right speaker count | cpWER | RTFx | peak MB |
|---|---|---|---|---|---|---|---|---|---|---|
| offline | **6.8%** | **15.9%** | 24.2% | 12.9% | 1.3% | 1.8% | 15/16 | 29.3% | 136 | 714 |
| sortformer | 21.8% | 25.8% | 28.6% | 23.7% | 0.4% | 1.7% | 15/16 | **25.6%** | 134 | 1301 |
| lseend | 38.1% | 40.6% | 44.1% | 25.6% | 2.4% | 12.6% | 9/16 | 50.4% | 100 | 1208 |
| lseend-ami (in-domain) | 11.6% | 15.9% | **21.7%** | 8.1% | 2.0% | 5.8% | 15/16 | 32.7% | 112 | 1043 |

  \*Components of strict DER. Transcript (words only, no speakers): **WER 22.0%**, Parakeet at 128× real time, 286 MB.

  - Per meeting, WER ranges from 12.2% (IS1009c) to 32.5% (EN2002d). The four EN2002 meetings (unscripted, more
    overlap) are all 30–33%; the 12 scenario meetings are 12–22%.
  - Sortformer has the lower cpWER in 15 of 16 meetings, but fails on IS1009c (cpWER 49.1% vs offline's 16.3%).
- **Diagnosis (exploratory, not predicted):** why does the lowest-DER system not give the best transcript?
  - Words were labelled with their true speaker (by midpoint, single-speaker regions only, 63,428 words) and each
    system's labels mapped to real speakers by majority.

| Diarizer | words given the wrong speaker | …of which within 1 s of a turn change | words outside any diarized segment |
|---|---|---|---|
| offline | 3.8% | 95% | 2.5% |
| sortformer | 2.8% | 61% | 10.8% |
| lseend-ami | 6.9% | 50% | 2.7% |

  - The offline pipeline finds the right speakers but places turn changes slightly late or early. DER's ±0.25 s
    collar forgives that; a transcript doesn't. 3.8% wrong words predicts a cpWER about 7.6 points above WER
    (two errors per wrong word); the measured gap is 7.3.
  - Sortformer's large "miss" barely matters for a transcript: speech recognition runs on its own, so a word in a
    gap still gets transcribed and simply takes the nearest speaker.
- **Conclusions:**
  - Prediction partly wrong: comparable DER came out *better* than predicted (6.8% vs ~10–11%), probably because
    this reference differs from FluidAudio's (see Data); strict DER (15.9%) was better than the predicted 20%+.
    Speed was as predicted: a 50-minute meeting is diarized and transcribed in under a minute on the Air.
  - **DER is the wrong metric to choose a diarizer for meeting notes.** The system with the lowest DER has the
    highest cpWER of the three usable ones. cpWER is the number to optimise.
  - The offline pipeline's errors are almost all at turn edges, which suggests a cheap fix: move each turn change to
    the nearest pause between transcribed words. To be tested (M01b), choosing any setting on AMI dev meetings.
  - Sortformer's typical case is better, but its failure on IS1009c (one of 16) is the kind of thing a user
    remembers. One mixed channel gives about a 26–29% cpWER: roughly one word in four is wrong or misattributed.

### M01b: moving speaker changes to pauses (30 Oct)

- **Question:** M01 found 95% of the offline diarizer's wrongly attributed words within 1 s of a turn change. If
  each change is moved to the longest pause between words nearby, do those words go to the right person?
- **Prediction:** offline cpWER falls 2–4 points; Sortformer gains less than 1 point.
- **Setup** (`snap.py`, `evaluate_m01b.py`, `run_m01.sh` with `DEV=1`, outputs in `bench/meetings/m01_dev/`):
  - Offline and Sortformer (high-context) plus Parakeet Ultra run on the 12 AMI dev mixes, exactly as M01.
  - For every place the speaker label changes between consecutive words, the change moves to the largest gap
    between words within `window` seconds of where the diarizer put it. Window swept on dev only; the plan was to
    apply the best one once to test.
  - Check: window 0 on the test set reproduces M01's 29.3% exactly.
- **Results (dev, cpWER; WER is unchanged because only labels move):**

| Diarizer | 0 s (off) | 0.25 s | 0.5 s | 0.75 s | 1 s | 1.5 s | 2 s |
|---|---|---|---|---|---|---|---|
| offline | 31.4% | 31.4% | 31.4% | 31.6% | 32.0% | 33.0% | 34.5% |
| sortformer | 24.4% | 24.3% | 25.0% | 26.2% | 27.8% | 31.0% | 35.2% |

- **Why it fails:** the idea assumes people pause before taking a turn. They don't. In AMI's dev reference, **79% of
  speaker changes have no pause at all**: the next person starts before the last one has finished (median gap
  −0.13 s), and 22% of all words are said while someone else is talking. The largest pause near a change is usually
  a pause inside one person's turn, so snapping to it moves the boundary the wrong way.
- **Conclusions:**
  - **Prediction wrong.** No window helps either diarizer by more than 0.1 point; anything over 0.5 s hurts. The
    best setting on dev is "off", so nothing was applied to the test set (it would equal M01).
  - Boundary errors in a one-channel mix come from overlap, not from badly placed boundaries between clean turns.
    Overlap can't be fixed by relabelling a single stream of words: it needs either separate channels (M02, M04)
    or a model that transcribes overlapping speakers separately.

### M02: your mic on its own channel (30 Oct)

- **Question:** if "you" are recorded on a separate channel (the mic) and everyone else comes from the call audio,
  how much better is who-said-what?
- **Prediction:** a large drop in errors; strict DER and cpWER down by a third or more.
- **Setup** (`make_calls.py`, `run_m02.sh`, `evaluate_m02.py`, outputs in `bench/meetings/m02/`):
  - 63 simulated calls: every participant of every test meeting takes a turn as "you" (no cherry-picking).
  - Both channels transcribed by Parakeet Ultra. Every mic word is labelled "you"; call-audio words get the speaker
    from diarizing the call audio only (offline and Sortformer, no speaker count given).
  - M01 is re-pooled with each meeting counted once per call, so both rows cover the same audio.
- **Results, no filter:**

| Diarizer | Audio | WER | cpWER |
|---|---|---|---|
| offline | one mixed channel (M01) | 21.7% | 29.0% |
| offline | mic + call audio | 80.4% | 84.6% |
| sortformer | one mixed channel (M01) | 22.8% | 25.5% |
| sortformer | mic + call audio | 81.1% | 83.1% |

  - **63.7% of the words transcribed from "your" mic were said by someone else**, and 18.4% of the words from the
    call audio were your own voice leaking back.
  - Not a bug: in ES2004a, MEO015 says 303 words but their headset yields 1,664. Measured on 400 words, a speaker's
    own headset is only a median 14 dB louder than the loudest other headset (10th percentile: 11.5 dB *quieter*),
    and Parakeet transcribes quiet, distant speech well. Everything is transcribed twice and much of it is
    credited to "you".
- **Upper bound (oracle bleed filter):** keep a mic word only if AMI says you were talking at that moment, and a
  call-audio word only if someone else was. Uses the answer key, so it's a ceiling, not a system.

| Diarizer | Audio | WER | cpWER |
|---|---|---|---|
| offline | one mixed channel (M01) | 21.7% | 29.0% |
| offline | mic + call audio, perfect bleed filter | 21.7% | **24.7%** |
| sortformer | mic + call audio, perfect bleed filter | 22.4% | 24.8% |

  (DER is not meaningful for the oracle rows: the filter removes words, not the diarizer's segments of leaked speech.)
- **Conclusions:**
  - **Prediction wrong.** A separate mic channel on its own makes the transcript far worse, not better. The mic hears
    the room, and speech recognition is good enough to transcribe what it hears. On a real call, the same happens
    whenever the call plays through laptop speakers instead of headphones.
  - With bleed removed perfectly, two channels cut cpWER from 29.0% to 24.7% (a 15% relative drop). Word accuracy is
    unchanged; the whole gain is attribution: the gap between cpWER and WER shrinks from 7.3 to 3.0 points. The
    gain is modest because "you" are only about a quarter of the words in a four-person meeting; in a one-to-one
    call it would be larger.
  - So the real question is how close a practical bleed filter gets to the ceiling: M04.

### M04: a loudness filter for bleed (30–31 Oct)

- **Question:** M02 showed that two channels only help once bleed is removed. How close does a simple filter that
  needs no answer key get to the perfect (oracle) filter?
- **Prediction:** without a fix, other people's words show up twice and some are credited to you (confirmed in
  M02); a reference-based filter removes most of it.
- **Setup** (`bleed.py`, `evaluate_m02.py --filter level:T`, dev outputs in `bench/meetings/m02_dev/`):
  - Each transcribed word is measured on both channels over its own time span (RMS level, dB). A mic word is kept
    only if it is at least T dB louder on the mic than in the call audio; a call-audio word only if it is at least
    T dB louder there than on the mic.
  - T chosen on the 48 dev calls (12 dev meetings, every participant as "you"), then applied once to the 63 test
    calls.
- **Dev sweep (cpWER; the oracle filter is the ceiling):**

| Diarizer | none | −9 dB | −6 dB | −3 dB | 0 dB | +3 dB | +6 dB | +10 dB | oracle |
|---|---|---|---|---|---|---|---|---|---|
| offline | 95.8% | 33.1% | 29.8% | **29.0%** | 29.2% | 30.3% | 32.4% | 38.3% | 26.8% |
| sortformer | 92.7% | 29.4% | 26.1% | **25.2%** | 25.5% | 26.7% | 28.9% | 35.3% | 24.1% |

  At −3 dB on dev, mic words that were really someone else fall from 66.0% to 4.5%.
- **Test, once, at −3 dB (63 calls):**

| Diarizer | Audio | WER | cpWER |
|---|---|---|---|
| offline | one mixed channel (M01) | 21.7% | 29.0% |
| offline | mic + call audio, loudness filter | 25.0% | 28.6% |
| offline | mic + call audio, oracle filter (M02) | 21.7% | 24.7% |
| sortformer | one mixed channel (M01) | 22.8% | 25.5% |
| sortformer | mic + call audio, loudness filter | 25.6% | 28.1% |
| sortformer | mic + call audio, oracle filter (M02) | 22.4% | 24.8% |

  On test, 8.3% of the mic words left after filtering were someone else's (dev: 4.5%), and 1.5% of the call-audio
  words were your echo.
- **Conclusions:**
  - **Prediction partly right.** The filter removes most bleed (63.7% → 8.3% of mic words), but the result barely
    beats one mixed channel with the offline diarizer (28.6% vs 29.0%) and is worse with Sortformer (28.1% vs 25.5%).
  - The cost is in the words, not the speakers: WER rises from about 22% to 25%. A word is judged on its level over
    its own short span, and in overlap or soft speech the true copy is sometimes the quieter one, so real words get
    thrown away along with the bleed. The oracle keeps WER at 21.7%; that 3-point gap is most of the distance to
    the ceiling.
  - The dev-to-test gap (dev bleed 4.5%, test 8.3%) says the threshold doesn't transfer well between rooms. Test
    has the EN2002 meetings, which have no equivalent in the dev set.
  - **AMI is close to the worst case for this.** Everyone sits in one room, so every headset hears everyone. On a
    real call, the call audio is a clean digital stream that never contains your voice (the other side's echo
    cancellation removes it), and your mic only hears the others if the call plays through speakers. With
    headphones there is no bleed at all, and the oracle row is what you get. M06 measures this on real calls.
  - A better filter to try: compare the *same* word on both channels (when both channels transcribe it, keep only
    the louder copy) instead of a fixed threshold per channel, and use the call app's own speaker-volume signal.

### M05: meeting notes from a small local model (30–31 Oct)

- **Question:** can a small model running on the Air turn an hour-long meeting into good notes, and how long does it
  take?
- **Prediction:** a 4–8B model at 4-bit gets most decisions and action items, with occasional made-up owners or
  dates; a few tens of seconds to two minutes per meeting.
- **Setup** (`summarise.py`, `run_m05.sh`, outputs in `bench/meetings/m05/<model>/<condition>/`):
  - The 12 scenario meetings of the test split (EN2002 has no human summaries).
  - Five models, all 4-bit MLX builds from mlx-community: Qwen3.5 2B, 4B and 9B; Gemma 4 E2B and E4B.
  - Two transcripts per meeting, so summary mistakes can be told apart from transcript mistakes. *Gold*: AMI's
    manual words and speakers. *Pipeline*: what the app would have, Parakeet Ultra plus the offline diarizer on the
    mix (M01). Both rendered the same way, one line per turn, `[mm:ss] Speaker N: text`, speakers numbered in order
    of first appearance (no names or roles, since the app wouldn't know them).
  - One fixed prompt for every model asking for four sections (Summary, Decisions, Action items, Open questions and
    problems) and "Only include what the transcript supports". Greedy decoding, thinking off, at most 1,200 tokens.
  - Run one model at a time with nothing else heavy running. Peak memory is MLX's own peak (weights + KV cache).
- **Speed and memory** (median per meeting; meetings are 13–37 minutes long):

| Model | Weights on disk | Pipeline transcript | Gold transcript | Prompt read (tokens/s) | Writing (tokens/s) | Peak memory |
|---|---|---|---|---|---|---|
| Qwen3.5 2B | 1.7 GB | 42 s | 59 s | ~345 | ~30 | 2.3–3.2 GB |
| Gemma 4 E2B | 3.6 GB | 32 s | 70 s | 560–730 | 12–18 | 3.3–3.7 GB |
| Qwen3.5 4B | 3.0 GB | 83 s | 132 s | ~150 | ~15 | 3.9–6.0 GB |
| Gemma 4 E4B | 5.2 GB | 51 s | 85 s | ~245 | ~15 | 5.0–5.4 GB |
| Qwen3.5 9B | 6.0 GB | 154 s | 244 s | ~90 | ~9 | 6.6–8.6 GB |

  - The pipeline transcript is 2–2.5× shorter in tokens (3.3k–10k against 7k–24k): Parakeet leaves out most
    disfluencies and backchannels, and the diarizer merges short interjections into longer turns, so there are fewer
    words and far fewer `[mm:ss] Speaker N:` line prefixes. That is why every model is faster on it.
  - Most of the time is reading the transcript, not writing the notes. Gemma's E-series reads 2–4× faster than the
    Qwen model of similar quality-tier, but writes more slowly.
  - Five of 120 runs hit the 1,200-token limit, all in a repetition loop (the same bullet over and over): four from
    Qwen3.5 2B, one from Gemma 4 E2B. None from the larger models. A shipping app would need a repetition guard for
    the 2B-class models.
- **Quality:** scored by a referee model that wrote none of the notes, Gemma 4 26B-A4B at 4-bit, using
  `referee.py` (one question per statement, one-word answer, greedy):
  - *Coverage:* for each item of AMI's human summary (abstract, decisions, actions, problems), do the notes cover
    it: yes, partly or no? Score = (yes + ½·partly) / items.
  - *Faithfulness:* for each bullet and summary sentence of the notes, does the **manual** transcript support it?
    Pipeline notes are also checked against the manual transcript, so an ASR error that reaches the notes counts.
  - **A referee bug, caught before any score was used.** The first version asked for every verdict at once as a JSON
    list. On ES2004a the 35B referee marked the first six statements supported and all ten after them
    unsupported. Checked by hand against the transcript, at least four of those ten were plainly said (the plastic
    case, the flip-top design, the worry about looking like a "cheapie" option, whether to undercut on price). The
    referee now asks one statement at a time. The transcript is prefilled once per meeting and its KV cache copied
    for each statement, which reproduces the full-prompt next-token choice in a check (max logit difference about 1,
    from bf16 rounding with different chunking). On the same meeting, per-statement verdicts matched the hand check.
  - **One referee, not two.** The plan was a second referee, Qwen3.5-35B-A3B (19 GB of weights, about 24 GB in
    use). On the 32 GB Mac with normal apps open it pushed 11–14 GB into swap and stopped making progress, so it
    finished only one meeting (ES2004a, gold, all five models: 70 claims, 39 summary items). On that overlap the two
    referees agreed on 61 of 70 claims but on only 4 of the 13 claims either one called unsupported, and on 31 of
    45 summary items. Gemma almost never answers "partly": in 13 of the 14 item disagreements Gemma said no and the
    35B said partly (6) or yes (7).
- **Scores** (12 meetings each; `score_m05.py`, `scores-gemma-4-26b-a4b-it-4bit.json`):

| Notes model | Transcript | Notes length (median words) | Coverage | Decisions | Actions | Flagged unsupported |
|---|---|---|---|---|---|---|
| Qwen3.5 2B | gold | 316 | 37% | 39% | 26% | 40% of 209 |
| Qwen3.5 2B | pipeline | 406 | 40% | 46% | 28% | 37% of 298 |
| Qwen3.5 4B | gold | 424 | 51% | 60% | 47% | 11% of 218 |
| Qwen3.5 4B | pipeline | 425 | 51% | 56% | 53% | 25% of 231 |
| Qwen3.5 9B | gold | 502 | 50% | 56% | 45% | 11% of 252 |
| Qwen3.5 9B | pipeline | 503 | 56% | 57% | 50% | 22% of 247 |
| Gemma 4 E2B | gold | 358 | 36% | 31% | 28% | 17% of 259 |
| Gemma 4 E2B | pipeline | 304 | 36% | 31% | 28% | 2% of 180 |
| Gemma 4 E4B | gold | 236 | 31% | 26% | 22% | 3% of 138 |
| Gemma 4 E4B | pipeline | 233 | 37% | 40% | 25% | 4% of 135 |

  Paired by meeting (24 pairs, gold and pipeline pooled, bootstrap 95% interval), coverage differences:
  - Qwen3.5 4B − 2B: **+13.7 points** (+6.5 to +21.3).
  - Qwen3.5 9B − 4B: +1.8 (−2.1 to +5.6), no measurable gain.
  - Qwen3.5 4B − Gemma 4 E4B: **+17.3** (+11.8 to +23.0).
  - Gemma 4 E4B − E2B: −1.2 (−5.9 to +3.2); Qwen3.5 2B − Gemma 4 E2B: +2.3 (−2.4 to +6.8).
  - Pipeline − gold transcript, per model: between +0.8 and +6.5 points, every interval includes zero. The ~25%
    cpWER pipeline transcript did not measurably lower coverage.
- **Hand check of the referee** (`handcheck_claims.json`, `handcheck_items.json`; I looked each one up in the manual
  transcript or the notes):
  - *Unsupported flags are mostly wrong.* 28 claims the referee called unsupported, sampled across all five models:
    8 really were (an owner or recipient nobody named, "in an hour", "the first half-hour", "five metres", a
    decision that was only an option); 12 were plainly said ("twelve fifty Euro", "in the shared folder", "I'll
    have to ask the manufacturing department", "another project team or a new project", the 16–45 age group); 8
    were arguable (a true statement with one added detail). Precision 29–57%.
  - *Supported verdicts are mostly right:* 13 of 15. The two misses were details the notes invented (a stylus
    discussion, "chip-on-print").
  - *"No" for coverage often means partly.* Of 15 items called not covered, 7 really were missing, 7 were partly
    covered and 1 was covered nearly word for word ("settle for the current quality level due to budget
    constraints").
  - The flags punish specific notes. Qwen notes name owners, numbers and dates, which is what the referee most often
    flags wrongly; Gemma E4B's notes are short and general ("the meeting reviewed previous discussions…") and are
    almost never flagged. The flag rate measures specificity as much as invention. Gemma judging Gemma-family notes
    may also be kinder; this experiment can't separate the two.
- **Result against the prediction:** partly confirmed.
  - Qwen3.5 4B covers about half of what AMI's human summarisers wrote (more, counting the referee's missing
    "partly"), with decisions best covered and action items worst. "Most decisions and action items" was too
    optimistic for every model; the human summaries are also more detailed than any one-page notes.
  - Made-up details happen, as predicted (owners, durations, measurements), but this referee can't count them
    reliably. The faithfulness column is not a result.
  - Speed was as predicted: 50 s to 2.5 min per meeting.
- **Conclusions:**
  - **Qwen3.5 4B is the notes model to beat.** It covers as much as 9B at about half the time and 2–3 GB less
    memory, and clearly more than 2B or either Gemma. Gemma E4B is faster (51 s) but writes half the length and
    covers much less.
  - **Transcript errors are not the bottleneck for notes.** The same model on the app's own transcript covered as
    much as on the manual one. The notes model is.
  - **A long-context 26B judge is not a usable faithfulness check.** It needs a better method before any claim
    about made-up details: give the judge only the transcript passages relevant to each statement (retrieval), ask
    for the supporting quote, and confirm a sample by hand. That is M05b.

### M08: notes per part, then merged (31 Oct)

- **Setup:** Qwen3.5 4B (4-bit, greedy, thinking off), gold transcripts of the 12 AMI dev meetings (ES2011, IS1008,
  TS3004 a–d, 17–40 min). The transcript is cut at turn boundaries into parts of 5, 10 or 20 minutes; each part gets
  notes in the same four sections (800 tokens max), told which part of how many it is and its minutes; a merge pass
  then sees only the part notes (1200 tokens max) and is told to merge repeats, keep the later version of anything
  changed, keep every distinct decision, action and problem, and add nothing. Baseline: the M05 prompt in one pass.
  Coverage by the M05 referee (Gemma 4 26B-A4B, coverage questions only). Paired bootstrap over the 12 meetings.
  Scripts: `summarise.py --dev --chunk-minutes N`, `run_m08.sh dev`, `score_m08.py dev`.
- **Results (dev):**

  | Notes | Coverage | Shorter 6 | Longer 6 | Median words | Median time |
  |---|---|---|---|---|---|
  | One pass | 54% | 59% | 48% | 414 | 130 s |
  | 5-min parts, merged | 48% | 52% | 44% | 765 | 316 s |
  | 10-min parts, merged | 51% | 50% | 52% | 560 | 201 s |
  | 20-min parts, merged | 50% | 52% | 47% | 491 | 188 s |
  | 10-min part notes, not merged | 64% | | | 1029 | |
  | 20-min part notes, not merged | 62% | | | 720 | |

  Paired differences against one pass: 5-min −5.1 (−13.7 to +3.2), 10-min −2.8 (−11.2 to +4.9), 20-min −3.9
  (−11.3 to +3.3). On the longer six, 10-min parts gained +3.3 (−9.8 to +12.0) and lost −8.9 on the shorter six.
  Per meeting the swings are large (−30 to +20 points), so 12 meetings only resolve differences of about 8 points.
- **Where it goes wrong:** scoring the part notes themselves, before the merge (a diagnostic added after seeing
  the result): they cover **+10.8** (+3.6 to +18.0, 10-min) and +7.9 (+0.4 to +15.1, 20-min) more than one pass,
  and the merge then loses **13.6** (+9.0 to +18.1) and 11.8 points. Item by item, what the merge drops is the
  meeting's arc: who presented what, that the group rated the prototype against its criteria, what they concluded
  ("the device met its goals"). The merged notes also turn things done during the meeting into action items
  ("Speaker 4: prepare a presentation showing the evaluation criteria table") because each part saw them as
  upcoming, and one merged summary invented a detail ("the broccoli shape") from two parts' notes.
- **Result against the prediction:** not confirmed. No part length beat one pass; notes got longer and time rose
  36–120%, more than the half allowed. The longer half of dev also had a smaller gap than test (48% vs 59%, not
  40% vs 64%), so dev had less room to show the effect predicted on test. The test run was skipped: rule 1 says the
  setting is chosen on dev, and on dev the best setting is no chunking.
- **Conclusions:**
  - **Keep one pass** for now; it is also the cheapest.
  - **The merge is the weak link, not the splitting.** The parts hold more of the meeting than one pass does, but
    a 4B model squeezing ~1,000 words of part notes into one page drops the overview first.
  - The part notes are also 2–2.5× longer, and longer notes cover more of a detailed human summary almost by
    construction, so the +8–11 isn't yet evidence that splitting helps. M08b separates the two.

### M08b: is it the parts or the length? (31 Oct)

- **Setup:** same model, meetings, referee and scoring as M08. (a) The 20-minute part notes (identical to M08's,
  greedy decoding) merged by a prompt that asks for a summary walking through every part and *every bullet kept*
  unless two say the same thing, plus "an action item is something someone will do after the meeting", with 2,000
  tokens of room. (b) One pass with the M05 prompt plus "Be thorough: cover every topic, presentation and
  discussion in the order they came up, and how each one ended", 2,000 tokens of room. Script:
  `run_m08.sh m08b`.
- **Results (dev, 12 meetings):**

  | Notes | Coverage | Shorter 6 | Longer 6 | Median words | Median time |
  |---|---|---|---|---|---|
  | One pass (M08) | 54% | 59% | 48% | 414 | 130 s |
  | 20-min part notes, not merged (M08) | 62% | 63% | 60% | 720 | |
  | (a) 20-min parts, keep-everything merge | 53% | 54% | 51% | 527 | 188 s |
  | (b) One pass, "be thorough" | 51% | 59% | 43% | 504 | 195 s |

  Paired: (a) − one pass −1.0 (−7.3 to +5.2); (a) − its own unmerged parts **−8.9** (−13.5 to −4.4); (a) − M08's
  merge +3.0 (−2.6 to +8.8). (b) − one pass −2.8 (−9.8 to +3.8); (b) − 20-min part notes **−10.7** (−19.4 to −2.8).
- **Result against the prediction:** not confirmed on either arm. (a) The model doesn't follow "keep every bullet":
  it still squeezes 720 words of part notes into 527 and loses 9 of the 12 points. (b) Asking for thorough notes
  added only 90 words and no coverage; on the longer meetings coverage fell (43% vs 48%). So the matched-length
  comparison couldn't be made, because one pass can't be made to write as much as the parts do.
- **Conclusions:**
  - **What makes the part notes cover more is that each call sees less**, not a prompt for length. A 4B model given
    a whole meeting writes about one page whatever it's asked; given 20 minutes it writes most of a page about those
    20 minutes.
  - **Any merge by the same 4B model gives the gain back.** Two prompts, both lose 9–14 points. If the extra
    coverage is worth having, the merge must not be a rewrite: e.g. keep the part notes as the detailed record
    (timestamped "minutes 0–20…") under a short summary, or merge the bullet lists without a model.
  - The trade is length. The unmerged part notes are 1.7× longer than one pass, and they repeat themselves across
    parts. Coverage against a detailed human summary rewards length, so whether readers want that is a product
    question the referee can't answer; M06 (Kai marking his own calls) can.

### M06: real calls (1 Nov, call 1 of several)

- **Question:** do the conclusions hold on real calls, recorded on this Mac with `meetbench record` (your mic plus a
  Core Audio process tap of everything the Mac plays)?
- **Prediction (from the plan):** yes for capture and attribution; echo handling matters more than on AMI.
- **Setup** (`scripts/meetings/m06.py`; audio, transcript and notes stay in `bench/meetings/m06/`, which git
  ignores; only counts are reported here):
  - Call 1: a 5.3-minute video call with one other person, played through the MacBook's speakers (no headphones),
    so the mic hears the other side.
  - Both channels resampled to 16 kHz mono and aligned with the stream start times in `meta.json` (the mic started
    0.19 s after the call audio). Parakeet Ultra on each channel; the offline diarizer on the call audio only.
  - Bleed: M04's level filter at −3 dB (chosen on AMI dev, not retuned). It left echoed words, so a second rule was
    added after looking at this call, the one M04's conclusions suggested: drop a mic word if the call audio has the
    same word within 1 s. Added post hoc on call 1, so it is checked again on the next calls, not claimed here.
  - Notes: M05's prompt and model (Qwen3.5 4B, 4-bit, greedy), with one change: the app knows which voice is yours,
    so the transcript labels it "You" instead of "Speaker 1".
- **Results (call 1):**
  - Capture worked on the first try: both channels had sound, and the call channel was digital silence (−120 dB)
    until the other person joined.
  - The diarizer found 1 speaker in the call audio, which is right.
  - Bleed through speakers was heavy: 183 of the mic's 406 words (45%) repeated a word in the call audio within 1 s.
    The level filter alone kept 209 mic words, 28 of them (13%) still echoes. With the matching rule, 181 were kept.
    The level filter also dropped 42 mic words with no match in the call audio, some of which may have been yours.
  - Notes: 108 words for a 5-minute call. A first read found two errors of attribution or place (a phrase you said
    credited to the other person; a city attached to the wrong fact) and one topic missed.
  - **Kai's marks:** the transcript is good overall, with two misheard phrases, and the notes copied both: the app's
    name, said by the other person, came out as "Mama B" instead of MurmurBee, and a two-word phrase of Kai's was
    misheard. So on this call the notes' errors start in the transcript, unlike AMI in M05, where transcript errors
    didn't cost the notes anything. AMI has no product names or nicknames; real calls are full of them.
- **Conclusions so far (one call):**
  - Capture and attribution work as predicted. Echo through speakers is heavy (45% of mic words) and needs both
    filters.
  - Names are the first thing to fix. Meeting transcripts should use the personal dictionary the app already keeps
    for dictation, either in the clean-up of the transcript or as a list of words given to the notes model. That is
    the next thing to try, on the next call.
  - Too short for M08's parts (one 20-minute part), so the one-pass versus parts question waits for a longer call.

### M06b: call 1's notes, redone (1 Nov)

- **Why:** Kai judged call 1's notes unusable. Besides the two misheard phrases, on a reread they credited a
  greeting to the wrong person, attached a fact to the wrong place, missed a topic, and filled three of the four
  sections with "None", because M05's sections (decisions, action items, problems) suit work meetings, not a chat.
- **Changes** (`m06.py`, all chosen after looking at this one call, so none is a measured result yet):
  - **Dictionary.** Kai's MurmurBee dictionary (59 terms, email addresses left out) is used as dictation uses it.
    Terms that sound like something said are picked (`Vocabulary.select`), two or three words that spell a term
    exactly are joined ("murmur bee"), a misspelt capitalised word close to a term is snapped to it
    (`PostEdit.snapNames`), and the picked terms go to the notes model as correct spellings. One change from
    dictation: a near match only counts when the spoken word isn't an English word. Without it, 9 terms were picked,
    8 of them wrong (ordinary words like "march" and "friend" sounding like names); with it, 1, the right one.
  - **Your name.** Your lines are labelled with the name MurmurBee signs with (Settings) instead of "You".
  - **Backchannels.** A one- or two-word line inside the other person's turn is folded away, so a turn reads as one
    line (62 lines became 31).
  - **Prompt.** A short summary, then notes in the order things came up with who said each, then action items and
    decisions only if there are any. Plus one sentence on keeping track of who said what.
  - **Kai's correction** of his misheard phrase, applied to the transcript as an edit (`--fix`), as a person would
    fix a transcript in the app before asking for notes.
- **What the dictionary fixed:** the app name in Kai's own lines. It didn't touch the other person's "Mama B",
  which is too far from MurmurBee in spelling (0.33 similarity) to snap safely, and may be how they said it. The
  notes model, given the spelling, wrote MurmurBee every time.
- **Notes, read by me against the transcript** (one call, one reader who also wrote the changes, so a weak test):

| Notes model | Words | Time | Wrong statements | Notes |
|---|---|---|---|---|
| Qwen3.5 4B, dictionary only | 431 | not timed | 5, plus 3 bullets made from pre-call noise | a past event written as a plan |
| Qwen3.5 4B, with Kai's fix | 440 | not timed | 6, plus 3 from noise | invents two events at the end of the call |
| Qwen3.5 9B, with fix | 511 | 125 s | 3, plus 2 from noise | lists facts as "decisions"; repeats the spelling hint back |
| Gemma 4 26B-A4B, with fix | 200 | 49 s | 1 | ignores the noise; misses the request at the end of the call |

  Times include loading the model. Weights: 4B 3.0 GB, 9B 6.0 GB, Gemma 26B-A4B 15.3 GB (only 4B parameters run
  per word, hence the speed).
- **Conclusions (one call):**
  - The new prompt reads better than M05's on a chat, but the 4B model still invents and misplaces facts with it.
    On AMI in M05, 9B gained nothing over 4B; on this call both Qwen models made errors Gemma 26B-A4B didn't.
  - Gemma 26B-A4B gave the most faithful notes and was the fastest here, but its 15 GB of weights rule it out as the
    default on 16 GB Macs. Worth scoring on AMI with M05's referee (which would then be judging its own model, so
    Qwen3.5-35B-A3B should referee), and offering as a "better notes" choice on Macs with 32 GB or more.
  - The dictionary works for names the person who owns it says. Names other people mispronounce still depend on
    the notes model.

### M06c: Underdog's models on call 1 (2 Nov)

- **Question:** do Conway Research's (Underdog's) open models write more faithful notes than Qwen3.5 4B, at a size a
  16 GB Mac can hold?
- **Models:** Underdog Poodle 4B (Qwen3.5 4B post-trained for tool calling and instruction following, IFEval 85 vs
  61 on its card; MLX 4-bit, 3.0 GB) and Underdog Saluki 27B 1.0 (Qwen3.8 27B at about 2.3 bits per weight, GGUF
  IQ2, 7.9 GB, llama.cpp 0.8.0 with Metal). Against Qwen3.5 4B and Gemma 4 26B-A4B from M06b. Each with thinking off
  and greedy decoding, and with thinking on at the model cards' sampling (temperature 0.6, top_p 0.95, top_k 20).
- **Setup:** M06b's transcript (dictionary plus Kai's correction) and prompt, unchanged. Errors counted by me
  against the transcript, as in M06b. Times include loading the model, on this Mac (M4, 10-core GPU, 32 GB).

| Notes model | Size | Time | Words | Wrong statements | Notes |
|---|---|---|---|---|---|
| Saluki 27B | 7.9 GB | 340 s | 434 | 0 | includes the request at the end that Gemma missed |
| Gemma 4 26B-A4B | 15.3 GB | 63 s | 200 | 1 | misses that request |
| Poodle 4B | 3.0 GB | 74 s | 500 | 4, plus 1 bullet from pre-call noise | one invented event at the end of the call |
| Poodle 4B, thinking | 3.0 GB | 264 s | 408 | 4 | credits one person's story to the other |
| Qwen3.5 4B | 3.0 GB | 75 s | 440 | 6, plus 3 from noise | as M06b (same notes, greedy) |
| Qwen3.5 4B, thinking | 3.0 GB | 897 s | none | | used the whole 9,200-token budget reasoning, no notes |
| Saluki 27B, thinking | 7.9 GB | over 1 h | none | | stopped at the 1-hour time-out |

- **Speed:** Saluki reads at 21 tokens a second and writes at 3.2 on this M4 (llama-bench, 1,024-token prompt), so
  most of its time is reading. A one-hour call (about 12,000 tokens) would take roughly 10 minutes to read and 4 to
  write. llama.cpp 0.6.0 was slower (14 and 2.2); 0.8.0 is what's reported. The M4's 10-core GPU is the slowest
  Apple silicon this would run on; M4 Pro and Max have 2–4× the bandwidth and GPU.
- **Conclusions (one call, one reader):**
  - Poodle's instruction-following training helps a little (4 errors against 6) but it still invents events. It's
  not a fix for small-model notes.
  - Saluki gave the most faithful notes of any model so far, in 7.9 GB, which a 16 GB Mac can hold. It's slow on
  this Mac, too slow to feel "instant" after a long call, unless its reading is done during the call (the
  transcript so far, kept in its cache) so only the writing is left at the end.
  - Thinking hurt every model here: slower, no more accurate, and two runs never finished.
  - Next, before choosing: score Saluki, Gemma 26B and Poodle on AMI test with a referee (M05's method), and run
  them on a longer real call.

### M09: the call 1 winners on AMI test (2 Nov)

- **Question:** do Saluki 27B and Gemma 4 26B-A4B, the most faithful notes models on call 1 (M06c), also beat
  Qwen3.5 4B on the 12 AMI test meetings, and does Poodle 4B?
- **Prediction** (written before running): Saluki and Gemma cover at least 5 points more than Qwen3.5 4B's 51% and
  have half its rate of truly unsupported statements; Poodle is within 3 points of Qwen3.5 4B on coverage, with
  slightly fewer unsupported statements.
- **Setup** (`run_m09.sh`, `faithful.py`, outputs in `bench/meetings/m09/`):
  - Notes: M05's prompt, pipeline transcript (what the app would have), greedy, thinking off, at most 1,200 tokens.
    Gemma and Poodle through MLX, Saluki (GGUF IQ2) through llama-server 0.8.0. Qwen3.5 4B's notes are M05's.
  - Referee: Qwen3.5-35B-A3B (4-bit MLX), which wrote none of the notes. M05's referee, Gemma 4 26B-A4B, would now
    be judging its own notes. The 35B swapped in M05 with whole transcripts in its prompt; here every prompt is short.
  - Coverage: M05's question, one AMI summary item at a time.
  - Faithfulness, M05b's design: the referee sees only the transcript passages most related to the statement
    (BM25 over windows of six turns, top four), must copy the line that supports it or write NONE, then answers
    supported, unsupported or unclear. Checked against the manual transcript. The pipeline's speaker numbers are
    mapped to the manual transcript's (most words in common), so a statement about who said what is checked too.
  - A sample of verdicts is checked by hand, blind to which model wrote the statement.
- **Notes speed** (M4, 10-core GPU, 32 GB; median per meeting, meetings are 3,300–9,600 prompt tokens): Gemma
  85 s (peak 16 GB), Poodle 85 s (4.6 GB), Saluki 596 s, up to 700 s (llama-server, 8.6 GB). Saluki read at
  16–23 tokens a second and wrote at 2.4–3.2, the slow end with about 12 GB already in swap.
- **Scores** (`score_m09.py`, `scores.json`; Qwen3.5-35B-A3B referee for every row, so rows compare with each other
  but not with M05's Gemma-refereed 51%):

| Notes model | Median words | Coverage | Abstract | Decisions | Actions | Problems | Statements | Flagged unsupported |
|---|---|---|---|---|---|---|---|---|
| Qwen3.5 4B | 425 | 66% | 68% | 65% | 60% | 69% | 231 | 44% |
| Poodle 4B | 461 | 72% | 72% | 67% | 72% | 82% | 282 | 47% |
| Gemma 4 26B-A4B | 253 | 52% | 52% | 51% | 50% | 55% | 142 | 40% |
| Saluki 27B | 390 | 66% | 64% | 64% | 70% | 76% | 210 | 44% |

  Paired by meeting against Qwen3.5 4B (12 pairs, bootstrap 95%), coverage: Poodle **+6.1** (+2.5 to +9.8), Saluki
  −0.6 (−5.5 to +4.1), Gemma **−14.8** (−18.3 to −11.3).
- **Hand check of the faithfulness referee** (`handcheck.json`, blind to model; `handcheck_key.json`;
  `handcheck_labels.json`): 15 statements it called unsupported and 15 it called supported, spread across the four
  models. I looked each up in the manual transcript, with six passages around it and a search of the whole meeting
  where those weren't enough, before opening the key.
  - *Its unsupported flags were right 1 time in 15.* The other 14 were plainly said: the 25 Euro price, "I'll have to
    ask the manufacturing department", the 60–80 age group, the beeper you set off from a button on the TV, the
    questionnaires. Often the quote it copied was the very line that supports the statement, and the verdict still
    said unsupported.
  - *Its supported verdicts were right 14 times in 15.* The miss gave a task an owner nobody assigned.
  - Across the 30, I found 2 statements truly unsupported (one Qwen3.5 4B, one Poodle 4B): an owner nobody named, and
    a "must be finalised first" nobody said. About 7%, but 7–8 statements per model are far too few to rank models.
  - Retrieval and a required quote didn't fix the referee; with its 40–47% flag rate it is worse than M05's. The
    strict wording ("adds a detail … that was not said") may be what it latches onto. The faithfulness column is not
    a result.
  - A splitting bug: `claims()` cuts sentences at "vs.", so a few statements are half-sentences. It affects every
    model's count slightly, Gemma's (which uses "vs." most) the most.
- **Result against the prediction:** refuted on coverage, untestable on faithfulness.
  - Neither big model covered more than Qwen3.5 4B. Saluki covered the same; Gemma covered 15 points less, in line
    with writing about 60% as many words (on call 1 too it was the shortest).
  - Poodle beat the "within 3 points" prediction: 6 points more than Qwen3.5 4B, the best of the four, at the same
    speed and memory. It also writes the most (461 words, up to 1,168 tokens), and coverage rewards length.
  - Truly unsupported statements look rare on AMI for every model (about 2 in 30 by hand), so the call 1 differences
    (Saluki 0, Gemma 1, Poodle 4, Qwen 6 errors) are the better faithfulness evidence so far, from a single call.
- **Conclusions:**
  - **Saluki is not worth its cost on this Mac.** It covers no more than Qwen3.5 4B and takes 7× as long (about
    10 minutes a meeting). Its weights have been removed; its AMI notes are kept.
  - **Poodle 4B is the best candidate for the app's notes model**: most coverage, 85 s a meeting, 4.6 GB. Its
    weakness is the one call 1 showed, invented details at the margin (4 errors vs Gemma's 1).
  - **Gemma 4 26B-A4B is the faithful but terse option.** Fewest errors on call 1, least coverage here, 16 GB peak,
    so it only suits 32 GB Macs.
  - **The referee can't count invented details**, after two designs. The next faithfulness test should be hand
    counted, on real calls: the longer call next, all models, errors counted as in M06b.

### M10: what the notes model does with notes you type (7–8 Nov)

- **Question:** the app lets you type during a call, and the notes model gets what you typed. Does it cover those
  points, and what does it do with a typed line the transcript doesn't support?
- **Prediction** (written before running): of 12 points typed across 4 AMI dev meetings, chosen because notes written
  without typing missed them, at least 10 appear in the notes with typing; notes grow by no more than 15%; a typed
  note that isn't in the transcript is kept in at least 3 of 4 meetings, and gets invented detail in at least 1.
- **Setup** (`bench/meetings/m10/`, `run.sh`; the app's own code through `MurmurBee --notes-test`): ES2011a, IS1008a,
  TS3004a, ES2011c (dev), pipeline transcripts, Poodle 4B (MLX 4-bit, greedy, thinking off), M06b's prompt with
  "Speaker N" labels. Typed notes per meeting: three short fragments in my words for summary items the untyped notes
  missed (e.g. "batteries or recharge stand, undecided"), plus "legal review before launch", which nobody said.
  Points counted by hand against the notes.
- **Found first, before any typing:** with M06b's prompt, Poodle writes 700–920 words on these meetings (M05's prompt
  gave 461 in M09), and at M09's limit of 1,200 tokens two of the four notes stopped mid-sentence in Decisions, the
  last section. The app's limit is now 2,400 tokens; all notes below end cleanly.
- **Results:**
  - *Typed points covered: about 6 of 12* (3, 2, 1, 0 by meeting), against none in the untyped notes. In ES2011a they
    were covered by pasting them in as a bullet list headed "Typed notes from the call", one with a typo added.
  - *The line nobody said:* kept in 2 of 4. In IS1008a it became a decision and an action item ("Legal review is
    scheduled to happen before launch").
  - *Length:* 3,267 words untyped against 3,117 typed (−5%), but per meeting from −25% to +56%.
- **Result against the prediction:** refuted on coverage (6, not 10) and on keeping the unsupported line (2, not 3);
  confirmed on length and on invented detail.
- **What changed in the app:** what you type is no longer left to the model. It appears word for word under its own
  "Your notes" heading, added by the app after the model's notes, and the prompt now says to use typed notes only to
  choose what to cover, not to repeat them or state anything the transcript doesn't support. M10b tests that prompt.

### M10b: typed notes as a guide only (8 Nov)

- **Prediction** (written before running): the line nobody said appears in the model's notes in at most 1 of 4
  meetings; at least 5 of the 12 typed points are still covered.
- **Setup:** as M10 with the new prompt (`run2.sh`, `*.typed2.md`); M10's notes kept in `m10a/`.
- **Results:**
  - *Typed points covered: about 7 of 12* (2, 2, 2, 1 or 2), now mostly in the model's own words with the detail from
    the transcript (e.g. "a rechargeable stand is being evaluated... undecided whether to include it"). One misplaced
    who said it: "cost info was missing", credited to the wrong speaker.
  - *The line nobody said:* in 2 of 4. In TS3004a it is quoted as something typed; in IS1008a it is again a decision,
    marked "(as noted in typed notes)", and the notes also invent that the project manager mentioned it.
  - The model still copied the typed notes into a list in 2 of 4 meetings despite being told not to.
  - Memory after the notes: 0.43 GB still in use once the model is released (the MLX cache is cleared after
    release). One timing is lost: the Mac slept during TS3004a.
- **Result against the prediction:** confirmed on coverage, refuted on the unsupported line (2 of 4, not at most 1).
- **Conclusions:**
  - Typed notes help: about half to 60% of the points people typed get covered, against none without.
  - The prompt can't keep a 4B model from stating what you typed as fact. The safe part is the app's: your words are
    always shown as you wrote them, under their own heading, so nothing you typed is lost or reworded. The leftover
    risk is the model repeating your own note as a decision, which is your information, not an invention about
    someone else.
  - Four meetings and one reader (who chose the points); a guide to how the feature behaves, not a measurement.

**App default (9 Nov):** the app ships Qwen3.5 4B as its notes model, not Poodle 4B. Poodle covered 6 points more on
AMI (M09) and made fewer errors on call 1 (M06c), but its weights are licensed CC BY-NC 4.0 (non-commercial only),
while Qwen3.5 4B is Apache 2.0. The model is one setting in `ModelStore.notes`, so it can change after the longer
real call.

### M11: did it work, and no secrets (16 Nov)

- **Why:** Kai's first real call through the app (30 minutes) gave notes that said an account had been connected,
  when the call made clear the sign-in failed and would be done later. The notes also copied a sign-in code that was
  read out.
- **Prediction** (written before running): with two new lines in the prompt, the notes say the connection didn't
  work or was left for later, and copy no sign-in code; on 2 AMI dev meetings, notes stay within 20% of their length.
- **Setup:** the call's saved transcript, typed notes, name and spellings, through `MurmurBee --notes-test` with
  Qwen3.5 4B (the app's model). Baseline: the app's prompt, which reproduced the app's own notes (two lines differ).
  New lines: "When someone tries to do something, say whether it worked, failed or was left for later; don't assume
  it worked" and "never write down passwords, sign-in codes or other secrets". Read by me; the call stays private, so
  only what changed is reported.
- **Results:**
  - *Sign-in code:* copied in the baseline, gone with the new lines.
  - *The connection:* the action items and decisions now say it is pending and why, but the summary's first
    paragraph still says it was connected successfully.
  - *Length:* 658 words, then 745. The AMI length check wasn't fair: the only earlier AMI notes with this prompt are
    Poodle's (M10), not Qwen's, so it's left open (Qwen with the new lines: 600 and 669 words on ES2011a and IS1008a,
    all sections present and finished).
- **Result against the prediction:** half confirmed. The secret is gone and the later sections are right; the summary
  still claims success.
- **Conclusions:**
  - The two lines stay: they fix the worst part (a sign-in code in the notes) and most of the outcome, at no visible
    cost. One call, one reader, so a guide, not a measurement.
  - A 4B model still gets an outcome backwards in its summary. Gemma 26B made the fewest errors on call 1 (M06c) and
    is the obvious "accurate" option for 32 GB Macs; Kai's next real calls are the test set for it.

### M12: the bigger model on the same call (16 Nov)

- **Question:** does Gemma 4 26B-A4B, run inside the app, get M11's outcome right, and what does it cost?
- **Setup:** M11's call, transcript and prompt (with M11's lines), `MurmurBee --notes-test`, Gemma 4 26B-A4B 4-bit
  (mlx-community at 0d77464).
- **Results:** the notes say the connection will be attempted later, with no claim that it worked and no sign-in
  code. 406 words (Qwen3.5 4B: 745), 118 s, and 20 GB peak memory footprint for the process (more than the 16 GB
  measured through Python in M09). One U+FFFD character appeared in the output and is now stripped.
- **Conclusion:** the app offers it as "Accurate" on Macs with 32 GB or more, chosen on the Meetings page or in
  Settings, downloaded from Hugging Face at that commit with every file's SHA-256 pinned. Everyone else gets Qwen3.5 4B
  without being asked. One call; the trade (fewer mistakes, shorter notes) is M06c's and M09's.

