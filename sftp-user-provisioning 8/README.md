# SFTP user provisioning (AWS Transfer Family + Terraform + Keeper)

Creates SFTP users on an **existing** Transfer Family server, each locked into
their own folder of an **existing** S3 bucket, and stores each user's private
key in Keeper. The list of users lives in one file, `users.yaml`. Everything
runs from your own machine - there is no CI/CD pipeline.

## What this does (short version)

1. You add users (name + S3 folder path) to `users.yaml`.
2. You run `provision-all.sh`, which reads the file, checks it, and provisions
   each user that doesn't already exist.
3. For each new user:
   - an RSA (4096-bit) SSH keypair is generated under `$TMPDIR` (`/tmp` by
     default) and shredded - overwritten, then deleted - the moment the run
     ends, success or failure
   - Terraform creates the user, attaches the public key, and adds a policy
     limiting the user to their own S3 folder
   - the script logs in over SFTP with the new private key to prove it works
   - only if that login succeeds is the private key stored in Keeper (via the
     Commander CLI)
   - if anything fails after the user is created, the user is deleted again
     so a re-run starts clean
4. The script prints what it's doing at every step (`==> ...` lines), and a
   summary of created / skipped / failed users at the end.

| File | Role |
|---|---|
| `users.yaml` | the list of users you edit |
| `scripts/provision-all.sh` | reads and validates `users.yaml`, loops over users |
| `scripts/provision-user.sh` | one user: skip check, keygen, Terraform, login test, Keeper |
| `terraform/` | generic module: Transfer user, SSH key, per-user scope-down policy |

Each user has its own Terraform state file, so provisioning one user never
touches another user's state.

## One-time setup

### 1. Tools

Install these on the machine you'll run the scripts from:

```bash
# AWS CLI, Terraform >= 1.10, jq, sftp client, ssh-keygen
# mikefarah yq v4 (NOT the python 'yq' package)
brew install awscli terraform jq yq        # macOS
# or on Ubuntu/Debian/WSL:
sudo apt install awscli jq openssh-client
sudo wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
sudo chmod +x /usr/local/bin/yq
# Terraform: https://developer.hashicorp.com/terraform/install
```

Check `yq --version` says `mikefarah/yq` - the Python `yq` package (`pip
install yq`) has different syntax and will not work here.

Your local AWS credentials (`aws configure`, an SSO profile, or
`AWS_PROFILE`) need permissions to manage Transfer Family users and read/write
the Terraform state bucket. See "AWS permissions" below.

### 2. Terraform state bucket

Any private, versioned, encrypted S3 bucket, separate from your SFTP data
bucket. Terraform >= 1.10 uses S3 native locking, so no DynamoDB table is
needed. Each user gets their own state file at
`s3://<TF_STATE_BUCKET>/sftp-users/<user>.tfstate`.

### 3. AWS permissions

Whatever AWS identity you run the scripts as (an IAM user or an assumed
role) needs:

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

`YOUR_TRANSFER_ROLE` is the existing IAM role Transfer Family assumes to
reach S3 (a different role from the one running these scripts).

### 4. Keeper setup (Commander CLI)

If you already have `keepercommander` installed and a `config.json` with a
persistent login session set up, skip straight to pointing the scripts at it:

```bash
export KEEPER_CONFIG=/path/to/your/config.json
```

**Starting from scratch:** Commander installs without admin rights as a
normal pip package - a virtualenv is optional, not required:

```bash
pip3 install --user keepercommander
```

Log in once, interactively, and turn on a persistent session so later runs
don't need to prompt for a password/2FA:

```bash
keeper shell
# at the "My Vault>" prompt:
this-device register
this-device persistent-login on
this-device timeout 30d
quit
```

This writes a `config.json` in your current directory (or pass
`--config=path/to/config.json` to control where). **Never commit this file**
- it holds a device token that keeps you logged in. It's already covered by
`.gitignore`, but keep it out of the repo folder entirely if you can, e.g.
`~/.keeper/sftp-provisioning-config.json`.

Each user's key is stored as a Keeper record titled `sftp/<user_name>` (login
type, with the private key in a masked custom field, the public key and S3
path in plain custom fields). Change the `sftp/` prefix with
`KEEPER_RECORD_PREFIX`, or file records in a specific folder with
`KEEPER_FOLDER`.

> **The exact Commander CLI syntax used in the script (`get ... --format=json`,
> `record-add ...`) is based on Keeper's published docs, not verified against
> a live vault here.** Test it on one throwaway user first (see below). If a
> command errors, run the same command by hand inside `keeper --config=... shell`
> to see Commander's own error, and tell me what it says - the two Keeper
> functions in `provision-user.sh` are isolated and easy to adjust.

## Running it

