#!/usr/bin/env bash

set -o nounset
set -o errexit

# Replace the placeholders in the file with the environment variables values
cp /config/rclone.conf /tmp/rclone.conf
sed -i "s@__RCLONE_ACCESS_ID__@$RCLONE_ACCESS_ID@g" "/tmp/rclone.conf"
sed -i "s@__RCLONE_SECRET_KEY__@$RCLONE_SECRET_KEY@g" "/tmp/rclone.conf"
sed -i "s@__PASSWORD__@$GDRIVE_PASSWORD@g" "/tmp/rclone.conf"
sed -i "s@__PASSWORD2__@$GDRIVE_PASSWORD2@g" "/tmp/rclone.conf"
sed -i "s@__GDRIVE_CLIENT_ID__@$GDRIVE_CLIENT_ID@g" "/tmp/rclone.conf"
sed -i "s@__GDRIVE_CLIENT_SECRET__@$GDRIVE_CLIENT_SECRET@g" "/tmp/rclone.conf"
sed -i "s@__GDRIVE_TOKEN__@$GDRIVE_TOKEN@g" "/tmp/rclone.conf"

echo "Sync minio buckets with encrypted remote gdrive-homelab-backups ..."
rclone --config /tmp/rclone.conf sync minio: gdrive-homelab-backups:
