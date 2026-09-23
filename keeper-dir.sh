#!/usr/bin/env bash
#
# Isolates ONLY the folder-creation question: does piping "cd X" + "mkdir Y"
# into one non-interactive Commander invocation actually create Y inside X?
# Tries several different ways Commander might expect this, one at a time,
# and after EACH attempt independently re-lists the parent folder to check
# with a fresh command (not trusting exit codes) whether it actually worked.
#
#   export KEEPER_CONFIG=/path/to/your/config.json
#   export KEEPER_FOLDER="SFTP Keys"
#   bash keeper-mkdir-isolate.sh

set -uo pipefail

: "${KEEPER_CONFIG:?set KEEPER_CONFIG=/path/to/your/config.json}"
KEEPER_CLI="${KEEPER_CLI:-keeper}"
: "${KEEPER_FOLDER:?set KEEPER_FOLDER=\"the parent folder you already created\"}"

banner() { printf '\n========== %s ==========\n' "$1"; }

# Lists the parent folder FRESH (new invocation, no assumptions) and shows
# whether a given child name appears in the raw output.
check_child() {
  local child="$1"
  local out
  out="$("$KEEPER_CLI" --config="$KEEPER_CONFIG" "ls \"$KEEPER_FOLDER\"" 2>&1)"
  echo "RAW ls OUTPUT:"
  echo "$out"
  if grep -qF "$child" <<<"$out"; then
    echo "==> '$child' IS visible in the listing"
    return 0
  else
    echo "==> '$child' is NOT visible in the listing"
    return 1
  fi
}

cleanup_child() {
  local child="$1"
  "$KEEPER_CLI" --config="$KEEPER_CONFIG" "rmdir \"$KEEPER_FOLDER/$child\"" >/dev/null 2>&1
  "$KEEPER_CLI" --config="$KEEPER_CONFIG" "cd \"$KEEPER_FOLDER\" && rmdir \"$child\"" >/dev/null 2>&1
}

echo "Parent folder: $KEEPER_FOLDER"
banner "BASELINE: listing parent before anything"
"$KEEPER_CLI" --config="$KEEPER_CONFIG" "ls \"$KEEPER_FOLDER\"" 2>&1

# ---- Attempt A: two lines piped via stdin (what the smoke test did) ----
banner "ATTEMPT A: piped stdin, two lines"
name="isolate-A"
cleanup_child "$name"
cmd_out="$(printf 'cd "%s"\nmkdir "%s"\n' "$KEEPER_FOLDER" "$name" | "$KEEPER_CLI" --config="$KEEPER_CONFIG" 2>&1)"
echo "COMMAND OUTPUT:"; echo "$cmd_out"
check_child "$name"
cleanup_child "$name"

# ---- Attempt B: single command string with && ----
banner "ATTEMPT B: one command string joined with &&"
name="isolate-B"
cleanup_child "$name"
cmd_out="$("$KEEPER_CLI" --config="$KEEPER_CONFIG" "cd \"$KEEPER_FOLDER\" && mkdir \"$name\"" 2>&1)"
echo "COMMAND OUTPUT:"; echo "$cmd_out"
check_child "$name"
cleanup_child "$name"

# ---- Attempt C: single command string joined with ; ----
banner "ATTEMPT C: one command string joined with ;"
name="isolate-C"
cleanup_child "$name"
cmd_out="$("$KEEPER_CLI" --config="$KEEPER_CONFIG" "cd \"$KEEPER_FOLDER\"; mkdir \"$name\"" 2>&1)"
echo "COMMAND OUTPUT:"; echo "$cmd_out"
check_child "$name"
cleanup_child "$name"

# ---- Attempt D: mkdir with a --folder / -f style parent option, if Commander has one ----
banner "ATTEMPT D: mkdir --help (to see its actual supported options)"
"$KEEPER_CLI" --config="$KEEPER_CONFIG" "mkdir --help" 2>&1 || \
  "$KEEPER_CLI" --config="$KEEPER_CONFIG" "help mkdir" 2>&1

# ---- Attempt E: mkdir with the reserved-character escape from the ORIGINAL error ----
# The very first error said: character "/" is reserved. use "//" inside folder name.
# That phrasing suggests // might be Commander's own way of encoding a literal "/"
# WITHIN one name - try it both as "does this let mkdir make a nested path" (E1)
# and confirm it's actually just a literal slash IN a single folder's name (E2).
banner "ATTEMPT E1: mkdir with // exactly as the error suggested"
name="isolate-E1"
"$KEEPER_CLI" --config="$KEEPER_CONFIG" "mkdir \"$KEEPER_FOLDER//$name\"" 2>&1
check_child "$name" || true
"$KEEPER_CLI" --config="$KEEPER_CONFIG" "rmdir \"$KEEPER_FOLDER//$name\"" >/dev/null 2>&1

banner "DONE - compare the four ls listings above and tell me which ATTEMPT(s) actually showed the child folder"
