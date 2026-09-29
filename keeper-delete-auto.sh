#!/usr/bin/env bash
#
# No copy-pasting needed. Collects every UID-shaped candidate from several
# discovery methods, then - safely, read-only, nothing destructive yet -
# runs `get <candidate>` on each one and checks whether the result actually
# matches our test record. Only a candidate that verifies this way is ever
# used for the real `rm`. Reports numbers and PASS/FAIL, nothing to copy.
#
#   export KEEPER_CONFIG=/path/to/your/config.json
#   export KEEPER_FOLDER="Sftp-Keys"
#   bash keeper-delete-verify.sh

set -uo pipefail
: "${KEEPER_CONFIG:?set KEEPER_CONFIG=/path/to/your/config.json}"
: "${KEEPER_FOLDER:?set KEEPER_FOLDER=\"the parent folder you already created\"}"
KEEPER_CLI="${KEEPER_CLI:-keeper}"
TEST_USER="${KEEPER_TEST_USER:-smoketest123}"

uid_candidates() { grep -oE '[A-Za-z0-9_-]{20,}' <<<"$1" | sort -u; }

banner() { printf '\n========== %s ==========\n' "$1"; }

banner "SETUP: (re)create the test record"
fake_priv_b64="$(printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\nFAKE\n-----END OPENSSH PRIVATE KEY-----\n' | base64 | tr -d '\n')"
cmd="record-add --title \"$TEST_USER\" --record-type login --force --folder \"$KEEPER_FOLDER\""
cmd="$cmd \"login=$TEST_USER\" \"c.secret.private_key_b64=$fake_priv_b64\""
"$KEEPER_CLI" --config="$KEEPER_CONFIG" "$cmd" >/dev/null 2>&1

banner "COLLECTING CANDIDATES (no output shown - just gathering)"
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
n="$(grep -c . <<<"$candidates" 2>/dev/null || echo 0)"
echo "Found $n candidate(s) total."

if [[ "$n" -eq 0 ]]; then
  banner "RESULT"
  echo "0 candidates found anywhere - nothing to verify. Delete the test"
  echo "record by hand for now; a different approach is needed here."
  exit 0
fi

banner "VERIFYING EACH CANDIDATE (read-only 'get' - nothing destructive yet)"
verified=""
i=0
while IFS= read -r uid; do
  i=$((i+1))
  out="$("$KEEPER_CLI" --config="$KEEPER_CONFIG" "get $uid --format=json" 2>&1)"
  if grep -qF "$TEST_USER" <<<"$out"; then
    echo "candidate $i: MATCHES our test record"
    verified="$verified
$uid"
  else
    echo "candidate $i: does not match (unrelated record, or lookup failed)"
  fi
done <<<"$candidates"
verified="$(sort -u <<<"$verified" | grep -v '^$')"
vn="$(grep -c . <<<"$verified" 2>/dev/null || echo 0)"

banner "RESULT"
if [[ "$vn" -eq 0 ]]; then
  echo "0 of $n candidates verified. None of them actually resolve to our"
  echo "test record via 'get'. Delete the test record by hand for now."
elif [[ "$vn" -eq 1 ]]; then
  echo "Exactly 1 candidate verified. Deleting the test record with it..."
  "$KEEPER_CLI" --config="$KEEPER_CONFIG" "rm -f $verified" >/dev/null 2>&1
  after="$("$KEEPER_CLI" --config="$KEEPER_CONFIG" "ls \"$KEEPER_FOLDER\"" 2>&1)"
  if grep -qF "$TEST_USER" <<<"$after"; then
    echo "VERDICT: rm ran but the record is STILL there. Report: FAILED."
  else
    echo "VERDICT: SUCCESS - verified match, deleted, and confirmed gone."
    echo "Just tell me: SUCCESS. That's all I need."
  fi
else
  echo "$vn candidates all verified as matching (unusual - might mean"
  echo "duplicate records exist). Not deleting automatically - this needs"
  echo "a closer look. Report: $vn verified, ambiguous."
fi
