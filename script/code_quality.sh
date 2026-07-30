#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${SAKURACORD_CODE_QUALITY_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}"
TOOLS_DIR="${SAKURACORD_CODE_QUALITY_TOOLS_DIR:-$ROOT_DIR/.build/code-quality-tools}"

SWIFTFORMAT_VERSION="0.62.1"
SWIFTFORMAT_SHA256="7cb1cb1fae04932047c7015441c543848e8e60e1572d808d080e0a1f1661114a"
SWIFTFORMAT_URL="https://github.com/nicklockwood/SwiftFormat/releases/download/$SWIFTFORMAT_VERSION/swiftformat.zip"

SWIFTLINT_VERSION="0.63.2"
SWIFTLINT_SHA256="c59a405c85f95b92ced677a500804e081596a4cae4a6a485af76065557d6ed29"
SWIFTLINT_URL="https://github.com/realm/SwiftLint/releases/download/$SWIFTLINT_VERSION/portable_swiftlint.zip"

SWIFTFORMAT_DIR="$TOOLS_DIR/swiftformat-$SWIFTFORMAT_VERSION"
SWIFTLINT_DIR="$TOOLS_DIR/swiftlint-$SWIFTLINT_VERSION"
SWIFTFORMAT_BIN="$SWIFTFORMAT_DIR/swiftformat"
SWIFTLINT_BIN="$SWIFTLINT_DIR/swiftlint"
SWIFTLINT_BASELINE="$ROOT_DIR/.swiftlint-baseline.json"

usage() {
  cat >&2 <<'EOF'
usage:
  ./script/code_quality.sh check
  ./script/code_quality.sh fix --staged
  ./script/code_quality.sh fix --files <Swift file> [<Swift file> ...]

check runs the complete pinned SwiftFormat and SwiftLint policy without
rewriting files. fix only runs SwiftFormat on the explicitly selected files.
EOF
}

remove_install_temp() {
  if [[ -n "${INSTALL_TEMP_DIR:-}" && -d "$INSTALL_TEMP_DIR" ]]; then
    rm -rf "$INSTALL_TEMP_DIR"
  fi
}

download_tool() {
  local name="$1"
  local version="$2"
  local url="$3"
  local sha256="$4"
  local destination="$5"
  local binary_name="$6"
  local archive

  if [[ -x "$destination/$binary_name" ]]; then
    return
  fi

  mkdir -p "$TOOLS_DIR"
  INSTALL_TEMP_DIR="$(mktemp -d "$TOOLS_DIR/.$name-$version.XXXXXX")"
  archive="$INSTALL_TEMP_DIR/$name.zip"
  trap remove_install_temp EXIT

  echo "Installing pinned $name $version..." >&2
  curl --fail --location --retry 3 --output "$archive" "$url"
  printf '%s  %s\n' "$sha256" "$archive" | shasum -a 256 --check
  ditto -x -k "$archive" "$INSTALL_TEMP_DIR/extracted"

  mkdir -p "$destination"
  ditto "$INSTALL_TEMP_DIR/extracted/$binary_name" "$destination/$binary_name"
  chmod +x "$destination/$binary_name"

  remove_install_temp
  INSTALL_TEMP_DIR=""
  trap - EXIT
}

bootstrap_tools() {
  local actual_version

  download_tool \
    SwiftFormat "$SWIFTFORMAT_VERSION" "$SWIFTFORMAT_URL" \
    "$SWIFTFORMAT_SHA256" "$SWIFTFORMAT_DIR" swiftformat
  download_tool \
    SwiftLint "$SWIFTLINT_VERSION" "$SWIFTLINT_URL" \
    "$SWIFTLINT_SHA256" "$SWIFTLINT_DIR" swiftlint

  actual_version="$("$SWIFTFORMAT_BIN" --version)"
  if [[ "$actual_version" != "$SWIFTFORMAT_VERSION" ]]; then
    echo "Expected SwiftFormat $SWIFTFORMAT_VERSION, found $actual_version at $SWIFTFORMAT_BIN." >&2
    return 1
  fi

  actual_version="$("$SWIFTLINT_BIN" version)"
  if [[ "$actual_version" != "$SWIFTLINT_VERSION" ]]; then
    echo "Expected SwiftLint $SWIFTLINT_VERSION, found $actual_version at $SWIFTLINT_BIN." >&2
    return 1
  fi
}

