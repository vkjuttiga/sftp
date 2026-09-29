#!/usr/bin/env bash
#
# Reads users.yaml (or delete.yaml, for delete) and provisions or deletes
# each user via provision-user.sh. See README for setup and details.
#
#   provision-all.sh validate|plan|apply|delete

set -euo pipefail

MODE="${1:?usage: $0 <validate|plan|apply|delete>}"
[[ "$MODE" == "validate" || "$MODE" == "plan" || "$MODE" == "apply" || "$MODE" == "delete" ]] \
  || { echo "mode must be validate, plan, apply or delete" >&2; exit 2; }

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
default_file="$here/../users.yaml"
[[ "$MODE" == "delete" ]] && default_file="$here/../delete.yaml"
CONFIG_FILE="${CONFIG_FILE:-$default_file}"
EXIT_SKIPPED=10

log() { printf '==> %s\n' "$*"; }
fail() { echo "ERROR: $*" >&2; exit 1; }

log "mode=$MODE"
log "reading $CONFIG_FILE"

[[ -f "$CONFIG_FILE" ]] || fail "config file not found: $CONFIG_FILE"

log "checking for trailing whitespace"
bad_lines="$(grep -n '[[:space:]]$' "$CONFIG_FILE" || true)"
[[ -z "$bad_lines" ]] || fail "trailing whitespace on line(s):
$bad_lines"

# YAML -> JSON -> one "name:path" line per entry (names and paths can't contain ':').
log "parsing users.yaml"
lines="$(yq -o=json '.' "$CONFIG_FILE" | jq -r '
    (.users // []) as $u
    | if ($u | type) != "array" then error("users must be a list") else $u end
    | .[]
    | if type != "object" then error("each entry needs name and path") else . end
    | "\(.name // ""):\(.path // "")"
  ')" || fail "could not read $CONFIG_FILE - it must look like:  users: [ {name: ..., path: ...} ]"

names=()
paths=()
seen=" "

if [[ "$MODE" == "delete" ]]; then
  log "validating entries (name required, no duplicate names; path optional)"
else
  log "validating entries (name and path both required, no duplicate names)"
fi
while IFS= read -r entry; do
  [[ -z "$entry" ]] && continue

  user="${entry%%:*}"
  path="${entry#*:}"
  path="${path#/}"
  path="${path%/}"

  [[ -n "$user" ]] || fail "an entry is missing 'name'"
  if [[ "$MODE" != "delete" ]]; then
    [[ -n "$path" ]] || fail "user '$user' has no path - every user needs an explicit path"
  fi
  [[ "$seen" != *" $user "* ]] || fail "user '$user' is listed twice"

  seen+="$user "
  names+=("$user")
  paths+=("$path")
done <<<"$lines"

if [[ ${#names[@]} -eq 0 ]]; then
  log "no users in $(basename "$CONFIG_FILE") - nothing to do"
  exit 0
fi

log "validated ${#names[@]} user(s) from $(basename "$CONFIG_FILE"):"
for i in "${!names[@]}"; do
  if [[ -n "${paths[$i]}" ]]; then
    printf '  %s -> %s\n' "${names[$i]}" "${paths[$i]}"
  else
    printf '  %s\n' "${names[$i]}"
  fi
done

[[ "$MODE" != "validate" ]] || { log "validate-only mode, stopping here"; exit 0; }

created=()
skipped=()
failed=()

for i in "${!names[@]}"; do
  user="${names[$i]}"
  path="${paths[$i]}"

  log "----- $user -----"
  if [[ -n "$path" ]]; then
    log "$MODE '$user' -> '$path'"
  else
    log "$MODE '$user'"
  fi
  rc=0
  bash "$here/provision-user.sh" "$MODE" "$user" "$path" || rc=$?
  case "$rc" in
    0) created+=("$user") ;;
    "$EXIT_SKIPPED") skipped+=("$user") ;;
    *) failed+=("$user") ;;
  esac
done

verb="Created"
[[ "$MODE" == "plan" ]] && verb="Would create"
[[ "$MODE" == "delete" ]] && verb="Deleted"

skip_label="Skipped (already exist)"
[[ "$MODE" == "delete" ]] && skip_label="Skipped (already gone)"

echo
log "$verb: ${created[*]:-none}"
log "$skip_label: ${skipped[*]:-none}"
log "Failed: ${failed[*]:-none}"

[[ ${#failed[@]} -eq 0 ]]
