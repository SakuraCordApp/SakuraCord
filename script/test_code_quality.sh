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
  local expected="${2:-Fixture.swift}"
  local remote_url="${3:-}"
  local output
  local status

  set +e
  output="$(
    cd "$FIXTURE_ROOT"
    printf '%s' "$input" | ./.githooks/pre-push origin "$remote_url" 2>&1
  )"
  status=$?
  set -e

  if [[ "$status" -eq 0 ]]; then
    echo "Expected pre-push code quality to reject the invalid fixture." >&2
    echo "$output" >&2
    return 1
  fi
  if [[ "$output" != *"$expected"* ]]; then
    echo "Expected diagnostic: $expected" >&2
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
# Commits otherwise start detached maintenance that can rewrite the object
# store while the fixture clones it.
git -C "$FIXTURE_ROOT" config maintenance.auto false
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

printf '\n// swiftlint:disable file_length\n' >>"$FIXTURE_ROOT/App/Sources/Fixture.swift"
set +e
SUPPRESSION_OUTPUT="$(
  SAKURACORD_CODE_QUALITY_ROOT="$FIXTURE_ROOT" \
    SAKURACORD_CODE_QUALITY_TOOLS_DIR="$TOOLS_DIR" \
    "$FIXTURE_ROOT/script/code_quality.sh" check 2>&1
)"
SUPPRESSION_STATUS=$?
set -e
if [[ "$SUPPRESSION_STATUS" -eq 0 ]]; then
  echo "Expected code quality to reject a file-length suppression." >&2
  exit 1
fi
if [[ "$SUPPRESSION_OUTPUT" != *"File-length suppressions and blanket disables are not allowed"* ]]; then
  echo "Expected the file-length suppression guard diagnostic." >&2
  echo "$SUPPRESSION_OUTPUT" >&2
  exit 1
fi

sed -i '' 's/swiftlint:disable file_length/swiftlint:disable all/' \
  "$FIXTURE_ROOT/App/Sources/Fixture.swift"
set +e
SUPPRESSION_OUTPUT="$(
  SAKURACORD_CODE_QUALITY_ROOT="$FIXTURE_ROOT" \
    SAKURACORD_CODE_QUALITY_TOOLS_DIR="$TOOLS_DIR" \
    "$FIXTURE_ROOT/script/code_quality.sh" check 2>&1
)"
SUPPRESSION_STATUS=$?
set -e
if [[ "$SUPPRESSION_STATUS" -eq 0 ]]; then
  echo "Expected code quality to reject a blanket SwiftLint suppression." >&2
  exit 1
fi
if [[ "$SUPPRESSION_OUTPUT" != *"File-length suppressions and blanket disables are not allowed"* ]]; then
  echo "Expected the blanket suppression guard diagnostic." >&2
  echo "$SUPPRESSION_OUTPUT" >&2
  exit 1
fi

# Both tips pass, but their clean merge exceeds the same file-length limit
# that caught PR #46 in CI. Keep the remote local so this fixture is hermetic.
git -C "$FIXTURE_ROOT" reset --hard "$GOOD_SHA" >/dev/null
python3 - "$FIXTURE_ROOT" <<'PYFIXTURE'
from pathlib import Path
import sys
root = Path(sys.argv[1])
policy = root / '.swiftlint.yml'
policy.write_text(policy.read_text().replace('warning: 2000', 'warning: 20'))
(root / 'App/Sources/Fixture.swift').write_text(
    'enum Fixture {\n' + ''.join(f'    static let value{index} = {index}\n' for index in range(14)) + '}\n')
PYFIXTURE
git -C "$FIXTURE_ROOT" add .swiftlint.yml App/Sources/Fixture.swift
git -C "$FIXTURE_ROOT" commit -qm "Shared merge fixture"
git -C "$FIXTURE_ROOT" branch nightly
BASE_REMOTE="$FIXTURE_ROOT/.build/base.git"
git clone --bare --quiet "$FIXTURE_ROOT" "$BASE_REMOTE"
git -C "$FIXTURE_ROOT" config "url.$BASE_REMOTE.insteadOf" https://github.com/SakuraCordApp/SakuraCord.git
git -C "$FIXTURE_ROOT" switch --quiet -c feature-merge
python3 - "$FIXTURE_ROOT/App/Sources/Fixture.swift" <<'PYFIXTURE'
from pathlib import Path
import sys
p = Path(sys.argv[1])
p.write_text(p.read_text().replace('}\n', '    static let feature0 = 0\n    static let feature1 = 1\n    static let feature2 = 2\n}\n'))
PYFIXTURE
git -C "$FIXTURE_ROOT" add App/Sources/Fixture.swift
git -C "$FIXTURE_ROOT" commit -qm "Feature under limit"
FEATURE_SHA="$(git -C "$FIXTURE_ROOT" rev-parse HEAD)"
(
  cd "$FIXTURE_ROOT"
  printf 'refs/heads/feature-merge %s refs/heads/feature-merge %s\n' "$FEATURE_SHA" "$ZERO_SHA" | ./.githooks/pre-push
)

