#!/usr/bin/env bash
#
# Step A: create one throwaway record (same as before), then try several
# different ways of asking Commander to show its UID. Doesn't delete
# anything - that's step B (keeper-verify-by-uid.sh), once you tell me
# which of these actually printed a UID.
#
#   export KEEPER_CONFIG=/path/to/your/config.json
#   export KEEPER_FOLDER="Sftp-Keys"
#   bash keeper-find-uid.sh

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

# ---- make sure the test record exists (record-add is idempotent with --force) ----
fake_priv_b64="$(printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\nFAKE-UID-TEST-KEY\n-----END OPENSSH PRIVATE KEY-----\n' | base64 | tr -d '\n')"
fake_pub_b64="$(printf 'ssh-rsa AAAAFAKE smoketest@sftp\n' | base64 | tr -d '\n')"
cmd="record-add --title \"$TEST_USER\" --record-type login --force --folder \"$KEEPER_FOLDER\""
cmd="$cmd \"login=$TEST_USER\" \"c.text.public_key_b64=$fake_pub_b64\" \"c.secret.private_key_b64=$fake_priv_b64\""
show "SETUP: (re)create the test record" "$KEEPER_CLI" --config="$KEEPER_CONFIG" "$cmd"

# ---- try every plausible way to surface its UID ----
show "ATTEMPT 1: search \"$TEST_USER\"" \
  "$KEEPER_CLI" --config="$KEEPER_CONFIG" "search \"$TEST_USER\""

show "ATTEMPT 2: ls -l \"$KEEPER_FOLDER\"  (long format)" \
  "$KEEPER_CLI" --config="$KEEPER_CONFIG" "ls -l \"$KEEPER_FOLDER\""

show "ATTEMPT 3: ls -v \"$KEEPER_FOLDER\"  (verbose)" \
  "$KEEPER_CLI" --config="$KEEPER_CONFIG" "ls -v \"$KEEPER_FOLDER\""

show "ATTEMPT 4: get \"$TEST_USER\"  (bare title, no folder path at all)" \
  "$KEEPER_CLI" --config="$KEEPER_CONFIG" "get \"$TEST_USER\""

show "ATTEMPT 5: get \"$TEST_USER\" --format=json  (bare title, json)" \
  "$KEEPER_CLI" --config="$KEEPER_CONFIG" "get \"$TEST_USER\" --format=json"

show "ATTEMPT 6: list --format=json \"$KEEPER_FOLDER\"" \
  "$KEEPER_CLI" --config="$KEEPER_CONFIG" "list --format=json \"$KEEPER_FOLDER\""

banner "WHAT TO DO NEXT"
cat <<'EOF'
Look through the six attempts above for anything that looks like a record
UID next to the title "smoketest123" - it's usually a ~22-character string
of letters/digits/-/_ (Keeper's UIDs look like this: 9vVajHFwSjt71gO2C48zJA).

- If ATTEMPT 4 or 5 (bare title, no folder) just worked and showed the
  record's fields directly - that's the simplest possible fix, tell me and
  we can skip UIDs entirely.
- Otherwise, copy the UID you found and run:
    KEEPER_TEST_UID=<the uid> bash keeper-verify-by-uid.sh
EOF
