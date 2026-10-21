#!/usr/bin/env bash
# tf-login.sh - Log in to an AWS Transfer Family user with the private key stored in Keeper.
# Repairs the key format on the fly (flattened lines, \n text, CRLF, quotes),
# keeps it only in memory, and deletes it when the session ends.
#
# Usage: TF_HOST=s-XXXXXXXX.server.transfer.<region>.amazonaws.com ./tf-login.sh <username>
# Optional: RECORD=<record title or UID> (default: the username)
#           B64_LABEL=<field holding the base64-encoded key> (default: private_key_b64)

set -uo pipefail

USER_NAME="${1:?Usage: $0 <username>}"
TF_HOST="${TF_HOST:?Set TF_HOST to the Transfer Family endpoint}"
RECORD="${RECORD:-$USER_NAME}"
B64_LABEL="${B64_LABEL:-private_key_b64}"

# Memory-backed temp location (falls back to /tmp where /dev/shm is not available)
TMP_DIR=/dev/shm; [ -d "$TMP_DIR" ] || TMP_DIR=/tmp
KEY=$(mktemp -p "$TMP_DIR" "${USER_NAME}.XXXXXX")
chmod 600 "$KEY"
cleanup() { shred -u "$KEY" "$KEY.raw" "$KEY.pub" 2>/dev/null || rm -f "$KEY" "$KEY.raw" "$KEY.pub"; }
trap cleanup EXIT

echo ">> Fetching Keeper record '$RECORD'"
JSON=$(keeper get "$RECORD" --format json 2>/dev/null || true)
if [ -z "$JSON" ] || ! echo "$JSON" | jq -e . >/dev/null 2>&1; then
  echo "!! Keeper record '$RECORD' not found. Find its UID with: keeper search $USER_NAME"
  echo "   then rerun with: RECORD=<record_uid> $0 $USER_NAME"; exit 1
fi

echo ">> Extracting private key from field '$B64_LABEL' (base64-encoded)"
B64=$(echo "$JSON" | jq -r --arg l "$B64_LABEL" \
  '[(.fields[]?, .custom[]?) | select(.label == $l) | .value[0]][0] // empty')
if [ -n "$B64" ]; then
  echo ">> Decoding base64"
  if ! echo "$B64" | tr -d ' \r\n"' | base64 -d > "$KEY.raw" 2>/dev/null; then
    echo "!! Field '$B64_LABEL' is not valid base64"; exit 1
  fi
else
  echo ">> Field '$B64_LABEL' not found - searching all fields for a plain-text key"
  # Finds the first value anywhere in the record that contains "PRIVATE KEY".
  echo "$JSON" | jq -r '[.. | strings | select(test("PRIVATE KEY"))][0] // empty' > "$KEY.raw"
fi

if [ ! -s "$KEY.raw" ] || ! grep -q "PRIVATE KEY" "$KEY.raw"; then
  echo "!! No private key found in record '$RECORD'"; exit 1
fi

echo ">> Repairing key format"
TYPE=$(grep -oE 'BEGIN [A-Z ]*PRIVATE KEY' "$KEY.raw" | head -1 | sed 's/^BEGIN //' || true)
[ -z "$TYPE" ] && TYPE="OPENSSH PRIVATE KEY"
WIDTH=70; [ "$TYPE" = "RSA PRIVATE KEY" ] && WIDTH=64
BODY=$(sed 's/\\n/ /g' "$KEY.raw" | tr -d '\r"' \
  | sed -e "s/-----BEGIN $TYPE-----//" -e "s/-----END $TYPE-----//" | tr -d ' \t\n')
{ echo "-----BEGIN $TYPE-----"; echo "$BODY" | fold -w "$WIDTH"; echo "-----END $TYPE-----"; } > "$KEY"

echo ">> Validating key"
if ! ssh-keygen -y -f "$KEY" > "$KEY.pub" 2>/dev/null; then
  echo "!! Key is still invalid after repair - the stored key data is incomplete or wrong"; exit 1
fi
echo ">> Key fingerprint: $(ssh-keygen -lf "$KEY.pub")"

echo ">> Connecting to $USER_NAME@$TF_HOST"
sftp -o IdentitiesOnly=yes -i "$KEY" "$USER_NAME@$TF_HOST"
