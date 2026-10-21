#!/usr/bin/env bash
#
# upload-attachment reported success, but no attachment shows in the UI.
# This checks Commander's own view of the record (get --format=json)
# BEFORE and AFTER the upload, and reports only whether anything actually
# changed - no need to read or paste JSON yourself.
#
#   export KEEPER_CONFIG=/path/to/your/config.json
#   export KEEPER_FOLDER="Sftp-Keys"
#   bash keeper-attachment-verify.sh

set -uo pipefail
: "${KEEPER_CONFIG:?set KEEPER_CONFIG=/path/to/your/config.json}"
: "${KEEPER_FOLDER:?set KEEPER_FOLDER=\"the parent folder you already created\"}"
KEEPER_CLI="${KEEPER_CLI:-keeper}"
TEST_USER="${KEEPER_TEST_USER:-smoketest123}"

banner() { printf '\n========== %s ==========\n' "$1"; }

banner "SETUP: (re)create the test record"
"$KEEPER_CLI" --config="$KEEPER_CONFIG" \
  "record-add --title \"$TEST_USER\" --record-type login --force --folder \"$KEEPER_FOLDER\" \"login=$TEST_USER\"" >/dev/null 2>&1

KEYFILE="$(mktemp)"
printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\nFAKE-VERIFY-TEST\n-----END OPENSSH PRIVATE KEY-----\n' > "$KEYFILE"

banner "BEFORE: snapshot of get --format=json"
before="$("$KEEPER_CLI" --config="$KEEPER_CONFIG" "get \"$TEST_USER\" --format=json" 2>&1)"
echo "captured ($(wc -c <<<"$before" | tr -d ' ') bytes)"

banner "RUNNING: upload-attachment --file <path> <bare title>"
up_out="$("$KEEPER_CLI" --config="$KEEPER_CONFIG" "upload-attachment --file \"$KEYFILE\" \"$TEST_USER\"" 2>&1)"
up_rc=$?
echo "exit code: $up_rc"
echo "output: ${up_out:-<empty>}"

banner "AFTER: snapshot of get --format=json"
after="$("$KEEPER_CLI" --config="$KEEPER_CONFIG" "get \"$TEST_USER\" --format=json" 2>&1)"
echo "captured ($(wc -c <<<"$after" | tr -d ' ') bytes)"

banner "RESULT"
if [[ "$before" == "$after" ]]; then
  echo "VERDICT: NO CHANGE - get's view of the record is byte-identical before"
  echo "and after. The upload reported success but genuinely did not modify"
  echo "the record Commander itself can see. This points to the upload"
  echo "going somewhere else entirely, or being silently discarded."
else
  echo "VERDICT: CHANGED - something about the record's data did change."
  echo "Byte count before: $(wc -c <<<"$before" | tr -d ' ')"
  echo "Byte count after:  $(wc -c <<<"$after" | tr -d ' ')"
  if command -v jq >/dev/null 2>&1; then
    before_keys="$(jq -r 'keys[]?' <<<"$before" 2>/dev/null | sort)"
    after_keys="$(jq -r 'keys[]?' <<<"$after" 2>/dev/null | sort)"
    new_keys="$(comm -13 <(echo "$before_keys") <(echo "$after_keys"))"
    if [[ -n "$new_keys" ]]; then
      echo "New top-level key(s) that appeared: $new_keys"
    else
      echo "No new top-level keys, but existing content changed size - something"
      echo "was recorded, just maybe not as a separate top-level 'attachments' key."
    fi
  fi
  echo "This means Commander DOES know something happened - worth checking"
  echo "whether the Keeper UI needs a refresh/reload, or whether you're"
  echo "looking at the record in a different view (e.g. a 'Files' tab vs"
  echo "the main field view)."
fi

banner "CLEANUP"
"$KEEPER_CLI" --config="$KEEPER_CONFIG" "rm -f \"$KEEPER_FOLDER/$TEST_USER\"" >/dev/null 2>&1
rm -f "$KEYFILE"
