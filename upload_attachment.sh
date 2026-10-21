#!/usr/bin/env bash
#
# upload-attachment's real usage is: upload-attachment --file <path> <record>
# - a positional, not --record. Tries it with the bare title first, then
# with the record's UID (found the same proven way as deletion), since we
# don't yet know which one "record" actually wants.
#
#   export KEEPER_CONFIG=/path/to/your/config.json
#   export KEEPER_FOLDER="Sftp-Keys"
#   bash keeper-attachment-test2.sh

set -uo pipefail
: "${KEEPER_CONFIG:?set KEEPER_CONFIG=/path/to/your/config.json}"
: "${KEEPER_FOLDER:?set KEEPER_FOLDER=\"the parent folder you already created\"}"
KEEPER_CLI="${KEEPER_CLI:-keeper}"
TEST_USER="${KEEPER_TEST_USER:-smoketest123}"

banner() { printf '\n========== %s ==========\n' "$1"; }

KEYFILE="$(mktemp)"
printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\nFAKE-ATTACH-TEST\n-----END OPENSSH PRIVATE KEY-----\n' > "$KEYFILE"

banner "SETUP: create the test record"
"$KEEPER_CLI" --config="$KEEPER_CONFIG" \
  "record-add --title \"$TEST_USER\" --record-type login --force --folder \"$KEEPER_FOLDER\" \"login=$TEST_USER\""

banner "ATTEMPT A: upload-attachment --file <path> <bare title>"
printf 'COMMAND: upload-attachment --file "%s" "%s"\n---\n' "$KEYFILE" "$TEST_USER"
"$KEEPER_CLI" --config="$KEEPER_CONFIG" "upload-attachment --file \"$KEYFILE\" \"$TEST_USER\""
echo "exit: $?"
printf -- '---\n'

banner "Finding the record's UID (same proven method as deletion)"
candidates="$(
  {
    "$KEEPER_CLI" --config="$KEEPER_CONFIG" "search \"$TEST_USER\"" 2>&1
    "$KEEPER_CLI" --config="$KEEPER_CONFIG" "list --format=json \"$TEST_USER\"" 2>&1
    "$KEEPER_CLI" --config="$KEEPER_CONFIG" "get \"$TEST_USER\"" 2>&1
    "$KEEPER_CLI" --config="$KEEPER_CONFIG" "get \"$TEST_USER\" --format=json" 2>&1
  } | grep -oE '[A-Za-z0-9_-]{20,}' | sort -u
)"
uid=""
while IFS= read -r c; do
  [[ -z "$c" ]] && continue
  out="$("$KEEPER_CLI" --config="$KEEPER_CONFIG" "get $c --format=json" 2>&1)"
  if grep -qF "$TEST_USER" <<<"$out"; then uid="$c"; break; fi
done <<<"$candidates"

if [[ -z "$uid" ]]; then
  echo "could not resolve a UID this time - skipping ATTEMPT B"
else
  echo "resolved UID: $uid"
  banner "ATTEMPT B: upload-attachment --file <path> <uid>"
  printf 'COMMAND: upload-attachment --file "%s" %s\n---\n' "$KEYFILE" "$uid"
  "$KEEPER_CLI" --config="$KEEPER_CONFIG" "upload-attachment --file \"$KEYFILE\" $uid"
  echo "exit: $?"
  printf -- '---\n'
fi

banner "WHAT TO DO NEXT"
cat <<'EOF'
Open the Keeper app/UI now and look at the 'smoketest123' record in
Sftp-Keys. Does it show a file attachment you can download? If yes, tell me
which ATTEMPT (A or B) you think caused it - or just "yes, attachment
present" if you're not sure which. If no attachment shows up at all, tell
me that too, along with whichever of A/B printed exit: 0 vs a nonzero exit.
EOF

banner "CLEANUP (leaves the record itself - delete separately if you want)"
echo "(not auto-deleting this time, in case you want to inspect it first)"
rm -f "$KEYFILE"
