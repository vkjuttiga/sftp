output "user_name" {
  description = "SFTP user name created."
  value       = aws_transfer_user.this.user_name
}

output "user_arn" {
  description = "ARN of the created Transfer Family user."
  value       = aws_transfer_user.this.arn
}

output "ssh_key_id" {
  description = "ID of the attached SSH public key."
  value       = aws_transfer_ssh_key.this.ssh_public_key_id
}

output "sftp_endpoint" {
  description = "Hostname to connect to for SFTP (used by the manual test script)."
  value       = "${var.server_id}.server.transfer.${var.aws_region}.amazonaws.com"
}
