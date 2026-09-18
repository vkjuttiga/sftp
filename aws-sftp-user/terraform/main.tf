# Assumes: Transfer Family server, S3 bucket, IAM role, and IAM role policy
# (GetBucketLocation + DeleteObject) already exist and are passed in as variables.
# This module only creates the SFTP user and attaches its public SSH key.

resource "aws_transfer_user" "this" {
  server_id           = var.server_id
  user_name           = var.user_name
  role                = var.role_arn
  home_directory_type = var.home_directory_type

  # PATH-style home directory (used only if home_directory_type = PATH)
  home_directory = var.home_directory_type == "PATH" ? var.home_directory : null

  # LOGICAL-style home directory mapping (used only if home_directory_type = LOGICAL)
  dynamic "home_directory_mappings" {
    for_each = var.home_directory_type == "LOGICAL" ? [1] : []
    content {
      entry  = "/"
      target = var.home_directory_entry_target != "" ? var.home_directory_entry_target : "/${var.s3_bucket}/${var.user_name}"
    }
  }

  tags = var.tags
}

# Attaches the previously generated public key to the user.
# The private key never touches Terraform state — it's generated locally
# and uploaded straight to Vault (see scripts/).
resource "aws_transfer_ssh_key" "this" {
  server_id = var.server_id
  user_name = aws_transfer_user.this.user_name
  body      = trimspace(file(var.public_key_path))
}
