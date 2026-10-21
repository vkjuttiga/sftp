#!/usr/bin/env bash
#
# Provisions (or deletes) one SFTP user in AWS Transfer Family and its key
# in Keeper. No key material is ever written to disk. Called by
# provision-all.sh. See README for setup, env vars, and design notes.
#
#   provision-user.sh plan|apply <user> <path>
#   provision-user.sh delete <user> [path]

set -euo pipefail

MODE="${1:?usage: $0 <plan|apply> <user> <path>  |  $0 delete <user> [path]}"
USER_NAME="${2:?usage: $0 <plan|apply> <user> <path>  |  $0 delete <user> [path]}"

[[ "$MODE" == "plan" || "$MODE" == "apply" || "$MODE" == "delete" ]] \
  || { echo "mode must be plan, apply or delete" >&2; exit 2; }

if [[ "$MODE" == "delete" ]]; then
  USER_PATH="${3:-}"   # optional - skips the path safety check below when omitted
else
  USER_PATH="${3:?usage: $0 <plan|apply> <user> <path>}"
fi

: "${AWS_REGION:?}" "${TRANSFER_SERVER_ID:?}" "${S3_BUCKET:?}" "${TRANSFER_ROLE_ARN:?}" "${TF_STATE_BUCKET:?}"
[[ "$MODE" == "apply" || "$MODE" == "delete" ]] \
  && : "${KEEPER_CONFIG:?$MODE needs Keeper - it is the only place the key ends up}"

KEY_TYPE="${KEY_TYPE:-rsa}"
SFTP_HOST="${SFTP_HOST:-${TRANSFER_SERVER_ID}.server.transfer.${AWS_REGION}.amazonaws.com}"

KEEPER_CLI="${KEEPER_CLI:-keeper}"
KEEPER_FOLDER="${KEEPER_FOLDER:-}"
KEEPER_RECORD_PREFIX="${KEEPER_RECORD_PREFIX:-}"
RECORD_TITLE="${KEEPER_RECORD_PREFIX}${USER_NAME}"

TF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../terraform" && pwd)"
export TF_IN_AUTOMATION=1
export TF_VAR_aws_region="$AWS_REGION"
export TF_VAR_server_id="$TRANSFER_SERVER_ID"
export TF_VAR_bucket_name="$S3_BUCKET"
export TF_VAR_role_arn="$TRANSFER_ROLE_ARN"

log() { printf '[%s] ==> %s\n' "$USER_NAME" "$*"; }
die() { printf '[%s] ERROR: %s\n' "$USER_NAME" "$*" >&2; exit 1; }

log "starting: mode=$MODE path=$USER_PATH key=$KEY_TYPE"

# Prefer RAM; fall back to $TMPDIR if /dev/shm doesn't exist (e.g. macOS).
if [[ -d /dev/shm ]]; then
  KEY_BASE=/dev/shm
else
  KEY_BASE="${TMPDIR:-/tmp}"
  log "no /dev/shm on this system - using $KEY_BASE instead (still wiped on exit)"
fi

WORK="$(mktemp -d "$KEY_BASE/sftp-user.XXXXXX")"
chmod 700 "$WORK"
KEY="$WORK/id"
VARS="$WORK/users.tfvars.json"

TF_CREATED=0   # 1 once terraform has created something not yet rolled back

tf() { terraform -chdir="$TF_DIR" "$@"; }

cleanup() {
  local rc=$?
  trap - EXIT

  if [[ $rc -ne 0 && $TF_CREATED -eq 1 ]]; then
    log "rolling back - removing the user"
    tf destroy -auto-approve -input=false -var-file="$VARS" \
      || log "rollback failed - delete user '$USER_NAME' and its state by hand"
  fi

  if [[ -f "$KEY" ]]; then
    command -v shred >/dev/null && shred -u "$KEY" || rm -f "$KEY"
  fi
  rm -f "$KEY.pub"
  rm -rf "$WORK"
  exit "$rc"
}
trap cleanup EXIT

