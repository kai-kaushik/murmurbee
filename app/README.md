# MurmurBee (MVP)

A menu-bar dictation app: hold the key, speak, release, and cleaned text is pasted at the cursor. Everything runs on the Mac.

- **Speech:** Parakeet TDT Ultra (FluidAudio, Neural Engine)
- **Cleanup:** Qwen3.5-0.8B fine-tuned on Kai's Wispr history (MLX, GPU), with a length check and a repetition guard
- **While you talk:** audio is cut at pauses, and each chunk is transcribed and cleaned in the background
- **Paste:** clipboard + a clean ⌘V at the cursor, verified through Accessibility; falls back to inserting through
  Accessibility, then to leaving the text on the clipboard. The previous clipboard is restored
- **History:** `~/Library/Application Support/MurmurBee/history.sqlite`
  - stores text, context (app, window, text before the cursor) and latencies
  - no audio is kept

## Build and run
```bash
./build.sh                      # needs Xcode + Metal toolchain (xcodebuild -downloadComponent MetalToolchain)
open "build.noindex/MurmurBee.app"
"build.noindex/MurmurBee.app/Contents/MacOS/MurmurBee" --selftest some.wav   # headless engine check
```

## Package
```bash
./make_dmg.sh                   # build.noindex/MurmurBee-<version>.dmg, drag-to-Applications
```
The cleanup model is not inside the DMG: it lives in `~/Library/Application Support/MurmurBee/models/`.
Shipping to other Macs needs a model download step, plus Developer ID signing and notarization.

## Permissions (first launch)
| Permission | Why |
|---|---|
| Microphone | recording |
| Accessibility | pasting and reading context |
| Input Monitoring | hearing the hold key |

Builds are signed with the self-signed "Local Flow Dev" certificate in the login keychain, so these grants survive
rebuilds. `build.sh` installs into /Applications and keeps its own output in `build.noindex/`, so Spotlight lists one copy.

## Keys
- **Hold:** Right Option by default, so it can run next to Wispr, which owns Fn. Change it in Settings.
- **Hands-free:** double-tap the key to start, tap once to finish (on by default; Settings → General).
- **Cancel:** Esc at any time, or pressing any other key while holding.

## Windows
- **Setup:** first launch, or whenever a permission is missing. Live checks, a relaunch button for Input Monitoring, and a test box.
- **Settings (⌘,):**
  - General: key, hands-free, microphone ("Automatic" avoids Bluetooth headset mics), AI cleanup, launch at login.
  - Dictionary: add and remove terms; auto-learned terms are tagged.
  - Privacy: learn from edits, history folder, delete history.

## Latency query
```bash
sqlite3 ~/Library/Application\ Support/MurmurBee/history.sqlite \
  "select round(duration_s,1), chunks, cleanup_paths, round(latency_total_ms), insert_confirmed from dictations order by id desc limit 20"
```
