# SFTP user provisioning (AWS Transfer Family + Terraform + Vault + GitHub Actions)

Creates SFTP users on an **existing** Transfer Family server, each locked into
their own folder of an **existing** S3 bucket, and stores each user's private
key in HashiCorp Vault. The list of users lives in one file, `users.yaml`.
Nothing is created until a human approves.

## What this does (short version)

A GitHub Actions pipeline that creates SFTP users on your existing AWS Transfer
Family server, driven by the list in `users.yaml`.

1. You add users (name + S3 folder path) to `users.yaml` and merge to `main`.
2. **validate** checks the file: every user has a path, no duplicates, no bad characters.
3. **plan** skips users that already exist and shows what Terraform will create for the rest.
4. A reviewer approves the run in GitHub (environment `sftp-production`).
5. **apply** handles each new user in turn:
   - logs in to Vault and confirms no secret exists for that user yet
   - generates an SSH key pair in RAM, so the key never touches disk
   - Terraform creates the user, attaches the public key, and adds a policy
     limiting the user to their own S3 folder
   - tests an SFTP login with the private key
   - only if the login works, stores the private key in Vault at `secret/sftp/<user>`
   - if anything fails after the user is created, the user is deleted again so a re-run starts clean

| File | Role |
|---|---|
| `users.yaml` | the only file you edit day to day |
| `.github/workflows/provision-sftp-users.yml` | validate, plan, approval, apply |
| `scripts/provision-all.sh` | reads and validates `users.yaml`, loops over users |
| `scripts/provision-user.sh` | one user: skip check, keygen, Terraform, login test, Vault |
| `terraform/` | generic module: Transfer user, SSH key, per-user scope-down policy |

Each user has its own Terraform state file, so adding one user never affects the others.

## users.yaml

```yaml
users:
  - name: acme
    path: acme/inbound
  - name: globex
    path: globex/drop
```

One user or many, same format. `name` is the SFTP user, `path` is the folder
inside the bucket they are locked into. There are no per-user Terraform
resources: Terraform is generic and the scripts feed it whatever is in the file.

How the file is treated:

- **Additive.** Users that already exist with the same path are skipped, so
  finished entries can stay in the file.
- **Existing users are never changed.** If an existing user's path differs from
  the file, that user fails with a clear error instead of being modified.
- **Removing an entry does not delete the user** (see "Removing a user").
- Every entry needs a path; typos in keys (`paht:`), duplicate names and bad
  paths are rejected before anything is created.

## How it works

```
PR touching users.yaml  -->  validate only (no cloud access)

push to main touching users.yaml   (or a manual run)
        |
        v
+---------------------------+
| validate                  |   users.yaml well formed?
+-------------+-------------+
              v
+---------------------------+
| plan (no approval)        |   per user: exists? -> skip. else terraform plan,
|                           |   shown in the run summary
+-------------+-------------+
              v
     >>> HUMAN APPROVAL <<<      GitHub environment "sftp-production"
              v
+---------------------------+
| apply                     |   for EACH new user:
|                           |     1. Vault login + "secret must not exist" check
|                           |     2. generate SSH keypair in RAM (/dev/shm)
|                           |     3. terraform apply (user + public key + policy)
|                           |     4. test SFTP login with the private key
|                           |     5. only now: write private key to Vault
|                           |   any failure after step 3 -> user is destroyed again
+---------------------------+
```

Design decisions worth knowing:

- **One terraform state per user** (`s3://<state-bucket>/sftp-users/<user>.tfstate`).
  A run that creates `globex` can never plan to delete `acme`, and a failed
  user can be rolled back without touching the others.
- **The private key never touches disk or GitHub.** It is generated in
  `/dev/shm`, and passed nowhere except the SFTP test and Vault. It is wiped on exit.
- **Vault is written last.** If the login test fails, nothing is in Vault, the
  user is destroyed, and a re-run starts clean. Vault writes use `cas=0`, so an
  existing secret can never be overwritten.
- **Two gates.** Changing `users.yaml` goes through your normal PR review, and
  the apply job then needs the environment approval.
- **The plan job uses a throw-away key** just so terraform can read a public key.
  The real key is generated after approval, so the apply job re-plans. The
  approval covers *what gets created*; the public key text in the plan is a placeholder.
- **Vault access is only granted to the approved job.** The token is an environment
  secret (option A) or the Vault role is bound to the `sftp-production` environment
  (option B), so an unapproved run cannot write secrets.