# `ls -l` on the folder is the confirmed-working way to see a UID next to
# a title - folder-scoped (unlike search, which spans the whole vault) and
# already proven in manual use. Tried first; `search`/`list`/`get` on the
# bare title are a fallback if it doesn't turn one up. Every candidate is
# still read-verified against the record before being trusted. Prints the
# verified UID (one per line if more than one truly matches) or nothing.
keeper_find_uid() {
  local candidates uid verified out line

  line="$("$KEEPER_CLI" --config="$KEEPER_CONFIG" "ls -l \"$KEEPER_FOLDER\"" 2>&1 | grep -F "$RECORD_TITLE")"
  candidates="$(grep -oE '[A-Za-z0-9_-]{20,}' <<<"$line" | sort -u)"

  if [[ -z "$candidates" ]]; then
    candidates="$(
      {
        "$KEEPER_CLI" --config="$KEEPER_CONFIG" "search \"$RECORD_TITLE\"" 2>&1
        "$KEEPER_CLI" --config="$KEEPER_CONFIG" "list --format=json \"$RECORD_TITLE\"" 2>&1
        "$KEEPER_CLI" --config="$KEEPER_CONFIG" "get \"$RECORD_TITLE\"" 2>&1
        "$KEEPER_CLI" --config="$KEEPER_CONFIG" "get \"$RECORD_TITLE\" --format=json" 2>&1
      } | grep -oE '[A-Za-z0-9_-]{20,}' | sort -u
    )"
  fi
  [[ -n "$candidates" ]] || return 1

  verified=""
  while IFS= read -r uid; do
    [[ -z "$uid" ]] && continue
    out="$("$KEEPER_CLI" --config="$KEEPER_CONFIG" "get $uid --format=json" 2>&1)"
    grep -qF "$RECORD_TITLE" <<<"$out" && verified="$verified
$uid"
  done <<<"$candidates"
  verified="$(sort -u <<<"$verified" | grep -v '^$')"
  [[ -n "$verified" ]] || return 1
  echo "$verified"
}

# Filed flat in KEEPER_FOLDER, titled with the username (see README - no
# per-user subfolder). The private key goes in twice: base64-encoded in a
# custom field (for scripted retrieval), and as a real file attachment
# named like a normal SSH key - so it can be downloaded as-is from the
# Keeper UI, no decoding needed. The attachment is best-effort: the field
# above is what resume-tracking relies on, so a failed attachment is logged
# but doesn't fail the whole upload.
keeper_upload_key() {
  log "uploading private key to Keeper as '$RECORD_TITLE'"
  local priv_b64 cmd out folder_arg=""
  priv_b64="$(base64 <"$KEY" | tr -d '\n')"
  [[ -n "$KEEPER_FOLDER" ]] && folder_arg=" --folder \"$KEEPER_FOLDER\""

  cmd="record-add --title \"$RECORD_TITLE\" --record-type login --force$folder_arg"
  cmd="$cmd \"login=$USER_NAME\" \"c.text.path=$USER_PATH\" \"c.secret.private_key_b64=$priv_b64\""

  if ! out="$("$KEEPER_CLI" --config="$KEEPER_CONFIG" "$cmd" 2>&1)"; then
    log "Keeper upload FAILED: $(tail -n 1 <<<"$out")"
    return 1
  fi

  local attach_file="$WORK/id_${KEY_TYPE}" attach_out uid
  cp "$KEY" "$attach_file"
  # upload-attachment's bare title always fails ("record UID not found" -
  # Commander treats the title text itself as a UID rather than resolving
  # it), so this goes straight to UID lookup rather than wasting a call.
  uid="$(keeper_find_uid | head -1)"
  if [[ -z "$uid" ]]; then
    log "WARNING: could not attach a downloadable copy - no UID found. Key is still in the private_key_b64 field"
  elif attach_out="$("$KEEPER_CLI" --config="$KEEPER_CONFIG" \
      "upload-attachment --file \"$attach_file\" $uid" 2>&1)"; then
    log "attached a downloadable copy of the key"
  else
    log "WARNING: could not attach a downloadable copy - $(tail -n 1 <<<"$attach_out"). Key is still in the private_key_b64 field"
  fi

  log "Keeper upload succeeded"
  return 0
}

