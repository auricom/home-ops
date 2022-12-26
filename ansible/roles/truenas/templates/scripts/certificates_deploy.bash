#!/bin/bash

# DEBUG
# set -x

# Variables
TARGET=$(hostname)
DAYS=21
SCRIPT_PATH="{{ scripts_dir }}"
CERTIFICATE_PATH="{{ certificates_dir }}"
CONFIG_FILE="${SCRIPT_PATH}/certificates_deploy.conf"
UPTIME_KUMA_ID="{{uptime_kuma_id_truenas_cert}}"

# Check if cert is older than 69 days
result=$(find ${CERTIFICATE_PATH}/cert.pem -mtime +69)

if [[ "$result" == "${CERTIFICATE_PATH}/cert.pem" ]]; then
    echo "ERROR - Certificate is older than 69 days"
    echo "ERROR - Verify than it has been renewed by ACME client on opnsense and that the upload automation has been executed"
    curl -s \
        --form-string "token={{secret_pushover_api_key}}" \
        --form-string "user={{secret_pushover_user_key}}" \
        --form-string "message=Certificate on $TARGET is older than 69 days. Verify than it has been renewed by ACME client on opnsense and that the upload automation has been executed" \
        https://api.pushover.net/1/messages.json
else
    echo "checking if $TARGET expires in less than $DAYS days"
    openssl x509 -checkend $(( 24*3600*$DAYS )) -noout -in <(openssl s_client -showcerts -connect $TARGET:443 </dev/null 2>/dev/null | openssl x509 -outform PEM)
    if [ $? -ne 0 ]; then
        echo "INFO - Certificate expires in less than $DAYS days"
        echo "INFO - Deploying new certificate"
        # Deploy certificate (truenas UI & minio)
        python ${SCRIPT_PATH}/certificates_deploy.py -c ${CONFIG_FILE}
        test $? -eq 0 && curl https://uptime-kuma.{{secret_cluster_domain}}/api/push/${UPTIME_KUMA_ID}?status=up&msg=OK&ping=
    else
        echo "INFO - Certificate expires in more than $DAYS"
    fi
fi
