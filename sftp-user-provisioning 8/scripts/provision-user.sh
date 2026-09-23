#!/usr/bin/env bash
#
# Provision ONE SFTP user end to end. LOCAL USE ONLY (no CI/CD).
#
#   provision-user.sh plan  <user> <path>   checks + terraform plan, changes nothing
#   provision-user.sh apply <user> <path>   creates the user for real
#
# apply order (nothing irreversible happens before the checks pass):
#   1. check the user: not there -> create it below. Already there with the
#      same path AND a saved key on disk for it -> skip (exit 10). Already
#      there with the same path but NO saved key (a previous run got the
#      user created and then failed before the key was saved) -> resume:
#      redo steps 2-4 for that same user, replacing its unusable orphaned
#      key. Already there with a different path -> error.
#   2. generate an RSA SSH keypair under $TMPDIR
#   3. terraform apply  (user + public key)
#   4. test the SFTP login with the private key
#   5. only then: copy both keys into a permanent per-user folder under
#      SFTP_KEYS_DIR - upload to wherever you store secrets is a manual
#      step you do yourself afterwards
# If anything fails after step 3 the user (or, when resuming, just its new
# SSH key) is destroyed again, so a re-run starts clean either way. Existing
# users are never modified beyond attaching/replacing their SSH key.
#
# plan mode never generates a real keypair - it writes a placeholder public
# key, since that's all terraform plan needs to read.
#
# NOTE: unlike a purely in-memory design, this leaves real private keys
# sitting on disk under SFTP_KEYS_DIR until you move them somewhere else (or
# delete them) yourself. Keep that folder out of anywhere synced/backed up
# to somewhere you don't want key material, and don't commit it to git.
#
# Required env : AWS_REGION TRANSFER_SERVER_ID S3_BUCKET TRANSFER_ROLE_ARN TF_STATE_BUCKET
# Optional     : KEY_TYPE (rsa|ed25519, default rsa, 4096-bit when rsa)
#                SFTP_HOST
#                SFTP_KEYS_DIR (default: $HOME/Documents/sftp-keys) - each
#                user gets a subfolder here: SFTP_KEYS_DIR/<user_name>/
#                TMPDIR (default: /tmp) - where the keypair is briefly
#                generated before being copied into SFTP_KEYS_DIR

set -euo pipefail

MODE="${1:?usage: $0 <plan|apply> <user> <path>}"
USER_NAME="${2:?usage: $0 <plan|apply> <user> <path>}"
USER_PATH="${3:?usage: $0 <plan|apply> <user> <path>}"

[[ "$MODE" == "plan" || "$MODE" == "apply" ]] || { echo "mode must be plan or apply" >&2; exit 2; }

: "${AWS_REGION:?}" "${TRANSFER_SERVER_ID:?}" "${S3_BUCKET:?}" "${TRANSFER_ROLE_ARN:?}" "${TF_STATE_BUCKET:?}"

KEY_TYPE="${KEY_TYPE:-rsa}"
SFTP_HOST="${SFTP_HOST:-${TRANSFER_SERVER_ID}.server.transfer.${AWS_REGION}.amazonaws.com}"
SFTP_KEYS_DIR="${SFTP_KEYS_DIR:-$HOME/Documents/sftp-keys}"
SFTP_KEYS_DIR="${SFTP_KEYS_DIR%/}"
USER_KEY_DIR="$SFTP_KEYS_DIR/$USER_NAME"

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
for bin in aws terraform jq sftp ssh-keygen; do
  command -v "$bin" >/dev/null || die "'$bin' is not installed or not on PATH"
done

KEY_BASE="${TMPDIR:-/tmp}"
KEY_BASE="${KEY_BASE%/}"
[[ -d "$KEY_BASE" ]] || die "temp directory '$KEY_BASE' does not exist"

WORK="$(mktemp -d "$KEY_BASE/sftp-user.XXXXXX")"
chmod 700 "$WORK"
KEY="$WORK/id"
VARS="$WORK/users.tfvars.json"

TF_CREATED=0        # 1 while a user exists that has not been fully delivered
RESUME=0            # 1 = user already existed without a saved key; only
                     # finish that leftover work, don't treat this as a
                     # brand-new user for rollback purposes

tf() { terraform -chdir="$TF_DIR" "$@"; }

