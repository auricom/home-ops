#!/bin/sh

# DEBUG
# set -x

# Variables
SCRIPT_PATH="{{ scripts_dir }}"
INTERVAL="{{ snapshots_interval }}"
POOL_NAME="{{ pool_name }}"

# Prune

${SCRIPT_PATH}/snapshots_prune.py --recursive --intervals ${INTERVAL} ${POOL_NAME}
${SCRIPT_PATH}/snapshots_clearempty.py --recursive ${POOL_NAME}
{% if ansible_facts['nodename'] == "truenas.{{ secret_domain }}" %}
${SCRIPT_PATH}/snapshots_prune.py --recursive --intervals daily:14 storage/video
{% endif %}
