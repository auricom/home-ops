#!/usr/bin/env bash

set -o nounset
set -o errexit



echo "Download rclone config file ..."
curl -fsSL \
    --output "/tmp/rclone.conf.age" \
    "https://raw.githubusercontent.com/auricom/dotfiles/main/private_dot_config/rclone/encrypted_private_rclone.conf.age"

echo "Decrypt rclone config file ..."
age --decrypt \
    -i /app/age_key \
    /tmp/rclone.conf.age > /tmp/rclone.conf


echo "Sync minio buckets with encrypted remote gdrive-homelab-backups ..."
rclone --config /tmp/rclone.conf sync minio: gdrive-homelab-backups:
