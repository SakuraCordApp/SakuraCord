# Linked Codex worktree workflow

This document applies only when the current checkout is an actual linked Git
worktree, or when one coordinating task is deliberately creating separate
linked worktrees for concurrent writers. It is not the default workflow for an
ordinary task in the primary SakuraCord checkout.

## Decide which checkout you are in

Run:

```sh
./script/worktree_runtime.sh
```

Read the first line:

- `Checkout: main` means the canonical checkout is active. Linked-worktree
  isolation is inactive. Use the normal build and test commands in the root
  README, keep the canonical `SakuraCord.app` identity, and do not apply the
  linked-only setup, cleanup, naming, or live-launch rules below.
- `Checkout: linked worktree` means this checkout has an isolated variant
  identity. Follow the linked-worktree sections below.

The existence of other paths in `git worktree list` does not change the mode of
the current checkout. Do not create a worktree, set `SAKURACORD_WORKTREE_ID`, or
invent a variant merely because this document or other registered worktrees
exist.

| Current checkout | App identity | Normal action |
| --- | --- | --- |
| Main checkout | `dist/SakuraCord.app`, `dev.sakuracord.SakuraCord` | Work normally in the current checkout. |
| Actual linked worktree | Variant app, bundle ID, output directory, and process path | Use offline fixtures and the linked-worktree wrappers. |
| Coordinating concurrent writers | One actual linked worktree per writer | Integrate their patches semantically in the designated target checkout. |

`script/worktree_test.sh` is a serialized test wrapper for whichever checkout
invokes it. Its name does not create, select, or switch to a worktree.

## What linked-worktree isolation covers

For an actual linked worktree, `script/worktree_runtime.sh` derives a stable
variant from the checkout path and assigns:

- a distinct executable, display name, app bundle, and bundle identifier;
- an app bundle under that checkout's `dist/worktrees/<variant>/`;
- checkout-local SwiftPM scratch and dependency-cache directories;
- exact executable-path process discovery and termination; and
- a checkout-local operation lock that serializes setup, build, package, and
  tests in that checkout.

These guarantees do not isolate the shared macOS desktop. Focus, pointer input,
menus, system dialogs, camera/microphone prompts, and other global UI operations
must still be serialized.

Normal-account state is not treated as safely isolated. Agent testing in linked
worktrees must use `--offline`, `--offline-long-server-list`, or
`--offline-forum-performance`. The live-worktree override is an explicit human
escape hatch, not an agent default and not proof that every persistent
application path is isolated. Even when the authenticated-test exception in
`AGENTS.md` is approved, an agent must perform it from the canonical main
checkout rather than enabling live access in a linked worktree.

## Setup and actions

Each concurrently writing agent gets its own Codex-created linked worktree from
the intended starting state. Never share one checkout between writers and never
edit or build through another task's checkout.

The Codex setup action runs:

```sh
./script/worktree_setup.sh
```

It prints the checkout classification and exact identity before resolving the
package graph. In a main checkout it only resolves dependencies and explicitly
says that no linked variant was created.

Repository environment actions operate on the current checkout:

- **Run Offline** and **Run Long Server Fixture** launch safe fixtures.
- **Package Isolated App** is isolated only when the first runtime line says
  `Checkout: linked worktree`; in main it packages the canonical app.
- **Show App Identity** prints the classification and exact bundle path.
- **Test App**, **Test Protocol**, and **Test All** serialize tests within the
  current checkout.

The cleanup hook stops only the exact executable in an actual linked worktree.
It is deliberately a no-op in the main checkout so cleanup cannot terminate the
canonical app or an authenticated user session.

## Computer Use targeting

For both main and linked checkouts, execute `script/worktree_runtime.sh` and use
the complete path from its `App:` line as the Computer Use `app` target. Never
target the generic display name `SakuraCord`.

Before interacting:

1. Confirm the helper reports the checkout you intended.
2. Confirm the printed executable path is the scoped running process.
3. If it is not running, launch that exact bundle with the intended offline
   fixture.
4. Continue using the same absolute bundle path for every state read and
   action.

Do not let a generic Computer Use lookup choose or launch another installed
copy. A bundle identifier is less precise because multiple canonical app copies
can share it.

## Integrating concurrent results

Use one designated integration checkout:

1. Record each source task's base revision and exact changed-file list.
2. Review every patch independently.
3. Apply non-overlapping changes first.
4. Reproduce overlapping semantic changes against the current target file;
   never overwrite a shared file wholesale from another worktree.
5. Search specifically for `<<<<<<<` and `>>>>>>>`, then run
   `git diff --check`.
6. Run relevant narrow tests, `./script/worktree_test.sh all`, package the
   current checkout, and perform strict deep code-sign verification.
7. Repeat read-only verification against the combined result for UI-sensitive
   or heavily overlapping changes.

Worktrees share Git metadata. Never force-move or delete another task's branch
while it is in use.

The repository Git hooks path is also shared. Run
`./script/install_git_hooks.sh` once in a fresh clone before creating or using
linked worktrees; do not install or bypass a different hook per worktree.

## Command reference

Main checkout:

```sh
./script/worktree_runtime.sh
./script/build_and_run.sh --offline
./script/worktree_test.sh app
./script/worktree_test.sh all
./script/build_and_run.sh package
```

Actual linked worktree:

```sh
./script/worktree_setup.sh
./script/build_and_run.sh --offline
./script/build_and_run.sh --offline-long-server-list
./script/build_and_run.sh --offline-forum-performance
./script/worktree_test.sh app
./script/worktree_test.sh protocol
./script/worktree_test.sh all
./script/build_and_run.sh package
./script/worktree_cleanup.sh
```

`package` stages a signed debug build without launching it.
`package-release` enables Swift release optimization and is reserved for
shipping validation; `script/package_dmg.sh` only permits the main checkout.
