# AWS Transfer Family SFTP User — Terraform + Vault

Creates a single SFTP user on an **existing** AWS Transfer Family server and
attaches an SSH public key to it. The Transfer Family server, S3 bucket,
IAM role, and IAM role policy (`s3:GetBucketLocation` + `s3:DeleteObject`)
are assumed to already exist and are passed in as Terraform variables.

```
aws-sftp-user/
├── terraform/
│   ├── versions.tf
│   ├── variables.tf
│   ├── main.tf                    # aws_transfer_user + aws_transfer_ssh_key
│   ├── outputs.tf
│   └── terraform.tfvars.example
├── scripts/
│   ├── generate_ssh_key.sh
│   ├── upload_key_to_vault.sh
│   └── test_sftp_connection.sh
├── keys/                          # generated locally, gitignored — never committed
└── .github/workflows/sftp-user.yml
```

Add `keys/` to `.gitignore` before you commit anything — private keys must
never land in the repo.

---

## Phase 1 — Manual run (do this first)

### 1. Generate the SSH keypair

```bash
cd scripts
chmod +x generate_ssh_key.sh
./generate_ssh_key.sh vendor-acme ../keys
```

Produces `keys/vendor-acme_id_ed25519` (private) and
`keys/vendor-acme_id_ed25519.pub` (public).

### 2. Upload the private key to Vault

Requires `VAULT_ADDR` and `VAULT_TOKEN` set in your shell (or
`vault login` already done).

```bash
chmod +x upload_key_to_vault.sh
./upload_key_to_vault.sh vendor-acme ../keys/vendor-acme_id_ed25519
```

This writes to `secret/sftp/vendor-acme` by default (override with a 3rd
arg). Once you've confirmed it's readable in Vault, shred the local copy —
the script prints the command to do that.

### 3. Terraform: create the SFTP user + attach the public key

```bash
cd ../terraform
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars: server_id, role_arn, s3_bucket, user_name,
# public_key_path (point at the .pub file from step 1)

terraform init
terraform plan
terraform apply
```

Only the **public** key is ever referenced by Terraform (`aws_transfer_ssh_key.this`).
The private key never touches Terraform or state.

Note the `sftp_endpoint` output — you'll need it for the connection test.

### 4. Test the connection manually

Pull the private key back out of Vault (or use the local copy if you
haven't shredded it yet), then:

```bash
cd ../scripts
chmod +x test_sftp_connection.sh
./test_sftp_connection.sh vendor-acme \
  "$(terraform -chdir=../terraform output -raw sftp_endpoint)" \
  ../keys/vendor-acme_id_ed25519
```

It connects, runs `pwd` and `ls -la`, then disconnects. A clean run means
the user, role permissions, and key are all wired correctly.

---

## Phase 2 — GitHub Actions (once the manual flow works)

`.github/workflows/sftp-user.yml` reproduces the same two steps
(`terraform apply`, then connection test) as a `workflow_dispatch` job:

- **AWS auth**: OIDC via `aws-actions/configure-aws-credentials` —
  no long-lived AWS keys in GitHub. Set `secrets.AWS_DEPLOY_ROLE_ARN` and
  repo/environment variable `vars.AWS_REGION`.
- **Terraform vars**: pulled from repo/environment `vars` (`TRANSFER_SERVER_ID`,
  `TRANSFER_ROLE_ARN`, `TRANSFER_S3_BUCKET`) plus the `user_name` workflow input.
- **Public key for CI runs**: since key generation is a one-off manual step
  (Phase 1, step 1), commit only the `.pub` file to a private, key-only
  location the workflow can read — or generate it in a prior manual step
  and drop it wherever `public_key_path` in the plan step points. Do not
  commit the private key.
- **Vault access in CI**: `hashicorp/vault-action` authenticates via JWT/OIDC
  (`role: github-actions-sftp` — set this role up in Vault to trust GitHub's
  OIDC issuer, scoped to this repo). It reads the private key back out and
  writes it to a `/tmp` file with `umask 077`, runs the same
  `test_sftp_connection.sh` used in Phase 1, then shreds the key
  unconditionally (`if: always()`).

Required GitHub configuration before first run:

| Type | Name | Value |
|---|---|---|
| Secret | `AWS_DEPLOY_ROLE_ARN` | IAM role ARN GitHub OIDC assumes |
| Secret | `VAULT_ADDR` | Vault address reachable from GH runners |
| Variable | `AWS_REGION` | e.g. `us-east-1` |
| Variable | `TRANSFER_SERVER_ID` | existing server ID |
| Variable | `TRANSFER_ROLE_ARN` | existing IAM role ARN |
| Variable | `TRANSFER_S3_BUCKET` | existing bucket name |

Trigger manually: **Actions → SFTP User - Terraform Apply & Connection
Test → Run workflow**, supply `user_name`.

---

## Notes / things worth double-checking against your environment

- `home_directory_type = LOGICAL` is used by default (recommended — scopes
  the user to `/<bucket>/<user_name>` without exposing the bucket root).
  Switch to `PATH` in `variables.tf` if your existing IAM policy expects that
  style instead.
- The existing IAM role policy only needs `GetBucketLocation` +
  `DeleteObject` per what you described — if the user also needs to
  upload/list, that policy will need `PutObject` / `ListBucket` too;
  Terraform here doesn't touch the policy, so that's a change on your
  existing role resource, not in this module.
- `aws_transfer_ssh_key` supports multiple keys per user if you ever need
  key rotation — just add another resource block with a different
  `public_key_path` before removing the old one.
