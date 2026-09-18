#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="${MARROWCHAT_ROOT_DIR:-$(cd "$SCRIPT_DIR/.." && pwd -P)}"
# shellcheck source=runtime.sh
source "$SCRIPT_DIR/runtime.sh"
# shellcheck source=debug_credentials_config.sh
source "$SCRIPT_DIR/debug_credentials_config.sh"
DEBUG_CREDENTIAL_DIRECTORY="$HOME/Library/Containers/$MARROWCHAT_BUNDLE_ID/Data/Library/Application Support/MarrowChat/InsecureDebugCredentials"

usage() {
  echo "usage: $0 [enable|disable|status|delete]" >&2
}

case "${1:-status}" in
  enable)
    marrowchat_set_persistent_debug_credentials "$ROOT_DIR" true
    echo "Persistent insecure debug credentials: enabled"
    ;;
  disable)
    marrowchat_set_persistent_debug_credentials "$ROOT_DIR" false
    echo "Persistent insecure debug credentials: disabled"
    ;;
  status)
    marrowchat_resolve_insecure_debug_credentials "$ROOT_DIR"
    if [[ "$MARROWCHAT_RESOLVED_INSECURE_DEBUG_CREDENTIALS" == "1" ]]; then
      state="enabled"
    else
      state="disabled"
    fi
    echo "Persistent insecure debug credentials: $state ($MARROWCHAT_INSECURE_DEBUG_CREDENTIALS_SOURCE)"
    ;;
  delete)
    if marrowchat_is_scoped_app_running; then
      echo "Quit MarrowChat before deleting its insecure debug credentials." >&2
      exit 2
    fi
    marrowchat_set_persistent_debug_credentials "$ROOT_DIR" false
    marrowchat_delete_insecure_debug_credentials "$DEBUG_CREDENTIAL_DIRECTORY"
    echo "Persistent insecure debug credentials: disabled"
    echo "Deleted $MARROWCHAT_DELETED_DEBUG_CREDENTIAL_COUNT insecure debug credential file(s)."
    echo "Keychain credentials were not changed."
    if [[ -d "$DEBUG_CREDENTIAL_DIRECTORY" ]]; then
      echo "Preserved unexpected entries in: $DEBUG_CREDENTIAL_DIRECTORY"
    fi
    ;;
  *)
    usage
    exit 2
    ;;
esac
