keeper --config "$KEEPER_CONFIG" get <UID_from_ls> --format json | jq -r '(.fields[]?, .custom[]?) | select(.label=="private_key_b64") | {type, start: (.value[0] | tostring | .[0:14])}'



keeper --config "$KEEPER_CONFIG" get <UID_from_ls> --format json | jq -r '(.fields[]?, .custom[]?) | select(.label=="private_key_b64") | .value[0]' | tr -d ' \r\n' | base64 -d > ~/.ssh/partner_acme_tf
chmod 600 ~/.ssh/partner_acme_tf
ssh-keygen -y -f ~/.ssh/partner_acme_tf > /dev/null && echo "key OK"
sftp -o IdentitiesOnly=yes -i ~/.ssh/partner_acme_tf partner_acme@s-XXXXXXXX.server.transfer.<region>.amazonaws.com
