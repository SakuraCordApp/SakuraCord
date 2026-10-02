# Testing

SakuraCord keeps its committed automated test suite deliberately selective.
Tests are production code with ongoing compile-time, runtime, reliability, and
maintenance costs.

## When to commit tests

Add or materially expand automated tests only when they protect at least one of
the following:

- critical behavior such as authentication, credentials, account mutations,
  Discord protocol contracts, persistence, encryption, or concurrency and
  lifecycle invariants;
- a major new feature with substantial behavioral logic or a durable public
  contract; or
- a significant regression that is likely to recur and can be covered by a
  focused, deterministic test.

Before adding a test, search the existing suite for equivalent coverage.
Prefer strengthening or parameterizing an existing test over adding another
scenario, and cover representative boundaries instead of every permutation.
Each committed test must protect a distinct production failure mode whose value
justifies its maintenance and execution cost.

## When not to commit tests

Do not add committed automated tests for purely visual UI work, including
changes limited to styling, spacing, layout tuning, animation, copy, icons, or
other presentation details. Temporary tests may be useful while developing
such a change, but they must be removed from the working tree and index before
commit.

Also avoid tests that only restate constants, exercise trivial mappings, verify
private implementation choreography, test mocks rather than production
behavior, or duplicate an invariant already covered at a more appropriate
boundary. A small fix does not require a new regression test by default.

## Test design

- Use the smallest scope that proves the behavior.
- Keep fixtures local to the test and isolate filesystem, network, clock, and
  process-global state.
- Do not use fixed delays as synchronization. Prefer injected clocks,
  continuations, or deterministic gates.
- Do not introduce mutable global test state or `nonisolated(unsafe)` fixtures.
- Keep additions proportional to the production behavior. Large test additions
  require an explicit justification and should prompt a search for a simpler
  boundary or existing coverage.
- Delete or consolidate tests when their behavior is duplicated, obsolete, or
  no longer worth their cost.

## Verification without new tests

Not adding a test does not mean skipping verification. Build and inspect the
smallest relevant scope, run existing focused tests when they provide useful
evidence, and follow the repository validation commands in the
[development guide](DEVELOPMENT.md#build-and-verification).
For purely visual changes, verify the rendered result; when automated visual
inspection cannot establish correctness, request user confirmation.

Before committing a change that used temporary UI tests, inspect both
`git status` and the staged diff to confirm that those tests are absent.

## Translation verification

`TranslationTokenTests`, `AppleTranslationCoordinatorTests`, `TranslationFeatureTests`,
and `TranslationSettingsTests` use synthetic input and injected services. They need
no account, downloaded models, permission dialogs, or network translation. Gates
and stored task handles synchronize completions; cancellation-ignoring fakes test
request identity independently of cooperative task cancellation. Run the normal
`./script/code_quality.sh check` and `./script/ci.sh` on the required Xcode toolchain.
A source parse or isolated service test is not an application build or UI test.

For manual verification, build the offline fixture with
`./script/build_and_run.sh --offline`, obtain its exact bundle path from
`./script/runtime.sh`, and use only synthetic messages/drafts. Enable Translation
under Features and test Dutch→English, English→Dutch, Japanese/Korean→a supported
target, and short ambiguous text. Include repeated mentions/custom emoji, links,
code, multiline RTL/Unicode, and spoilers. Check selection, Copy Translation,
links/mentions, spoiler concealment/reveal, accessibility, incoming/outgoing bubbles,
light/dark modes, resizing, and returning to cached conversations. Exercise both
composers, translated edits and toggles, long-draft send validation, dismissal,
settings changes, and repeated same-pair requests.

On a test Mac, use System Settings > General > Language & Region > Translation
Languages to inspect model installation. Verify first-use approval and cancellation,
navigation/window closure during a download, and retry. With models already installed,
disconnect networking and repeat synthetic translation. Check the traditional-model
path on a Mac without Apple Intelligence. Do not remove a user's existing models
merely to run this check. Judge meaningful translation and exact protected-token
integrity, not a permanent golden output from a changing model. Record these runtime
checks separately from fake-based tests in the PR; unavailable checks remain unverified.
