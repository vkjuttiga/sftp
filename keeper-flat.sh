#!/usr/bin/env bash
#
# Tests the FLAT design: no per-user subfolder, no mkdir, no cd. Just one
# record per user, titled with the user's name, sitting directly inside the
# one parent folder you already created by hand. This only relies on the ONE
# thing already confirmed to work: record-add --folder "<parent>".
#
#   export KEEPER_CONFIG=/path/to/your/config.json
#   export KEEPER_FOLDER="SFTP Keys"      # the parent folder you already made
#   bash keeper-flat-record-test.sh
#
# Optional: KEEPER_CLI (default: keeper), KEEPER_TEST_USER (default: smoketest123)
#
# Creates ONE throwaway record, reads it back, verifies the key round-trips,
# then deletes it. Nothing else in your vault is touched.

set -uo pipefail

: "${KEEPER_CONFIG:?set KEEPER_CONFIG=/path/to/your/config.json}"
: "${KEEPER_FOLDER:?set KEEPER_FOLDER=\"the parent folder you already created\"}"
KEEPER_CLI="${KEEPER_CLI:-keeper}"
TEST_USER="${KEEPER_TEST_USER:-smoketest123}"
RECORD_PATH="${KEEPER_FOLDER}/${TEST_USER}"

PASS=0
FAIL=0
banner() { printf '\n========== %s ==========\n' "$1"; }

try() {
  local desc="$1"; shift
  banner "$desc"
  printf 'COMMAND: %s\n---\n' "$*"
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  echo "$out"
  printf -- '---\nRESULT: exit %d (%s)\n' "$rc" "$([[ $rc -eq 0 ]] && echo success || echo FAILED)"
  [[ $rc -eq 0 ]] && PASS=$((PASS+1)) || FAIL=$((FAIL+1))
  printf '%s' "$out"
}

echo "Keeper CLI:    $KEEPER_CLI"
echo "Config file:   $KEEPER_CONFIG"
echo "Parent folder: $KEEPER_FOLDER"
echo "Test user:     $TEST_USER"
echo "Record path:   $RECORD_PATH  (a RECORD, not a folder)"

# ---- Step 0: confirm the parent folder is there and empty-ish ----
try "STEP 0: list the parent folder before anything" \
  "$KEEPER_CLI" --config="$KEEPER_CONFIG" "ls \"$KEEPER_FOLDER\""

# ---- Step 1: create ONE record, titled with the username, flat in the parent ----
fake_priv_b64="$(printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\nFAKE-FLAT-TEST-KEY\n-----END OPENSSH PRIVATE KEY-----\n' | base64 | tr -d '\n')"
fake_pub_b64="$(printf 'ssh-rsa AAAAFAKE smoketest@sftp\n' | base64 | tr -d '\n')"
cmd="record-add --title \"$TEST_USER\" --record-type login --force --folder \"$KEEPER_FOLDER\""
cmd="$cmd \"login=$TEST_USER\""
cmd="$cmd \"c.text.path=smoke/test\""
cmd="$cmd \"c.text.public_key_b64=$fake_pub_b64\""
cmd="$cmd \"c.secret.private_key_b64=$fake_priv_b64\""
try "STEP 1: record-add, title=\"$TEST_USER\", flat inside \"$KEEPER_FOLDER\"" \
  "$KEEPER_CLI" --config="$KEEPER_CONFIG" "$cmd"

# ---- Step 2: fresh ls of the parent - does the new record actually show up THERE? ----
try "STEP 2: list the parent folder again - is '$TEST_USER' in it now?" \
  "$KEEPER_CLI" --config="$KEEPER_CONFIG" "ls \"$KEEPER_FOLDER\""
ls_out="$("$KEEPER_CLI" --config="$KEEPER_CONFIG" "ls \"$KEEPER_FOLDER\"" 2>&1)"
if grep -qF "$TEST_USER" <<<"$ls_out"; then
  echo "==> '$TEST_USER' IS visible inside '$KEEPER_FOLDER' - this is the key check"
else
  echo "==> '$TEST_USER' is NOT visible inside '$KEEPER_FOLDER' - record-add's --folder didn't land it there"
  FAIL=$((FAIL+1))
fi

# ---- Step 3: also check the VAULT ROOT, in case --folder was silently ignored ----
try "STEP 3: list the vault root too, in case it landed there instead" \
  "$KEEPER_CLI" --config="$KEEPER_CONFIG" "ls"

# ---- Step 4: read the record back by its folder/title path, verify round trip ----
try "STEP 4: get \"$RECORD_PATH\" --format=json" \
  "$KEEPER_CLI" --config="$KEEPER_CONFIG" "get \"$RECORD_PATH\" --format=json"
raw="$("$KEEPER_CLI" --config="$KEEPER_CONFIG" "get \"$RECORD_PATH\" --format=json" 2>&1)"

banner "STEP 5: does the private key round-trip correctly?"
if command -v jq >/dev/null 2>&1; then
  found="$(jq -r '.fields[]? | select(.label=="private_key_b64") | .value[0]' <<<"$raw" 2>/dev/null)"
  if [[ -n "$found" ]]; then
    decoded="$(printf '%s' "$found" | base64 -d 2>/dev/null || printf '%s' "$found" | base64 -D 2>/dev/null)"
    echo "decoded private key:"; echo "$decoded"
    if [[ "$decoded" == *"FAKE-FLAT-TEST-KEY"* ]]; then
      echo "RESULT: exit 0 (success - round trip matches)"; PASS=$((PASS+1))
    else
      echo "RESULT: FAILED - decoded content doesn't match"; FAIL=$((FAIL+1))
    fi
  else
    echo "RESULT: FAILED - private_key_b64 field not found. Raw JSON was:"
    echo "$raw"
    FAIL=$((FAIL+1))
  fi
else
  echo "jq not installed - eyeball the raw JSON from STEP 4 above for a private_key_b64 field"
fi

# ---- Step 6: clean up ----
try "STEP 6: remove the test record" \
  "$KEEPER_CLI" --config="$KEEPER_CONFIG" "rm -f \"$RECORD_PATH\""
try "STEP 6b: confirm it's really gone" \
  "$KEEPER_CLI" --config="$KEEPER_CONFIG" "ls \"$KEEPER_FOLDER\""

banner "SUMMARY"
echo "Passed: $PASS"
echo "Failed: $FAIL"
if [[ $FAIL -eq 0 ]]; then
  echo "The flat design works end to end - ready to wire into the real script."
else
  echo "Send me everything above, especially STEP 2 and STEP 3's raw ls output -"
  echo "that tells us whether --folder is being honored at all, or where records"
  echo "actually land when you pass it."
fi
