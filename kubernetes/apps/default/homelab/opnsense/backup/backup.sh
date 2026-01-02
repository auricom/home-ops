#!/usr/bin/env bash

# Exit on error, undefined vars, pipe failures, and debug each command
set -o errexit
set -o nounset
set -o pipefail
set -o xtrace

# Cleanup temporary files on script exit
trap 'rm -f "/tmp/${config_filename}"' EXIT

# Send start ping to healthchecks
if [[ -n "${HEALTHCHECKS_ID:-}" ]]; then
    curl --max-time 10 --retry 5 "https://hc-ping.com/${HEALTHCHECKS_ID}/start"
fi

config_filename="$(date "+%Y%m%d-%H%M%S").xml"

echo "Download Opnsense config file ..."
curl -fsSL \
    --user "${OPNSENSE_KEY}:${OPNSENSE_SECRET}" \
    --output "/tmp/${config_filename}" \
    "${OPNSENSE_URL}/api/core/backup/download/this"

echo "Copy backup to NFS share ..."
cp "/tmp/${config_filename}" "/mnt/nfs/opnsense/${config_filename}"

echo "Cleaning up backups older than 90 days ..."
find "/mnt/nfs/opnsense/" -name "*.xml" -type f -mtime +90 -delete

# Send completion ping to healthchecks
if [[ -n "${HEALTHCHECKS_ID:-}" ]]; then
    curl --max-time 10 --retry 5 "https://hc-ping.com/${HEALTHCHECKS_ID}"
fi
