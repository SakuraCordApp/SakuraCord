#!/usr/bin/env bash

marrowchat_release_version() {
  local root_dir="$1"
  local version="${MARROWCHAT_VERSION:-}"
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
    echo "MARROWCHAT_VERSION or the latest release tag must use MAJOR.MINOR.PATCH." >&2
    return 2
  fi

  printf '%s\n' "$version"
}

marrowchat_is_release_tag() {
  local tag="$1"
  [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-Beta-[0-9]+)?$ ]]
}

marrowchat_is_nightly_release_tag() {
  local tag="$1"
  [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+-Beta-[0-9]+$ ]]
}

marrowchat_release_version_from_tag() {
  local tag="$1"
  local version

  if ! marrowchat_is_release_tag "$tag"; then
    echo "Release tags must use vMAJOR.MINOR.PATCH or vMAJOR.MINOR.PATCH-Beta-NUMBER." >&2
    return 2
  fi

  version="${tag#v}"
  printf '%s\n' "${version%%-Beta-*}"
}

marrowchat_release_track_from_tag() {
  local tag="$1"

  if ! marrowchat_is_release_tag "$tag"; then
    echo "Release tags must use vMAJOR.MINOR.PATCH or vMAJOR.MINOR.PATCH-Beta-NUMBER." >&2
    return 2
  fi
  if marrowchat_is_nightly_release_tag "$tag"; then
    printf 'nightly\n'
  else
    printf 'regular\n'
  fi
}

marrowchat_release_asset_version_from_tag() {
  local tag="$1"
  local beta_number
  local version

  if ! marrowchat_is_release_tag "$tag"; then
    echo "Release tags must use vMAJOR.MINOR.PATCH or vMAJOR.MINOR.PATCH-Beta-NUMBER." >&2
    return 2
  fi
  if marrowchat_is_nightly_release_tag "$tag"; then
    version="$(marrowchat_release_version_from_tag "$tag")"
    beta_number="${tag##*-}"
    printf '%s-Beta-%s\n' "$version" "$beta_number"
  else
    printf '%s\n' "${tag#v}"
  fi
}

marrowchat_release_display_name_from_tag() {
  local tag="$1"
  local beta_number
  local version

  if ! marrowchat_is_release_tag "$tag"; then
    echo "Release tags must use vMAJOR.MINOR.PATCH or vMAJOR.MINOR.PATCH-Beta-NUMBER." >&2
    return 2
  fi
  if marrowchat_is_nightly_release_tag "$tag"; then
    version="$(marrowchat_release_version_from_tag "$tag")"
    beta_number="${tag##*-}"
    printf 'v%s Beta %s\n' "$version" "$beta_number"
  else
    printf '%s\n' "$tag"
  fi
}

marrowchat_release_dmg_name() {
  local version="$1"

  if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "A MAJOR.MINOR.PATCH release version is required for the DMG name." >&2
    return 2
  fi

  printf 'MarrowChat.v%s.dmg\n' "$version"
}

marrowchat_release_dmg_url_name() {
  local version="$1"
  marrowchat_release_dmg_name "$version"
}

marrowchat_release_dmg_name_from_tag() {
  local tag="$1"
  local asset_version

  asset_version="$(marrowchat_release_asset_version_from_tag "$tag")"
  if marrowchat_is_nightly_release_tag "$tag"; then
    printf 'MarrowChat-v%s.dmg\n' "$asset_version"
  else
    printf 'MarrowChat.v%s.dmg\n' "$asset_version"
  fi
}
