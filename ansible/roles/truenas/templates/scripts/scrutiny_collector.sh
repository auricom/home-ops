#!/bin/sh

# DEBUG
# set -x

# Variables
BIN_PATH="{{ scrutiny_dir }}/{{ scrutiny_bin }}"
HOSTNAME=$(hostname)

$BIN_PATH run --host-id=${HOSTNAME} --api-endpoint=https://scrutiny.{{ secret_cluster_domain }}
