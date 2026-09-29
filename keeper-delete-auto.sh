#!/usr/bin/env bash
#
# Two candidates both verified via a read-only `get` last time - could be a
# genuine duplicate record (leftover from earlier test rounds - we've run a
# lot of these), or one candidate giving a false-positive match. This
# narrows it down by actually deleting one candidate at a time and
# rechecking `ls` after each - the only thing that tells us, for certain,
# whether a given UID controls the folder's visible copy of the record.
#
#   export KEEPER_CONFIG=/path/to/your/config.json
#   export KEEPER_FOLDER="Sftp-Keys"
#   bash keeper-delete-narrow.sh

set -uo pipefail
: "${KEEPER_CONFIG:?set KEEPER_CONFIG=/path/to/your/config.json}"
: "${KEEPER_FOLDER:?set KEEPER_FOLDER=\"the parent folder you already created\"}"
KEEPER_CLI="${KEEPER_CLI:-keeper}"
TEST_USER="${KEEPER_TEST_USER:-smoketest123}"

uid_candidates() { grep -oE '[A-Za-z0-9_-]{20,}' <<<"$1" | sort -u; }
visible_in_folder() {
  local out
  out="$("$KEEPER_CLI" --config="$KEEPER_CONFIG" "ls \"$KEEPER_FOLDER\"" 2>&1)"
  grep -qF "$TEST_USER" <<<"$out"
}

banner() { printf '\n========== %s ==========\n' "$1"; }

banner "SETUP: ensure the test record exists"
if ! visible_in_folder; then
  fake_priv_b64="$(printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\nFAKE\n-----END OPENSSH PRIVATE KEY-----\n' | base64 | tr -d '\n')"
  cmd="record-add --title \"$TEST_USER\" --record-type login --force --folder \"$KEEPER_FOLDER\""
  cmd="$cmd \"login=$TEST_USER\" \"c.secret.private_key_b64=$fake_priv_b64\""
  "$KEEPER_CLI" --config="$KEEPER_CONFIG" "$cmd" >/dev/null 2>&1
fi
visible_in_folder || { echo "could not (re)create the test record - stopping"; exit 1; }
echo "confirmed visible in $KEEPER_FOLDER"

banner "COLLECTING VERIFIED CANDIDATES"
all=""
for c in \
  "search \"$TEST_USER\"" \
  "list --format=json \"$TEST_USER\"" \
  "get \"$TEST_USER\"" \
  "get \"$TEST_USER\" --format=json"
do
  out="$("$KEEPER_CLI" --config="$KEEPER_CONFIG" "$c" 2>&1)"
  all="$all
$(uid_candidates "$out")"
done
candidates="$(sort -u <<<"$all" | grep -v '^$')"

verified=""
while IFS= read -r uid; do
  [[ -z "$uid" ]] && continue
  out="$("$KEEPER_CLI" --config="$KEEPER_CONFIG" "get $uid --format=json" 2>&1)"
  grep -qF "$TEST_USER" <<<"$out" && verified="$verified
$uid"
done <<<"$candidates"
verified="$(sort -u <<<"$verified" | grep -v '^$')"
vn="$(grep -c . <<<"$verified" 2>/dev/null || echo 0)"
echo "$vn candidate(s) verified: re-narrowing by actually deleting one at a time"

banner "NARROWING - delete one candidate, recheck ls, repeat only if still visible"
i=0
resolved=0
while IFS= read -r uid; do
  [[ -z "$uid" ]] && continue
  i=$((i+1))
  if ! visible_in_folder; then
    echo "candidate $i: skipped - record already gone (an earlier candidate resolved it)"
    continue
  fi
  "$KEEPER_CLI" --config="$KEEPER_CONFIG" "rm -f $uid" >/dev/null 2>&1
  if visible_in_folder; then
    echo "candidate $i: deleted it, but the record is STILL visible - this UID was a false positive, not the real controlling one"
  else
    echo "candidate $i: deleted it, record is now GONE - this is the real UID"
    resolved=1
  fi
done <<<"$verified"

banner "RESULT"
if visible_in_folder; then
  echo "The test record is still visible after trying every verified candidate."
  echo "None of them actually control the folder's copy. Report: NONE WORKED."
else
  echo "The test record is gone. Report: RESOLVED."
  if [[ $resolved -eq 1 ]]; then
    echo "(exactly one candidate was the real UID - a clean result)"
  fi
fi
