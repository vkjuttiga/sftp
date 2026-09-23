#!/usr/bin/env bash
#
# Fetches the record and finds the private-key field ITSELF, regardless of
# exactly how Commander nests or names it - you don't need to read or paste
# any JSON. It prints only short, plain verdicts.
#
#   export KEEPER_CONFIG=/path/to/your/config.json
#   KEEPER_TEST_UID=YOUR_REAL_UID bash keeper-auto-detect.sh
#
# Needs jq. If jq isn't installed, it falls back to a much cruder grep-based
# search and tells you so.

set -uo pipefail
: "${KEEPER_CONFIG:?set KEEPER_CONFIG=/path/to/your/config.json}"
: "${KEEPER_TEST_UID:?set KEEPER_TEST_UID to a real uid, no brackets}"
KEEPER_CLI="${KEEPER_CLI:-keeper}"

echo "Fetching record $KEEPER_TEST_UID ..."
raw="$("$KEEPER_CLI" --config="$KEEPER_CONFIG" "get $KEEPER_TEST_UID --format=json" 2>&1)"

if [[ "$raw" != \{* && "$raw" != \[* ]]; then
  echo "VERDICT: the get command itself did not return JSON. Its output was:"
  echo "$raw"
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is not installed, falling back to a plain text search."
  echo
  if grep -qi "private_key_b64" <<<"$raw"; then
    echo "VERDICT: the text 'private_key_b64' DOES appear somewhere in the output."
    echo "Please install jq (brew install jq / apt install jq) so this script can"
    echo "pinpoint exactly where, automatically."
  else
    echo "VERDICT: the text 'private_key_b64' does NOT appear anywhere at all."
    echo "That means the field either wasn't saved under that name, or this UID"
    echo "isn't the record we created."
  fi
  exit 0
fi

echo "Parsed OK. Searching every object in the document for a field whose"
echo "label/name/type mentions 'private' ..."
echo

# Walk every OBJECT anywhere in the tree (not just leaves) and keep any that
# has a label/name/type key mentioning "private" - this matches whatever
# {label, value} / {name, value} / {type, value} shape Commander actually
# uses, without assuming which one in advance.
matches="$(jq -c '
  [.. | objects | select(
      (has("label") and (.label // "" | ascii_downcase | contains("private"))) or
      (has("name")  and (.name  // "" | ascii_downcase | contains("private"))) or
      (has("type")  and (.type  // "" | ascii_downcase | contains("private")))
    )]
' <<<"$raw" 2>&1)"

if [[ "$matches" == "[]" || -z "$matches" ]]; then
  echo "VERDICT: found NOTHING anywhere in the JSON with a label/name/type"
  echo "mentioning 'private'. That's unexpected - either this UID isn't the"
  echo "record we created, or the field genuinely never saved. Grab a fresh"
  echo "UID from keeper-find-uid.sh and try this script again with that one."
  exit 1
fi

count="$(jq 'length' <<<"$matches")"
echo "VERDICT: found $count matching field object(s)."
echo

best_path_desc=""
for i in $(seq 0 $((count-1))); do
  entry="$(jq -c ".[$i]" <<<"$matches")"
  label="$(jq -r '.label // .name // .type // "?"' <<<"$entry")"
  # .value is commonly an array like ["..."] but might be a bare string -
  # try both shapes.
  val="$(jq -r 'if (.value | type) == "array" then .value[0] else .value end' <<<"$entry" 2>/dev/null)"
  [[ -z "$val" || "$val" == "null" ]] && val=""

  echo "  FIELD: label/name/type = \"$label\""
  if [[ -n "$val" ]]; then
    decoded="$(printf '%s' "$val" | base64 -d 2>/dev/null || printf '%s' "$val" | base64 -D 2>/dev/null)"
    if [[ "$decoded" == *"PRIVATE KEY"* ]]; then
      echo "  ==> its value decodes (base64) to a PEM private key. THIS IS THE FIELD."
      best_path_desc="label \"$label\", decodes from base64"
    elif [[ "$val" == *"PRIVATE KEY"* ]]; then
      echo "  ==> its value IS already a PEM key (not base64-wrapped)."
      best_path_desc="label \"$label\", stored as plain text (not base64)"
    else
      echo "  ==> its value does not decode to a key (this is probably just the label match, not the data)"
    fi
  else
    echo "  ==> has no usable .value to check"
  fi
  echo
done

echo "=========================================="
if [[ -n "$best_path_desc" ]]; then
  echo "FINAL VERDICT: found it - $best_path_desc"
  echo "Tell me exactly that line and I'll fix the lookup filter to match."
else
  echo "FINAL VERDICT: found label(s) mentioning 'private' but none of their"
  echo "values decoded to an actual key. Tell me the FIELD lines printed above"
  echo "(the label names only, not values) and I'll take it from there."
fi
echo "=========================================="
