#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEMP_ROOT="$(mktemp -d)"

cleanup() {
  rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT

create_fixture() {
  local fixture_root="$1"
  local remote="$fixture_root/remote.git"
  local seed="$fixture_root/seed"

  mkdir -p "$fixture_root" "$seed/script"
  git init --bare --quiet "$remote"
  git -C "$seed" init --quiet
  git -C "$seed" config user.name "Branch Sync Test"
  git -C "$seed" config user.email "branch-sync@example.invalid"
  cp "$ROOT_DIR/script/sync_main_into_nightly.sh" "$seed/script/"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    ': "${SAKURACORD_TEST_VALIDATION_LOG:?}"' \
    'printf "validated\n" > "$SAKURACORD_TEST_VALIDATION_LOG"' \
    > "$seed/script/ci.sh"
  chmod +x "$seed/script/"*.sh
  printf 'base\n' > "$seed/base.txt"
  git -C "$seed" add .
  git -C "$seed" commit --quiet -m "Base"
  git -C "$seed" branch -M main
  git -C "$seed" remote add origin "$remote"
  git -C "$seed" push --quiet origin main
  git -C "$seed" branch nightly
  git -C "$seed" push --quiet origin nightly
}

FAST_FORWARD_ROOT="$TEMP_ROOT/fast-forward"
create_fixture "$FAST_FORWARD_ROOT"
printf 'main\n' > "$FAST_FORWARD_ROOT/seed/main.txt"
git -C "$FAST_FORWARD_ROOT/seed" add main.txt
git -C "$FAST_FORWARD_ROOT/seed" commit --quiet -m "Advance main"
git -C "$FAST_FORWARD_ROOT/seed" push --quiet origin main
git clone --quiet --branch nightly \
  "$FAST_FORWARD_ROOT/remote.git" "$FAST_FORWARD_ROOT/worker"
SAKURACORD_TEST_VALIDATION_LOG="$FAST_FORWARD_ROOT/validation.log" \
  "$FAST_FORWARD_ROOT/worker/script/sync_main_into_nightly.sh" origin >/dev/null
git -C "$FAST_FORWARD_ROOT/worker" fetch --quiet origin main nightly
if [[ "$(git -C "$FAST_FORWARD_ROOT/worker" rev-parse origin/main)" != \
  "$(git -C "$FAST_FORWARD_ROOT/worker" rev-parse origin/nightly)" ]]; then
  echo "A nightly branch behind main was not fast-forwarded." >&2
  exit 1
fi
if [[ -e "$FAST_FORWARD_ROOT/validation.log" ]]; then
  echo "A fast-forward synchronization ran redundant merged-tree validation." >&2
  exit 1
fi

DIVERGED_ROOT="$TEMP_ROOT/diverged"
create_fixture "$DIVERGED_ROOT"
printf 'main\n' > "$DIVERGED_ROOT/seed/main.txt"
git -C "$DIVERGED_ROOT/seed" add main.txt
git -C "$DIVERGED_ROOT/seed" commit --quiet -m "Advance main"
git -C "$DIVERGED_ROOT/seed" push --quiet origin main
git -C "$DIVERGED_ROOT/seed" switch --quiet nightly
printf 'nightly\n' > "$DIVERGED_ROOT/seed/nightly.txt"
git -C "$DIVERGED_ROOT/seed" add nightly.txt
git -C "$DIVERGED_ROOT/seed" commit --quiet -m "Advance nightly"
git -C "$DIVERGED_ROOT/seed" push --quiet origin nightly
git clone --quiet --branch nightly \
  "$DIVERGED_ROOT/remote.git" "$DIVERGED_ROOT/worker"
SAKURACORD_TEST_VALIDATION_LOG="$DIVERGED_ROOT/validation.log" \
  "$DIVERGED_ROOT/worker/script/sync_main_into_nightly.sh" origin >/dev/null
git -C "$DIVERGED_ROOT/worker" fetch --quiet origin main nightly
if ! git -C "$DIVERGED_ROOT/worker" merge-base --is-ancestor \
  origin/main origin/nightly; then
  echo "A diverged nightly branch was not merged with main." >&2
  exit 1
fi
if ! grep -Fxq validated "$DIVERGED_ROOT/validation.log"; then
  echo "A merged nightly tree was pushed without validation." >&2
  exit 1
fi

CONFLICT_ROOT="$TEMP_ROOT/conflict"
create_fixture "$CONFLICT_ROOT"
printf 'main\n' > "$CONFLICT_ROOT/seed/base.txt"
git -C "$CONFLICT_ROOT/seed" add base.txt
git -C "$CONFLICT_ROOT/seed" commit --quiet -m "Change base on main"
git -C "$CONFLICT_ROOT/seed" push --quiet origin main
git -C "$CONFLICT_ROOT/seed" switch --quiet nightly
printf 'nightly\n' > "$CONFLICT_ROOT/seed/base.txt"
git -C "$CONFLICT_ROOT/seed" add base.txt
git -C "$CONFLICT_ROOT/seed" commit --quiet -m "Change base on nightly"
git -C "$CONFLICT_ROOT/seed" push --quiet origin nightly
git clone --quiet --branch nightly \
  "$CONFLICT_ROOT/remote.git" "$CONFLICT_ROOT/worker"
NIGHTLY_BEFORE="$(
  git --git-dir="$CONFLICT_ROOT/remote.git" rev-parse refs/heads/nightly
)"
if SAKURACORD_TEST_VALIDATION_LOG="$CONFLICT_ROOT/validation.log" \
  "$CONFLICT_ROOT/worker/script/sync_main_into_nightly.sh" origin \
  >/dev/null 2>&1; then
  echo "A conflicting main-to-nightly merge unexpectedly succeeded." >&2
  exit 1
fi
NIGHTLY_AFTER="$(
  git --git-dir="$CONFLICT_ROOT/remote.git" rev-parse refs/heads/nightly
)"
if [[ "$NIGHTLY_AFTER" != "$NIGHTLY_BEFORE" ]]; then
  echo "A conflicting merge changed the remote nightly branch." >&2
  exit 1
fi

printf 'Main-to-nightly synchronization tests passed.\n'
