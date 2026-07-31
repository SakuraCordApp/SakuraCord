#!/usr/bin/env bash

sakuracord_release_version() {
  local root_dir="$1"
  local version="${SAKURACORD_VERSION:-}"
  local release_tag

  if [[ -z "$version" ]]; then
    release_tag="$(
      git -C "$root_dir" describe \
        --tags \
        --abbrev=0 \
        --match 'v[0-9]*.[0-9]*.[0-9]*' \
        2>/dev/null || true
    )"
    version="${release_tag#v}"
  fi

  if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "SAKURACORD_VERSION or the latest release tag must use MAJOR.MINOR.PATCH." >&2
    return 2
  fi

  printf '%s\n' "$version"
}

sakuracord_release_dmg_name() {
  local version="$1"

  if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "A MAJOR.MINOR.PATCH release version is required for the DMG name." >&2
    return 2
  fi

  printf 'SakuraCord.v%s.dmg\n' "$version"
}

sakuracord_release_dmg_url_name() {
  local version="$1"
  sakuracord_release_dmg_name "$version"
}
