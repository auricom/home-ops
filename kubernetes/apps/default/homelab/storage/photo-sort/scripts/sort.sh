#!/bin/bash

set -o nounset
set -o errexit

# set -x

# Check if necessary environment variables are set
if [[ -z "${SORT_SOURCE_DIR}" ]] || [[ -z "${SORT_DEST_DIR}" ]]; then
    echo "SORT_SOURCE_DIR and SORT_DEST_DIR environment variables must be set."
    exit 1
fi

grep -q ID_LIKE=debian /etc/os-release

# Function to log messages to stdout
log_message() {
    DATE=$(date '+%Y-%m-%d %H:%M:%S')
    echo "${DATE} - $1"
}

# Function to cleanup orphaned symlinks
cleanup_orphans() {
    log_message "Cleaning up orphaned symlinks."

    # Use fd to find all broken symlinks in SORT_DEST_DIR
    fd --follow --type symlink '' "${SORT_DEST_DIR}" | while IFS= read -r symlink; do
        # Check if the symlink is broken
        if [[ ! -e "${symlink}" ]]; then
            echo "Removing broken symlink newer than 6 months: ${symlink}"
            rm "${symlink}"  # Remove the broken symlink
            log_message "Removed symlink ${symlink}."
        fi
    done
}

# Function to process files
process_file() {
    local file="$1"

    # Check if "DCIM" is in the file's full path
    if [[ "${file}" == *"/Camera/"* ]]; then
        log_message "Processing file: ${file}"

        # Extract the EXIF creation date using exiftool
        local exif_date=$(exiftool -d "%Y-%m-%d" -CreateDate -S -s "${file}")

        if [[ -z "${exif_date}" ]]; then
            log_message "EXIF data not found for ${file}"
            return  # Skip files without EXIF data
        fi

        # Parse the year, month, and day from the EXIF date
        local year=$(echo "${exif_date}" | cut -d "-" -f 1)
        local month=$(echo "${exif_date}" | cut -d "-" -f 2)
        local day=$(echo "${exif_date}" | cut -d "-" -f 3)

        # Construct the destination directory path based on the EXIF date
        local dest_path="${SORT_DEST_DIR}/${year}/${year}-${month}/${year}-${month}-${day}"

        # Create the destination directory if it doesn't exist
        mkdir -p "${dest_path}"

        # Extract the device name (subfolder name in SORT_SOURCE_DIR)
        local device_name=$(basename "$(dirname "$(dirname "${file}")")")

        # Calculate the relative path from the destination directory back to the original file
        local relative_path=$(realpath --relative-to="${dest_path}" "${file}")

        # Create a symlink for the file in the destination directory, prefixed with the device name
        local symlink_name="${device_name}_$(basename "${file}")"
        local symlink_path="${dest_path}/${symlink_name}"

        # Check if the symlink already exists to avoid creating duplicates
        if [[ ! -L "${symlink_path}" ]]; then  # -L tests if the file is a symlink
            ln -s "${relative_path}" "${symlink_path}"
            log_message "Processed and linked: ${file} -> ${symlink_path}"
        else
            log_message "Skipping symlink creation; already exists: ${symlink_path}"
        fi
    else
        log_message "Skipping file (not in Camera directory): ${file}"
    fi
}


export -f process_file log_message
export SORT_SOURCE_DIR SORT_DEST_DIR

# Start processing
log_message "Starting to process files."

cd "${SORT_SOURCE_DIR}"

# Use fd to find image files and process them
fd --type file --changed-within 15days --exec bash -c 'process_file "$@"' bash {}

cleanup_orphans

log_message "Processing complete."
