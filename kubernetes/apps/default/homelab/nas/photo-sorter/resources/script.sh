#!/usr/bin/env bash

set -x
set -Eeuo pipefail


set -x
# Global counters
PROCESSED_COUNT=0
SKIPPED_COUNT=0
EXISTING_COUNT=0
ORPHAN_COUNT=0


set -x
# Function to log messages to stdout
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}


set -x
# Function to log processed files to the log file
log_processed_file() {
    local source_file="$1"
    local dest_file="$2"
    echo "PROCESSED: $source_file -> $dest_file" >> "$PROCESSED_LOG_FILE"
    ((PROCESSED_COUNT++))
}


set -x
# Function to log skipped files to the log file
log_skipped_file() {
    local file="$1"
    local reason="$2"
    echo "SKIPPED: $file (Reason: $reason)" >> "$PROCESSED_LOG_FILE"
    ((SKIPPED_COUNT++))
}


set -x
# Function to log existing files to the log file
log_existing_file() {
    local file="$1"
    echo "EXISTING: $file" >> "$PROCESSED_LOG_FILE"
    ((EXISTING_COUNT++))
}


set -x
# Function to cleanup orphaned symlinks
cleanup_orphans() {
    set -x

    log_message "Cleaning up orphaned symlinks."

    # Use fd to find all broken symlinks in SORT_DEST_DIR
    fd --follow --type symlink '' "$SORT_DEST_DIR" | while IFS= read -r symlink; do
        # Check if the symlink is broken
        if [ ! -e "$symlink" ]; then
            echo "Removing broken symlink: $symlink"
            rm "$symlink"  # Remove the broken symlink
            log_message "Removed symlink $symlink."
            ((ORPHAN_COUNT++))
        fi
    done
}


set -x
# Function to process files
process_file() {
    local file="$1"

    if [[ "$file" == *"/Camera/"* ]]; then

        # Check if file is 0 bytes and delete it
        if [ ! -s "$file" ]; then
        log_message "Deleting empty file (0 bytes): $file"
        rm "$file"
        log_skipped_file "$file" "Empty file (0 bytes)"
        return
        fi

        log_message "Processing file: $file"

        # Extract the EXIF creation date using exiftool
        local exif_date=$(exiftool -d "%Y-%m-%d" -CreateDate -S -s "$file")

        if [ -z "$exif_date" ]; then
        log_message "EXIF data not found for $file"
        log_skipped_file "$file" "No EXIF data"
        return  # Skip files without EXIF data
        fi

        # Parse the year, month, and day from the EXIF date
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
            log_message "Removed existing symlink: $dest_file_path"
        fi

        mv "$file" "$dest_file_path"
        log_message "Processed and moved: $file -> $dest_file_path"
        log_processed_file "$file" "$dest_file_path"
    fi
}



set -x
export -f process_file log_message log_processed_file log_skipped_file log_existing_file
export SORT_SOURCE_DIR SORT_DEST_DIR PROCESSED_LOG_FILE PROCESSED_COUNT SKIPPED_COUNT EXISTING_COUNT ORPHAN_COUNT

set -x
# Initialize processed files log
PROCESSED_LOG_FILE="$SORT_DEST_DIR/processed_files_$(date '+%Y%m%d_%H%M%S').log"
echo "=== PHOTO SORTER PROCESSING LOG ===" > "$PROCESSED_LOG_FILE"
echo "Started: $(date '+%Y-%m-%d %H:%M:%S')" >> "$PROCESSED_LOG_FILE"
echo "Source Directory: $SORT_SOURCE_DIR" >> "$PROCESSED_LOG_FILE"
echo "Destination Directory: $SORT_DEST_DIR" >> "$PROCESSED_LOG_FILE"
echo "" >> "$PROCESSED_LOG_FILE"

set -x
# Start processing
log_message "Starting to process files..."
log_message "Log file: $PROCESSED_LOG_FILE"
echo "DEBUG: Current working directory before cd: $(pwd)"
echo "DEBUG: SORT_SOURCE_DIR: $SORT_SOURCE_DIR"
echo "DEBUG: SORT_DEST_DIR: $SORT_DEST_DIR"

cd "$SORT_SOURCE_DIR" || {
    echo "ERROR: Failed to change to source directory: $SORT_SOURCE_DIR"
    exit 1
}
echo "DEBUG: Changed to directory: $(pwd)"

set -x
# Use fd to find image files and process them
log_message "Searching for image files in Camera directories..."
echo "DEBUG: Running fd command..."
echo "DEBUG: Command: fd --type file --exec bash -c 'process_file \"\$@\"' bash {}"
echo "DEBUG: Working directory: $(pwd)"

set -x
# Run fd command with detailed error capture
fd_command="fd --type file --exec bash -c 'process_file \"\$@\"' bash {}"
echo "DEBUG: Executing: $fd_command"

# Capture both stdout and stderr for debugging
fd --type file --exec bash -c 'process_file "$@"' bash {} 2>&1

echo "DEBUG: fd command completed successfully"

set -x
cleanup_orphans

set -x
# Generate summary
log_message "Processing complete!"
echo "" >> "$PROCESSED_LOG_FILE"
echo "=== SUMMARY ===" >> "$PROCESSED_LOG_FILE"
echo "Total files processed: $PROCESSED_COUNT" >> "$PROCESSED_LOG_FILE"
echo "Total files skipped: $SKIPPED_COUNT" >> "$PROCESSED_LOG_FILE"
echo "Total files already existing: $EXISTING_COUNT" >> "$PROCESSED_LOG_FILE"
echo "Total orphaned symlinks removed: $ORPHAN_COUNT" >> "$PROCESSED_LOG_FILE"
echo "Finished: $(date '+%Y-%m-%d %H:%M:%S')" >> "$PROCESSED_LOG_FILE"

# Print summary to console
echo "╔════════════════════════════════════════════════════════════╗"
echo "║                 PHOTO SORTER SUMMARY                       ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo "Files processed: $PROCESSED_COUNT"
echo "Files skipped: $SKIPPED_COUNT"
echo "Files already existing: $EXISTING_COUNT"
echo "Orphaned symlinks removed: $ORPHAN_COUNT"
echo "Log file created: $PROCESSED_LOG_FILE"
