#!/usr/bin/env bash

set -Eeuo pipefail

log_message() {
    DATE=$(date '+%Y-%m-%d %H:%M:%S')
    echo "${DATE} - $1"
}

SEC_SEED=true # Include Secret Seed (true| false)

# Max number of backups to keep (set as 0 to never delete anything)
maxnrOfFiles=20


log_message "Backing up current TrueNAS config"

# Check current TrueNAS version number
versiondir=$(curl --no-progress-meter \
    -X "GET" \
    "https://storage.feisar.ovh/api/v2.0/system/version" \
    -H "Authorization: Bearer ${API_KEY}" \
    -H "accept: */*" \
    -H "Content-Type: application/json")
versiondir=$(echo $versiondir | sed 's/TrueNAS-/v/' | tr -d \'\" )

log_message "TrueNAS version is ${versiondir}"

# Set directory for backups to: 'path on server' / 'current version number'
backupMainDir="${BACKUP_LOCATION}/${versiondir}"

# Create directory for for backups (Location/Version)
mkdir -p $backupMainDir

# Use appropriate extension if we are exporting the secret seed
if [ "${SEC_SEED}" = true ]
then
    fileExt="tar"
    log_message "Secret Seed will be included"
else
    fileExt="db"
    log_message "Secret Seed will NOT be included"
fi

# Generate file name
fileName=$(hostname)-config-$(date +%Y%m%d-%H%M%S).$fileExt

# API call to backup config and include secret seed
curl --no-progress-meter \
-X "POST" \
"https://${HOSTNAME}/api/v2.0/config/save" \
-H "Authorization: Bearer ${API_KEY}" \
-H "accept: */*" \
-H "Content-Type: application/json" \
-d '{"secretseed": '$SEC_SEED'}' \
--output $backupMainDir/$fileName

#### NEW SECTION 1 STARTS ####
# compare new file to old file, delete new if identical to last one
cmpFile="$( ls -t ${backupMainDir} | tail -1 )"
if cmp $fileName $cmpFile ; then
  log_message deleting "${backupMainDir}/${fileName}"
  rm $backupMainDir/$fileName
  log_message "Config has not changed, no action taken. Quitting"
  exit
fi
#
#### NEW SECTION 1 ENDS ####

log_message "Config saved to ${backupMainDir}/${fileName}"

#
# The next section checks for and deletes old backups
#
# Will not run if $maxnrOfFiles is set to zero (0)
#

if [ ${maxnrOfFiles} -ne 0 ]
then
    log_message "Checking for old backups to delete"
    log_message "Number of files to keep: ${maxnrOfFiles}"

    # Get number of files in the backup directory
    nrOfFiles="$(ls -l ${backupMainDir} | grep -c "^-.*")"

    log_message "Current number of files: ${nrOfFiles}"

    # Only do something if the current number of files is greater than $maxnrOfFiles
     if [ ${maxnrOfFiles} -lt ${nrOfFiles} ]
     then
         nFileToRemove="$((nrOfFiles - maxnrOfFiles))"
         log_message "Removing ${nFileToRemove} file(s)"
          while [ $nFileToRemove -gt 0 ]
          do
             fileToRemove="$(ls -t ${backupMainDir} | tail -1)"
             log_message "Removing file ${fileToRemove}"
             nFileToRemove="$((nFileToRemove - 1))"
             rm ${backupMainDir}/${fileToRemove}
             done
         fi
# Inform the user that no files will be deleted if $maxnrOfFiles is set to zero (0)
else
    log_message "NOT deleting old backups because '\$maxnrOfFiles' is set to 0"
fi

#All Done

log_message "DONE!"
