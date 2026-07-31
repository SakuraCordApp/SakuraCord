#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TOOLS_DIR="$ROOT_DIR/.build/code-quality-tools"
FIXTURE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/sakuracord-code-quality-test.XXXXXX")"
ZERO_SHA="0000000000000000000000000000000000000000"

cleanup() {
  rm -rf "$FIXTURE_ROOT"
}
trap cleanup EXIT

expect_hook_failure() {
  local input="$1"
  local output
  local status

  set +e
  output="$(
    cd "$FIXTURE_ROOT"
    printf '%s' "$input" | ./.githooks/pre-push 2>&1
  )"
  status=$?
  set -e

  if [[ "$status" -eq 0 ]]; then
    echo "Expected pre-push code quality to reject the invalid fixture." >&2
    echo "$output" >&2
    return 1
  fi
  if [[ "$output" != *"Fixture.swift"* ]]; then
    echo "Expected a file-level Fixture.swift diagnostic." >&2
    echo "$output" >&2
    return 1
  fi
}

expect_commit_failure() {
  local output
  local status
  local head_before

  head_before="$(git -C "$FIXTURE_ROOT" rev-parse HEAD)"
  set +e
  output="$(git -C "$FIXTURE_ROOT" commit -qm "Commit rejected by quality hook" 2>&1)"
  status=$?
  set -e

  if [[ "$status" -eq 0 ]]; then
    echo "Expected pre-commit code quality to reject the invalid fixture." >&2
    return 1
  fi
  if [[ "$output" != *"Fixture.swift"* ]]; then
    echo "Expected a file-level Fixture.swift diagnostic from pre-commit." >&2
    echo "$output" >&2
    return 1
  fi
  if [[ "$(git -C "$FIXTURE_ROOT" rev-parse HEAD)" != "$head_before" ]]; then
    echo "The rejected commit unexpectedly advanced HEAD." >&2
    return 1
  fi
}

mkdir -p \
  "$FIXTURE_ROOT/.githooks" \
  "$FIXTURE_ROOT/App/Sources" \
  "$FIXTURE_ROOT/script"
cp "$ROOT_DIR/.swiftformat" "$FIXTURE_ROOT/.swiftformat"
cp "$ROOT_DIR/.swiftlint.yml" "$FIXTURE_ROOT/.swiftlint.yml"
cp "$ROOT_DIR/.githooks/pre-commit" "$FIXTURE_ROOT/.githooks/pre-commit"
cp "$ROOT_DIR/.githooks/pre-push" "$FIXTURE_ROOT/.githooks/pre-push"
cp "$ROOT_DIR/script/check_code_quality_snapshot.sh" "$FIXTURE_ROOT/script/check_code_quality_snapshot.sh"
cp "$ROOT_DIR/script/code_quality.sh" "$FIXTURE_ROOT/script/code_quality.sh"
cp "$ROOT_DIR/script/pre_commit_code_quality.sh" "$FIXTURE_ROOT/script/pre_commit_code_quality.sh"
cp "$ROOT_DIR/script/pre_push_code_quality.sh" "$FIXTURE_ROOT/script/pre_push_code_quality.sh"
cp \
  "$ROOT_DIR/script/fixtures/code_quality/Corrected.swift.fixture" \
  "$FIXTURE_ROOT/App/Sources/Fixture.swift"
chmod +x \
  "$FIXTURE_ROOT/.githooks/pre-commit" \
  "$FIXTURE_ROOT/.githooks/pre-push" \
  "$FIXTURE_ROOT/script/check_code_quality_snapshot.sh" \
  "$FIXTURE_ROOT/script/code_quality.sh" \
  "$FIXTURE_ROOT/script/pre_commit_code_quality.sh" \
  "$FIXTURE_ROOT/script/pre_push_code_quality.sh"

git -C "$FIXTURE_ROOT" init -q
git -C "$FIXTURE_ROOT" config user.name "SakuraCord Code Quality Test"
git -C "$FIXTURE_ROOT" config user.email "code-quality-test@sakuracord.invalid"
git -C "$FIXTURE_ROOT" add .
git -C "$FIXTURE_ROOT" commit -qm "Correct fixture"
git -C "$FIXTURE_ROOT" config core.hooksPath .githooks

