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
evidence, and follow the repository validation commands in the root README.
For purely visual changes, verify the rendered result; when automated visual
inspection cannot establish correctness, request user confirmation.

Before committing a change that used temporary UI tests, inspect both
`git status` and the staged diff to confirm that those tests are absent.
