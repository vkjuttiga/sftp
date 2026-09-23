#!/usr/bin/env bash
#
# Standalone Keeper Commander smoke test. Exercises, one at a time, every
# Commander CLI call the provisioning scripts want to make - nothing here
# touches AWS or Terraform at all. Run it, see which numbered step fails,
# fix that one step, re-run.
#
#   export KEEPER_CONFIG=/path/to/your/config.json
#   export KEEPER_FOLDER="SFTP Keys"      # optional, parent folder you already made
#   bash keeper-smoke-test.sh
#
# Optional: KEEPER_CLI (default: keeper), KEEPER_TEST_USER (default: smoketest123)
#
# Each step prints the EXACT command it ran, its exit code, and its raw
# output - nothing is hidden or swallowed. Fix a step, then just re-run the
# whole script; steps clean up after themselves at the end (step 7).

set -uo pipefail   # deliberately no -e: we want to see every step run, even after a failure

: "${KEEPER_CONFIG:?set KEEPER_CONFIG=/path/to/your/config.json}"
KEEPER_CLI="${KEEPER_CLI:-keeper}"
KEEPER_FOLDER="${KEEPER_FOLDER:-}"
TEST_USER="${KEEPER_TEST_USER:-smoketest123}"
TEST_FOLDER="${KEEPER_FOLDER:+${KEEPER_FOLDER%/}/}${TEST_USER}"
TEST_TITLE="sftp"

PASS=0
FAIL=0

banner() { printf '\n========== %s ==========\n' "$1"; }

# Runs a command, shows it, shows the result. Never exits the script.
try() {
  local desc="$1"; shift
  banner "$desc"
  printf 'COMMAND: %s\n' "$*"
  printf -- '---\n'
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  echo "$out"
  printf -- '---\n'
  if [[ $rc -eq 0 ]]; then
    echo "RESULT: exit 0 (success)"
    PASS=$((PASS+1))
  else
    echo "RESULT: exit $rc (FAILED)"
    FAIL=$((FAIL+1))
  fi
  printf '%s' "$out"   # so callers can inspect it if needed
}

# Same as try(), but feeds stdin instead of a trailing positional command -
# this is how folder creation (cd + mkdir) is actually invoked in the real
# script, since Commander's mkdir won't take a "/"-joined path in one shot.
try_stdin() {
  local desc="$1"; shift
  local stdin_text="$1"; shift
  banner "$desc"
  printf 'COMMAND: %s\n' "$* (reading commands from stdin, shown below)"
  printf 'STDIN:\n%s\n' "$stdin_text"
  printf -- '---\n'
  local out rc
  out="$(printf '%s\n' "$stdin_text" | "$@" 2>&1)"; rc=$?
  echo "$out"
  printf -- '---\n'
  if [[ $rc -eq 0 ]]; then
    echo "RESULT: exit 0 (success)"
    PASS=$((PASS+1))
  else
    echo "RESULT: exit $rc (FAILED)"
    FAIL=$((FAIL+1))
  fi
}

echo "Keeper CLI:    $KEEPER_CLI"
echo "Config file:   $KEEPER_CONFIG"
echo "Parent folder: ${KEEPER_FOLDER:-<none - using Keeper root>}"
echo "Test user:     $TEST_USER"
echo "Test folder:   $TEST_FOLDER"
echo "Test title:    $TEST_TITLE"

# ---- Step 0: can we even reach Keeper? ----
try "STEP 0: whoami (confirms the config.json logs in at all)" \
  "$KEEPER_CLI" --config="$KEEPER_CONFIG" "whoami"

# ---- Step 1: does the parent folder exist / is it reachable? ----
if [[ -n "$KEEPER_FOLDER" ]]; then
  try "STEP 1: list the parent folder ($KEEPER_FOLDER)" \
    "$KEEPER_CLI" --config="$KEEPER_CONFIG" "ls \"$KEEPER_FOLDER\""
else
  echo
  echo "STEP 1: skipped (no KEEPER_FOLDER set - using Keeper root)"
fi

