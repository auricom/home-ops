#!/usr/bin/env bash

PUID=${PUID:-1000}
PGID=${PGID:-1000}

usermod -o -u "$PUID" borg &>/dev/null
groupmod -o -g "$PGID" borg &>/dev/null

BORG_DATA_DIR=/backups
SSH_KEY_DIR=/keys
BORG_CMD='cd ${BORG_DATA_DIR}/${client_name}; borg serve --restrict-to-path ${BORG_DATA_DIR}/${client_name} ${BORG_SERVE_ARGS}'
AUTHORIZED_KEYS_PATH=/home/borg/.ssh/authorized_keys

# Append only mode?
BORG_APPEND_ONLY=${BORG_APPEND_ONLY:=no}

source /etc/os-release
echo "########################################################"
echo -n " * BorgServer powered by "
borg -V
echo " * Based on k8s-at-home"
echo "########################################################"
echo " * User  id: $(id -u borg)"
echo " * Group id: $(id -g borg)"
echo "########################################################"


# Precheck if BORG_ADMIN is set
if [ "${BORG_APPEND_ONLY}" == "yes" ] && [ -z "${BORG_ADMIN}" ] ; then
    echo "WARNING: BORG_APPEND_ONLY is active, but no BORG_ADMIN was specified!"
fi

# Precheck directories & client ssh-keys
for dir in BORG_DATA_DIR SSH_KEY_DIR ; do
    dirpath=$(eval echo '$'${dir})
    echo " * Testing Volume ${dir}: ${dirpath}"
    if [ ! -d "${dirpath}" ] ; then
        echo "ERROR: ${dirpath} is no directory!"
        exit 1
    fi

    if [ "$(find ${SSH_KEY_DIR}/clients ! -regex '.*/\..*' -a -type f | wc -l)" == "0" ] ; then
        echo "ERROR: No SSH-Pubkey file found in ${SSH_KEY_DIR}"
        exit 1
    fi
done

# Create SSH-Host-Keys on persistent storage, if not exist
mkdir -p ${SSH_KEY_DIR}/host 2>/dev/null
echo " * Checking / Preparing SSH Host-Keys..."
for keytype in ed25519 rsa ; do
    if [ ! -f "${SSH_KEY_DIR}/host/ssh_host_${keytype}_key" ] ; then
        echo "  ** Creating SSH Hostkey [${keytype}]..."
        ssh-keygen -q -f "${SSH_KEY_DIR}/host/ssh_host_${keytype}_key" -N '' -t ${keytype}
    fi
done

echo "########################################################"
echo " * Starting SSH-Key import..."

# Add every key to borg-users authorized_keys
rm ${AUTHORIZED_KEYS_PATH} &>/dev/null
for keyfile in $(find "${SSH_KEY_DIR}/clients" ! -regex '.*/\..*' -a -type f); do
    client_name=$(basename ${keyfile})
    mkdir ${BORG_DATA_DIR}/${client_name} 2>/dev/null
    echo "  ** Adding client ${client_name} with repo path ${BORG_DATA_DIR}/${client_name}"

    # If client is $BORG_ADMIN unset $client_name, so path restriction equals $BORG_DATA_DIR
    # Otherwise add --append-only, if enabled
    borg_cmd=${BORG_CMD}
    if [ "${client_name}" == "${BORG_ADMIN}" ] ; then
        echo "   ** Client '${client_name}' is BORG_ADMIN! **"
        unset client_name
    elif [ "${BORG_APPEND_ONLY}" == "yes" ] ; then
        borg_cmd="${BORG_CMD} --append-only"
    fi

  echo -n "restrict,command=\"$(eval echo -n \"${borg_cmd}\")\" " >> ${AUTHORIZED_KEYS_PATH}
  cat ${keyfile} >> ${AUTHORIZED_KEYS_PATH}
  echo >> ${AUTHORIZED_KEYS_PATH}
done
chmod 0600 "${AUTHORIZED_KEYS_PATH}"

echo " * Validating structure of generated ${AUTHORIZED_KEYS_PATH}..."
ERROR=$(ssh-keygen -lf ${AUTHORIZED_KEYS_PATH} 2>&1 >/dev/null)
if [ $? -ne 0 ]; then
    echo "ERROR: ${ERROR}"
    exit 1
fi

chown -R borg:borg ${BORG_DATA_DIR}
chown borg:borg ${AUTHORIZED_KEYS_PATH}
chmod 600 ${AUTHORIZED_KEYS_PATH}

echo "########################################################"
echo " * Init done!"
