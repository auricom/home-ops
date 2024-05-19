#!/bin/bash

# Variables
DATE=$(date +%Y%m%d%H%M)
BACKUP_SRC="/storage/backup"
BACKUP_DEST="homelab@storage.{{ secret_domain }}:/vol1/backups/servers/coreelec.{{ secret_domain }}/"

error_handler() {
    local error_line=$1
    local error_message=$2
    script_name=$(basename "$0")
    local script_name

    echo "Error occurred in script '${script_name}' at line: ${error_line}"
    echo "Error message: ${error_message}"

    curl -s \
        --form-string "token={{ pushover_api_token }}" \
        --form-string "user={{ pushover_user_key }}" \
        --form-string "message=coreelec.{{ secret_domain }}
script: ${script_name}
error_line: ${error_line}
error_message: ${error_message}" \
        https://api.pushover.net/1/messages.json
        exit 1
}

trap 'error_handler $LINENO "$BASH_COMMAND"' ERR

tar cvf "${BACKUP_SRC}/${DATE}.tar" \
    storage/.kodi storage/.config storage/.cache storage/.ssh \
    --exclude=storage/.kodi/userdata/Thumbnails

# Keep the last 5 backups on disk
find "${BACKUP_SRC}/*.tar" -mtime +5 -type f -delete

rsync -avh "${BACKUP_SRC}/" "${BACKUP_DEST}" --delete
