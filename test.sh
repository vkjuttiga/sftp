keeper --config "$KEEPER_CONFIG" get <UID_from_ls> --format json | jq -r '(.fields[]?, .custom[]?) | select(.label=="private_key_b64") | {type, start: (.value[0] | tostring | .[0:14])}'
