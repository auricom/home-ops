#!/bin/bash

# DEBUG
# set -x

# Get certificates from remote server

# Variables
SCRIPT_PATH="{{ scripts_dir }}"
CERTIFICATE_PATH="{{ certificates_dir }}"
CONFIG_FILE="${SCRIPT_PATH}/certificates_deploy.conf"
{% if main_nas == true %}POSTGRES_DIR="/mnt/storage/jail-mounts/postgres/data{{ postgres_version }}/"{% endif %}

# Check if cert has been uploaded last week
result=$(find ${CERTIFICATE_PATH}/cert.pem -mtime -7)

if [[ "$result" == "${CERTIFICATE_PATH}/cert.pem" ]]; then

    # Deploy certificate (truenas UI & minio)
    python ${SCRIPT_PATH}/certificates_deploy.py -c ${CONFIG_FILE}
    test $? -ne 0 && FLAG_NOTIF=true
    {% if main_nas == true %}

    # Deploy certificate (postgresql jail)
    umask 0177
    cp ${CERTIFICATE_PATH}/fullchain.pem ${POSTGRES_DIR}/server.crt
    cp ${CERTIFICATE_PATH}/key.pem ${POSTGRES_DIR}/server.key
    chown 770:770 ${POSTGRES_DIR}/server.crt ${POSTGRES_DIR}/server.key
    chmod 600 ${POSTGRES_DIR}/server.crt ${POSTGRES_DIR}/server.key
    # restart postgresql
    iocage postgres service postgresql restart
    {% endif %}
fi
