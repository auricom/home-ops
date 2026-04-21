#!/usr/bin/env bash

set -Eeuo pipefail


# Global counters
PROCESSED_COUNT=0
SKIPPED_COUNT=0
EXISTING_COUNT=0
ORPHAN_COUNT=0


log() {
    gum log --structured --level "$@"
}


# Function to log processed files (removed file logging)
log_processed_file() {
    local source_file="$1"
    local dest_file="$2"
    ((++PROCESSED_COUNT))
}


log_skipped_file() {
    local file="$1"
    local reason="$2"
    ((++SKIPPED_COUNT))
}


log_existing_file() {
    local file="$1"
    ((++EXISTING_COUNT))
}

cleanup_orphans() {

    log info "Cleaning up orphaned symlinks."

    # Use fd to find all broken symlinks in SORT_DEST_DIR
    fd --follow --type symlink '' "$SORT_DEST_DIR" | while IFS= read -r symlink; do
        # Check if the symlink is broken
        if [ ! -e "$symlink" ]; then
            log info "Removing broken symlink: $symlink"
            rm "$symlink"  # Remove the broken symlink
            log info "Removed symlink $symlink."
            ((++ORPHAN_COUNT))
        fi
    done
}

process_file() {
    local file="$1"

    if [[ "$file" == *"/Camera/"* ]]; then

        # Check if file is 0 bytes and delete it
        if [ ! -s "$file" ]; then
        log warn "Deleting empty file (0 bytes): $file"
        rm "$file"
        log_skipped_file "$file" "Empty file (0 bytes)"
        return
        fi

        log info "Processing file: $file"

        # Extract the EXIF creation date using exiftool
        local exif_date=$(exiftool -d "%Y-%m-%d" -CreateDate -S -s "$file")

        if [ -z "$exif_date" ]; then
            log warn "EXIF data not found for $file, trying to extract date from filename"

            # Try to extract date from filename (format: YYYYMMDD_HHMMSS)
            local filename=$(basename "$file")
            if [[ "$filename" =~ ^([0-9]{8})_([0-9]{6}) ]]; then
                # Extract date parts from filename
                local year="${BASH_REMATCH[1]:0:4}"
                local month="${BASH_REMATCH[1]:4:2}"
                local day="${BASH_REMATCH[1]:6:2}"

                # Validate the extracted date
                if [[ "$year" =~ ^[0-9]{4}$ ]] && [[ "$month" =~ ^[0-9]{2}$ ]] && [[ "$day" =~ ^[0-9]{2}$ ]]; then
                    log info "Successfully extracted date from filename: $year-$month-$day"
                    exif_date="$year-$month-$day"
                else
                    log warn "Invalid date format extracted from filename: $filename"
                    log_skipped_file "$file" "No EXIF data and invalid filename date format"
                    return  # Skip files without valid date
                fi
            else
                log warn "Filename does not contain date pattern: $filename"
                log_skipped_file "$file" "No EXIF data and no date in filename"
                return  # Skip files without date in filename
            fi
        fi

        # Parse the year, month, and day from the EXIF date or filename
        local year=$(echo "$exif_date" | cut -d "-" -f 1)
        local month=$(echo "$exif_date" | cut -d "-" -f 2)
        local day=$(echo "$exif_date" | cut -d "-" -f 3)

        # Construct the destination directory path based on the EXIF date
        local dest_path="$SORT_DEST_DIR/$year/${year}-${month}/${year}-${month}-${day}"

        # Create the destination directory if it doesn't exist
        mkdir -p "$dest_path"

        # Extract the device name (subfolder name in SORT_SOURCE_DIR)
        local device_name=$(basename "$(dirname "$(dirname "$file")")")

        # Prepare the destination file path, prefixed with the device name
        local dest_file_name="${device_name}_$(basename "$file")"
        local dest_file_path="$dest_path/$dest_file_name"

        # Check if there's an existing symlink at the destination and remove it
        if [ -L "$dest_file_path" ]; then
            rm "$dest_file_path"
            log info "Removed existing symlink: $dest_file_path"
        fi

        mv "$file" "$dest_file_path"
        log info "Processed and moved: $file -> $dest_file_path"
        log_processed_file "$file" "$dest_file_path"
    fi
}

export -f log process_file log_processed_file log_skipped_file log_existing_file
export SORT_SOURCE_DIR SORT_DEST_DIR PROCESSED_COUNT SKIPPED_COUNT EXISTING_COUNT ORPHAN_COUNT

log info "Starting to process files..."

cd "$SORT_SOURCE_DIR" || {
    log error "Failed to change to source directory: $SORT_SOURCE_DIR"
    exit 1
}
log info "Searching for image files in Camera directories..."

fd_command="fd --type file --exec bash -c 'process_file \"\$@\"' bash {}"

fd --type file --exec bash -c 'process_file "$@"' bash {} 2>&1

cleanup_orphans

log info "Processing complete!"

log info "Files processed: $PROCESSED_COUNT"
log info "Files skipped: $SKIPPED_COUNT"
log info "Files already existing: $EXISTING_COUNT"
log info "Orphaned symlinks removed: $ORPHAN_COUNT"
