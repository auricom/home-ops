#!/bin/bash

# DEBUG
# set -x

# Get certificates from remote server

# Variables
SCRIPT_PATH="{{ scripts_dir }}"
CERTIFICATE_PATH="{{ certificates_dir }}"
CONFIG_FILE="${SCRIPT_PATH}/certificates_deploy.conf"

# Check if cert has been uploaded last week
result=$(find ${CERTIFICATE_PATH}/cert.pem -mtime -7)

if [[ "$result" == "${CERTIFICATE_PATH}/cert.pem" ]]; then

    # Deploy certificate
    python ${SCRIPT_PATH}/certificates_deploy.py -c ${CONFIG_FILE}
    test $? -ne 0 && FLAG_NOTIF=true

fi