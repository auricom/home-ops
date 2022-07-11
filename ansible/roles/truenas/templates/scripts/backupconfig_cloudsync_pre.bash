#!/bin/bash

# DEBUG
# set -x

# Configuration backup Cloud Sync pre-script

# Variables
DATE=$(date +%Y%m%d)
BACKUP_FOLDER="{{ backups_dir }}servers/{{ ansible_facts['nodename'] }}"

cp -p /data/freenas-v1.db ${BACKUP_FOLDER}/${DATE}.db
chmod -R 775 ${BACKUP_FOLDER}/${DATE}.db
chown -R homelab:homelab ${BACKUP_FOLDER}/${DATE}.db

# Keep the last 90 backups on disk
find ${BACKUP_FOLDER}/*.db -mtime +90 -type f -delete
