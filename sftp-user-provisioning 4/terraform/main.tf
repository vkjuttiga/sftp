locals {
  users = {
    for name, u in var.users : name => {
      public_key = trimspace(file(u.public_key_path))
      prefix     = trim(coalesce(u.home_directory_target, name), "/")
    }
  }
}

# Scope-down policy, one per user. It is attached to the user (not the shared
# role), so each user is limited to their own folder even though they all
# assume the same IAM role.
data "aws_iam_policy_document" "scope_down" {
  for_each = local.users

  statement {
    sid       = "BucketLevel"
    actions   = var.bucket_actions
    resources = ["arn:aws:s3:::${var.bucket_name}"]
  }

  statement {
    sid       = "OwnFolderOnly"
    actions   = var.object_actions
    resources = ["arn:aws:s3:::${var.bucket_name}/${each.value.prefix}/*"]
  }
}

resource "aws_transfer_user" "this" {
  for_each = local.users

  server_id = var.server_id
  user_name = each.key
  role      = var.role_arn
  policy    = data.aws_iam_policy_document.scope_down[each.key].json

  # The user sees "/" but it is really s3://<bucket>/<prefix>. They cannot
  # navigate above it.
  home_directory_type = "LOGICAL"
  home_directory_mappings {
    entry  = "/"
    target = "/${var.bucket_name}/${each.value.prefix}"
  }

  tags = {
    Name = each.key
  }
}

resource "aws_transfer_ssh_key" "this" {
  for_each = local.users

  server_id = var.server_id
  user_name = aws_transfer_user.this[each.key].user_name
  body      = each.value.public_key
}
