#!/usr/bin/env bash

MARROWCHAT_INSECURE_DEBUG_CREDENTIALS_CONFIG_KEY="marrowchat.insecureDebugCredentials"

marrowchat_read_persistent_debug_credentials() {
  local root_dir="$1"
  local configured_value
  local status

  MARROWCHAT_PERSISTENT_DEBUG_CREDENTIALS_IS_SET=0
  MARROWCHAT_PERSISTENT_DEBUG_CREDENTIALS=0

  if ! git -C "$root_dir" rev-parse --git-dir >/dev/null 2>&1; then
    return 0
  fi

  if configured_value="$(
    git -C "$root_dir" config --local --type=bool \
      --get "$MARROWCHAT_INSECURE_DEBUG_CREDENTIALS_CONFIG_KEY" 2>/dev/null
  )"; then
    MARROWCHAT_PERSISTENT_DEBUG_CREDENTIALS_IS_SET=1
    case "$configured_value" in
      true) MARROWCHAT_PERSISTENT_DEBUG_CREDENTIALS=1 ;;
      false) MARROWCHAT_PERSISTENT_DEBUG_CREDENTIALS=0 ;;
      *)
        echo "Unexpected Git boolean for $MARROWCHAT_INSECURE_DEBUG_CREDENTIALS_CONFIG_KEY." >&2
        return 2
        ;;
    esac
    return 0
  else
    status=$?
  fi

  if [[ "$status" -eq 1 ]]; then
    return 0
  fi

  echo "Git config $MARROWCHAT_INSECURE_DEBUG_CREDENTIALS_CONFIG_KEY must be a boolean." >&2
  return 2
}

marrowchat_resolve_insecure_debug_credentials() {
  local root_dir="$1"

  MARROWCHAT_RESOLVED_INSECURE_DEBUG_CREDENTIALS=0
  MARROWCHAT_INSECURE_DEBUG_CREDENTIALS_SOURCE="default"

  if [[ "${MARROWCHAT_INSECURE_DEBUG_CREDENTIALS+x}" == "x" ]]; then
    case "$MARROWCHAT_INSECURE_DEBUG_CREDENTIALS" in
      0|1)
        MARROWCHAT_RESOLVED_INSECURE_DEBUG_CREDENTIALS="$MARROWCHAT_INSECURE_DEBUG_CREDENTIALS"
        MARROWCHAT_INSECURE_DEBUG_CREDENTIALS_SOURCE="environment"
        return 0
        ;;
      *)
        echo "MARROWCHAT_INSECURE_DEBUG_CREDENTIALS must be 0 or 1." >&2
        return 2
        ;;
    esac
  fi

  marrowchat_read_persistent_debug_credentials "$root_dir" || return $?
  if [[ "$MARROWCHAT_PERSISTENT_DEBUG_CREDENTIALS_IS_SET" == "1" ]]; then
    MARROWCHAT_RESOLVED_INSECURE_DEBUG_CREDENTIALS="$MARROWCHAT_PERSISTENT_DEBUG_CREDENTIALS"
    MARROWCHAT_INSECURE_DEBUG_CREDENTIALS_SOURCE="repository config"
  fi
}

marrowchat_apply_secure_release_credential_policy() {
  local mode="$1"
  local updates_enabled="$2"

  if [[ "$mode" != "package-release" && "$mode" != "run-release" \
    && "$updates_enabled" != "1" ]]; then
    return 0
  fi

  if [[ "$MARROWCHAT_RESOLVED_INSECURE_DEBUG_CREDENTIALS" == "1" \
    && "$MARROWCHAT_INSECURE_DEBUG_CREDENTIALS_SOURCE" == "environment" ]]; then
    echo "Insecure debug credentials cannot be used for release or update-enabled packages." >&2
    return 2
  fi

  MARROWCHAT_RESOLVED_INSECURE_DEBUG_CREDENTIALS=0
  MARROWCHAT_INSECURE_DEBUG_CREDENTIALS_SOURCE="release safety override"
}

marrowchat_set_persistent_debug_credentials() {
  local root_dir="$1"
  local value="$2"

  if ! git -C "$root_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "Persistent debug credentials require a Git checkout: $root_dir" >&2
    return 2
  fi

  git -C "$root_dir" config --local \
    "$MARROWCHAT_INSECURE_DEBUG_CREDENTIALS_CONFIG_KEY" "$value"
}

marrowchat_delete_insecure_debug_credentials() {
  local directory="$1"
  local candidate
  local filename

  MARROWCHAT_DELETED_DEBUG_CREDENTIAL_COUNT=0

  if [[ ! -e "$directory" && ! -L "$directory" ]]; then
    return 0
  fi
  if [[ -L "$directory" || ! -d "$directory" ]]; then
    echo "Refusing to delete unexpected debug credential path: $directory" >&2
    return 2
  fi

  while IFS= read -r -d '' candidate; do
    filename="${candidate##*/}"
    if [[ -f "$candidate" && ! -L "$candidate" \
      && "$filename" =~ ^[0-9]+\.credential$ ]]; then
      rm -f -- "$candidate"
      MARROWCHAT_DELETED_DEBUG_CREDENTIAL_COUNT=$((
        MARROWCHAT_DELETED_DEBUG_CREDENTIAL_COUNT + 1
      ))
    fi
  done < <(find "$directory" -mindepth 1 -maxdepth 1 -print0)

  rmdir "$directory" 2>/dev/null || true
}