# Keeper is the source of truth for "does this user already have a key" -
# not anything local, since someone else may have provisioned this user
# from a different machine. `ls <folder>` is scoped to that one folder,
# confirmed live - `list`/`search` weren't (list treats its argument as a
# search pattern, not a folder path; search spans the whole vault).
keeper_record_exists() {
  local out cmd="ls"
  [[ -n "$KEEPER_FOLDER" ]] && cmd="ls \"$KEEPER_FOLDER\""
  out="$("$KEEPER_CLI" --config="$KEEPER_CONFIG" "$cmd" 2>&1)" \
    || die "could not check Keeper for an existing record: $out"
  grep -qF "$RECORD_TITLE" <<<"$out"
}

# Deletes every verified UID (see keeper_find_uid above it) one at a time,
# rechecking the folder after each - some discovery methods search the
# whole vault, not just this one, so more than one can verify (e.g. a
# same-titled leftover elsewhere). Never guesses which single UID is right.
keeper_delete_record() {
  log "looking up the record's UID"
  local verified uid
  verified="$(keeper_find_uid)" || { log "no UID found for '$RECORD_TITLE'"; return 1; }

  while IFS= read -r uid; do
    [[ -z "$uid" ]] && continue
    keeper_record_exists || break   # already gone - an earlier candidate resolved it
    "$KEEPER_CLI" --config="$KEEPER_CONFIG" "rm -f $uid" >/dev/null 2>&1
  done <<<"$verified"

  if keeper_record_exists; then
    log "record still present after trying every verified UID"
    return 1
  fi
  return 0
}

check_existing_user() {
  log "checking if user '$USER_NAME' already exists"
  local out current expected
  if out="$(aws transfer describe-user --region "$AWS_REGION" --output json \
    --server-id "$TRANSFER_SERVER_ID" --user-name "$USER_NAME" 2>&1)"; then
    current="$(jq -r '.User.HomeDirectoryMappings[0].Target // .User.HomeDirectory // ""' <<<"$out")"
    current="${current%/}"
    expected="/${S3_BUCKET}/${USER_PATH}"
    [[ "$current" == "$expected" ]] \
      || die "exists but points to '$current', users.yaml says '$expected' - won't touch it"

    if [[ "$MODE" != "apply" ]]; then
      log "already exists - skipping"
      exit 10
    fi

    if keeper_record_exists; then
      log "already fully set up - skipping"
      exit 10 # provision-all.sh treats this as "nothing to do"
    fi

    log "user exists but has no record of a completed key upload - regenerating the key"
    return
  elif [[ "$out" != *ResourceNotFoundException* ]]; then
    die "could not check for the user: $out"
  fi
}

generate_keys() {
  log "generating $KEY_TYPE key pair"
  local bits=() fmt=()
  if [[ "$KEY_TYPE" == "rsa" ]]; then
    bits=(-b 4096)
    # Classic PEM format ("-----BEGIN RSA PRIVATE KEY-----"), not the newer
    # OpenSSH container format - several GUI SFTP clients (Cyberduck,
    # FileZilla, older WinSCP/PuTTY) only accept the former.
    fmt=(-m PEM)
  fi
  ssh-keygen -q -t "$KEY_TYPE" ${bits[@]+"${bits[@]}"} ${fmt[@]+"${fmt[@]}"} -N "" -C "sftp-${USER_NAME}" -f "$KEY"
  chmod 600 "$KEY"
}