```bash
export AWS_REGION=ap-south-1
export TRANSFER_SERVER_ID=s-0123456789abcdef0
export S3_BUCKET=my-sftp-bucket
export TRANSFER_ROLE_ARN=arn:aws:iam::123456789012:role/transfer-s3-role
export TF_STATE_BUCKET=my-tf-state
export KEEPER_CONFIG=/path/to/your/config.json   # not needed for validate/plan

bash scripts/provision-all.sh validate   # check users.yaml only, no cloud access
bash scripts/provision-all.sh plan       # + terraform plan per user, nothing created
bash scripts/provision-all.sh apply      # create the users for real
```

**Test with one throwaway user first.** Add a single entry to `users.yaml`,
run `plan`, read the output, then run `apply` and watch it go through each
step. Once that works end to end, add the rest of your users.

`users.yaml` behaviour:
- **Additive.** A user that already exists with the same path is skipped, so
  finished entries can stay in the file.
- **Existing users are never changed.** If an existing user's path differs
  from the file, that user fails with a clear error instead of being modified.
- **Removing an entry does not delete the user** (see "Removing a user").

Validation is intentionally minimal: every entry needs a non-empty `name`
and `path`, and no two entries can share a name. That's it - it's a basic
sanity check, not a strict schema. Note that this means a `path` containing
`..` is no longer rejected; Terraform still only ever touches the S3 location
you give it, but it's worth knowing this check is gone if `users.yaml` is
ever populated from somewhere less trusted than your own hands.

## Using the key afterwards

```bash
keeper --config="$KEEPER_CONFIG" 'get "sftp/acme" --format=json' | jq .
# or, interactively:
keeper shell
My Vault> get sftp/acme
```

Copy the `private_key` field out to a file with `chmod 600` before using it
with `sftp -i`.

## Design notes

### Why keys are generated by the script, not by Terraform

Terraform *can* generate an SSH key pair itself (the `tls_private_key`
resource), which would cut a chunk of shell code. It isn't used here for one
reason: **`tls_private_key` stores the private key in the Terraform state
file**, in the clear as far as Terraform is concerned. That state file lives
in S3 for every user. Anyone who can read the state bucket could then read
every user's private key - which defeats the entire point of storing keys in
Keeper.

The trade-off if you wanted that anyway: state-bucket access would need to be
locked down as tightly as Keeper access itself, and the "only store the key
after the login test passes" requirement would need a `local-exec`
provisioner instead of the script's own test step, with weaker rollback (a
failed `local-exec` leaves the user created rather than triggering a full
destroy). Given the private key is the most sensitive thing this whole setup
produces, keeping it out of any Terraform state seemed worth the extra shell
code. Happy to switch this if you'd rather have it in Terraform - say the
word.

### Why Keeper access uses the Commander CLI

Commander installs without admin rights (`pip3 install --user keepercommander`,
no venv required) and can be scripted non-interactively once persistent login
is set up, which fits running everything locally. Keeper Secrets Manager (KSM) would be
a more "designed for automation" fit, but needs an Application/API access
that wasn't available.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `yq is not installed` / `wrong yq` | Install mikefarah/yq v4; the python `yq` package won't work. |
| `already exists but points to ...` | The user exists with a different path than `users.yaml`. The script never edits users: fix the file or change the user by hand. |
| `AccessDenied` on `transfer:CreateUser` / `iam:PassRole` | Your local AWS identity is missing a permission from "AWS permissions" above. |
| `AccessDenied` on the state bucket | Missing `s3:GetObject`/`PutObject`/`DeleteObject` on `sftp-users/*`, or `s3:ListBucket` on the bucket. |
| `Error acquiring the state lock` | A previous run was killed mid-way. Remove the leftover `.tflock` object for that user in the state bucket. |
| `keeper: command not found` | It's not on `PATH` (common with `pip3 install --user`, or if it's in a venv you haven't activated). Set `KEEPER_CLI` to its full path instead, e.g. `export KEEPER_CLI=~/.local/bin/keeper`. |
| Keeper commands error or return nothing | Commander's exact output/exit codes weren't verified here - see the note in "Keeper setup". Run the same command by hand in `keeper shell` to see the real error, and share it so the script can be adjusted. |
| `login attempt 1/6 failed ...` six times, then rollback | Your machine can't reach the SFTP endpoint (VPC-only or IP-restricted server), or the server doesn't allow SSH key login. The user is deleted again automatically. |
| Key material left behind after a crash | Shouldn't happen (the cleanup trap runs even on failure), but if a run is killed with `kill -9` or the machine loses power mid-run, check `$TMPDIR` for a leftover `sftp-user.*` folder and delete it by hand. |
| `this configuration doesn't support terraform version ...` | Your local Terraform is older than 1.10. Upgrade it (the state backend uses a 1.10+ feature), or ask to switch the backend to DynamoDB locking if you need to stay on an older version. |

## Removing a user

Kept out of the scripts on purpose, so running `apply` again can never
delete access by accident. Delete the user from the Transfer server
(`terraform destroy` with the same state key, or the console/CLI), delete
the Keeper record (`sftp/<user>`), delete the state object
`sftp-users/<user>.tfstate`, and remove the entry from `users.yaml`
(otherwise the next run would create it again).
