#!/usr/bin/env bash
#
# Read users.yaml, validate it, then provision each user in turn.
#
#   provision-all.sh validate   check users.yaml only, needs no cloud access
#   provision-all.sh plan       validate + terraform plan per user, changes nothing
#   provision-all.sh apply      create the users
#
# Config file: $CONFIG_FILE, default <repo>/users.yaml. Needs mikefarah yq v4 + jq.
#
# Every entry must have a name and a path. One bad entry stops the whole run
# before anything is created. Each user is then provisioned by a separate
# process, so one failing user does not stop the others; the exit code is
# non-zero if any user failed. provision-user.sh exits 10 for "already exists
# with the same path, skipped".

set -euo pipefail

MODE="${1:?usage: $0 <validate|plan|apply>}"
[[ "$MODE" == "validate" || "$MODE" == "plan" || "$MODE" == "apply" ]] \
  || { echo "mode must be validate, plan or apply" >&2; exit 2; }

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-$here/../users.yaml}"
EXIT_SKIPPED=10

fail() { echo "::error::$*" >&2; exit 1; }

[[ -f "$CONFIG_FILE" ]] || fail "config file not found: $CONFIG_FILE"
command -v jq >/dev/null || fail "jq is not installed"
command -v yq >/dev/null || fail "yq is not installed (https://github.com/mikefarah/yq)"
yq --version 2>&1 | grep -qi mikefarah || fail "wrong yq: this needs mikefarah/yq v4, not the python 'yq'"

# YAML -> JSON -> one "name:path" line per entry (names and paths can't contain ':').
lines="$(yq -o=json '.' "$CONFIG_FILE" | jq -r '
    (.users // []) as $u
    | if ($u | type) != "array" then error("users must be a list") else $u end
    | .[]
    | if type != "object" then error("each entry needs name and path") else . end
    | (keys - ["name", "path"]) as $extra
    | if ($extra | length) > 0 then error("unknown key(s): " + ($extra | join(", "))) else . end
    | "\(.name // ""):\(.path // "")"
  ')" || fail "could not read $CONFIG_FILE - it must look like:  users: [ {name: ..., path: ...} ]"

entries=()
seen=" "

while IFS= read -r entry; do
  [[ -z "$entry" ]] && continue

  user="${entry%%:*}"
  path="${entry#*:}"
  path="${path#/}"
  path="${path%/}"

  [[ "$user" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_@.-]{2,99}$ ]] \
    || fail "invalid user name '$user' (3-100 chars: letters, digits, _ @ . -)"
  [[ -n "$path" ]] || fail "user '$user' has no path - every user needs an explicit path"
  [[ "$path" =~ ^[a-zA-Z0-9._/-]+$ ]] \
    || fail "invalid path '$path' for '$user' (allowed: letters, digits, . _ - /)"
  [[ "$path" != *..* && "$path" != *//* ]] \
    || fail "invalid path '$path' for '$user' (no '..' or '//')"
  [[ "$seen" != *" $user "* ]] || fail "user '$user' is listed twice"

  seen+="$user "
  entries+=("$user $path")
done <<<"$lines"

if [[ ${#entries[@]} -eq 0 ]]; then
  echo "::notice::no users in $(basename "$CONFIG_FILE") - nothing to do"
  exit 0
fi

echo "Validated ${#entries[@]} user(s) from $(basename "$CONFIG_FILE"):"
printf '  %s\n' "${entries[@]}"

[[ "$MODE" != "validate" ]] || exit 0

created=()
skipped=()
failed=()

for entry in "${entries[@]}"; do
  user="${entry%% *}"
  path="${entry#* }"

  echo "::group::$MODE $user -> $path"
  rc=0
  bash "$here/provision-user.sh" "$MODE" "$user" "$path" || rc=$?
  case "$rc" in
    0) created+=("$user") ;;
    "$EXIT_SKIPPED") skipped+=("$user") ;;
    *) failed+=("$user") ;;
  esac
  echo "::endgroup::"
done

verb="Created"
[[ "$MODE" == "plan" ]] && verb="Would create"

echo
echo "$verb: ${created[*]:-none}"
echo "Skipped (already exist): ${skipped[*]:-none}"
echo "Failed: ${failed[*]:-none}"

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "### Result ($MODE)"
    echo "- $verb: ${created[*]:-none}"
    echo "- Skipped (already exist): ${skipped[*]:-none}"
    echo "- Failed: ${failed[*]:-none}"
  } >>"$GITHUB_STEP_SUMMARY"
fi

[[ ${#failed[@]} -eq 0 ]]
