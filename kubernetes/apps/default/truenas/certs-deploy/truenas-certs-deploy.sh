#!/usr/bin/env bash

set -o nounset
set -o errexit

mkdir -p ~/.ssh
cp /opt/id_rsa ~/.ssh/id_rsa
chmod 600 ~/.ssh/id_rsa

printf -v truenas_api_key %q "$TRUENAS_API_KEY"
printf -v cert_deploy_s3_enabled_str %q "$CERTS_DEPLOY_S3_ENABLED"
printf -v pushover_api_key_str %q "$PUSHOVER_API_KEY"
printf -v pushover_user_key_str %q "$PUSHOVER_USER_KEY"
printf -v secret_domain_str %q "$SECRET_DOMAIN"

scp -o StrictHostKeyChecking=no /app/truenas-certs-deploy.py homelab@${HOSTNAME}.${SECRET_DOMAIN}:${TRUENAS_HOME}/scripts/certificates_deploy.py

ssh -o StrictHostKeyChecking=no homelab@${HOSTNAME}.${SECRET_DOMAIN} "/bin/bash -s $truenas_api_key $cert_deploy_s3_enabled_str $pushover_api_key_str $pushover_user_key_str $secret_domain_str" << 'EOF'

set -o nounset
set -o errexit

PUSHOVER_API_KEY=$3
PUSHOVER_USER_KEY=$4
SECRET_DOMAIN=$5

# Variables
TARGET=$(hostname)
DAYS=21
CERTIFICATE_PATH="${HOME}/letsencrypt/${SECRET_DOMAIN}"
SCRIPT_PATH="${HOME}/scripts"

export CERTS_DEPLOY_API_KEY=$1
export CERTS_DEPLOY_PRIVATE_KEY_PATH=${CERTIFICATE_PATH}/key.pem
export CERTS_DEPLOY_FULLCHAIN_PATH=${CERTIFICATE_PATH}/fullchain.pem
export CERTS_DEPLOY_S3_ENABLED=$2

# Check if cert is older than 69 days
result=$(find ${CERTS_DEPLOY_PRIVATE_KEY_PATH} -mtime +69)

if [[ "$result" == "${CERTS_DEPLOY_PRIVATE_KEY_PATH}" ]]; then
    echo "ERROR - Certificate is older than 69 days"
    echo "ERROR - Verify than it has been renewed by ACME client on opnsense and that the upload automation has been executed"
    curl -s \
        --form-string "token=${PUSHOVER_API_KEY}" \
        --form-string "user=${PUSHOVER_USER_KEY}" \
        --form-string "message=Certificate on $TARGET is older than 69 days. Verify than it has been renewed by ACME client on opnsense and that the upload automation has been executed" \
        https://api.pushover.net/1/messages.json
else
    echo "checking if $TARGET expires in less than $DAYS days"
    result=(openssl x509 -checkend $(( 24*3600*$DAYS )) -noout -in <(openssl s_client -showcerts -connect $TARGET:443 </dev/null 2>/dev/null | openssl x509 -outform PEM))
    if [ "$result" == "Certificate will expire" ]; then
        echo "INFO - Certificate expires in less than $DAYS days"
        echo "INFO - Deploying new certificate"
        # Deploy certificate (truenas UI & minio)
        python ${SCRIPT_PATH}/certificates_deploy.py
    else
        echo "INFO - Certificate expires in more than $DAYS"
    fi
fi

EOF
