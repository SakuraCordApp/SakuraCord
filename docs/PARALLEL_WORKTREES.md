# Parallel worktree workflow

SakuraCord's Codex environment is designed so each task can build and visually
test its own checkout without terminating or opening another task's app.

## What is isolated

Every linked worktree gets a deterministic variant identity derived from its
checkout path. The scripts use that identity for:

- a distinct app executable and display name;
- a distinct bundle identifier and app bundle under that worktree's `dist/`;
- worktree-local SwiftPM scratch and dependency-cache directories;
- exact-path process discovery and termination; and
- a worktree-local operation lock that prevents a build and test in the same
  checkout from corrupting one another.

The main checkout remains `SakuraCord.app` with bundle identifier
`dev.sakuracord.SakuraCord`. A linked worktree produces an app such as
`SakuraCord-a365-12ab34.app` with its own matching bundle identifier. The
visible display name includes the same variant so Computer Use can target the
correct build.

The Codex **Run Offline** and **Run Long Server Fixture** actions are the safe
defaults for agent visual testing. They never restore a stored Discord session,
use an in-memory database, and can remain open beside builds from other
worktrees. Live-account launches from linked worktrees are rejected unless a
person deliberately sets `SAKURACORD_ALLOW_LIVE_WORKTREE=1`.

## Starting parallel tasks

Create each Codex task in its own worktree from the same intended starting
state. If the main checkout contains the large unfinished change that all tasks
must extend, choose that working-tree state when creating each task. Do not
reuse one worktree for two writing tasks.

The environment setup script resolves the Swift package graph and prints the
worktree's app identity. Useful header actions are:

- **Run Offline** for ordinary visual testing;
- **Run Long Server Fixture** for the larger offline server list;
- **Package Isolated App** for a signed bundle without launching it;
- **Show App Identity** for the exact app path and bundle identifier Computer
  Use should target; and
- **Test App**, **Test Protocol**, and **Test All** for serialized tests inside
  that worktree.

The cleanup hook stops only the executable inside the worktree being removed.
It never uses `pkill` or `killall`.

## Integrating completed work

Use one integration task against the current main working tree:

1. Record each source task's base revision and exact changed-file list.
2. Review each patch independently; do not copy whole shared files from another
   checkout over newer main versions.
3. Apply non-overlapping changes first. For overlapping files, reproduce both
   semantic changes against the current file and review the combined diff.
4. After every source is integrated, search for conflict markers and run
   `git diff --check`.
5. Run the relevant narrow tests, then **Test All** and **Package Isolated App**.
6. Ask the source tasks for read-only verification against the integrated diff
   when the change is UI-sensitive or several tasks touched the same surface.

Keep the integration in the existing unfinished commit/worktree unless the user
explicitly requests separate commits. Worktrees share Git metadata, so never
force-move or delete another task's branch while it is still in use.

## Shell entrypoints

The same behavior is available outside the Codex header:

```sh
./script/worktree_setup.sh
./script/build_and_run.sh --offline
./script/build_and_run.sh package
./script/worktree_test.sh app
./script/worktree_test.sh all
./script/worktree_cleanup.sh
```
