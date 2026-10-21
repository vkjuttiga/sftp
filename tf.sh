#!/usr/bin/env bash
# tf-login.sh - Log in to an AWS Transfer Family user with the private key stored in Keeper.
# Repairs the key format on the fly (flattened lines, \n text, CRLF, quotes),
# keeps it only in memory, and deletes it when the session ends.
#
# Usage: TF_HOST=s-XXXXXXXX.server.transfer.<region>.amazonaws.com ./tf-login.sh <username>
# Optional: RECORD=<record title or UID> (default: the username)
#           B64_LABEL=<field holding the base64-encoded key> (default: private_key_b64)
#           KEEPER_VENV=<path to the Commander virtualenv> (default: ~/keeper-venv)
#           KEEPER_USER=<Keeper login email> (used only if a login is needed)
#           KEEPER_FOLDER=<Keeper folder name or UID holding the records> (default: Sftp-Keys)
#           KEEPER_CONFIG=<Commander config.json with your saved session> (default: ~/.keeper/config.json)

set -uo pipefail

USER_NAME="${1:?Usage: $0 <username>}"
TF_HOST="${TF_HOST:?Set TF_HOST to the Transfer Family endpoint}"
RECORD="${RECORD:-$USER_NAME}"
B64_LABEL="${B64_LABEL:-private_key_b64}"
KEEPER_VENV="${KEEPER_VENV:-$HOME/keeper-venv}"
KEEPER_FOLDER="${KEEPER_FOLDER:-Sftp-Keys}"
KEEPER_CONFIG="${KEEPER_CONFIG:-$HOME/.keeper/config.json}"

echo ">> Preparing Keeper Commander"
if ! command -v keeper >/dev/null 2>&1; then
  if [ -f "$KEEPER_VENV/bin/activate" ]; then
    echo ">> Activating Commander virtualenv: $KEEPER_VENV"
    # shellcheck disable=SC1091
    source "$KEEPER_VENV/bin/activate"
  fi
fi
command -v keeper >/dev/null 2>&1 || { echo "!! 'keeper' not found. Set KEEPER_VENV to your Commander virtualenv"; exit 1; }

# Use the existing config.json so Commander reuses the saved (persistent) session
KEEPER=(keeper)
if [ -f "$KEEPER_CONFIG" ]; then
  echo ">> Using Keeper config: $KEEPER_CONFIG"
  KEEPER+=(--config "$KEEPER_CONFIG")
else
  echo ">> Keeper config not found at $KEEPER_CONFIG - using Commander's default"
fi

echo ">> Checking Keeper session"
if ! timeout 60 "${KEEPER[@]}" whoami </dev/null >/dev/null 2>&1; then
  echo ">> No active Keeper session - logging in (enter password / 2FA when prompted)"
  if [ -n "${KEEPER_USER:-}" ]; then "${KEEPER[@]}" login "$KEEPER_USER"; else "${KEEPER[@]}" login; fi \
    || { echo "!! Keeper login failed"; exit 1; }
  echo ">> Tip: run 'keeper this-device persistent-login on' once to skip this next time"
fi
echo ">> Keeper session OK"

# Memory-backed temp location (falls back to /tmp where /dev/shm is not available)
TMP_DIR=/dev/shm; [ -d "$TMP_DIR" ] || TMP_DIR=/tmp
KEY=$(mktemp -p "$TMP_DIR" "${USER_NAME}.XXXXXX")
chmod 600 "$KEY"
cleanup() { shred -u "$KEY" "$KEY.raw" "$KEY.pub" 2>/dev/null || rm -f "$KEY" "$KEY.raw" "$KEY.pub"; }
trap cleanup EXIT

REFS=("$RECORD" "$KEEPER_FOLDER/$RECORD")
echo ">> Looking up record UID for '$RECORD' in folder '$KEEPER_FOLDER'"
UID_FOUND=$(timeout 60 "${KEEPER[@]}" ls -l "$KEEPER_FOLDER" </dev/null 2>/dev/null \
  | awk -v t="$RECORD" '{ hit = 0; for (i = 1; i <= NF; i++) if ($i == t) hit = 1
      if (hit) for (i = 1; i <= NF; i++) if ($i ~ /^[A-Za-z0-9_-]{22}$/) { print $i; exit } }' || true)
if [ -n "$UID_FOUND" ]; then
  echo ">> Found record UID: $UID_FOUND"
  REFS=("$UID_FOUND" "${REFS[@]}")
fi

JSON=""
for ref in "${REFS[@]}"; do
  echo ">> Fetching Keeper record '$ref'"
  JSON=$(timeout 60 "${KEEPER[@]}" get "$ref" --format json </dev/null 2>/dev/null || true)
  if [ -n "$JSON" ] && echo "$JSON" | jq -e . >/dev/null 2>&1; then break; fi
  JSON=""
done
if [ -z "$JSON" ]; then
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
