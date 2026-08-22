# Security Policy

## Reporting a vulnerability

Please do not open a public issue for security vulnerabilities.

Report vulnerabilities through GitHub's private security advisory feature
on this repository: open the **Security** tab, then **Advisories** →
**Report a vulnerability**. This creates a private channel between you and
the maintainer, separate from the public issue tracker.

If you cannot use that channel for any reason, open a public issue containing
**only** the sentence "I would like to report a security issue" and nothing
else — no details, no reproduction steps, no payload. The maintainer will reply
with a private channel. There is no security email address for this project.

Include as much detail as you can:

- The version or commit you tested (`git rev-parse HEAD`, or the app's
  build git SHA, which is embedded in `Info.plist` as `KoedexBuildGitSHA`).
- Steps to reproduce, and the impact you believe the issue has.
- Whether the issue requires local access, a malicious clipboard/selection
  payload, a malicious prompt delivered through `codex app-server`, or
  something else.

## Supported versions

Koedex publishes release tags (`v0.1.0` onward) but does not yet have a formal
support matrix. Only the latest commit on the default branch is supported.
Please reproduce against a fresh build from the latest release tag, or from
`main`, before reporting.

## Response window

This is a project maintained in spare time. Please allow up to 7 days for
an initial response acknowledging the report, and up to 30 days for a fix
or a mitigation plan, depending on severity. If you have not heard back
within that window, it is fine to follow up on the same advisory thread.

## Scope

Koedex runs entirely on your Mac and talks to two things over the network
indirectly: Apple's on-device Speech framework (which may download
recognition model assets from Apple) and the `codex` CLI process you
already have installed and authenticated, which talks to OpenAI on your
behalf. Vulnerabilities in `codex` itself, or in Apple's frameworks, are
out of scope for this repository — please report those upstream. In-scope
issues include anything in this app's own code: permission handling,
text-injection/clipboard handling, prompt construction sent to
`codex app-server`, and local data storage under
`~/Library/Application Support/Koedex/`.

## Known limitations

Koedex is an early public release. The following are already known and are on
the list to address after release; the first and third are also described for
users in the README and the manual. **Please do not spend your time writing
them up as new reports** — a
report that adds a concrete attack path, a working reproduction, or a case
outside what is described here is very welcome.

- **On the selection-read path, secure-field detection relies solely on the
  operating system.** Before reading a selection, Koedex checks whether macOS
  reports that secure input is active. That covers ordinary password fields in
  native apps and in Safari and Chrome. Unlike the insertion paths, which do
  classify the focused element by its accessibility role and subrole, the read
  path does not, so a field that declares itself secure without macOS enabling
  secure input is not recognised there. Fields that merely look secret but are technically ordinary text
  fields — one-time passcode and 2FA boxes are the common case — are not
  detectable at all and never will be by this mechanism.
- **The secure-field classification taken when recording stops is not
  re-checked before every delivery path.** A field that changes into a password
  field during the AI round trip, while macOS still does not report secure
  input, is the case this covers.
- **The AI's answer can influence where the answer is delivered.** Selected
  text and web-search results are untrusted input, and the system prompt
  instructs the model to treat them as such, but the app does not independently
  re-derive the delivery target from the user's speech. Automatically pressing
  Return after delivery exists only in hands-free send for ordinary voice
  input; it is never reachable from AI command mode.
