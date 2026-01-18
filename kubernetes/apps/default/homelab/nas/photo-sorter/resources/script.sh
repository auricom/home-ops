#!/usr/bin/env bash

set -Eeuo pipefail

# Color definitions for beautiful output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Global counters
PROCESSED_COUNT=0
SKIPPED_COUNT=0
EXISTING_COUNT=0
ORPHAN_COUNT=0

# Function to log messages to stdout with colors
log_message() {
    echo -e "${BLUE}$(date '+%Y-%m-%d %H:%M:%S')${NC} - $1"
}

# Function to log processed files to the log file
log_processed_file() {
    local source_file="$1"
    local dest_file="$2"
    echo "PROCESSED: $source_file -> $dest_file" >> "$PROCESSED_LOG_FILE"
    ((PROCESSED_COUNT++))
}

# Function to log skipped files to the log file
log_skipped_file() {
    local file="$1"
    local reason="$2"
    echo "SKIPPED: $file (Reason: $reason)" >> "$PROCESSED_LOG_FILE"
    ((SKIPPED_COUNT++))
}

# Function to log existing files to the log file
log_existing_file() {
    local file="$1"
    echo "EXISTING: $file" >> "$PROCESSED_LOG_FILE"
    ((EXISTING_COUNT++))
}

# Function to cleanup orphaned symlinks
cleanup_orphans() {
    log_message "Cleaning up orphaned symlinks."

    # Use fd to find all broken symlinks in SORT_DEST_DIR
    fd --follow --type symlink '' "$SORT_DEST_DIR" | while IFS= read -r symlink; do
        # Check if the symlink is broken
        if [ ! -e "$symlink" ]; then
            echo -e "${YELLOW}Removing broken symlink: $symlink${NC}"
            rm "$symlink"  # Remove the broken symlink
            log_message "Removed symlink $symlink."
            ((ORPHAN_COUNT++))
        fi
    done
}

# Function to process files
process_file() {

    set -x
    local file="$1"

    log_message "Processing file: $file"

    # Extract the EXIF creation date using exiftool
    local exif_date=$(exiftool -d "%Y-%m-%d" -CreateDate -S -s "$file")

    if [ -z "$exif_date" ]; then
        log_message "${RED}EXIF data not found for $file${NC}"
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
}


export -f process_file log_message log_processed_file log_skipped_file log_existing_file
export SORT_SOURCE_DIR SORT_DEST_DIR PROCESSED_LOG_FILE PROCESSED_COUNT SKIPPED_COUNT EXISTING_COUNT ORPHAN_COUNT

# Initialize processed files log
PROCESSED_LOG_FILE="$SORT_DEST_DIR/processed_files_$(date '+%Y%m%d_%H%M%S').log"
echo "=== PHOTO SORTER PROCESSING LOG ===" > "$PROCESSED_LOG_FILE"
echo "Started: $(date '+%Y-%m-%d %H:%M:%S')" >> "$PROCESSED_LOG_FILE"
echo "Source Directory: $SORT_SOURCE_DIR" >> "$PROCESSED_LOG_FILE"
echo "Destination Directory: $SORT_DEST_DIR" >> "$PROCESSED_LOG_FILE"
echo "" >> "$PROCESSED_LOG_FILE"

# Start processing
log_message "${MAGENTA}Starting to process files...${NC}"
log_message "Log file: $PROCESSED_LOG_FILE"

cd "$SORT_SOURCE_DIR"

# Use fd to find image files and process them
log_message "${CYAN}Searching for image files in Camera directories...${NC}"
fd --type file --exec bash -c 'process_file "$@"' bash {} --path "/Camera/"

cleanup_orphans

# Generate summary
log_message "${MAGENTA}Processing complete!${NC}"
echo "" >> "$PROCESSED_LOG_FILE"
echo "=== SUMMARY ===" >> "$PROCESSED_LOG_FILE"
echo "Total files processed: $PROCESSED_COUNT" >> "$PROCESSED_LOG_FILE"
echo "Total files skipped: $SKIPPED_COUNT" >> "$PROCESSED_LOG_FILE"
echo "Total files already existing: $EXISTING_COUNT" >> "$PROCESSED_LOG_FILE"
echo "Total orphaned symlinks removed: $ORPHAN_COUNT" >> "$PROCESSED_LOG_FILE"
echo "Finished: $(date '+%Y-%m-%d %H:%M:%S')" >> "$PROCESSED_LOG_FILE"

# Print beautiful summary to console
echo -e "${MAGENTA}"
echo "╔════════════════════════════════════════════════════════════╗"
echo "║                 PHOTO SORTER SUMMARY                       ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo -e "${NC}"
echo -e "${GREEN}✓ Files processed: $PROCESSED_COUNT${NC}"
echo -e "${YELLOW}⚠ Files skipped: $SKIPPED_COUNT${NC}"
echo -e "${BLUE}ℹ Files already existing: $EXISTING_COUNT${NC}"
echo -e "${RED}✗ Orphaned symlinks removed: $ORPHAN_COUNT${NC}"
echo -e "${MAGENTA}Log file created: $PROCESSED_LOG_FILE${NC}"
echo -e "${NC}"
