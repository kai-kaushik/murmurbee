# Microphone startup investigation and validation

The failure being addressed is late or stalled microphone capture while the UI already indicates listening.
The user reported missing opening words and occasional waits of about ten seconds without recording.

## Why this approach

The initial audio logs show a stale 44.1 kHz client/tap format against 48 kHz or 16 kHz input hardware, followed by
`Failed to create tap, config change pending!`. CoreAudio also logged `throwing -10877` and failed I/O starts.
The selected route's input hardware format is now used when installing the tap and converting to 16 kHz mono.

Engine startup and `isRunning` do not prove that audio buffers are arriving. In eight observed Bluetooth
recordings, configuration changes stopped the engine and recovery completed 1.737–2.373 seconds after the
initial engine start. The UI had already indicated listening. Those observations do not explain every part
of the separately reported ten-second wait; key-to-buffer timing was not available for all earlier attempts.

The final implementation therefore measures real buffer arrival and sustained capture, moves hardware work
off the main thread, reuses a stopped graph for the same device, bounds retries and startup/stall deadlines,
and shows a starting state until audio is ready. Context reads have a time budget so slow Accessibility
queries cannot indefinitely delay startup. Password checks precede optional context reads.

Automatic selection keeps the existing policy: prefer a built-in microphone when the system default input
is Bluetooth, otherwise follow the system default. No device vendor, name, or UID is hard-coded by this fix.

Apple's [configuration-change documentation](https://developer.apple.com/documentation/avfaudio/avaudioengineconfigurationchangenotification)
describes the engine stopping when hardware sample rate or channel count changes. The
[input-node documentation](https://developer.apple.com/documentation/avfaudio/avaudioengine/inputnode)
identifies its input format as the hardware format.

## Validation

[Sanitized validation results](validation.sanitized.json) contain the four hardware runs and 15 deterministic
checks. On Automatic, first audio arrived in 184–209 ms and readiness was detected in 686–712 ms. Built-in
input was also tested explicitly. Repeated starts, stopping without further sample collection, and immediate
cancellation passed. The user subsequently confirmed that opening-word dictations work on Automatic and
reported improved dictation while using Bluetooth headphones. The headphone result is manual user validation;
no new instrumented startup timings or specific microphone-route information were collected for that test.

These final measurements use Automatic/built-in input, whereas the earlier failures used a Bluetooth input.
They are not a controlled before/after performance comparison. USB/default selection rules are covered with
deterministic device fixtures; physical USB hardware was not tested.
The standard clean Xcode/Metal build was not run; the local release build reused the release shader resource.

Run `cd app && ./test_capture.sh` for the deterministic checks. Build the optional local hardware probe with
`./test_capture.sh --hardware`, then open `build.noindex/CaptureProbe.app` and allow microphone access. The
probe uses the production recorder, checks available input routes, and writes timings/counts only.

## Historical crash excerpts: background, not proven fixed

The following reports are all from v0.1.6, build 7, on 2026-10-29:

- [08:38:19 — Swift executor assertion in HomePane.list](MurmurBee-2026-10-29-083819.sanitized.json)
- [08:38:58 — repeated HomePane.list executor assertion](MurmurBee-2026-10-29-083858.sanitized.json)
- [16:35:00 — recursive os_unfair_lock abort in Session.finish](MurmurBee-2026-10-29-163500.sanitized.json)

The history-view failures are outside this change's scope. The lock abort was not reproduced against the
final code, so these attachments do not establish a crash regression fix. They are included as historical
context from the same investigation. No claim is made that every error found in the original log audit is fixed.

Only allowlisted diagnostic fields and top stack symbols are included. The excerpts omit device/incident
UUIDs, process IDs, register contents, memory addresses, personal filesystem paths, and dictation contents.
Raw crash files and full unified-log exports are not included.
