#!/usr/bin/env bash
#
# ls -v showed no UID at all on this Commander version (same as plain ls).
# This tries several other ways to get a UID for one specific record,
# printing raw output for each so we can see, for real, which one - if
# any - actually shows it. No guessing this time.
#
#   export KEEPER_CONFIG=/path/to/your/config.json
#   export KEEPER_FOLDER="Sftp-Keys"
#   bash keeper-find-uid-v2.sh

set -uo pipefail
: "${KEEPER_CONFIG:?set KEEPER_CONFIG=/path/to/your/config.json}"
: "${KEEPER_FOLDER:?set KEEPER_FOLDER=\"the parent folder you already created\"}"
KEEPER_CLI="${KEEPER_CLI:-keeper}"
TEST_USER="${KEEPER_TEST_USER:-smoketest123}"

banner() { printf '\n========== %s ==========\n' "$1"; }
show() {
  banner "$1"; shift
  printf 'COMMAND: %s\n---\n' "$*"
  "$@" 2>&1
  printf -- '---\n'
}

banner "SETUP: (re)create the test record"
fake_priv_b64="$(printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\nFAKE\n-----END OPENSSH PRIVATE KEY-----\n' | base64 | tr -d '\n')"
cmd="record-add --title \"$TEST_USER\" --record-type login --force --folder \"$KEEPER_FOLDER\""
cmd="$cmd \"login=$TEST_USER\" \"c.secret.private_key_b64=$fake_priv_b64\""
"$KEEPER_CLI" --config="$KEEPER_CONFIG" "$cmd"

show "ATTEMPT 1: search \"$TEST_USER\"" \
  "$KEEPER_CLI" --config="$KEEPER_CONFIG" "search \"$TEST_USER\""

show "ATTEMPT 2: list --format=json \"$TEST_USER\"  (title as the search pattern this time, not the folder)" \
  "$KEEPER_CLI" --config="$KEEPER_CONFIG" "list --format=json \"$TEST_USER\""

show "ATTEMPT 3: get \"$TEST_USER\"  (bare title, no folder, no format)" \
  "$KEEPER_CLI" --config="$KEEPER_CONFIG" "get \"$TEST_USER\""

show "ATTEMPT 4: get \"$TEST_USER\" --format=json  (bare title, json)" \
  "$KEEPER_CLI" --config="$KEEPER_CONFIG" "get \"$TEST_USER\" --format=json"

banner "WHAT TO DO NEXT"
cat <<'EOF'
Paste all four blocks above, even the ones that error - the error text
itself is useful. A Keeper UID looks like a ~22-character string of
letters, digits, - and _ (e.g. 9vVajHFwSjt71gO2C48zJA). Whichever attempt
shows one clearly, tell me which number it was.
EOF

banner "CLEANUP"
"$KEEPER_CLI" --config="$KEEPER_CONFIG" "rm -f \"$KEEPER_FOLDER/$TEST_USER\"" 2>&1 \
  || echo "(cleanup via folder/title failed as expected - delete '$TEST_USER' by hand if needed once you have a UID)"