# Advance the remote after the first check; the next push must fetch it again.
git -C "$FIXTURE_ROOT" switch --quiet nightly
python3 - "$FIXTURE_ROOT/App/Sources/Fixture.swift" <<'PYFIXTURE'
from pathlib import Path
import sys
p = Path(sys.argv[1])
p.write_text(p.read_text().replace('enum Fixture {\n', 'enum Fixture {\n    static let base0 = 0\n    static let base1 = 1\n    static let base2 = 2\n'))
PYFIXTURE
git -C "$FIXTURE_ROOT" add App/Sources/Fixture.swift
git -C "$FIXTURE_ROOT" commit -qm "Base under limit"
git -C "$FIXTURE_ROOT" push --quiet "$BASE_REMOTE" nightly
git -C "$FIXTURE_ROOT" switch --quiet feature-merge
printf 'staged fixture\n' > "$FIXTURE_ROOT/Unrelated.txt"
git -C "$FIXTURE_ROOT" add Unrelated.txt
printf 'unstaged fixture\n' >> "$FIXTURE_ROOT/Unrelated.txt"
INDEX_BEFORE="$(git -C "$FIXTURE_ROOT" write-tree)"
DIRTY_BEFORE="$(shasum -a 256 "$FIXTURE_ROOT/Unrelated.txt")"
printf 'preserve fetch head\n' > "$FIXTURE_ROOT/.git/FETCH_HEAD"
expect_hook_failure \
  "refs/heads/feature-merge $FEATURE_SHA refs/heads/feature-merge $ZERO_SHA
" "currently contains 22"
expect_hook_failure \
  "refs/heads/feature-merge $FEATURE_SHA refs/heads/main $ZERO_SHA
" "currently contains 22" "https://github.com/contributor/SakuraCord.git"
[[ "$INDEX_BEFORE" == "$(git -C "$FIXTURE_ROOT" write-tree)" ]]
[[ "$DIRTY_BEFORE" == "$(shasum -a 256 "$FIXTURE_ROOT/Unrelated.txt")" ]]
[[ "$(cat "$FIXTURE_ROOT/.git/FETCH_HEAD")" == "preserve fetch head" ]]
[[ -z "$(git -C "$FIXTURE_ROOT" for-each-ref refs/sakuracord/code-quality/)" ]]

# Splitting out the added declarations makes the combined tree pass.
git -C "$FIXTURE_ROOT" reset --hard "$FEATURE_SHA" >/dev/null
python3 - "$FIXTURE_ROOT/App/Sources" <<'PYFIXTURE'
from pathlib import Path
import sys
root = Path(sys.argv[1])
p = root / 'Fixture.swift'
lines = p.read_text().splitlines(keepends=True)
added = [line for line in lines if 'static let feature' in line]
p.write_text(''.join(line for line in lines if line not in added))
(root / 'AddedFixture.swift').write_text('enum AddedFixture {\n' + ''.join(added) + '}\n')
PYFIXTURE
git -C "$FIXTURE_ROOT" add App/Sources
git -C "$FIXTURE_ROOT" commit -qm "Split feature declarations"
(
  cd "$FIXTURE_ROOT"
  printf 'refs/heads/feature-merge %s refs/heads/feature-merge %s\n' "$(git rev-parse HEAD)" "$FEATURE_SHA" | ./.githooks/pre-push
)

# An unavailable base must not silently degrade to checking only the head.
git -C "$FIXTURE_ROOT" config --unset "url.$BASE_REMOTE.insteadOf"
git -C "$FIXTURE_ROOT" config "url.$FIXTURE_ROOT/missing.git.insteadOf" https://github.com/SakuraCordApp/SakuraCord.git
expect_hook_failure \
  "refs/heads/feature-merge $(git -C "$FIXTURE_ROOT" rev-parse HEAD) refs/heads/feature-merge $FEATURE_SHA
" "Could not fetch nightly"

echo "Code-quality regression fixture passed."
