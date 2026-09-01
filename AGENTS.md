# SakuraCord

SakuraCord is an interactive native macOS Discord client. User-visible actions
initiate account actions.

## Platform posture

SakuraCord targets only the newest macOS beta and its matching Xcode and Swift
toolchain. The current required versions live in the root README and package
manifests.

- Prefer the newest suitable Apple APIs and current Swift language patterns.
- Migrate, do not wrap. When a platform API has a suitable modern replacement,
  adopt it and remove the superseded app-owned path.
- Do not add back-deployment branches, compatibility shims, or speculative
  fallbacks for older Apple platforms unless explicitly requested.
- Capability gaps and vendored sources are deliberate exceptions. Understand
  why an older API exists before replacing it.

## Read it before you

| Read it before you | Source |
| --- | --- |
| navigate or change the canonical documentation set | [docs/README.md](docs/README.md) |
| change package ownership, runtime wiring, persistence, plugins, or packaging | [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) |
| add or materially change production REST, Gateway, authentication, upload, or other Discord communication | [docs/PROTOCOL_BASELINE.md](docs/PROTOCOL_BASELINE.md) |
| build, run, test, package, or verify the app | [README.md — Build from source](README.md#build-from-source) |
| add, change, or remove automated tests | [docs/TESTING.md](docs/TESTING.md) |
| commit or push from a fresh clone | [docs/README.md — Developer and agent bootstrap](docs/README.md#developer-and-agent-bootstrap) |
| push `main`, create a release tag, or change release automation | [docs/RELEASING.md](docs/RELEASING.md) |
| use Computer Use against SakuraCord | run `./script/runtime.sh` and use the complete path from its `App:` line |
| work on planned scope, priority, acceptance criteria, or progress | [Roadmap Management](plugin://roadmap-management@personal) |
| draft release notes or a Discord release announcement | [RELEASE_NOTES_STYLE.md](docs/RELEASE_NOTES_STYLE.md) and [DISCORD_RELEASE_ANNOUNCEMENTS_STYLE.md](docs/DISCORD_RELEASE_ANNOUNCEMENTS_STYLE.md) |

## Further Information

- Inspect current code, tests, configuration, and Git state before relying on
  documentation or roadmap descriptions. Preserve unrelated and dirty work.
- For work that is not exclusively UI, prefer a read-only authenticated
  verification pass against a configured session when it can exercise the
  changed behavior. Agent-run verification must not deliberately mutate remote
  account state or content.
- When using Computer Use, target SakuraCord by the absolute bundle path printed
  by `runtime.sh`, never by display name, and keep that target for the session.
- Roadmap state belongs only in the deployed roadmap service. Repository code
  and commits are evidence to assess, not proof that an item is complete.
- Keep documentation canonical. Update an existing source of truth instead of
  duplicating architecture, protocol, workflow, or planning information.
- Preserve the release-branch invariant: `main` must always be an ancestor of
  `nightly`. Before pushing `main`, incorporate the same commit into `nightly`
  without rewriting either branch and push both refs atomically when possible.
  Never push a regular or beta release tag until its commit is present on the
  remote `nightly` branch. Follow `docs/RELEASING.md` for the exact sequence.

## Tests

Reserve committed automated tests for critical behavior, major new
functionality, and high-value regression coverage. Do not commit automated
tests for purely visual UI changes. Temporary UI tests may be used during
development, but remove them before committing.

## Before you finish

Follow the relevant validation defined by the sources above. Report only checks
actually performed, and distinguish compilation, tests, packaging, signature,
live-account, and visual verification.
