#!/usr/bin/env bash
#
# Compares several ways to check "does a record titled X already exist in
# KEEPER_FOLDER" against your real vault, since `list --format=json
# "<folder>"` turned out to treat its argument as a search pattern, not a
# folder path. Creates one throwaway record, tries each candidate before
# and after it exists, and shows raw output for all of them so we can pick
# whichever is actually reliable - no more single guesses.
#
#   export KEEPER_CONFIG=/path/to/your/config.json
#   export KEEPER_FOLDER="Sftp-Keys"
#   bash keeper-check-exists-v2.sh

set -uo pipefail
: "${KEEPER_CONFIG:?set KEEPER_CONFIG=/path/to/your/config.json}"
: "${KEEPER_FOLDER:?set KEEPER_FOLDER=\"the parent folder you already created\"}"
KEEPER_CLI="${KEEPER_CLI:-keeper}"
TEST_USER="${KEEPER_TEST_USER:-smoketest123}"

banner() { printf '\n========== %s ==========\n' "$1"; }

try_candidate() {
  local label="$1" cmd="$2"
  banner "$label"
  printf 'COMMAND: %s\n---\n' "$cmd"
  local out
  out="$("$KEEPER_CLI" --config="$KEEPER_CONFIG" "$cmd" 2>&1)"
  echo "$out"
  printf -- '---\n'
  if grep -qF "$TEST_USER" <<<"$out"; then
    echo "CONTAINS '$TEST_USER': yes"
  else
    echo "CONTAINS '$TEST_USER': no"
  fi
}

banner "BEFORE: none of these should contain '$TEST_USER' yet"
try_candidate "ls (plain, folder as arg)"            "ls \"$KEEPER_FOLDER\""
try_candidate "ls -v (verbose, folder as arg)"       "ls -v \"$KEEPER_FOLDER\""
try_candidate "search (title as pattern)"            "search \"$TEST_USER\""
try_candidate "search --format=json"                 "search \"$TEST_USER\" --format=json"

banner "CREATING the test record"
fake_priv_b64="$(printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\nFAKE\n-----END OPENSSH PRIVATE KEY-----\n' | base64 | tr -d '\n')"
cmd="record-add --title \"$TEST_USER\" --record-type login --force --folder \"$KEEPER_FOLDER\""
cmd="$cmd \"login=$TEST_USER\" \"c.secret.private_key_b64=$fake_priv_b64\""
"$KEEPER_CLI" --config="$KEEPER_CONFIG" "$cmd"

banner "AFTER: which of these NOW contain '$TEST_USER'?"
try_candidate "ls (plain, folder as arg)"            "ls \"$KEEPER_FOLDER\""
try_candidate "ls -v (verbose, folder as arg)"       "ls -v \"$KEEPER_FOLDER\""
try_candidate "search (title as pattern)"            "search \"$TEST_USER\""
try_candidate "search --format=json"                 "search \"$TEST_USER\" --format=json"

banner "CLEANUP"
"$KEEPER_CLI" --config="$KEEPER_CONFIG" "rm -f \"$KEEPER_FOLDER/$TEST_USER\"" 2>&1 \
  || echo "(cleanup failed - delete '$TEST_USER' from '$KEEPER_FOLDER' by hand)"

banner "WHAT TO DO NEXT"
cat <<'EOF'
Look at the four "AFTER" results above. Whichever one correctly went from
"CONTAINS: no" (before) to "CONTAINS: yes" (after), and ideally is JSON (the
"--format=json" ones), is the one to wire into the real check. Tell me which
one(s) worked and I'll update the script to match.
EOF
