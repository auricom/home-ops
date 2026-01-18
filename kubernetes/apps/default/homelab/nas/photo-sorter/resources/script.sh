#!/usr/bin/env bash

set -Eeuo pipefail

# Check if necessary directories exist
if [[ ! -d "${SORT_SOURCE_DIR}" ]] || [[ ! -d "${SORT_DEST_DIR}" ]]; then
    echo "SORT_SOURCE_DIR and SORT_DEST_DIR directories must exist."
    exit 1
fi

log_message() {
    DATE=$(date '+%Y-%m-%d %H:%M:%S')
    echo "${DATE} - $1"
}

# Function to cleanup orphaned symlinks
cleanup_orphans() {
    log_message "Cleaning up orphaned symlinks."

    # Find all symlinks in SORT_DEST_DIR (without following them)
    find "${SORT_DEST_DIR}" -type l | while IFS= read -r symlink; do
        # Check if the symlink is broken by reading the target and checking if it exists
        # Use readlink to get the target, then check if it exists
        target=$(readlink -f "${symlink}" 2>/dev/null)
        if [[ -z "${target}" ]] || [[ ! -e "${target}" ]]; then
            echo "Removing broken symlink: ${symlink}"
            rm "${symlink}"  # Remove the broken symlink
            log_message "Removed broken symlink ${symlink}."
        fi
    done
}

# Function to process files
process_file() {
    local file="$1"

    # Check if "DCIM" is in the file's full path
    if [[ "${file}" == *"/Camera/"* ]]; then
        log_message "Processing file: ${file}"

        # Skip empty files
        if [[ ! -s "${file}" ]]; then
            log_message "Skipping empty file: ${file}"
            return
        fi

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
        if ! relative_path=$(realpath --relative-to="${dest_path}" "${file}" 2>/dev/null); then
            log_message "Failed to get relative path for ${file}, using absolute path"
            relative_path="${file}"
        fi

        # Create a symlink for the file in the destination directory, prefixed with the device name
        local symlink_name="${device_name}_$(basename "${file}")"
        local symlink_path="${dest_path}/${symlink_name}"

        # Check if the symlink already exists to avoid creating duplicates
        if [[ ! -e "${symlink_path}" ]]; then  # Check if file exists (works for broken symlinks too)
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

# Find image files and process them
fd --type file --changed-within 15days --exec bash -c 'process_file "$@"' bash {}

cleanup_orphans

log_message "Processing complete."
