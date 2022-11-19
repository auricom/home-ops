#!/usr/bin/env bash

# Runs smartctl to report current temperature of all disks.

JSON="["

DISKS=$(/sbin/sysctl -n kern.disks | cut -d= -f2)

for i in ${DISKS}
do
  # Get temperature from smartctl (requires root).
  [[ "${i}" = *"ada"* ]] && TEMP=$(/usr/local/sbin/smartctl -l scttemp /dev/$i | grep '^Current Temperature:' | awk '{print $3}')
  [[ "${i}" = *"nvd"* ]] && DEVICE_NUMBER=$(echo ${i} | cut -c 4) && TEMP=$(smartctl -a /dev/nvme${DEVICE_NUMBER} | grep Temperature: | head -1 | awk '{print $2}')
  
  if [ ${TEMP:-0} -gt 0 ]
  then
    JSON=$(echo "${JSON}{")
    JSON=$(echo "${JSON}\"temperature\":${TEMP},")
    JSON=$(echo "${JSON}\"disk\":\"${i}\"")
    JSON=$(echo "${JSON}},")
  fi

done

# Remove trailing "," on last field.
JSON=$(echo ${JSON} | sed 's/,$//')

echo -e "${JSON}]"