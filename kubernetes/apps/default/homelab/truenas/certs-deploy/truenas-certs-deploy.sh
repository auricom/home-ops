#!/usr/bin/env bash

set -o nounset
set -o errexit

mkdir -p ~/.ssh
cp /opt/id_rsa ~/.ssh/id_rsa
chmod 600 ~/.ssh/id_rsa

if [ "${HOSTNAME}" == "truenas" ]; then
    printf -v truenas_api_key %q "$TRUENAS_API_KEY"
elif [ "${HOSTNAME}" == "truenas-remote" ]; then
    printf -v truenas_api_key %q "$TRUENAS_REMOTE_API_KEY"
fi
printf -v cert_deploy_minio_enabled_str %q "$CERTS_DEPLOY_MINIO_ENABLED"
printf -v cert_deploy_postgresql_enabled_str %q "$CERTS_DEPLOY_POSTGRESQL_ENABLED"
printf -v pushover_api_token_str %q "$PUSHOVER_API_TOKEN"
printf -v pushover_user_key_str %q "$PUSHOVER_USER_KEY"
printf -v secret_domain_str %q "$SECRET_DOMAIN"

scp -o StrictHostKeyChecking=no /app/truenas-certs-deploy.py homelab@${HOSTNAME}.${SECRET_DOMAIN}:${TRUENAS_HOME}/scripts/certificates_deploy.py

ssh -o StrictHostKeyChecking=no homelab@${HOSTNAME}.${SECRET_DOMAIN} "/bin/bash -s $truenas_api_key $cert_deploy_minio_enabled_str $cert_deploy_postgresql_enabled_str $pushover_api_token_str $pushover_user_key_str $secret_domain_str" << 'EOF'

set -o nounset
set -o errexit

PUSHOVER_API_TOKEN=$4
PUSHOVER_USER_KEY=$5
SECRET_DOMAIN=$6

# Variables
TARGET=$(hostname)
DAYS=21
CERTIFICATE_PATH="${HOME}/letsencrypt/${SECRET_DOMAIN}"
SCRIPT_PATH="${HOME}/scripts"

export CERTS_DEPLOY_API_KEY=$1
export CERTS_DEPLOY_PRIVATE_KEY_PATH=${CERTIFICATE_PATH}/key.pem
export CERTS_DEPLOY_FULLCHAIN_PATH=${CERTIFICATE_PATH}/fullchain.pem
if [ "$2" == "True" ]; then
    export CERTS_DEPLOY_MINIO_ENABLED=$2
fi
CERTS_DEPLOY_MINIO_CERT_PATH=/mnt/{{ iocage_pool_name }}/iocage/jails/minio_v2/root/home/minio/certs
if [ "$3" == "True" ]; then
    export CERTS_DEPLOY_POSTGRESQL_ENABLED=$3
fi
CERTS_DEPLOY_POSTGRESQL_PATH=/mnt/{{ postgresql_pool_name }}/postgresql

# Check if cert is older than 69 days
result=$(find ${CERTS_DEPLOY_PRIVATE_KEY_PATH} -mtime +69)

if [[ "$result" == "${CERTS_DEPLOY_PRIVATE_KEY_PATH}" ]]; then
    echo "ERROR - Certificate is older than 69 days"
    echo "ERROR - Verify than it has been renewed by ACME client on opnsense and that the upload automation has been executed"
    curl -s \
        --form-string "token=${PUSHOVER_API_TOKEN}" \
        --form-string "user=${PUSHOVER_USER_KEY}" \
        --form-string "message=Certificate on $TARGET is older than 69 days. Verify than it has been renewed by ACME client on opnsense and that the upload automation has been executed" \
        https://api.pushover.net/1/messages.json
else
    echo "INFO checking if $TARGET expires in less than $DAYS days"
    set +o errexit
    openssl x509 -checkend $(( 24*3600*$DAYS )) -noout -in <(openssl s_client -showcerts -connect $TARGET:443 </dev/null 2>/dev/null | openssl x509 -outform PEM)
    if [[ $? -ne 0 ]]; then
        set -o errexit
        echo "INFO - Certificate expires in less than $DAYS days"
        echo "INFO - Deploying new certificate"
        # Deploy certificate (truenas UI)
        python ${SCRIPT_PATH}/certificates_deploy.py
        # Copy certificates (minio)
        if [ "CERTS_DEPLOY_MINIO_ENABLED" == "True" ]; then
            cp -pr ${CERTS_DEPLOY_PRIVATE_KEY_PATH} ${CERTS_DEPLOY_MINIO_CERT_PATH}/private.key
            cp -pr ${CERTS_DEPLOY_FULLCHAIN_PATH} ${CERTS_DEPLOY_MINIO_CERT_PATH}/public.crt
            iocage exec minio_v2 'service minio restart'
        fi
        # Copy certificates (postgresql)
        if [ "CERTS_DEPLOY_POSTGRESQL_ENABLED" == "True" ]; then
            pg_data_dirs=$(find /mnt/{{ postgresql_pool_name }}/postgresql -type d -maxdepth 1 -name '*data*' -exec basename {} \;)
            for i in $pg_data_dirs; do
                cp -pr ${CERTS_DEPLOY_PRIVATE_KEY_PATH} ${CERTS_DEPLOY_POSTGRESQL_PATH}/$i/server.key
                cp -pr ${CERTS_DEPLOY_FULLCHAIN_PATH} ${CERTS_DEPLOY_POSTGRESQL_PATH}/$i/server.crt
                iocage exec postgresql_v${i: -2} 'service postgresql reload'
            done
        fi
        curl -s \
            --form-string "token=${PUSHOVER_API_TOKEN}" \
            --form-string "user=${PUSHOVER_USER_KEY}" \
            --form-string "message=New Let's Encrypt certificate deployed on $TARGET." \
            https://api.pushover.net/1/messages.json

    else
        echo "INFO - Certificate expires in more than $DAYS"
    fi
fi

EOF