## Repo layout

```
users.yaml                                   the only file you edit day to day
.github/workflows/provision-sftp-users.yml   validate -> plan -> approval -> apply
scripts/provision-all.sh                     reads + validates users.yaml, loops over users
scripts/provision-user.sh                    skip check -> keygen -> terraform -> login test -> Vault
terraform/                                   generic module: transfer user, ssh key, scope-down policy
```

Runner/tooling needs: `aws`, `terraform` >= 1.10, `jq`, `curl`, `sftp`, `ssh-keygen`,
and **mikefarah `yq` v4** (preinstalled on GitHub's ubuntu runners; not the python `yq`).

## One-time setup

### 1. Terraform state bucket

Any private, versioned S3 bucket in the same account. Terraform >= 1.10 uses
S3 native locking, so no DynamoDB table is needed.

### 2. AWS: OIDC role for the pipeline

Create the GitHub OIDC provider once (`token.actions.githubusercontent.com`,
audience `sts.amazonaws.com`), then a role, e.g. `github-sftp-provisioner`.

Trust policy. Note the **two** subjects: a job that uses an `environment` gets a
different `sub` claim than one that doesn't.

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Federated": "arn:aws:iam::ACCOUNT_ID:oidc-provider/token.actions.githubusercontent.com" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": { "token.actions.githubusercontent.com:aud": "sts.amazonaws.com" },
      "StringLike": {
        "token.actions.githubusercontent.com:sub": [
          "repo:YOUR_ORG/YOUR_REPO:ref:refs/heads/main",
          "repo:YOUR_ORG/YOUR_REPO:environment:sftp-production"
        ]
      }
    }
  }]
}
```

Permissions policy (replace the placeholders):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "TransferUsers",
      "Effect": "Allow",
      "Action": [
        "transfer:CreateUser", "transfer:UpdateUser", "transfer:DeleteUser",
        "transfer:DescribeUser", "transfer:ImportSshPublicKey", "transfer:DeleteSshPublicKey",
        "transfer:TagResource", "transfer:UntagResource", "transfer:ListTagsForResource"
      ],
      "Resource": [
        "arn:aws:transfer:REGION:ACCOUNT_ID:server/SERVER_ID",
        "arn:aws:transfer:REGION:ACCOUNT_ID:user/SERVER_ID/*"
      ]
    },
    {
      "Sid": "PassTheSharedRole",
      "Effect": "Allow",
      "Action": "iam:PassRole",
      "Resource": "arn:aws:iam::ACCOUNT_ID:role/YOUR_TRANSFER_ROLE",
      "Condition": { "StringEquals": { "iam:PassedToService": "transfer.amazonaws.com" } }
    },
    {
      "Sid": "StateObjects",
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
      "Resource": "arn:aws:s3:::STATE_BUCKET/sftp-users/*"
    },
    {
      "Sid": "StateList",
      "Effect": "Allow",
      "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::STATE_BUCKET"
    }
  ]
}
```

### 3. Vault access (pick one)

The scripts talk to Vault through its **HTTP API** with `curl` (no Vault CLI on
the runner). These are the only calls made, all on KV v2 at `secret/`
(change with `VAULT_KV_MOUNT`):

| Call | Purpose |
|---|---|
| `GET  /v1/secret/metadata/sftp/<user>` | check the secret doesn't exist yet |
| `POST /v1/secret/data/sftp/<user>` | store `private_key` + `public_key` (`cas=0`: create only) |
| `GET  /v1/secret/data/sftp/<user>` | read back and compare with what was generated |
| `DELETE /v1/secret/metadata/sftp/<user>` | roll back if a later step fails |

Both options need this policy:

```bash
vault policy write sftp-provisioner - <<'EOF'
path "secret/data/sftp/*"     { capabilities = ["create", "read"] }
path "secret/metadata/sftp/*" { capabilities = ["read", "delete"] }
EOF
```

**Option A: a token you already have (simplest)**

1. Create a token with that policy (or check that yours has it):

   ```bash
   vault token create -policy=sftp-provisioner -period=768h -display-name=github-sftp
   ```

   Quick check that it works:

   ```bash
   curl -s -H "X-Vault-Token: $TOKEN" "$VAULT_ADDR/v1/auth/token/lookup-self" | jq .data.policies
   ```

