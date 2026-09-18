#!/usr/bin/env bash
# Tests an SFTP connection to the newly created Transfer Family user.
# Usage: ./test_sftp_connection.sh <user_name> <sftp_endpoint> <private_key_path>
#   sftp_endpoint = terraform output sftp_endpoint
set -euo pipefail

USER_NAME="${1:?Usage: $0 <user_name> <sftp_endpoint> <private_key_path>}"
ENDPOINT="${2:?Usage: $0 <user_name> <sftp_endpoint> <private_key_path>}"
PRIVATE_KEY="${3:?Usage: $0 <user_name> <sftp_endpoint> <private_key_path>}"

chmod 600 "$PRIVATE_KEY" 2>/dev/null || true

echo "Connecting to ${USER_NAME}@${ENDPOINT} ..."
sftp -i "$PRIVATE_KEY" \
  -o StrictHostKeyChecking=accept-new \
  -o BatchMode=yes \
  "${USER_NAME}@${ENDPOINT}" <<'EOF'
pwd
ls -la
bye
EOF

echo "Connection test succeeded."
