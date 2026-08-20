# Security Policy

## Reporting a vulnerability

Please do not open a public issue for security vulnerabilities.

Report vulnerabilities through GitHub's private security advisory feature
on this repository: open the **Security** tab, then **Advisories** →
**Report a vulnerability**. This creates a private channel between you and
the maintainer, separate from the public issue tracker.

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
Please reproduce against a fresh build from `main` before reporting.

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
