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

http_host=${S3_URL#*//}
http_host=${http_host%:*}
http_request_date=$(date -R)
http_filepath="opnsense/${config_filename}"
http_signature=$(
    printf "PUT\n\ntext/xml\n%s\n/%s" "${http_request_date}" "${http_filepath}" \
        | openssl sha1 -hmac "${AWS_SECRET_ACCESS_KEY}" -binary \
        | base64
)

echo "Download Opnsense config file ..."
curl -fsSL \
    --user "${OPNSENSE_KEY}:${OPNSENSE_SECRET}" \
    --output "/tmp/${config_filename}" \
    "${OPNSENSE_URL}/api/core/backup/download/this"

echo "Upload backup to s3 bucket ..."
curl -fsSL \
    -X PUT -T "/tmp/${config_filename}" \
    -H "Host: ${http_host}" \
    -H "Date: ${http_request_date}" \
    -H "Content-Type: text/xml" \
    -H "Authorization: AWS ${AWS_ACCESS_KEY_ID}:${http_signature}" \
    "${S3_URL}/${http_filepath}"

# Send completion ping to healthchecks
if [[ -n "${HEALTHCHECKS_ID:-}" ]]; then
    curl --max-time 10 --retry 5 "https://hc-ping.com/${HEALTHCHECKS_ID}"
fi
