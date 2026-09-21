#!/usr/bin/env bash
#
# Provision ONE SFTP user end to end.
#
#   provision-user.sh plan  <user> <path>   checks + terraform plan, changes nothing
#   provision-user.sh apply <user> <path>   creates the user for real
#
# apply order (nothing irreversible happens before the checks pass):
#   1. check the user: already there with the same path -> skip (exit 10);
#      already there with a different path -> error; and no secret in Vault yet
#   2. generate SSH keypair in RAM (/dev/shm)
#   3. terraform apply  (user + public key + scope-down policy)
#   4. test the SFTP login with the private key
#   5. only then write the private key to Vault
# If anything fails after step 3 the user is destroyed again, so a re-run starts clean.
# Existing users are never modified.
#
# Required env : AWS_REGION TRANSFER_SERVER_ID S3_BUCKET TRANSFER_ROLE_ARN TF_STATE_BUCKET
# apply also   : VAULT_ADDR, plus either VAULT_TOKEN (local testing) or
#                VAULT_ROLE + GitHub OIDC (pipeline)
# Optional     : KEY_TYPE (ed25519|rsa, default ed25519)  SFTP_HOST
#                VAULT_NAMESPACE  VAULT_JWT_MOUNT (jwt)  VAULT_JWT_AUDIENCE (vault)
#                VAULT_KV_MOUNT (secret)  VAULT_KV_PREFIX (sftp)

set -euo pipefail

MODE="${1:?usage: $0 <plan|apply> <user> <path>}"
USER_NAME="${2:?usage: $0 <plan|apply> <user> <path>}"
USER_PATH="${3:?usage: $0 <plan|apply> <user> <path>}"

[[ "$MODE" == "plan" || "$MODE" == "apply" ]] || { echo "mode must be plan or apply" >&2; exit 2; }

: "${AWS_REGION:?}" "${TRANSFER_SERVER_ID:?}" "${S3_BUCKET:?}" "${TRANSFER_ROLE_ARN:?}" "${TF_STATE_BUCKET:?}"
if [[ "$MODE" == "apply" ]]; then : "${VAULT_ADDR:?}"; fi

KEY_TYPE="${KEY_TYPE:-ed25519}"
SFTP_HOST="${SFTP_HOST:-${TRANSFER_SERVER_ID}.server.transfer.${AWS_REGION}.amazonaws.com}"
VAULT_JWT_MOUNT="${VAULT_JWT_MOUNT:-jwt}"
VAULT_JWT_AUDIENCE="${VAULT_JWT_AUDIENCE:-vault}"
VAULT_KV_MOUNT="${VAULT_KV_MOUNT:-secret}"
VAULT_KV_PREFIX="${VAULT_KV_PREFIX:-sftp}"
SECRET_PATH="${VAULT_KV_PREFIX}/${USER_NAME}"

TF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../terraform" && pwd)"
export TF_IN_AUTOMATION=1
export TF_VAR_aws_region="$AWS_REGION"
export TF_VAR_server_id="$TRANSFER_SERVER_ID"
export TF_VAR_bucket_name="$S3_BUCKET"
export TF_VAR_role_arn="$TRANSFER_ROLE_ARN"

log() { printf '[%s] %s\n' "$USER_NAME" "$*"; }
die() { printf '[%s] ERROR: %s\n' "$USER_NAME" "$*" >&2; exit 1; }
summary() { if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then echo "$*" >>"$GITHUB_STEP_SUMMARY"; fi; }

EXIT_SKIPPED=10   # provision-all.sh treats this as "already exists, nothing to do"

for bin in aws terraform jq curl sftp ssh-keygen; do
  command -v "$bin" >/dev/null || die "'$bin' is not installed"
done
[[ -d /dev/shm ]] || die "/dev/shm not found - run this on Linux so keys never touch disk"

# Everything sensitive lives in RAM and is wiped on exit.
WORK="$(mktemp -d -p /dev/shm sftp-user.XXXXXX)"
chmod 700 "$WORK"
KEY="$WORK/id"
VARS="$WORK/users.tfvars.json"
HEADERS="$WORK/vault_headers"

TF_CREATED=0        # 1 while a user exists that has not been fully delivered
VAULT_WRITTEN=0
VAULT_MINTED=0      # 1 if we logged in ourselves (and so must revoke the token)

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
    if [[ $VAULT_WRITTEN -eq 1 ]]; then
      vault DELETE "$VAULT_KV_MOUNT/metadata/$SECRET_PATH" >/dev/null 2>&1 \
        || log "could not remove Vault secret $VAULT_KV_MOUNT/$SECRET_PATH - please delete it"
    fi
  fi

  if [[ $VAULT_MINTED -eq 1 ]]; then
    vault POST "auth/token/revoke-self" >/dev/null 2>&1 || true
  fi

  if [[ -f "$KEY" ]]; then shred -u "$KEY" 2>/dev/null || true; fi
  rm -rf "$WORK"
  exit "$rc"
}
trap cleanup EXIT

# ---------------------------------------------------------------- Vault ----
# Thin curl wrapper. The token goes in a header file, not on the command line.
vault() {
  local method="$1" path="$2"
  shift 2
  curl -sS --fail-with-body -X "$method" -H "@$HEADERS" "$@" "$VAULT_ADDR/v1/$path"
}

