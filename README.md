# Koedex

<p align="center">
  <img src="Assets/Branding/KoedexIcon-1024.png" width="128" alt="Koedex icon">
</p>

[English](README.md) | [日本語](README.ja.md) | [User guide](docs/manual/en.md) | [日本語ガイド](docs/manual/ja.md)

Koedex is a system-wide voice input app for macOS. Hold down a hotkey (the
fn key by default) to record, release it to stop: your speech is
transcribed on-device, cleaned up by AI (filler removal, self-corrections,
punctuation), and pasted at the cursor position in whatever app is
frontmost.

> **New here?** — The User guide above walks through installation, first-run
> setup, and every setting in plain language.
> This README is the developer-facing summary.

## Not affiliated with OpenAI

Koedex is an independent, community project. It is **not affiliated with,
sponsored by, or endorsed by OpenAI**. "OpenAI", "ChatGPT", and "Codex" are
trademarks of OpenAI. Koedex does not use any OpenAI logo or brand color,
and nothing here should be read as an official OpenAI product or
communication channel. See [NOTICE](NOTICE) for the full notice.

## Requirements

- macOS 26 (Tahoe) or later — Koedex depends on Apple's SpeechAnalyzer
  APIs, which are not available on earlier releases.
- Swift 6.2 or later to build from source. The Command Line Tools SDK is
  enough; a full Xcode.app install is not required.