2. In GitHub, add it as an **environment secret** named `VAULT_TOKEN` on the
   `sftp-production` environment (Settings > Environments > sftp-production >
   Environment secrets). Do not use a repository secret: an environment secret
   only exists in the approved apply job, so an unapproved run can't use it.
3. Leave the `VAULT_ROLE` variable unset.

The pipeline never revokes or renews this token. Watch its expiry: a periodic
token needs renewing before its period runs out, otherwise the apply job fails
with `Vault refused the token`. Give it the narrow policy above, not a root token.

**Option B: no stored token (GitHub OIDC / JWT login)**

Vault trusts GitHub's identity token, so nothing long-lived is stored anywhere.
Vault must be able to reach GitHub's discovery URL.

```bash
# once per Vault
vault auth enable jwt
vault write auth/jwt/config \
  oidc_discovery_url="https://token.actions.githubusercontent.com" \
  bound_issuer="https://token.actions.githubusercontent.com"

# only the approved (environment) job can log in
vault write auth/jwt/role/sftp-provisioner \
  role_type=jwt \
  user_claim=repository \
  bound_audiences=vault \
  bound_subject="repo:YOUR_ORG/YOUR_REPO:environment:sftp-production" \
  token_policies=sftp-provisioner \
  token_ttl=15m token_max_ttl=15m
```

Then set the `VAULT_ROLE` variable to `sftp-provisioner` and don't create a
`VAULT_TOKEN` secret. If `VAULT_TOKEN` is set it wins; otherwise this login is used.

In both options each user ends up at `secret/sftp/<user_name>` with the fields
`private_key` and `public_key`.

### 4. GitHub: the approval gate

1. **Settings > Environments > New environment** named exactly `sftp-production`.
2. Tick **Required reviewers** and add the people/teams who may approve.
   Optionally tick **Prevent self-review** and restrict **Deployment branches** to `main`.
3. Under **Settings > Secrets and variables > Actions > Variables** add:

| Variable | Example / meaning |
|---|---|
| `AWS_REGION` | `ap-south-1` |
| `AWS_PIPELINE_ROLE_ARN` | role from step 2 |
| `TRANSFER_SERVER_ID` | `s-0123456789abcdef0` |
| `S3_BUCKET` | bucket the users land in |
| `TRANSFER_ROLE_ARN` | existing shared IAM role Transfer Family assumes |
| `TF_STATE_BUCKET` | bucket from step 1 |
| `VAULT_ADDR` | `https://vault.example.com:8200` |
| `VAULT_ROLE` | `sftp-provisioner` (only for option B, JWT login) |
| `VAULT_NAMESPACE` | optional (HCP / Enterprise) |
| `VAULT_KV_MOUNT`, `VAULT_KV_PREFIX` | optional, default `secret` and `sftp` |
| `SFTP_HOST` | optional, only if you use a custom hostname |

The only secret is `VAULT_TOKEN`, and only for Vault option A: add it as an
**environment secret** on `sftp-production`. AWS always uses GitHub's OIDC token, so
no AWS keys are stored.

> Required reviewers on **private** repositories needs a paid GitHub plan
> (Team/Enterprise). Public repos have it for free.

## Test it manually first

Same scripts, run from a Linux shell that can reach the SFTP endpoint and Vault.
Point `CONFIG_FILE` at a scratch file so you don't touch the real `users.yaml`:

```bash
export AWS_REGION=ap-south-1
export TRANSFER_SERVER_ID=s-0123456789abcdef0
export S3_BUCKET=my-sftp-bucket
export TRANSFER_ROLE_ARN=arn:aws:iam::123456789012:role/transfer-s3-role
export TF_STATE_BUCKET=my-tf-state
export VAULT_ADDR=https://vault.example.com:8200
export VAULT_TOKEN="$(vault print token)"      # after: vault login ...

cat > /tmp/test-users.yaml <<'EOF2'
users:
  - name: testuser1
    path: test/testuser1
EOF2
export CONFIG_FILE=/tmp/test-users.yaml

bash scripts/provision-all.sh validate
bash scripts/provision-all.sh plan     # look at the plan
bash scripts/provision-all.sh apply    # creates the user for real
```

Once one user works end to end, use the pipeline.

The scripts keep keys in RAM (`/dev/shm`), which exists on Linux and WSL. On
**macOS or Git Bash** you get `/dev/shm not found`. For local testing only, run
with `ALLOW_DISK_KEYS=1` (keys are written to a temp folder and deleted on exit),
or use WSL/Linux/Docker. The GitHub runners are Linux, so the pipeline is unaffected.