vault_login() {
  : >"$HEADERS"
  chmod 600 "$HEADERS"
  if [[ -n "${VAULT_NAMESPACE:-}" ]]; then
    echo "X-Vault-Namespace: $VAULT_NAMESPACE" >>"$HEADERS"
  fi

  if [[ -n "${VAULT_TOKEN:-}" ]]; then
    log "using the Vault token from VAULT_TOKEN"
    echo "X-Vault-Token: $VAULT_TOKEN" >>"$HEADERS"
    return
  fi

  : "${VAULT_ROLE:?set VAULT_ROLE (or VAULT_TOKEN for local runs)}"
  : "${ACTIONS_ID_TOKEN_REQUEST_URL:?not running in GitHub Actions with id-token: write}"

  local jwt resp
  jwt="$(curl -sS --fail -H "Authorization: Bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
    "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=${VAULT_JWT_AUDIENCE}" | jq -r .value)"

  resp="$(VAULT_ROLE="$VAULT_ROLE" JWT="$jwt" jq -n '{role: env.VAULT_ROLE, jwt: env.JWT}' \
    | vault POST "auth/${VAULT_JWT_MOUNT}/login" --data @-)"

  echo "X-Vault-Token: $(jq -r .auth.client_token <<<"$resp")" >>"$HEADERS"
  VAULT_MINTED=1
  log "logged in to Vault"
}

vault_secret_exists() {
  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' -H "@$HEADERS" \
    "$VAULT_ADDR/v1/$VAULT_KV_MOUNT/metadata/$SECRET_PATH")"
  case "$code" in
    200) return 0 ;;
    404) return 1 ;;
    000) die "cannot reach Vault at $VAULT_ADDR" ;;
    401|403) die "Vault refused the token (HTTP $code): it is expired/invalid, or its policy lacks read on $VAULT_KV_MOUNT/metadata/$VAULT_KV_PREFIX/*" ;;
    *) die "Vault answered HTTP $code while checking $VAULT_KV_MOUNT/$SECRET_PATH" ;;
  esac
}

vault_store_key() {
  # cas=0 means "create only if it does not exist yet", so we can never overwrite
  jq -n --rawfile priv "$KEY" --rawfile pub "$KEY.pub" \
    '{options: {cas: 0}, data: {private_key: $priv, public_key: $pub}}' \
    | vault POST "$VAULT_KV_MOUNT/data/$SECRET_PATH" --data @- >/dev/null
  VAULT_WRITTEN=1

  # read it back and make sure what Vault holds is what we generated
  vault GET "$VAULT_KV_MOUNT/data/$SECRET_PATH" | jq -j .data.data.private_key | cmp -s - "$KEY" \
    || die "private key read back from Vault does not match"
}

# ------------------------------------------------------------ pre-checks ----
check_existing_user() {
  local out current expected
  if out="$(aws transfer describe-user --region "$AWS_REGION" --output json \
    --server-id "$TRANSFER_SERVER_ID" --user-name "$USER_NAME" 2>&1)"; then
    current="$(jq -r '.User.HomeDirectoryMappings[0].Target // .User.HomeDirectory // ""' <<<"$out")"
    current="${current%/}"
    expected="/${S3_BUCKET}/${USER_PATH}"
    if [[ "$current" == "$expected" ]]; then
      log "already exists with the same path - skipping"
      summary "- \`$USER_NAME\`: already exists at \`$expected\`, skipped"
      exit "$EXIT_SKIPPED"
    fi
    die "already exists but points to '$current' while users.yaml says '$expected'. The pipeline never changes existing users: fix users.yaml or change the user by hand"
  elif [[ "$out" != *ResourceNotFoundException* ]]; then
    die "could not check whether the user exists: $out"
  fi
}

# --------------------------------------------------------------- steps ------
generate_keys() {
  local bits=()
  if [[ "$KEY_TYPE" == "rsa" ]]; then bits=(-b 4096); fi
  ssh-keygen -q -t "$KEY_TYPE" "${bits[@]}" -N "" -C "sftp-${USER_NAME}" -f "$KEY"
  chmod 600 "$KEY"
}

write_tfvars() {
  jq -n --arg user "$USER_NAME" --arg pub "$KEY.pub" --arg path "$USER_PATH" \
    '{users: {($user): {public_key_path: $pub, home_directory_target: $path}}}' >"$VARS"
}

tf_init() {
  tf init -input=false -reconfigure \
    -backend-config="bucket=$TF_STATE_BUCKET" \
    -backend-config="key=sftp-users/${USER_NAME}.tfstate" \
    -backend-config="region=$AWS_REGION" >/dev/null
}

test_connection() {
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

add_plan_to_summary() {
  [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] || return 0
  {
    echo "### \`$USER_NAME\` -> \`s3://$S3_BUCKET/${USER_PATH}/\`"
    echo '```'
    sed -n '/Terraform will perform/,$p' "$WORK/plan.txt"
    echo '```'
  } >>"$GITHUB_STEP_SUMMARY"
}

# ---------------------------------------------------------------- main ------
log "mode=$MODE path=$USER_PATH"

check_existing_user

if [[ "$MODE" == "apply" ]]; then
  vault_login
  if vault_secret_exists; then
    die "Vault already has $VAULT_KV_MOUNT/$SECRET_PATH - refusing to overwrite"
  fi
fi

generate_keys
write_tfvars
tf_init

if [[ "$MODE" == "plan" ]]; then
  # The key generated here is a throw-away, only there so terraform can read a
  # public key. The real key is generated again after approval.
  tf plan -input=false -no-color -var-file="$VARS" | tee "$WORK/plan.txt"
  add_plan_to_summary
  exit 0
fi

TF_CREATED=1
tf apply -auto-approve -input=false -var-file="$VARS"

test_connection || die "could not log in with the new key"

vault_store_key
TF_CREATED=0
VAULT_WRITTEN=0
log "done: user created, login tested, private key stored at $VAULT_KV_MOUNT/$SECRET_PATH"
