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

sakuracord_is_release_tag() {
  local tag="$1"
  [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-nightly\.[0-9]+)?$ ]]
}

sakuracord_is_nightly_release_tag() {
  local tag="$1"
  [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+-nightly\.[0-9]+$ ]]
}

sakuracord_release_version_from_tag() {
  local tag="$1"
  local version

  if ! sakuracord_is_release_tag "$tag"; then
    echo "Release tags must use vMAJOR.MINOR.PATCH or vMAJOR.MINOR.PATCH-nightly.NUMBER." >&2
    return 2
  fi

  version="${tag#v}"
  printf '%s\n' "${version%%-nightly.*}"
}

sakuracord_release_track_from_tag() {
  local tag="$1"

  if ! sakuracord_is_release_tag "$tag"; then
    echo "Release tags must use vMAJOR.MINOR.PATCH or vMAJOR.MINOR.PATCH-nightly.NUMBER." >&2
    return 2
  fi
  if sakuracord_is_nightly_release_tag "$tag"; then
    printf 'nightly\n'
  else
    printf 'regular\n'
  fi
}

sakuracord_release_asset_version_from_tag() {
  local tag="$1"

  if ! sakuracord_is_release_tag "$tag"; then
    echo "Release tags must use vMAJOR.MINOR.PATCH or vMAJOR.MINOR.PATCH-nightly.NUMBER." >&2
    return 2
  fi
  printf '%s\n' "${tag#v}"
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

sakuracord_release_dmg_name_from_tag() {
  local tag="$1"
  local asset_version

  asset_version="$(sakuracord_release_asset_version_from_tag "$tag")"
  printf 'SakuraCord.v%s.dmg\n' "$asset_version"
}