cleanup() {
  local rc=$?
  trap - EXIT

  if [[ $rc -ne 0 && $TF_CREATED -eq 1 ]]; then
    if [[ $RESUME -eq 1 ]]; then
      log "failed while resuming an existing user - rolling back just the new SSH key (the user itself pre-dates this run, so it's left alone)"
      tf destroy -auto-approve -input=false -var-file="$VARS" \
        -target="aws_transfer_ssh_key.this[\"$USER_NAME\"]" \
        || log "ROLLBACK FAILED: remove the SSH key you just tried to attach for user '$USER_NAME' by hand"
    else
      log "failed after creating the user - rolling back"
      tf destroy -auto-approve -input=false -var-file="$VARS" \
        || log "ROLLBACK FAILED: delete user '$USER_NAME' and state key sftp-users/$USER_NAME.tfstate by hand"
    fi
  fi

  # This is the transient copy in $WORK, not the permanent one in
  # SFTP_KEYS_DIR (that copy is made deliberately, in save_keys_locally, and
  # is meant to persist - see the NOTE at the top of this file).
  if [[ -f "$KEY" ]]; then
    if command -v shred >/dev/null; then
      shred -u -z "$KEY" || rm -f "$KEY"
    else
      dd if=/dev/urandom of="$KEY" bs=1024 count="$(( ($(wc -c <"$KEY") / 1024) + 1 ))" conv=notrunc 2>/dev/null
      rm -f "$KEY"
    fi
  fi
  rm -f "$KEY.pub" 2>/dev/null
  rm -rf "$WORK"
  exit "$rc"
}
trap cleanup EXIT

# ------------------------------------------------------------ pre-checks ----
check_existing_user() {
  log "checking whether Transfer Family user '$USER_NAME' already exists"
  local out current expected
  if out="$(aws transfer describe-user --region "$AWS_REGION" --output json \
    --server-id "$TRANSFER_SERVER_ID" --user-name "$USER_NAME" 2>&1)"; then
    current="$(jq -r '.User.HomeDirectoryMappings[0].Target // .User.HomeDirectory // ""' <<<"$out")"
    current="${current%/}"
    expected="/${S3_BUCKET}/${USER_PATH}"
    if [[ "$current" != "$expected" ]]; then
      die "already exists but points to '$current' while users.yaml says '$expected'. The pipeline never changes existing users: fix users.yaml or change the user by hand"
    fi

    # User exists at the right path. That alone doesn't mean it's finished -
    # a previous run can have created the user and then failed before the
    # key was saved. Only treat it as done if a key is already saved for it.
    if [[ "$MODE" == "apply" && ! -f "$USER_KEY_DIR/id_${KEY_TYPE}" ]]; then
      log "user exists but no saved key found at $USER_KEY_DIR - resuming: will generate a new key, attach it, test, and save it (the old, never-saved key is unusable and will be replaced)"
      RESUME=1
      return
    fi

    log "already exists with the same path and a saved key - skipping"
    exit 10 # provision-all.sh treats this as "already exists, nothing to do"
  elif [[ "$out" != *ResourceNotFoundException* ]]; then
    die "could not check whether the user exists: $out"
  fi
}

# --------------------------------------------------------------- steps ------
generate_keys() {
  log "generating a fresh $KEY_TYPE keypair in $WORK"
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

save_keys_locally() {
  log "saving the keypair to $USER_KEY_DIR"
  mkdir -p "$USER_KEY_DIR"
  chmod 700 "$USER_KEY_DIR"
  cp "$KEY" "$USER_KEY_DIR/id_${KEY_TYPE}"
  cp "$KEY.pub" "$USER_KEY_DIR/id_${KEY_TYPE}.pub"
  chmod 600 "$USER_KEY_DIR/id_${KEY_TYPE}"
  chmod 644 "$USER_KEY_DIR/id_${KEY_TYPE}.pub"
  # A small note to make manual upload easier later - not sensitive itself.
  printf 'user: %s\npath: %s\nserver: %s\n' "$USER_NAME" "$USER_PATH" "$SFTP_HOST" \
    >"$USER_KEY_DIR/info.txt"
}

# ---------------------------------------------------------------- main ------
check_existing_user

if [[ "$MODE" == "plan" ]]; then
  log "writing a placeholder public key (plan only needs terraform to read *a* public key file - no real keypair is generated until apply)"
  printf 'ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000 plan-placeholder-not-a-real-key\n' >"$KEY.pub"
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

test_connection || die "could not log in with the new key"

save_keys_locally
TF_CREATED=0
if [[ $RESUME -eq 1 ]]; then
  log "done: existing user's key regenerated, login tested, keypair saved to $USER_KEY_DIR"
else
  log "done: user created, login tested, keypair saved to $USER_KEY_DIR"
fi
