#!/usr/bin/env bash
#
# Provision ONE SFTP user end to end. LOCAL USE ONLY (no CI/CD).
#
#   provision-user.sh plan  <user> <path>   checks + terraform plan, changes nothing
#   provision-user.sh apply <user> <path>   creates the user for real
#
# apply order (nothing irreversible happens before the checks pass):
#   1. check the user: already there with the same path -> skip (exit 10);
#      already there with a different path -> error; and no record in
#      Keeper yet for this user
#   2. generate an RSA SSH keypair in RAM (/dev/shm)
#   3. terraform apply  (user + public key + scope-down policy)
#   4. test the SFTP login with the private key
#   5. only then: store the private key in Keeper via Commander CLI
# If anything fails after step 3 the user is destroyed again, so a re-run
# starts clean. Existing users are never modified.
#
# Required env : AWS_REGION TRANSFER_SERVER_ID S3_BUCKET TRANSFER_ROLE_ARN TF_STATE_BUCKET
# apply also   : KEEPER_CONFIG - path to a Commander config.json with a
#                persistent login session already set up (see README)
# Optional     : KEY_TYPE (rsa|ed25519, default rsa, 4096-bit when rsa)
#                SFTP_HOST
#                KEEPER_CLI (default: keeper)
#                KEEPER_RECORD_PREFIX (default: sftp) - record titled "<prefix>/<user>"
#                KEEPER_FOLDER (optional Keeper folder to file the record in)
#                TMPDIR (default: /tmp) - where the keypair is briefly written;
#                shredded (overwritten, then unlinked) as soon as the run ends

set -euo pipefail

MODE="${1:?usage: $0 <plan|apply> <user> <path>}"
USER_NAME="${2:?usage: $0 <plan|apply> <user> <path>}"
USER_PATH="${3:?usage: $0 <plan|apply> <user> <path>}"

[[ "$MODE" == "plan" || "$MODE" == "apply" ]] || { echo "mode must be plan or apply" >&2; exit 2; }

: "${AWS_REGION:?}" "${TRANSFER_SERVER_ID:?}" "${S3_BUCKET:?}" "${TRANSFER_ROLE_ARN:?}" "${TF_STATE_BUCKET:?}"
if [[ "$MODE" == "apply" ]]; then : "${KEEPER_CONFIG:?}"; fi

KEY_TYPE="${KEY_TYPE:-rsa}"
SFTP_HOST="${SFTP_HOST:-${TRANSFER_SERVER_ID}.server.transfer.${AWS_REGION}.amazonaws.com}"
KEEPER_CLI="${KEEPER_CLI:-keeper}"
KEEPER_RECORD_PREFIX="${KEEPER_RECORD_PREFIX:-sftp}"
KEEPER_FOLDER="${KEEPER_FOLDER:-}"
RECORD_TITLE="${KEEPER_RECORD_PREFIX}/${USER_NAME}"

TF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../terraform" && pwd)"
export TF_IN_AUTOMATION=1
export TF_VAR_aws_region="$AWS_REGION"
export TF_VAR_server_id="$TRANSFER_SERVER_ID"
export TF_VAR_bucket_name="$S3_BUCKET"
export TF_VAR_role_arn="$TRANSFER_ROLE_ARN"

log() { printf '[%s] ==> %s\n' "$USER_NAME" "$*"; }
die() { printf '[%s] ERROR: %s\n' "$USER_NAME" "$*" >&2; exit 1; }

log "starting (mode=$MODE, path=$USER_PATH, key type=$KEY_TYPE)"

log "checking required tools are installed"
for bin in aws terraform jq sftp ssh-keygen "$KEEPER_CLI"; do
  command -v "$bin" >/dev/null || die "'$bin' is not installed or not on PATH"
done

KEY_BASE="${TMPDIR:-/tmp}"
KEY_BASE="${KEY_BASE%/}"
[[ -d "$KEY_BASE" ]] || die "temp directory '$KEY_BASE' does not exist"
log "keypair will be generated under $KEY_BASE and shredded when this run ends"

WORK="$(mktemp -d "$KEY_BASE/sftp-user.XXXXXX")"
chmod 700 "$WORK"
KEY="$WORK/id"
VARS="$WORK/users.tfvars.json"

TF_CREATED=0        # 1 while a user exists that has not been fully delivered
KEEPER_WRITTEN=0

tf() { terraform -chdir="$TF_DIR" "$@"; }

cleanup() {
  local rc=$?
  trap - EXIT

  if [[ $rc -ne 0 ]]; then
    if [[ $TF_CREATED -eq 1 ]]; then
      log "failed after creating the user - rolling back"
      tf destroy -auto-approve -input=false -var-file="$VARS" \
        || log "ROLLBACK FAILED: delete user '$USER_NAME' and state key sftp-users/$USER_NAME.tfstate by hand"
    fi
    if [[ $KEEPER_WRITTEN -eq 1 ]]; then
      log "removing the Keeper record written for this failed run"
      "$KEEPER_CLI" --config="$KEEPER_CONFIG" "rm -f \"$RECORD_TITLE\"" >/dev/null 2>&1 \
        || log "could not remove Keeper record '$RECORD_TITLE' - please delete it by hand"
    fi
  fi

  if [[ -f "$KEY" ]]; then
    log "shredding the private key (overwrite + unlink)"
    if command -v shred >/dev/null; then
      shred -u -z "$KEY" || rm -f "$KEY"
    else
      # no 'shred' on this system (e.g. some macOS setups) - best-effort overwrite
      dd if=/dev/urandom of="$KEY" bs=1024 count="$(( ($(wc -c <"$KEY") / 1024) + 1 ))" conv=notrunc 2>/dev/null
      rm -f "$KEY"
    fi
  fi
  rm -f "$KEY.pub" 2>/dev/null
  rm -rf "$WORK"
  exit "$rc"
}
trap cleanup EXIT

