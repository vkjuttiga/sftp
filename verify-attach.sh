#!/usr/bin/env bash
#
# Bare-title upload-attachment is now confirmed to just fail outright
# ("record UID not found") - Commander tries to use the title text AS a
# UID. This checks the OTHER path: does upload-attachment with the
# record's REAL UID actually attach something, or does it also report
# success while changing nothing? Same before/after get comparison as
# keeper-attachment-verify.sh, just against the UID form this time.
#
#   export KEEPER_CONFIG=/path/to/your/config.json
#   export KEEPER_FOLDER="Sftp-Keys"
#   bash keeper-attachment-verify-uid.sh

set -uo pipefail
: "${KEEPER_CONFIG:?set KEEPER_CONFIG=/path/to/your/config.json}"
: "${KEEPER_FOLDER:?set KEEPER_FOLDER=\"the parent folder you already created\"}"
KEEPER_CLI="${KEEPER_CLI:-keeper}"
TEST_USER="${KEEPER_TEST_USER:-smoketest123}"

banner() { printf '\n========== %s ==========\n' "$1"; }

banner "SETUP: (re)create the test record"
"$KEEPER_CLI" --config="$KEEPER_CONFIG" \
  "record-add --title \"$TEST_USER\" --record-type login --force --folder \"$KEEPER_FOLDER\" \"login=$TEST_USER\"" >/dev/null 2>&1

banner "Finding the record's UID (ls -l on the folder - the method already confirmed to work)"
lsl="$("$KEEPER_CLI" --config="$KEEPER_CONFIG" "ls -l \"$KEEPER_FOLDER\"" 2>&1)"
line="$(grep -F "$TEST_USER" <<<"$lsl")"
echo "matching line: $line"
uid="$(grep -oE '[A-Za-z0-9_-]{20,}' <<<"$line" | head -1)"

if [[ -z "$uid" ]]; then
  echo "could not extract a UID from that line - stopping"
  exit 1
fi
echo "resolved UID: $uid"

KEYFILE="$(mktemp)"
printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\nFAKE-UID-ATTACH-TEST\n-----END OPENSSH PRIVATE KEY-----\n' > "$KEYFILE"

banner "BEFORE: snapshot of get \$uid --format=json"
before="$("$KEEPER_CLI" --config="$KEEPER_CONFIG" "get $uid --format=json" 2>&1)"
echo "captured ($(wc -c <<<"$before" | tr -d ' ') bytes)"

banner "RUNNING: upload-attachment --file <path> <uid>"
up_out="$("$KEEPER_CLI" --config="$KEEPER_CONFIG" "upload-attachment --file \"$KEYFILE\" $uid" 2>&1)"
up_rc=$?
echo "exit code: $up_rc"
echo "output: ${up_out:-<empty>}"

banner "AFTER: snapshot of get \$uid --format=json"
after="$("$KEEPER_CLI" --config="$KEEPER_CONFIG" "get $uid --format=json" 2>&1)"
echo "captured ($(wc -c <<<"$after" | tr -d ' ') bytes)"

banner "RESULT"
if [[ "$before" == "$after" ]]; then
  echo "VERDICT: NO CHANGE - even with the real UID, get's view is identical"
  echo "before and after. upload-attachment is not doing what we think it"
  echo "does, regardless of title vs UID."
else
  echo "VERDICT: CHANGED - byte count before: $(wc -c <<<"$before" | tr -d ' '),"
  echo "after: $(wc -c <<<"$after" | tr -d ' '). Commander's own data DID"
  echo "update. Go check the Keeper UI now for this specific record"
  echo "('$TEST_USER' in '$KEEPER_FOLDER') - does an attachment show up?"
fi

banner "CLEANUP (record left in place so you can inspect it in the UI)"
echo "delete it yourself once you're done checking, or re-run with --force via record-add"
rm -f "$KEYFILE"
