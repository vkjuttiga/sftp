#!/usr/bin/env bash
# Generates an ed25519 keypair for a Transfer Family SFTP user.
# Usage: ./generate_ssh_key.sh <user_name> [output_dir]
set -euo pipefail

USER_NAME="${1:?Usage: $0 <user_name> [output_dir]}"
OUT_DIR="${2:-../keys}"

mkdir -p "$OUT_DIR"
KEY_PATH="${OUT_DIR}/${USER_NAME}_id_ed25519"

if [[ -f "$KEY_PATH" ]]; then
  echo "Key already exists at $KEY_PATH — refusing to overwrite." >&2
  exit 1
fi

ssh-keygen -t ed25519 -f "$KEY_PATH" -N "" -C "${USER_NAME}@aws-transfer-family"
chmod 600 "$KEY_PATH"
chmod 644 "${KEY_PATH}.pub"

echo "Private key: $KEY_PATH"
echo "Public key:  ${KEY_PATH}.pub"
echo "Next: upload the private key to Vault, and point terraform.tfvars"
echo "      public_key_path at ${KEY_PATH}.pub"
