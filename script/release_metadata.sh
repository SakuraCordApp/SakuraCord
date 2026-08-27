#!/usr/bin/env bash

sakuracord_latest_release_tag() {
  local root_dir="$1"
  local release_tag

  release_tag="$(
    git -C "$root_dir" describe \
      --tags \
      --abbrev=0 \
      --match 'v[0-9]*.[0-9]*.[0-9]*' \
      2>/dev/null || true
  )"
  if [[ -n "$release_tag" ]] && ! sakuracord_is_release_tag "$release_tag"; then
    echo "The latest release tag must use vMAJOR.MINOR.PATCH or vMAJOR.MINOR.PATCH-Beta-NUMBER." >&2
    return 2
  fi

  printf '%s\n' "$release_tag"
}

sakuracord_release_version() {
  local root_dir="$1"
  local version="${SAKURACORD_VERSION:-}"
  local release_tag

  if [[ -z "$version" ]]; then
    release_tag="$(sakuracord_latest_release_tag "$root_dir")" || return
    if [[ -n "$release_tag" ]]; then
      version="$(sakuracord_release_version_from_tag "$release_tag")" || return
    fi
  fi

  if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "SAKURACORD_VERSION or the latest release tag must use MAJOR.MINOR.PATCH." >&2
    return 2
  fi

  printf '%s\n' "$version"
}

sakuracord_bundle_display_version() {
  local root_dir="$1"
  local bundle_version="$2"
  local release_tag="${SAKURACORD_RELEASE_TAG:-}"

  if [[ -z "$release_tag" && -z "${SAKURACORD_VERSION:-}" ]]; then
    release_tag="$(sakuracord_latest_release_tag "$root_dir")" || return
  fi
  if [[ -n "$release_tag" ]]; then
    sakuracord_release_appcast_display_version_from_tag "$release_tag"
  else
    printf '%s\n' "$bundle_version"
  fi
}

sakuracord_is_release_tag() {
  local tag="$1"
  [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-Beta-[0-9]+)?$ ]]
}

sakuracord_is_nightly_release_tag() {
  local tag="$1"
  [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+-Beta-[0-9]+$ ]]
}

sakuracord_release_version_from_tag() {
  local tag="$1"
  local version

  if ! sakuracord_is_release_tag "$tag"; then
    echo "Release tags must use vMAJOR.MINOR.PATCH or vMAJOR.MINOR.PATCH-Beta-NUMBER." >&2
    return 2
  fi

  version="${tag#v}"
  printf '%s\n' "${version%%-Beta-*}"
}

sakuracord_release_track_from_tag() {
  local tag="$1"

  if ! sakuracord_is_release_tag "$tag"; then
    echo "Release tags must use vMAJOR.MINOR.PATCH or vMAJOR.MINOR.PATCH-Beta-NUMBER." >&2
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
  local beta_number
  local version

  if ! sakuracord_is_release_tag "$tag"; then
    echo "Release tags must use vMAJOR.MINOR.PATCH or vMAJOR.MINOR.PATCH-Beta-NUMBER." >&2
    return 2
  fi
  if sakuracord_is_nightly_release_tag "$tag"; then
    version="$(sakuracord_release_version_from_tag "$tag")"
    beta_number="${tag##*-}"
    printf '%s-Beta-%s\n' "$version" "$beta_number"
  else
    printf '%s\n' "${tag#v}"
  fi
}

sakuracord_release_display_name_from_tag() {
  local tag="$1"
  local beta_number
  local version

  if ! sakuracord_is_release_tag "$tag"; then
    echo "Release tags must use vMAJOR.MINOR.PATCH or vMAJOR.MINOR.PATCH-Beta-NUMBER." >&2
    return 2
  fi
  if sakuracord_is_nightly_release_tag "$tag"; then
    version="$(sakuracord_release_version_from_tag "$tag")"
    beta_number="${tag##*-}"
    printf 'v%s Beta %s\n' "$version" "$beta_number"
  else
    printf '%s\n' "$tag"
  fi
}

sakuracord_release_appcast_display_version_from_tag() {
  local tag="$1"
  local display_name

  display_name="$(sakuracord_release_display_name_from_tag "$tag")" || return
  printf '%s\n' "${display_name#v}"
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
  if sakuracord_is_nightly_release_tag "$tag"; then
    printf 'SakuraCord-v%s.dmg\n' "$asset_version"
  else
    printf 'SakuraCord.v%s.dmg\n' "$asset_version"
  fi
}
