#!/bin/bash

# Variables
FLAG_NOTIF=false

DATE=`date +%Y%m%d%H%M`
BACKUP_PATH="/storage/backup"

cd /

tar cvf ${BACKUP_PATH}/${DATE}.tar \
    storage/.kodi storage/.config storage/.cache storage/.ssh \
    --exclude=storage/.kodi/userdata/Thumbnails

# Keep the last 5 backups on disk
find ${BACKUP_PATH}/*.tar -mtime +5 -type f -delete
