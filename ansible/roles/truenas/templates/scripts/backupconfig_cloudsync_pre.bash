#!/bin/bash

# DEBUG
# set -x

# Configuration backup Cloud Sync pre-script

# Variables
SOURCE_FOLDER="/var/db/system/configs"
BACKUP_FOLDER="{{ backups_dir }}servers/{{ ansible_facts['nodename'] }}"

cd ${SOURCE_FOLDER}*
rsync --archive --delete --human-readable --delete ./ ${BACKUP_FOLDER}
test $? -ne 0 && FLAG_NOTIF=true

chmod -R 775 ${BACKUP_FOLDER}/*
chown -R homelab:homelab ${BACKUP_FOLDER}/*

# Keep the last 90 backups on disk
# find ${BACKUP_FOLDER}/* -mtime +90 -type f -delete