# ---- Step 2: create the per-user subfolder the CORRECT way (cd, then mkdir) ----
mkdir_stdin=""
[[ -n "$KEEPER_FOLDER" ]] && mkdir_stdin+="cd \"$KEEPER_FOLDER\"
"
mkdir_stdin+="mkdir \"$TEST_USER\""
try_stdin "STEP 2: create subfolder '$TEST_FOLDER' (cd then mkdir, piped)" \
  "$mkdir_stdin" "$KEEPER_CLI" --config="$KEEPER_CONFIG"

# ---- Step 3: confirm the subfolder is now really there ----
try "STEP 3: list the new subfolder's parent to confirm it exists" \
  "$KEEPER_CLI" --config="$KEEPER_CONFIG" "ls \"${KEEPER_FOLDER:-.}\""

# ---- Step 4: add a record inside it, with base64 custom fields (no raw newlines) ----
fake_priv_b64="$(printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\nFAKE-SMOKE-TEST-KEY\n-----END OPENSSH PRIVATE KEY-----\n' | base64 | tr -d '\n')"
fake_pub_b64="$(printf 'ssh-rsa AAAAFAKE smoketest@sftp\n' | base64 | tr -d '\n')"
cmd="record-add --title \"$TEST_TITLE\" --record-type login --force --folder \"$TEST_FOLDER\""
cmd="$cmd \"login=$TEST_USER\""
cmd="$cmd \"c.text.path=smoke/test\""
cmd="$cmd \"c.text.public_key_b64=$fake_pub_b64\""
cmd="$cmd \"c.secret.private_key_b64=$fake_priv_b64\""
try "STEP 4: record-add inside '$TEST_FOLDER' (base64 fields, referencing the folder by path)" \
  "$KEEPER_CLI" --config="$KEEPER_CONFIG" "$cmd"

# ---- Step 5: read it back as JSON, referencing the record by folder/title path ----
try "STEP 5: get \"$TEST_FOLDER/$TEST_TITLE\" --format=json (existence check + read-back)" \
  "$KEEPER_CLI" --config="$KEEPER_CONFIG" "get \"$TEST_FOLDER/$TEST_TITLE\" --format=json"

# ---- Step 6: does the JSON shape match what the script expects? ----
banner "STEP 6: does the JSON have a 'private_key_b64' field the script can find?"
raw="$("$KEEPER_CLI" --config="$KEEPER_CONFIG" "get \"$TEST_FOLDER/$TEST_TITLE\" --format=json" 2>&1)"
echo "$raw"
if command -v jq >/dev/null 2>&1; then
  found="$(jq -r '.fields[]? | select(.label=="private_key_b64") | .value[0]' <<<"$raw" 2>/dev/null)"
  if [[ -n "$found" ]]; then
    decoded="$(printf '%s' "$found" | base64 -d 2>/dev/null || printf '%s' "$found" | base64 -D 2>/dev/null)"
    echo "found field, decodes to:"
    echo "$decoded"
    if [[ "$decoded" == *"FAKE-SMOKE-TEST-KEY"* ]]; then
      echo "RESULT: exit 0 (success - round trip matches)"
      PASS=$((PASS+1))
    else
      echo "RESULT: FAILED - decoded content doesn't match what we stored"
      FAIL=$((FAIL+1))
    fi
  else
    echo "RESULT: FAILED - .fields[] with label=private_key_b64 not found at that path."
    echo "Look at the raw JSON above and tell me the actual shape - the jq filter"
    echo "in the real script (keeper_upload_key / README) needs to match it."
    FAIL=$((FAIL+1))
  fi
else
  echo "jq not installed locally - install it to let this script verify automatically,"
  echo "or eyeball the raw JSON above for a private_key_b64 field yourself."
fi

# ---- Step 7: clean up everything this test created ----
try "STEP 7a: remove the test record" \
  "$KEEPER_CLI" --config="$KEEPER_CONFIG" "rm -f \"$TEST_FOLDER/$TEST_TITLE\""
try "STEP 7b: remove the test folder" \
  "$KEEPER_CLI" --config="$KEEPER_CONFIG" "rmdir \"$TEST_FOLDER\""

banner "SUMMARY"
echo "Passed: $PASS"
echo "Failed: $FAIL"
if [[ $FAIL -eq 0 ]]; then
  echo "All Keeper calls the pipeline needs work as written - nothing to fix."
else
  echo "Send me the FAILED step number(s) and their exact output above, and"
  echo "we'll fix that one call before touching the real provisioning script."
fi
