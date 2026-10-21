#!/usr/bin/env bash
#
# Tests whether Commander can attach a real local FILE to a record (instead
# of a text field) - if so, the Keeper UI can offer a direct file download
# with the exact original key bytes, no base64/decode step needed at all.
# Tries a few plausible command forms, since the exact syntax isn't
# something I can know in advance.
#
#   export KEEPER_CONFIG=/path/to/your/config.json
#   export KEEPER_FOLDER="Sftp-Keys"
#   bash keeper-attachment-test.sh

set -uo pipefail
: "${KEEPER_CONFIG:?set KEEPER_CONFIG=/path/to/your/config.json}"
: "${KEEPER_FOLDER:?set KEEPER_FOLDER=\"the parent folder you already created\"}"
KEEPER_CLI="${KEEPER_CLI:-keeper}"
TEST_USER="${KEEPER_TEST_USER:-smoketest123}"

banner() { printf '\n========== %s ==========\n' "$1"; }
try() {
  banner "$1"; shift
  printf 'COMMAND: %s\n---\n' "$*"
  "$@" 2>&1
  printf -- '---\n'
}

# A real-shaped (but fake) PEM file, on disk, so Commander reads it as an
# actual file rather than us embedding its content in a command string.
KEYFILE="$(mktemp)"
printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\nFAKE-ATTACHMENT-TEST-KEY-MULTILINE\nANOTHER-LINE-OF-FAKE-DATA\n-----END OPENSSH PRIVATE KEY-----\n' > "$KEYFILE"

banner "SETUP: create the test record (no key field yet - attachment only)"
"$KEEPER_CLI" --config="$KEEPER_CONFIG" \
  "record-add --title \"$TEST_USER\" --record-type login --force --folder \"$KEEPER_FOLDER\" \"login=$TEST_USER\""

try "ATTEMPT 1: help for 'upload-attachment' (read its real usage, if it exists)" \
  "$KEEPER_CLI" --config="$KEEPER_CONFIG" "upload-attachment --help"

try "ATTEMPT 2: upload-attachment --file <path> --record <title>" \
  "$KEEPER_CLI" --config="$KEEPER_CONFIG" "upload-attachment --file \"$KEYFILE\" --record \"$TEST_USER\""

try "ATTEMPT 3: record-add's own --attach option, if it has one" \
  "$KEEPER_CLI" --config="$KEEPER_CONFIG" "record-add --help"

banner "WHAT TO DO NEXT"
cat <<'EOF'
If ATTEMPT 1 printed real usage text (not "unknown command"), that confirms
upload-attachment exists - tell me what its actual options are (or just
that it printed something real) and I'll match the syntax exactly.

If ATTEMPT 2 looks like it succeeded (no error, or a confirmation message),
open the Keeper app/UI, find the 'smoketest123' record in Sftp-Keys, and
check: does it show a file attachment you can download? That visual check
in the UI is the real confirmation - tell me yes or no.

If both attempts clearly failed ("unknown command" or similar), attachments
aren't something this CLI supports non-interactively, and we'll stick with
the base64 field - I'll instead make the manual copy-paste steps as safe
and foolproof as possible.
EOF

banner "CLEANUP"
"$KEEPER_CLI" --config="$KEEPER_CONFIG" "rm -f \"$KEEPER_FOLDER/$TEST_USER\"" 2>&1 \
  || echo "(cleanup via folder/title failed as expected - delete '$TEST_USER' by hand if needed)"
rm -f "$KEYFILE"
