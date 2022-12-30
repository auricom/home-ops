#!/bin/sh

# DEBUG
# set -x

# Variables
SCRIPT_PATH="{{ scripts_dir }}"
INTERVAL="{{ snapshots_interval }}"
POOL_NAME="{{ pool_name }}"

# Prune

${SCRIPT_PATH}/snapshots_prune.py --recursive --intervals ${INTERVAL} ${POOL_NAME}
${SCRIPT_PATH}/snapshots_prune.py --recursive --intervals daily:14 {% if not main_nas %}replication/{% endif %}${POOL_NAME}/minio
{% if ansible_facts['nodename'] == "truenas.{{ secret_domain }}" %}
${SCRIPT_PATH}/snapshots_prune.py --recursive --intervals daily:7 ${POOL_NAME}/video
{% endif %}
${SCRIPT_PATH}/snapshots_clearempty.py --recursive ${POOL_NAME}
