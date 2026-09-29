#!/usr/bin/env bash
#
# Tests deleting a Keeper record scoped to one folder. `get` and `rm` by
# "folder/title" path both failed earlier (get needed a UID instead), so
# `rm` almost certainly needs one too. This finds the UID from `ls -v`,
# deletes by UID, and confirms with a fresh `ls` that it's actually gone -
# not just that `rm` returned success.
#
#   export KEEPER_CONFIG=/path/to/your/config.json
#   export KEEPER_FOLDER="Sftp-Keys"
#   bash keeper-delete-test.sh

set -uo pipefail
: "${KEEPER_CONFIG:?set KEEPER_CONFIG=/path/to/your/config.json}"
: "${KEEPER_FOLDER:?set KEEPER_FOLDER=\"the parent folder you already created\"}"
KEEPER_CLI="${KEEPER_CLI:-keeper}"
TEST_USER="${KEEPER_TEST_USER:-smoketest123}"

banner() { printf '\n========== %s ==========\n' "$1"; }

banner "SETUP: (re)create the test record"
fake_priv_b64="$(printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\nFAKE\n-----END OPENSSH PRIVATE KEY-----\n' | base64 | tr -d '\n')"
cmd="record-add --title \"$TEST_USER\" --record-type login --force --folder \"$KEEPER_FOLDER\""
cmd="$cmd \"login=$TEST_USER\" \"c.secret.private_key_b64=$fake_priv_b64\""
"$KEEPER_CLI" --config="$KEEPER_CONFIG" "$cmd"

banner "STEP 1: ls -v \"$KEEPER_FOLDER\" (find the UID)"
lsv="$("$KEEPER_CLI" --config="$KEEPER_CONFIG" "ls -v \"$KEEPER_FOLDER\"" 2>&1)"
echo "$lsv"

banner "STEP 2: extract a UID from the line mentioning '$TEST_USER'"
line="$(grep -F "$TEST_USER" <<<"$lsv")"
echo "matching line: $line"
uid="$(grep -oE '[A-Za-z0-9_-]{20,}' <<<"$line" | head -1)"
if [[ -z "$uid" ]]; then
  echo "VERDICT: could not extract anything UID-shaped from that line."
  echo "Paste the matching line above (shown right here, no need to go find it)"
  echo "and I'll fix the extraction pattern."
  exit 1
fi
echo "extracted UID: $uid"

banner "STEP 3: rm -f $uid"
"$KEEPER_CLI" --config="$KEEPER_CONFIG" "rm -f $uid"
echo "exit code: $?"

banner "STEP 4: confirm with a FRESH ls - is '$TEST_USER' actually gone?"
after="$("$KEEPER_CLI" --config="$KEEPER_CONFIG" "ls \"$KEEPER_FOLDER\"" 2>&1)"
echo "$after"
if grep -qF "$TEST_USER" <<<"$after"; then
  echo "VERDICT: FAILED - '$TEST_USER' is still there. The UID or the rm command was wrong."
else
  echo "VERDICT: confirmed deleted."
fi
