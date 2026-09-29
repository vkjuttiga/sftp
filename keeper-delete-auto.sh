#!/usr/bin/env bash
#
# Tries several ways to find a record's UID, automatically, and reports
# only short verdicts - no need to paste any raw output. If exactly one
# UID-shaped candidate turns up, it deletes with it and confirms via a
# fresh `ls` that the record is actually gone.
#
#   export KEEPER_CONFIG=/path/to/your/config.json
#   export KEEPER_FOLDER="Sftp-Keys"
#   bash keeper-delete-auto.sh

set -uo pipefail
: "${KEEPER_CONFIG:?set KEEPER_CONFIG=/path/to/your/config.json}"
: "${KEEPER_FOLDER:?set KEEPER_FOLDER=\"the parent folder you already created\"}"
KEEPER_CLI="${KEEPER_CLI:-keeper}"
TEST_USER="${KEEPER_TEST_USER:-smoketest123}"

# A Keeper UID looks like ~22 chars of letters/digits/-/_. 20+ comfortably
# excludes the test title itself and any other short words in the output.
uid_candidates() { grep -oE '[A-Za-z0-9_-]{20,}' <<<"$1" | sort -u; }

banner() { printf '\n========== %s ==========\n' "$1"; }

banner "SETUP: (re)create the test record"
fake_priv_b64="$(printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\nFAKE\n-----END OPENSSH PRIVATE KEY-----\n' | base64 | tr -d '\n')"
cmd="record-add --title \"$TEST_USER\" --record-type login --force --folder \"$KEEPER_FOLDER\""
cmd="$cmd \"login=$TEST_USER\" \"c.secret.private_key_b64=$fake_priv_b64\""
"$KEEPER_CLI" --config="$KEEPER_CONFIG" "$cmd" >/dev/null 2>&1

all_candidates=""

try() {
  local label="$1" out rc
  shift
  out="$("$KEEPER_CLI" --config="$KEEPER_CONFIG" "$1" 2>&1)"; rc=$?
  local found
  found="$(uid_candidates "$out")"
  if [[ -n "$found" ]]; then
    echo "$label: exit=$rc, UID-shaped candidate(s): $found"
    all_candidates="$all_candidates
$found"
  else
    echo "$label: exit=$rc, no UID-shaped text found"
  fi
}

banner "TRYING SEVERAL WAYS TO FIND A UID (short results only)"
try "search"              "search \"$TEST_USER\""
try "list (title as pattern)" "list --format=json \"$TEST_USER\""
try "get (bare title)"    "get \"$TEST_USER\""
try "get (bare title, json)" "get \"$TEST_USER\" --format=json"

unique="$(sort -u <<<"$all_candidates" | grep -v '^$')"
count="$(wc -l <<<"$unique" | tr -d ' ')"
[[ -z "$unique" ]] && count=0

banner "RESULT"
if [[ "$count" -eq 0 ]]; then
  echo "No UID-shaped text found anywhere. None of these methods expose a"
  echo "usable UID on this Commander version - deletion by UID isn't going"
  echo "to work here. Delete this test record by hand for now; I'll need a"
  echo "different approach for automated deletion."
elif [[ "$count" -eq 1 ]]; then
  echo "Exactly one candidate: $unique"
  echo "Attempting deletion with it..."
  "$KEEPER_CLI" --config="$KEEPER_CONFIG" "rm -f $unique" >/dev/null 2>&1
  after="$("$KEEPER_CLI" --config="$KEEPER_CONFIG" "ls \"$KEEPER_FOLDER\"" 2>&1)"
  if grep -qF "$TEST_USER" <<<"$after"; then
    echo "VERDICT: FAILED - the record is still there after rm. This UID"
    echo "candidate didn't work either."
  else
    echo "VERDICT: SUCCESS - confirmed deleted with a fresh ls."
    echo "This UID came from a reliable method - tell me which label above"
    echo "showed it (search / list / get / get json) and I'll wire that in."
  fi
else
  echo "Found $count different candidates - can't safely guess which is"
  echo "correct:"
  echo "$unique"
  echo "Not attempting deletion automatically. Tell me these values (they're"
  echo "short, safe to type) and which label(s) they came from."
fi
