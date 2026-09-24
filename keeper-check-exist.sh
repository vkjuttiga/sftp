#!/usr/bin/env bash
#
# Tests the "does a record for this user already exist in Keeper" check
# that provision-user.sh now relies on - lists KEEPER_FOLDER, searches the
# whole JSON document for a title match, no assumption about the exact
# shape in advance. Creates one throwaway record if it doesn't already
# exist, confirms the check finds it, then cleans up.
#
#   export KEEPER_CONFIG=/path/to/your/config.json
#   export KEEPER_FOLDER="Sftp-Keys"
#   bash keeper-check-exists.sh

set -uo pipefail
: "${KEEPER_CONFIG:?set KEEPER_CONFIG=/path/to/your/config.json}"
: "${KEEPER_FOLDER:?set KEEPER_FOLDER=\"the parent folder you already created\"}"
KEEPER_CLI="${KEEPER_CLI:-keeper}"
TEST_USER="${KEEPER_TEST_USER:-smoketest123}"

banner() { printf '\n========== %s ==========\n' "$1"; }

record_exists() {
  local out
  out="$("$KEEPER_CLI" --config="$KEEPER_CONFIG" "list --format=json \"$KEEPER_FOLDER\"" 2>&1)" || {
    echo "list command itself failed:"
    echo "$out"
    return 2
  }
  echo "RAW list --format=json OUTPUT:"
  echo "$out"
  echo
  jq -e --arg title "$TEST_USER" \
    '[.. | objects | select((.title // .name // "") == $title)] | length > 0' \
    <<<"$out" >/dev/null 2>&1
}

banner "STEP 1: check BEFORE the record exists (expect: not found)"
if record_exists; then
  echo "VERDICT: already found '$TEST_USER' - a leftover from an earlier test run, that's fine"
  ALREADY_THERE=1
else
  rc=$?
  [[ $rc -eq 2 ]] && { echo "VERDICT: could not even run the list command - fix that before anything else"; exit 1; }
  echo "VERDICT: correctly reports not found"
  ALREADY_THERE=0
fi

if [[ $ALREADY_THERE -eq 0 ]]; then
  banner "STEP 2: create the test record"
  fake_priv_b64="$(printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\nFAKE\n-----END OPENSSH PRIVATE KEY-----\n' | base64 | tr -d '\n')"
  cmd="record-add --title \"$TEST_USER\" --record-type login --force --folder \"$KEEPER_FOLDER\""
  cmd="$cmd \"login=$TEST_USER\" \"c.secret.private_key_b64=$fake_priv_b64\""
  "$KEEPER_CLI" --config="$KEEPER_CONFIG" "$cmd"
fi

banner "STEP 3: check AFTER the record exists (expect: found)"
if record_exists; then
  echo "VERDICT: correctly reports found"
  FOUND_OK=1
else
  echo "VERDICT: FAILED - record exists but the check didn't find it"
  echo "This means list --format=json's JSON shape doesn't match what the"
  echo "jq filter expects. Send me the RAW OUTPUT printed above and I'll fix it."
  FOUND_OK=0
fi

if [[ $ALREADY_THERE -eq 0 ]]; then
  banner "CLEANUP: removing the test record"
  "$KEEPER_CLI" --config="$KEEPER_CONFIG" "rm -f \"$KEEPER_FOLDER/$TEST_USER\"" 2>&1 \
    || echo "(cleanup failed - delete '$TEST_USER' from '$KEEPER_FOLDER' by hand)"
fi

banner "SUMMARY"
if [[ "${FOUND_OK:-0}" -eq 1 ]]; then
  echo "The existence check works correctly - ready to trust in the real script."
else
  echo "The existence check needs adjusting - send me the RAW OUTPUT from STEP 3."
fi
