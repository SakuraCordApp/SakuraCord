# Documentation

Choose the task first. Current contracts live in the linked guide; implementation
and tests provide the exact fields and algorithms. Planned scope and progress
belong in GitHub Issues and milestones, not these documents.

| I need to… | Start here |
| --- | --- |
| Contribute a change or open a pull request | [Contributing](../CONTRIBUTING.md) |
| Install or build the app | [Root README](../README.md#build-from-source) |
| Run a local/offline build, choose credentials or signing | [Development](DEVELOPMENT.md) |
| Find the model, provider and presentation owner | [Architecture](ARCHITECTURE.md#find-the-owner) |
| Change a Discord request or event | [Protocol baseline](PROTOCOL_BASELINE.md), then its topic guide |
| Choose tests or run focused verification | [Testing](TESTING.md) |
| Diagnose a failure or report a bug | [Troubleshooting](DEVELOPMENT.md#troubleshooting) / [report a problem](DEVELOPMENT.md#report-a-problem) |
| Promote, tag, publish or repair a release | [Releasing](RELEASING.md) |
| Draft release copy | [GitHub notes](RELEASE_NOTES_STYLE.md) / [Discord announcement](DISCORD_RELEASE_ANNOUNCEMENTS_STYLE.md) |
| Find licences or asset provenance | [Third-party notices](THIRD_PARTY_NOTICES.md), [Brand](../Brand/README.md), [DMG sources](../App/Packaging/DMG/SOURCES.md) |

Repository-wide agent instructions live in [AGENTS.md](../AGENTS.md).
Vendored READMEs apply to their upstream components; the
[DaveKit wrapper](../Packages/DaveKit/README.md) identifies the app boundary.
Released `Releases/*.json` files are historical authored copy, not descriptions
of the current checkout.

## Developer and agent bootstrap

Every fresh clone must install the repository-managed Git hooks before its
first commit or push:

```sh
./script/install_git_hooks.sh
git config --local --get core.hooksPath
```

The second command must print `.githooks`. The installer refuses to replace a
different configured hook path; integrate it explicitly rather than bypassing
checks. Before considering a change ready to push, run:

```sh
./script/code_quality.sh check
```

This is the pinned SwiftFormat/SwiftLint policy shared with CI. Pre-commit checks
the staged snapshot; pre-push checks committed tips. Feature branches, including
forks, also validate the merged tree against canonical `nightly`. Conflicts,
unavailable bases and merged-tree failures block the push. Temporary snapshots
leave the checkout, index, branches and `FETCH_HEAD` unchanged.

Canonical `main`/`nightly` and tag pushes validate their committed trees without
a synthetic PR merge; fork branches with those names still get merge validation.
Snapshot checks use that snapshot's pinned policy. A later base change still
requires fresh CI. See Development for broader verification.

## Documentation ownership

| Information | One authoritative home |
| --- | --- |
| Package boundaries, lifecycle, persistence | Architecture |
| Commands, local configuration, troubleshooting | Development; release-specific procedures in Releasing |
| Shared network safety and verification policy | Protocol baseline |
| Feature-family wire contracts and deliberate deviations | Relevant `protocol/` topic |
| Which tests deserve maintenance and how to run them | Testing |
| Protocol rationale and source references | Beside the relevant contract; keep working research notes out of the repository |
| Scope, acceptance criteria, status and progress | GitHub Issues and milestones |

When updating documentation:

- Replace the superseded rule where it is owned; link from other documents.
- Keep code constants and exhaustive inventories in code unless a concise table
  materially helps the reader. Link the owner and representative checks.
- Document decisions, invariants and supported procedures. Avoid describing every
  view arrangement or narrating implementation steps.
- Distinguish static inspection, mocked tests and live observations. Include a
  source version or observation date only when it explains a contract.
- Add a topic only for a durable boundary that cannot fit its existing owner.
  Do not create one implementation journal per feature.
- Check local paths/anchors and changed command examples. Review inbound links
  before renaming headings. Preserve required licences and historical release copy.
- Delete obsolete guidance and research journals; retain only useful technical
  conclusions in the relevant contract.
- Keep personal timezones/locations, machine paths, test-account or server names,
  usage history and capture-session details out of documentation.

## Issues and roadmap

GitHub Issues in this repository are the source of truth for bugs, suggestions,
and planned work; versions are GitHub milestones. The
[SakuraCord hub](https://github.com/SakuraCordApp/Roadmap) mirrors reports and
conversation between GitHub, Discord forum posts, and the
[tracker](https://sakuracord.app/tracker). Updates are queued, so mirrors can lag.
The hub database holds projections, links, subscriptions, and sync state; do not
maintain a second backlog there or in a repository `ROADMAP.md`.

- File reports in the app (`/bug`, `/suggest`, the **Help** menu, or a
  `sakuracord.app/report` link card), the website, Discord's report forms, or
  GitHub's issue forms. Continue discussion on the existing report.
- Issue types are Bug or Feature; area and priority use `area: …` and
  `priority: …` labels. The hub normalizes status from one `status: …` label
  and the issue's open/closed state and close reason. Closing as completed alone
  means Done, not Shipped; duplicate and not-planned closures retain their own
  outcomes.
- Milestone descriptions supply the [roadmap](https://sakuracord.app/roadmap):
  a headline line, optional summary, then `- highlight (#N)` bullets. Assigning
  a milestone moves New or Confirmed issues to Planned; removing it moves
  Planned back to Confirmed. It does not override Needs Info or work already
  in progress.
- Put `Fixes #N` in a PR title/body or a commit message. An open linked PR moves
  an issue awaiting work to In Progress; a merged PR or a commit pushed to
  `nightly` moves it to In Nightly. Target implementation PRs at `nightly`.
  The first published release whose tag contains a recorded fix marks it
  Shipped and closes it, including beta releases. A later regular release is
  tracked separately. The hub posts release updates and notifies Discord
  followers. See [Releasing](RELEASING.md#release-model) for the checklist.
- New reports trigger one read-only triage and investigation agent in GitHub
  Actions against the nightly checkout (GPT-6 Luna by default). It reads the
  report, recent comments, screenshots, and similar reports, then posts one
  assessment with classification, questions, duplicate suggestions, and code
  findings. The hub validates the result before applying metadata; later
  maintainer status decisions take precedence over automated triage. Each agent
  edits one Discord status card with its current workflow step (refreshed about
  once a minute) and final outcome. Triage puts the assessment in that same card.
- Both bugs and suggestions require the latest published nightly or regular
  release. The agent can correct either category and considers closed reports
  as duplicates. It verifies fix-commit ancestry against the reported release:
  fixed in code, published in nightly, and published in regular are distinct.
  A build already containing a claimed fix needs regression investigation.
  Verified existing fixes join release tracking; unreleased fixes stay open.
- Maintainers can rerun with `agent: investigate` or Discord's Manage menu.
  The label stays until the hub applies the result; retry a failed run in
  Actions. A report body edited during assessment triggers a fresh run.
- `agent: fix` explicitly starts the separate macOS implementation agent. When
  it produces changes, it opens or updates a draft PR against `nightly`.
  Neither agent merges changes; review their output like any contribution.

Use `gh issue list`, `gh issue view`, and `gh api` to read and update issues.
A code match or commit is evidence to review, not proof that an issue is complete.
The hub's [lifecycle rules](https://github.com/SakuraCordApp/Roadmap/blob/main/src/lifecycle.ts)
and [fix/release synchronization](https://github.com/SakuraCordApp/Roadmap/blob/main/src/sync/activity.ts)
implement these transitions; this repository's [agent workflows](../.github/workflows)
run the assessments and fixes.
