# Contributing to SakuraCord

Thanks for helping improve SakuraCord. Bug reports, feature suggestions,
documentation, and focused code changes are all welcome.

## Report a bug or suggest a feature

Update to the latest published nightly or regular release, then search the
[existing issues](https://github.com/SakuraCordApp/SakuraCord/issues) before
opening a report. Add useful details to an existing report when it covers the
same problem.

For bugs, include reproduction steps, expected and actual behaviour, your app
version and release track, and your macOS version. Screenshots or recordings
help with visual problems. Follow the [support recipe](docs/DEVELOPMENT.md#report-a-problem)
to collect diagnostics, and review attachments for private information before
posting them.

For suggestions, explain the problem you want to solve and how the change would
help. Discuss substantial features or architectural changes in an issue before
starting implementation so the scope can be agreed on. Issues and milestones
track planned work; see [issues and roadmap](docs/README.md#issues-and-roadmap)
for how reports move through development and releases.

## Set up a development checkout

1. Fork the repository and create a working branch from the upstream `nightly`
   branch. Development pull requests target `nightly`.
2. Follow [Build from source](README.md#build-from-source) for the current macOS,
   Xcode, Swift, and Metal Toolchain requirements. SakuraCord targets the newest
   macOS beta and its matching toolchain.
3. Complete the [developer bootstrap](docs/README.md#developer-and-agent-bootstrap)
   to install the repository Git hooks before your first commit or push. Verify
   that `git config --local --get core.hooksPath` prints `.githooks`.
4. Set up local signing and launch the offline demo using the linked build
   instructions. It lets you explore the app without contacting Discord.

Use the guarded build and launch scripts. The [development guide](docs/DEVELOPMENT.md)
covers signing, credentials, authenticated sessions, and focused offline scenes.

## Make a focused change

Find the model, provider, and presentation owner in the
[architecture guide](docs/ARCHITECTURE.md#find-the-owner) before implementing a
feature. Keep responsibilities with their existing owners, follow project
conventions, and prefer the smallest maintainable solution. Avoid unrelated
refactors, unnecessary dependencies, and compatibility paths for older macOS
versions. Prefer suitable current Apple APIs over app-owned replacements.

Read the [protocol baseline](docs/PROTOCOL_BASELINE.md) before changing Discord
requests, Gateway handling, authentication, uploads, or other communication.
Use offline fixtures where possible and follow its verification boundary for
live sessions. If you use a coding agent, have it follow [AGENTS.md](AGENTS.md),
including the limits on account-mutating verification.

Never commit credentials, cookie exports, authorization headers, account
databases, personal Discord data, or unsanitized traffic captures.

Update documentation where the behaviour is owned. The
[documentation index](docs/README.md) identifies those sources; link to them
instead of duplicating their instructions.

## Verify your work

Use the [testing guide](docs/TESTING.md) to choose relevant existing checks and
the [development commands](docs/DEVELOPMENT.md#build-and-verification) to run
them. Run `git diff --check` and the required
`./script/code_quality.sh check` before considering a change ready to push.
Broad changes also need the full `./script/ci.sh` validation.

Keep committed tests selective: critical behaviour, major functionality, and
high-value regression coverage. Extend existing coverage when appropriate. A
small fix does not automatically need a new test, and purely visual changes
should be checked in the rendered app without adding committed UI tests.
Remove temporary UI tests before committing.

For documentation-only changes, check claims, local links and anchors, command
syntax, and whitespace; an app rebuild is not needed solely for prose. Do not
run build or test jobs concurrently in the same checkout.

## Open a pull request

Open your pull request against `nightly`, with a title and description that
explain the problem and resulting behaviour. Include:

- `Fixes #N` when the change fixes a tracked issue.
- The checks you actually ran and any remaining verification gaps. Distinguish
  compilation, tests, packaging/signature checks, live-account behaviour, and
  visual verification when reporting results.
- Before-and-after screenshots or a recording for visible changes, with private
  information removed.

Keep the diff focused and address review feedback on the same pull request.
Draft pull requests are useful for work that still needs feedback or validation.

### Required Greptile review before merging

Every pull request must meet both requirements before it can be merged:

- Greptile has reviewed the latest revision and given it a **5/5 confidence score**.
- **No valid Greptile findings remain unresolved**, including findings from
  earlier review rounds. A 5/5 score alone does not satisfy this requirement.

Fix each valid finding, push the changes, and wait for Greptile's automatic
review. If a finding is a false positive, explain why in its review thread with
supporting evidence; a maintainer must agree before it can be treated as resolved.
Dismissing a comment or resolving its thread without addressing the finding is
insufficient.

A missing, pending, or outdated review does not satisfy the requirement. False
positives may be excluded from the findings requirement, but do not waive the
5/5 score. These requirements apply alongside the usual checks and maintainer
review.