## Adding users through the pipeline

1. Edit `users.yaml` and add one or more entries.
2. Open a PR. The **validate** job checks the file (no credentials needed).
3. Merge to `main`. The **plan** job runs; open the run and read its **Summary**:
   it lists, per user, what terraform will create or that the user is skipped.
4. The **apply** job shows *Waiting for review*. A reviewer opens the run,
   clicks **Review deployments**, ticks `sftp-production`, and approves (or rejects).
5. After approval each new user is created, login-tested, and stored in Vault.
   The final summary lists created / skipped / failed. One failing user does not
   stop the others; the run is marked failed if any user failed.

If a user failed, fix the cause and use **Actions > Run workflow** on `main`
(the file is already correct, so no new commit is needed). Users that already
succeeded are skipped.

Rules enforced before anything is created:

- User names: 3-100 characters (`a-z A-Z 0-9 _ @ . -`), no duplicates.
- Paths: letters, digits, `. _ - /`; no `..`, no `//`; leading/trailing `/` ignored.

## Using the key afterwards

```bash
# vault CLI
vault kv get -field=private_key secret/sftp/acme > /dev/shm/acme.key && chmod 600 /dev/shm/acme.key

# or plain HTTP
curl -s -H "X-Vault-Token: $VAULT_TOKEN" "$VAULT_ADDR/v1/secret/data/sftp/acme" \
  | jq -r .data.data.private_key > /dev/shm/acme.key && chmod 600 /dev/shm/acme.key

sftp -i /dev/shm/acme.key acme@s-0123456789abcdef0.server.transfer.ap-south-1.amazonaws.com
```

## Permissions: read this before handing users out

The per-user policy (`terraform/main.tf`) grants exactly what was asked for:
`s3:GetBucketLocation` on the bucket and `s3:DeleteObject` on the user's own
folder. AWS applies the **intersection** of that policy and the shared role's
policy, so with these defaults a user can log in but **cannot list, download or
upload**. That is why the login test only runs `pwd`.

If users need more, extend the lists (and make sure the shared role allows the
same actions):

```hcl
# terraform/variables.tf defaults, or pass -var
bucket_actions = ["s3:GetBucketLocation", "s3:ListBucket"]
object_actions = ["s3:DeleteObject", "s3:GetObject", "s3:PutObject"]
```

`s3:ListBucket` is granted on the whole bucket by this template. If users must
not see other folders' names, add a `Condition` on `s3:prefix` for that action.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `Not authorized to perform sts:AssumeRoleWithWebIdentity` | Trust policy `sub` doesn't match. The plan job uses `ref:refs/heads/<branch>`, the apply job uses `environment:sftp-production`. Run from `main` (push events and manual runs on `main` are covered). |
| `Vault refused the token (HTTP 401/403)` | Token expired/invalid, or its policy lacks the paths above. Check with the `lookup-self` call in step 3. |
| Vault login `permission denied` (option B) | `bound_subject` / `bound_audiences` on the JWT role don't match, or Vault can't reach GitHub's discovery URL. |
| Login test fails 6 times | Runner can't reach the SFTP endpoint (VPC-only or IP-restricted server: use a self-hosted runner), or the server isn't service-managed with SFTP enabled. |
| `already exists but points to ...` | The user exists with a different path than `users.yaml`. The pipeline never edits users: fix the file or change the user by hand. |
| `Vault already has ...` | A secret exists for a user that doesn't. Deliberate (never overwrites); delete the stale secret or pick another name. |
| `wrong yq` | The python `yq` is installed; you need mikefarah/yq v4. |
| Run did nothing after merge | The push didn't touch `users.yaml`, or the list is empty. |
| `ROLLBACK FAILED` in the log | Delete the user in Transfer Family and the state object `sftp-users/<user>.tfstate`, then re-run. |
| `Error acquiring the state lock` | A previous run is still going or was killed; remove the `.tflock` object for that user in the state bucket. |
| Approval never appears | Environment name isn't exactly `sftp-production`, or it has no required reviewers. |

## Removing a user

Kept out of the pipeline on purpose, so a bad merge can't delete access.
Delete the user from the Transfer server (`terraform destroy` with the same
state key, or the console/CLI), delete `secret/metadata/sftp/<user>` in Vault,
delete the state object `sftp-users/<user>.tfstate`, and remove the entry from
`users.yaml` (otherwise the next run would create it again).
