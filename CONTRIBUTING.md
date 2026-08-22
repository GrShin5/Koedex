# Contributing to Koedex

Thanks for your interest in Koedex. This document covers how to build the
project, how to run its checks, and what maintainers expect from a pull
request.

## Prerequisites

- macOS 26 (Tahoe) or later. Koedex depends on the SpeechAnalyzer APIs and
  is not buildable or runnable on earlier macOS versions.
- Swift 6.2 or later. The Command Line Tools SDK is sufficient — a full
  Xcode.app install is not required.
- A recent version of the Codex CLI (`codex`) on your `PATH`, authenticated
  with a ChatGPT subscription, if you want to exercise the AI-assist paths
  end to end. This is not required just to build the project or run the
  regression suite.

## Building

```bash
# Build the executable
swift build

# Build the .app bundle (creates dist/Koedex.app)
./scripts/make_app.sh debug
```

The first time you assemble an `.app` bundle you will need a stable local
code-signing certificate; see the README's "Install"
section for the one-time `scripts/make_signing_cert.sh` setup.

## Running the checks

Koedex ships a self-contained regression suite that does not talk to the
network or to `codex app-server`:

```bash
swift build
.build/debug/Koedex --test-regressions
```

Run this before opening a pull request. A handful of pasteboard fixtures
require a real pasteboard server and self-skip with a printed notice in
headless/CI-like environments — that is expected, not a failure.

## What the public CI actually runs

The `build` workflow (`.github/workflows/build.yml`) runs against this public repository,
which does not contain every file in the development source. Concretely, it runs:

- Toolchain info (`swift --version`)
- `swift build`
- The regression suite (`.build/debug/Koedex --test-regressions`)
- The log-hygiene check

It always skips, while printing a notice that it did so:

- Localization coverage (`scripts/check_localization_coverage.py`)
- The `scripts/tests` suite (`python3 -m unittest discover -s scripts/tests`)

Both are skipped because the files they depend on are development-side only and are not
part of the public repository. **A green CI badge therefore does not mean those two checks
ran** — check the workflow logs for the "skipped: ..." lines if you need to confirm.

## Code style

- Follow the style of the surrounding code rather than introducing a new
  convention. In particular:
  - In-code comments are written in Japanese, matching the rest of the
    codebase. Please keep new comments in Japanese unless the surrounding
    file is already in English.
  - Commit subject lines are written in English, imperative mood, e.g.
    `fix: correct hands-free trigger timeout`.
- Keep changes minimal and focused. Avoid drive-by reformatting or
  renaming in the same commit as a functional change.
- Prefer adding or extending regression coverage in
  `Sources/Koedex/Support/RegressionTestSuite.swift` for logic that can be
  tested without a live pasteboard, microphone, or `codex` process.

## Pull requests

- Describe what changed and why, not just what. If the change affects
  permissions, text injection, or anything that talks to `codex
  app-server`, call that out explicitly — these are the areas most likely
  to need careful review.
- Keep the diff scoped to one change. Unrelated cleanup should be its own
  PR.
- Make sure `swift build` and `.build/debug/Koedex --test-regressions`
  both pass before requesting review.
- If your change is user-visible, mention whether both the English and
  Japanese in-app strings (`Sources/Koedex/Resources/en.lproj`,
  `Sources/Koedex/Resources/ja.lproj`) were updated.
- For anything beyond a small fix, opening an issue to discuss the
  approach first is welcome but not required.

## Licensing of contributions

Koedex is licensed under the Apache License 2.0; see [LICENSE](LICENSE).

Unless you state otherwise in writing, any contribution you intentionally
submit for inclusion in Koedex is submitted under the same Apache License
2.0, with no additional terms or conditions. This is the inbound=outbound
rule described in Section 5 of the license itself, and submitting a pull
request is taken as agreement to it.

Only submit work you have the right to license this way. Do not paste code
from sources under an incompatible license, and if a change is derived from
third-party material, say so in the pull request so the attribution and
[NOTICE](NOTICE) requirements can be handled before it is merged.
