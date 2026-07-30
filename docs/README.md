# SakuraCord documentation

This directory contains durable repository documentation. It is intentionally
small: implementation details should be discoverable from code and tests, while
planned work and progress belong in the canonical roadmap service.

## Canonical documents

| Document | Purpose |
| --- | --- |
| [Architecture](ARCHITECTURE.md) | Package ownership, runtime boundaries, persistence, plugins, and packaging. |
| [Protocol baseline](PROTOCOL_BASELINE.md) | Current SakuraCord network contracts, safety rules, capability gates, and dated protocol evidence. |
| [Linked worktrees](PARALLEL_WORKTREES.md) | Conditional isolation workflow for actual linked Codex worktrees and concurrent writers. |
| [Third-party notices](THIRD_PARTY_NOTICES.md) | Attribution and license notices that must remain with the repository. |

The root [README](../README.md) is the public project entry point.
Repository-wide agent rules live in [AGENTS.md](../AGENTS.md).

## Developer and agent bootstrap

Every fresh clone must install the repository-managed Git hooks before its
first push:

```sh
./script/install_git_hooks.sh
git config --local --get core.hooksPath
```

The second command must print `.githooks`. This setup applies to developers and
coding agents. The installer is safe to rerun, but deliberately refuses to
replace a different existing hooks path; integrate that hook configuration
explicitly instead of bypassing the repository pre-push check.

Before a change is considered ready to push, run:

```sh
./script/code_quality.sh check
```

That command is the pinned SwiftFormat and SwiftLint path shared by local
development, the pre-push hook, and CI.

## Roadmap

The deployed roadmap service is the only source of truth for planned work,
lifecycle state, acceptance criteria, verification, research gaps, and linked
Discord discussions. Use the
[Roadmap Management plugin](plugin://roadmap-management@personal) instead of
adding or updating a repository `ROADMAP.md`.

Roadmap state is revisioned independently of Git. A code match or commit is
evidence to review, not proof that a roadmap item is complete.

## Documentation policy

- Update an existing canonical document when a change alters a durable
  repository-wide contract.
- Put feature status, acceptance criteria, research, and verification on the
  canonical roadmap item.
- Put narrow, time-bound implementation evidence in the pull request or commit
  description. Update `PROTOCOL_BASELINE.md` only when it establishes or
  supersedes a repository-wide network baseline.
- Do not add one Markdown implementation journal per feature. Create a new
  document only for a durable cross-cutting workflow, architecture boundary,
  or legal requirement that does not fit an existing document.
- Date observations and name their evidence. Do not present an old client
  build, benchmark, or live verification as current.
- Prefer deleting obsolete documentation over leaving a tombstone that agents
  may treat as current.

Adjacent asset inventories under `Brand/`, packaging attribution under
`App/Packaging/`, and vendored dependency READMEs under `Packages/DaveKit/` are
scoped to their own directories and are not SakuraCord planning documents.