run_check() {
  local status=0
  local -a source_paths=()

  bootstrap_tools
  if [[ ! -f "$SWIFTLINT_BASELINE" ]]; then
    echo "Missing checked-in SwiftLint baseline: $SWIFTLINT_BASELINE" >&2
    return 1
  fi
  cd "$ROOT_DIR"
  if [[ -d App ]]; then
    source_paths+=(App)
  fi
  if [[ -d Packages ]]; then
    source_paths+=(Packages)
  fi
  if [[ "${#source_paths[@]}" -eq 0 ]]; then
    echo "No App or Packages source directory exists under $ROOT_DIR." >&2
    return 1
  fi

  echo "SwiftFormat $SWIFTFORMAT_VERSION (lint mode)"
  if ! "$SWIFTFORMAT_BIN" "${source_paths[@]}" \
    --config "$ROOT_DIR/.swiftformat" \
    --cache ignore \
    --lint; then
    status=1
  fi

  echo "SwiftLint $SWIFTLINT_VERSION (strict, no cache)"
  if ! "$SWIFTLINT_BIN" lint \
    --strict \
    --no-cache \
    --quiet \
    --config "$ROOT_DIR/.swiftlint.yml" \
    --baseline "$SWIFTLINT_BASELINE"; then
    status=1
  fi

  if [[ "$status" -ne 0 ]]; then
    echo >&2
    echo "Code-quality checks failed. Fix selected formatting safely with:" >&2
    echo "  ./script/code_quality.sh fix --staged" >&2
    echo "  ./script/code_quality.sh fix --files <Swift file> [...]" >&2
    return "$status"
  fi

  echo "Code-quality checks passed."
}

validate_fix_path() {
  local path="$1"

  if [[ "$path" = /* || "$path" == ".." || "$path" == ../* || "$path" == */../* ]]; then
    echo "Fix paths must be repository-relative and may not contain '..': $path" >&2
    return 1
  fi
  if [[ "$path" != *.swift || ( "$path" != App/* && "$path" != Packages/* ) ]]; then
    echo "Fix paths must be Swift files under App or Packages: $path" >&2
    return 1
  fi
  if ! git -C "$ROOT_DIR" ls-files --error-unmatch -- "$path" >/dev/null 2>&1; then
    echo "Fix paths must already be tracked by Git: $path" >&2
    return 1
  fi
  if [[ ! -f "$ROOT_DIR/$path" ]]; then
    echo "Fix path does not exist in the working tree: $path" >&2
    return 1
  fi
}

run_fix() {
  local selection="${1:-}"
  local path
  local -a paths=()

  case "$selection" in
    --staged)
      if [[ "$#" -ne 1 ]]; then
        usage
        return 2
      fi
      while IFS= read -r -d '' path; do
        paths+=("$path")
      done < <(
        git -C "$ROOT_DIR" diff \
          --cached \
          --name-only \
          --diff-filter=ACMR \
          -z \
          -- '*.swift'
      )
      if [[ "${#paths[@]}" -eq 0 ]]; then
        echo "No staged Swift files need formatting."
        return
      fi
      for path in "${paths[@]}"; do
        validate_fix_path "$path"
        if ! git -C "$ROOT_DIR" diff --quiet -- "$path"; then
          echo "Refusing to format staged file with additional unstaged edits: $path" >&2
          echo "Stage or preserve those edits, or use --files to select the working file explicitly." >&2
          return 1
        fi
      done
      ;;
    --files)
      shift
      if [[ "$#" -eq 0 ]]; then
        usage
        return 2
      fi
      paths=("$@")
      for path in "${paths[@]}"; do
        validate_fix_path "$path"
      done
      ;;
    *)
      usage
      return 2
      ;;
  esac

  bootstrap_tools
  cd "$ROOT_DIR"
  "$SWIFTFORMAT_BIN" "${paths[@]}" \
    --config "$ROOT_DIR/.swiftformat" \
    --cache ignore

  if [[ "$selection" == "--staged" ]]; then
    git add -- "${paths[@]}"
    echo "Formatted and re-staged ${#paths[@]} selected Swift file(s)."
  else
    echo "Formatted ${#paths[@]} explicitly selected Swift file(s)."
  fi
}

case "${1:-}" in
  check)
    if [[ "$#" -ne 1 ]]; then
      usage
      exit 2
    fi
    run_check
    ;;
  fix)
    shift
    run_fix "$@"
    ;;
  *)
    usage
    exit 2
    ;;
esac