# ----------------------------------------------------------------- Keeper ---
# Thin wrapper around the Commander CLI, run non-interactively with a
# persistent-login config file (see README - "Keeper setup").
# NOTE: exact command syntax can vary a little between Commander versions.
# If a call here doesn't match your version, run the same command inside
# `keeper --config="$KEEPER_CONFIG" shell` by hand to see the right form,
# and adjust the two functions below.
keeper() {
  "$KEEPER_CLI" --config="$KEEPER_CONFIG" "$1"
}

keeper_record_exists() {
  log "checking Keeper for an existing record titled '$RECORD_TITLE'"
  local out
  if out="$(keeper "get \"$RECORD_TITLE\" --format=json" 2>&1)" && [[ "$out" == \{* ]]; then
    return 0
  fi
  return 1
}

keeper_store_key() {
  log "writing the private key to Keeper as '$RECORD_TITLE'"
  local priv pub cmd folder_arg=""
  priv="$(cat "$KEY")"
  pub="$(cat "$KEY.pub")"
  [[ -n "$KEEPER_FOLDER" ]] && folder_arg=" --folder \"$KEEPER_FOLDER\""

  cmd="record-add --title \"$RECORD_TITLE\" --record-type login --force$folder_arg"
  cmd="$cmd \"login=$USER_NAME\""
  cmd="$cmd \"c.text.path=$USER_PATH\""
  cmd="$cmd \"c.text.public_key=$pub\""
  cmd="$cmd \"c.secret.private_key=$priv\""

  "$KEEPER_CLI" --config="$KEEPER_CONFIG" "$cmd" >/dev/null
  KEEPER_WRITTEN=1

  keeper_record_exists || die "record was written but a lookup right after didn't find it - check it manually in Keeper"
}

# ------------------------------------------------------------ pre-checks ----
check_existing_user() {
  log "checking whether Transfer Family user '$USER_NAME' already exists"
  local out current expected
  if out="$(aws transfer describe-user --region "$AWS_REGION" --output json \
    --server-id "$TRANSFER_SERVER_ID" --user-name "$USER_NAME" 2>&1)"; then
    current="$(jq -r '.User.HomeDirectoryMappings[0].Target // .User.HomeDirectory // ""' <<<"$out")"
    current="${current%/}"
    expected="/${S3_BUCKET}/${USER_PATH}"
    if [[ "$current" == "$expected" ]]; then
      log "already exists with the same path - skipping"
      exit 10 # provision-all.sh treats this as "already exists, nothing to do"
    fi
    die "already exists but points to '$current' while users.yaml says '$expected'. The pipeline never changes existing users: fix users.yaml or change the user by hand"
  elif [[ "$out" != *ResourceNotFoundException* ]]; then
    die "could not check whether the user exists: $out"
  fi
}

# --------------------------------------------------------------- steps ------
generate_keys() {
  log "generating a fresh $KEY_TYPE keypair in $WORK (shredded on exit, see cleanup below)"
  local bits=()
  if [[ "$KEY_TYPE" == "rsa" ]]; then bits=(-b 4096); fi
  ssh-keygen -q -t "$KEY_TYPE" ${bits[@]+"${bits[@]}"} -N "" -C "sftp-${USER_NAME}" -f "$KEY"
  chmod 600 "$KEY"
}

write_tfvars() {
  jq -n --arg user "$USER_NAME" --arg pub "$KEY.pub" --arg path "$USER_PATH" \
    '{users: {($user): {public_key_path: $pub, home_directory_target: $path}}}' >"$VARS"
}

tf_init() {
  log "initializing terraform (state: s3://$TF_STATE_BUCKET/sftp-users/${USER_NAME}.tfstate)"
  tf init -input=false -reconfigure \
    -backend-config="bucket=$TF_STATE_BUCKET" \
    -backend-config="key=sftp-users/${USER_NAME}.tfstate" \
    -backend-config="region=$AWS_REGION" >/dev/null
}

test_connection() {
  log "testing the SFTP login with the new key against $SFTP_HOST"
  local attempt
  for attempt in 1 2 3 4 5 6; do
    if sftp -i "$KEY" -b - \
      -o BatchMode=yes -o IdentitiesOnly=yes -o ConnectTimeout=15 \
      -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$WORK/known_hosts" \
      "${USER_NAME}@${SFTP_HOST}" <<<"pwd" >/dev/null 2>"$WORK/sftp.err"; then
      log "SFTP login works"
      return 0
    fi
    log "login attempt $attempt/6 failed: $(tail -n 1 "$WORK/sftp.err")"
    sleep 10
  done
  return 1
}

# ---------------------------------------------------------------- main ------
check_existing_user

if [[ "$MODE" == "apply" ]] && keeper_record_exists; then
  die "Keeper already has a record titled '$RECORD_TITLE' - refusing to overwrite"
fi

generate_keys
write_tfvars
tf_init

if [[ "$MODE" == "plan" ]]; then
  log "running terraform plan (this key is throw-away, just so terraform has a public key to read)"
  tf plan -input=false -no-color -var-file="$VARS"
  exit 0
fi

log "running terraform apply"
TF_CREATED=1
tf apply -auto-approve -input=false -var-file="$VARS"

test_connection || die "could not log in with the new key"

keeper_store_key
TF_CREATED=0
KEEPER_WRITTEN=0
log "done: user created, login tested, private key stored in Keeper as '$RECORD_TITLE'"
