#!/usr/bin/env bash
#
# Step B: given a UID found by keeper-find-uid.sh, confirm `get <uid>`
# actually returns the record and that the private key round-trips
# correctly. Cleans up the test record at the end either way.
#
#   export KEEPER_CONFIG=/path/to/your/config.json
#   export KEEPER_FOLDER="Sftp-Keys"
#   KEEPER_TEST_UID=<uid from keeper-find-uid.sh> bash keeper-verify-by-uid.sh

set -uo pipefail

: "${KEEPER_CONFIG:?set KEEPER_CONFIG=/path/to/your/config.json}"
: "${KEEPER_FOLDER:?set KEEPER_FOLDER=\"the parent folder you already created\"}"
: "${KEEPER_TEST_UID:?set KEEPER_TEST_UID=<the uid keeper-find-uid.sh showed you>}"
KEEPER_CLI="${KEEPER_CLI:-keeper}"
TEST_USER="${KEEPER_TEST_USER:-smoketest123}"

banner() { printf '\n========== %s ==========\n' "$1"; }
PASS=0; FAIL=0

show() {
  banner "$1"; shift
  printf 'COMMAND: %s\n---\n' "$*"
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  echo "$out"
  printf -- '---\nRESULT: exit %d (%s)\n' "$rc" "$([[ $rc -eq 0 ]] && echo success || echo FAILED)"
  [[ $rc -eq 0 ]] && PASS=$((PASS+1)) || FAIL=$((FAIL+1))
  printf '%s' "$out"
}

echo "UID under test: $KEEPER_TEST_UID"

show "STEP 4: get $KEEPER_TEST_UID --format=json" \
  "$KEEPER_CLI" --config="$KEEPER_CONFIG" "get $KEEPER_TEST_UID --format=json"
raw="$("$KEEPER_CLI" --config="$KEEPER_CONFIG" "get $KEEPER_TEST_UID --format=json" 2>&1)"

banner "STEP 5: does the private key round-trip correctly?"
if command -v jq >/dev/null 2>&1; then
  found="$(jq -r '.fields[]? | select(.label=="private_key_b64") | .value[0]' <<<"$raw" 2>/dev/null)"
  if [[ -n "$found" ]]; then
    decoded="$(printf '%s' "$found" | base64 -d 2>/dev/null || printf '%s' "$found" | base64 -D 2>/dev/null)"
    echo "decoded private key:"; echo "$decoded"
    if [[ "$decoded" == *"FAKE-UID-TEST-KEY"* ]]; then
      echo "RESULT: exit 0 (success - round trip matches)"; PASS=$((PASS+1))
    else
      echo "RESULT: FAILED - decoded content doesn't match what we stored"; FAIL=$((FAIL+1))
    fi
  else
    echo "RESULT: FAILED - private_key_b64 field not found in that JSON shape. Raw JSON was:"
    echo "$raw"
    FAIL=$((FAIL+1))
  fi
else
  echo "jq not installed - eyeball the raw JSON from STEP 4 above for a private_key_b64 field"
fi

show "CLEANUP: rm -f $KEEPER_TEST_UID" \
  "$KEEPER_CLI" --config="$KEEPER_CONFIG" "rm -f $KEEPER_TEST_UID"
show "CLEANUP fallback: rm -f by folder/title, in case the UID form of rm didn't work" \
  "$KEEPER_CLI" --config="$KEEPER_CONFIG" "rm -f \"$KEEPER_FOLDER/$TEST_USER\""

banner "SUMMARY"
echo "Passed: $PASS"
echo "Failed: $FAIL"
if [[ $FAIL -eq 0 ]]; then
  echo "get by UID works and the round trip is clean - this is the retrieval"
  echo "method to document. Send me this output and I'll update the README."
else
  echo "Send me this whole output - particularly the raw JSON from STEP 4 -"
  echo "and we'll adjust the jq filter or the lookup method."
fi