write_tfvars() {
  log "writing terraform variables"
  jq -n --arg user "$USER_NAME" --arg pub "$KEY.pub" --arg path "$USER_PATH" \
    '{users: {($user): {public_key_path: $pub, home_directory_target: $path}}}' >"$VARS"
}

tf_init() {
  log "initializing terraform"
  tf init -input=false -reconfigure \
    -backend-config="bucket=$TF_STATE_BUCKET" \
    -backend-config="key=sftp-users/${USER_NAME}.tfstate" \
    -backend-config="region=$AWS_REGION" >/dev/null
}

test_connection() {
  log "testing SFTP login"
  local attempt
  for attempt in 1 2 3 4 5 6; do
    if sftp -i "$KEY" -b - \
      -o BatchMode=yes -o IdentitiesOnly=yes -o ConnectTimeout=15 \
      -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$WORK/known_hosts" \
      "${USER_NAME}@${SFTP_HOST}" <<<"pwd" >/dev/null 2>"$WORK/sftp.err"; then
      log "login works"
      return 0
    fi
    log "login attempt $attempt/6 failed: $(tail -n 1 "$WORK/sftp.err")"
    sleep 10
  done
  return 1
}

delete_user() {
  local out current expected found_in_aws=0 found_in_keeper=0

  log "checking whether '$USER_NAME' exists in Transfer Family"
  if out="$(aws transfer describe-user --region "$AWS_REGION" --output json \
    --server-id "$TRANSFER_SERVER_ID" --user-name "$USER_NAME" 2>&1)"; then
    if [[ -n "$USER_PATH" ]]; then
      current="$(jq -r '.User.HomeDirectoryMappings[0].Target // .User.HomeDirectory // ""' <<<"$out")"
      current="${current%/}"
      expected="/${S3_BUCKET}/${USER_PATH}"
      [[ "$current" == "$expected" ]] \
        || die "exists but points to '$current', delete.yaml says '$expected' - refusing to delete the wrong user"
    fi

    found_in_aws=1
    log "destroying AWS resources for '$USER_NAME'"
    printf 'ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC0 delete-placeholder\n' >"$KEY.pub"
    write_tfvars
    tf_init
    tf destroy -auto-approve -input=false -var-file="$VARS" \
      || die "terraform destroy failed for '$USER_NAME'"
  elif [[ "$out" == *ResourceNotFoundException* ]]; then
    log "not in Transfer Family - nothing to destroy there"
  else
    die "could not check for the user: $out"
  fi

  if keeper_record_exists; then
    found_in_keeper=1
    log "deleting Keeper record for '$USER_NAME'"
    keeper_delete_record || die "could not delete the Keeper record for '$USER_NAME'"
  else
    log "no Keeper record found for '$USER_NAME'"
  fi

  if [[ $found_in_aws -eq 0 && $found_in_keeper -eq 0 ]]; then
    log "nothing found in AWS or Keeper - already clean"
    exit 10
  fi
  log "done: '$USER_NAME' removed"
}

# ---------------------------------------------------------------- main ------
if [[ "$MODE" == "delete" ]]; then
  delete_user
  exit 0
fi

check_existing_user

if [[ "$MODE" == "plan" ]]; then
  log "writing a placeholder public key (plan only reads one, never a real key)"
  printf 'ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC0 plan-placeholder\n' >"$KEY.pub"
else
  generate_keys
fi
write_tfvars
tf_init

if [[ "$MODE" == "plan" ]]; then
  log "running terraform plan"
  tf plan -input=false -no-color -var-file="$VARS"
  exit 0
fi

log "running terraform apply"
TF_CREATED=1
tf apply -auto-approve -input=false -var-file="$VARS"

test_connection || die "login test failed"

keeper_upload_key || die "key upload failed - the user's new key doesn't exist anywhere now, so it's being rolled back"
TF_CREATED=0

log "done: user set up, login tested, key uploaded to Keeper and wiped locally"