cp \
  "$ROOT_DIR/script/fixtures/code_quality/Misformatted.swift.fixture" \
  "$FIXTURE_ROOT/App/Sources/Fixture.swift"
git -C "$FIXTURE_ROOT" add App/Sources/Fixture.swift
expect_commit_failure
git -C "$FIXTURE_ROOT" commit --no-verify -qm "Deliberately misformat fixture"
BAD_SHA="$(git -C "$FIXTURE_ROOT" rev-parse HEAD)"

expect_hook_failure \
  "refs/heads/main $BAD_SHA refs/heads/main $ZERO_SHA
"

SAKURACORD_CODE_QUALITY_ROOT="$FIXTURE_ROOT" \
  SAKURACORD_CODE_QUALITY_TOOLS_DIR="$TOOLS_DIR" \
  "$FIXTURE_ROOT/script/code_quality.sh" fix --files App/Sources/Fixture.swift
git -C "$FIXTURE_ROOT" add App/Sources/Fixture.swift
(
  cd "$FIXTURE_ROOT"
  ./.githooks/pre-commit
)
git -C "$FIXTURE_ROOT" commit -qm "Correct committed fixture"
GOOD_SHA="$(git -C "$FIXTURE_ROOT" rev-parse HEAD)"

(
  cd "$FIXTURE_ROOT"
  printf \
    'refs/heads/main %s refs/heads/main %s\n' \
    "$GOOD_SHA" "$BAD_SHA" \
    | ./.githooks/pre-push
)

printf 'preserve me\n' >"$FIXTURE_ROOT/Notes.txt"
git -C "$FIXTURE_ROOT" add Notes.txt
git -C "$FIXTURE_ROOT" commit -qm "Add unrelated fixture"
printf 'unrelated dirty work\n' >>"$FIXTURE_ROOT/Notes.txt"
NOTES_BEFORE="$(shasum -a 256 "$FIXTURE_ROOT/Notes.txt")"

cp \
  "$ROOT_DIR/script/fixtures/code_quality/Misformatted.swift.fixture" \
  "$FIXTURE_ROOT/App/Sources/Fixture.swift"
git -C "$FIXTURE_ROOT" add App/Sources/Fixture.swift

expect_commit_failure

expect_hook_failure \
  "refs/heads/main $(git -C "$FIXTURE_ROOT" rev-parse HEAD) refs/heads/main $GOOD_SHA
"

SAKURACORD_CODE_QUALITY_ROOT="$FIXTURE_ROOT" \
  SAKURACORD_CODE_QUALITY_TOOLS_DIR="$TOOLS_DIR" \
  "$FIXTURE_ROOT/script/code_quality.sh" fix --staged

NOTES_AFTER="$(shasum -a 256 "$FIXTURE_ROOT/Notes.txt")"
if [[ "$NOTES_BEFORE" != "$NOTES_AFTER" ]]; then
  echo "The staged auto-fix changed unrelated dirty work." >&2
  exit 1
fi

(
  cd "$FIXTURE_ROOT"
  printf \
    'refs/heads/main %s refs/heads/main %s\n' \
    "$(git rev-parse HEAD)" "$GOOD_SHA" \
    | ./.githooks/pre-push
)

cp \
  "$ROOT_DIR/script/fixtures/code_quality/LintInvalid.swift.fixture" \
  "$FIXTURE_ROOT/App/Sources/LintFixture.swift"
git -C "$FIXTURE_ROOT" add App/Sources/LintFixture.swift

expect_commit_failure

expect_hook_failure \
  "refs/heads/main $(git -C "$FIXTURE_ROOT" rev-parse HEAD) refs/heads/main $GOOD_SHA
"

cp \
  "$ROOT_DIR/script/fixtures/code_quality/LintCorrected.swift.fixture" \
  "$FIXTURE_ROOT/App/Sources/LintFixture.swift"
git -C "$FIXTURE_ROOT" add App/Sources/LintFixture.swift

(
  cd "$FIXTURE_ROOT"
  ./.githooks/pre-commit
  printf \
    'refs/heads/main %s refs/heads/main %s\n' \
    "$(git rev-parse HEAD)" "$GOOD_SHA" \
    | ./.githooks/pre-push
)

echo "Code-quality regression fixture passed."
