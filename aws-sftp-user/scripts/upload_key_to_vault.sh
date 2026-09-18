#!/usr/bin/env bash
# Uploads a private key to Vault's KV store for a given SFTP user.
# Requires: vault CLI, VAULT_ADDR + VAULT_TOKEN (or VAULT_ROLE_ID/SECRET_ID) set in env.
# Usage: ./upload_key_to_vault.sh <user_name> <private_key_path> [vault_path]
set -euo pipefail

USER_NAME="${1:?Usage: $0 <user_name> <private_key_path> [vault_path]}"
PRIVATE_KEY_PATH="${2:?Usage: $0 <user_name> <private_key_path> [vault_path]}"
VAULT_PATH="${3:-secret/sftp/${USER_NAME}}"

if [[ ! -f "$PRIVATE_KEY_PATH" ]]; then
  echo "Private key not found at $PRIVATE_KEY_PATH" >&2
  exit 1
fi

vault kv put "$VAULT_PATH" \
  private_key=@"${PRIVATE_KEY_PATH}" \
  user_name="${USER_NAME}"

echo "Uploaded private key for '${USER_NAME}' to Vault at: ${VAULT_PATH}"
echo "Consider deleting the local private key copy once it's confirmed in Vault:"
echo "  shred -u ${PRIVATE_KEY_PATH}   # or securely remove per your policy"