- The [Codex CLI](https://www.npmjs.com/package/@openai/codex) (`codex`)
  on your `PATH`, authenticated with a ChatGPT subscription (i.e.
  `~/.codex/auth.json` is present and valid). Koedex launches `codex
  app-server` as a child process; it does not talk to any API directly.

## What leaves your Mac

- **Transcription is entirely on-device.** Koedex uses Apple's
  SpeechAnalyzer/SpeechTranscriber to turn your speech into text locally.
  Audio never leaves your machine for transcription. The only network
  activity here is macOS downloading the speech recognition model asset
  from Apple the first time a language is used.
- **AI cleanup and "AI command" go through your local `codex` CLI.** The
  transcribed text (not audio) is sent to `codex app-server`, which uses
  your own authenticated ChatGPT subscription to talk to OpenAI. Koedex
  starts `codex app-server` with `mcp_servers={}` and `plugins={}` and
  does not modify your `~/.codex/config.toml`.
- Everything else — settings, history, your personal dictionary, custom
  instructions — is stored locally under
  `~/Library/Application Support/Koedex/` and is never transmitted
  anywhere by Koedex itself.

## Install / build from source

```bash
# From a clone of this repository:

# Build the executable only
swift build

# Assemble dist/Koedex.app
./scripts/make_app.sh debug
```

### Future distribution

Koedex does not currently provide a distributable release. When one is
prepared, it must be built from a clean clone of this official repository at
the matching release tag. Do not distribute an `.app` created from another
working copy.

### Code-signing certificate (one-time setup)

`scripts/make_app.sh` refuses to produce an ad-hoc-signed `.app`, because
ad-hoc signatures change on every rebuild and macOS revokes your
Accessibility/Microphone/Speech Recognition permissions whenever the
signing identity changes. Instead it requires a stable, local, self-signed
"Koedex Dev" certificate.

Before your first build, create it:

```bash
bash scripts/make_signing_cert.sh
```

This generates a self-signed code-signing certificate and imports it into
your login keychain. macOS will then ask you to approve trusting it for
code signing — **this approval happens in a Keychain Access GUI dialog and
cannot be scripted or automated**; it's a deliberate macOS security gate.
The script itself finishes successfully whether or not you complete that
approval, and prints the manual steps you need if it's still pending:

```bash
security add-trusted-cert -k "$HOME/Library/Keychains/login.keychain-db" \
  "$HOME/Library/Application Support/Koedex/koedex_dev_cert.crt"
```

`scripts/make_app.sh` will not assemble an `.app` bundle until the
certificate shows up as a trusted codesigning identity
(`security find-identity -v -p codesigning`). Once it does, rerun
`./scripts/make_app.sh debug` (or `release`).

## Granting the three permissions

Koedex needs three macOS privacy permissions. After copying
`dist/Koedex.app` somewhere like `/Applications` and launching it for the
first time, grant them as prompted (or add them manually if a dialog
doesn't appear):

1. **Accessibility** — for the global hotkey (via a `CGEventTap`) and for
   sending ⌘V at the cursor. System Settings → Privacy & Security →
   Accessibility → add Koedex and enable it.
2. **Microphone** — for recording your voice. System Settings → Privacy &
   Security → Microphone → enable Koedex.
3. **Speech Recognition** — for on-device transcription. Usually prompted
   automatically on first launch; otherwise check System Settings →
   Privacy & Security → Speech Recognition.

Accessibility is checked once, at process start. After granting it,
**fully quit and relaunch Koedex** rather than continuing in the same
session — it will not pick up a newly granted Accessibility permission
until it restarts.

## Usage

- Place your cursor in any text field, then press and hold **fn** to
  start recording. Press **fn** again to stop; Koedex transcribes, runs AI
  cleanup, and pastes the result at the cursor automatically.
- A small floating HUD shows the current stage ("recording", "cleaning
  up", etc.) while this happens.
- Open **Settings…** from the menu bar icon to toggle AI cleanup, manage
  custom instructions, review history, and edit your personal dictionary.
- The hotkey is configurable in Settings; the default is fn (`0x3F`).

### AI command mode

AI command mode is a separate, one-tap flow for asking the AI to do
something rather than just transcribing:

- Default binding: **fn + Space** to start, **fn** to stop (both are
  configurable).
- **With text selected** when you start recording: your spoken instruction
  is applied to the selected text (summarize, translate, rewrite, etc.).
  The result is pasted back only if the original caret position is still
  verified safe at stop time; otherwise it's shown in a separate,
  copyable window instead of being inserted blindly. Web search is
  disabled in this path for safety, since selected text could contain
  a prompt-injection attempt.
- **Without a selection**: your spoken instruction is treated as a
  question, answered in a separate window. Web search is available only
  in this path, and the answer lists the specific links it actually used.
- History for AI command mode stores only the transcribed spoken
  instruction — never the selected text, the answer, audio, or the links
  used.

### Hands-free send

Hands-free send lets you speak a trigger phrase to automatically send your
message (by simulating Return, ⌘Return, or ⌃Return) instead of pasting and
stopping there. It is off by default and configured separately in
Settings, with its own explicit opt-in for auto-sending in external apps.

## Running the app the first time (Gatekeeper)

Releases of Koedex are currently **not notarized**. The first time you
open a downloaded `Koedex.app`, macOS Gatekeeper will refuse to launch it
with a normal double-click.

To open it:

1. Right-click (or Control-click) `Koedex.app` and choose **Open**, then
   confirm in the dialog that appears; **or**
2. Try to open it normally once (it will be blocked), then go to
   **System Settings → Privacy & Security** and click **Open Anyway** next
   to the Koedex entry.

You only need to do this once per build. If neither of the above works —
for example because of how the file was transferred — and you've verified
where you got the file from, you can clear the quarantine flag directly as
a last resort:

```bash
xattr -dr com.apple.quarantine /Applications/Koedex.app
```

## Development

```bash
# Build
swift build

# Assemble an .app bundle — four targets are supported:
./scripts/make_app.sh debug                  # dist/Koedex.app, debug build
./scripts/make_app.sh release                # dist/Koedex.app, release build
./scripts/make_app.sh onboarding-debug        # dist/Koedex Debug.app, isolated onboarding-flow sandbox
./scripts/make_app.sh language-setup-debug    # dist/Koedex Language Setup Debug.app, isolated language-setup sandbox

# Regression suite — no network or codex app-server calls
.build/debug/Koedex --test-regressions

# Fail the run if more checks self-skip than expected (CI passes 13)
.build/debug/Koedex --test-regressions --max-skips 13
```

Diagnostic commands, for investigating a specific subsystem. These are not
part of the regression suite and are not run by CI.

```bash
# Transcribe an audio file, once or repeatedly
# Needs both microphone and speech-recognition permission, same as recording does
.build/debug/Koedex --test-stt path/to/audio.wav
.build/debug/Koedex --test-stt-repeat 5 path/to/audio.wav

# Measure when partial transcription results arrive, without recording
.build/debug/Koedex --test-stt-partials path/to/audio.wav \
  --probe-locale ja-JP --probe-reporting volatile,fast --probe-trailing-silence-ms 12000
# also accepts --probe-chunk-ms, --probe-feed, --probe-format, --probe-transcription,
# --probe-attributes, --probe-preset, --probe-label, --probe-reserve, --probe-prepare,
# --probe-start-time, --probe-detector

# Run AI cleanup — this DOES start codex app-server
.build/debug/Koedex --test-cleanup "text to clean up" --test-model <slug> --test-effort <effort>

# Run cleanup N times in one process, to see the warm-thread effect.
# Takes a count only — the input is a fixed built-in string, not one you pass.
.build/debug/Koedex --test-cleanup-repeat 3 --test-model <slug> --test-effort <effort>
```

The `onboarding-debug` and `language-setup-debug` builds use their own
`~/Library/Application Support/Koedex Debug/` (or equivalent) data
directory, so you can rehearse first-run flows without touching your
regular Koedex settings, history, dictionary, or Codex connection.

A handful of pasteboard-related regression fixtures need a real pasteboard
server; they self-skip with a printed notice in headless or CI-like
environments where one isn't available. That's expected, not a failure —
see `.github/workflows/build.yml` for how CI runs the same suite.

## Support-only flag

Koedex also accepts `--support-scoped-clipboard-fallback enable|disable|status`.
This is a diagnostic/support tool for working around specific external-app
paste compatibility issues; normal users don't need it, and it's visible
here only because it's discoverable from the source anyway.

It is governed by the compatibility-mode toggle in settings: `enable` refuses
while that toggle is off, and turning the toggle off clears this flag. Turning
the toggle back on does not restore it — run `enable` again. The command also
refuses on the `onboarding-debug` and `language-setup-debug` builds.

Quit Koedex before running any of these. The command refuses while Koedex is
running, so that the app and the command never both own the settings file.

## License

Koedex is licensed under the [Apache License 2.0](LICENSE). See also
[NOTICE](NOTICE) for attribution and the non-affiliation notice.
