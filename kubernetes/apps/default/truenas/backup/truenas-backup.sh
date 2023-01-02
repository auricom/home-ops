#!/usr/bin/env bash

set -o nounset
set -o errexit

mkdir -p ~/.ssh
cp /opt/id_rsa ~/.ssh/id_rsa
chmod 600 ~/.ssh/id_rsa

printf -v aws_access_key_id_str %q "$AWS_ACCESS_KEY_ID"
printf -v aws_secret_access_key_str %q "$AWS_SECRET_ACCESS_KEY"
printf -v secret_domain_str %q "$SECRET_DOMAIN"


ssh -o StrictHostKeyChecking=no root@${HOSTNAME}.${SECRET_DOMAIN} "/bin/bash -s $aws_access_key_id_str $aws_secret_access_key_str $secret_domain_str" << 'EOF'

set -o nounset
set -o errexit

AWS_ACCESS_KEY_ID=$1
AWS_SECRET_ACCESS_KEY=$2
SECRET_DOMAIN=$3

config_filename="$(date "+%Y%m%d-%H%M%S").tar"

http_host=truenas.${SECRET_DOMAIN}
http_request_date=$(date -R)
http_content_type="application/x-tar"
http_filepath="truenas/$(hostname)/${config_filename}"
http_signature=$(
    printf "PUT\n\n${http_content_type}\n%s\n/%s" "${http_request_date}" "${http_filepath}" \
        | openssl sha1 -hmac "${AWS_SECRET_ACCESS_KEY}" -binary \
        | base64
)

echo "Creating backup archive ..."

tar -cvlf /tmp/backup-${config_filename} --strip-components=2 /data/freenas-v1.db /data/pwenc_secret

echo "Upload backup to s3 bucket ..."
curl -fsSL \
    -X PUT -T "/tmp/backup-${config_filename}" \
    -H "Host: ${http_host}" \
    -H "Date: ${http_request_date}" \
    -H "Content-Type: ${http_content_type}" \
    -H "Authorization: AWS ${AWS_ACCESS_KEY_ID}:${http_signature}" \
    "https://truenas.${SECRET_DOMAIN}:51515/${http_filepath}"

rm /tmp/backup-*.tar

EOF
