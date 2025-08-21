#!/bin/bash

# Exit on any error
set -e
# Exit on undefined variable
set -u
# Exit if any command in pipe fails
set -o pipefail

# Set locale to UTF-8
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

# Create a logging function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

checkForVariable() {
    if [[ -z "${!1:-}" ]]; then
        log "ERROR: $1 environment variable is not set"
        exit 1
    fi
}

cleanup() {
    local exit_code=$?
    log "Cleaning up..."
    [[ -f "$TRANSCODE_INPUT_DIR/.fdignore" ]] && rm -f "$TRANSCODE_INPUT_DIR/.fdignore"
    [[ -f "$TRANSCODE_OUTPUT_DIR/.fdignore" ]] && rm -f "$TRANSCODE_OUTPUT_DIR/.fdignore"
    exit $exit_code
}

manage_execution_time() {
    local timestamp_file="$TRANSCODE_DB/last_execution"

    if [[ "$1" == "read" ]]; then
        if [[ -f "$timestamp_file" ]]; then
            cat "$timestamp_file"
        else
            echo "@0"  # Return epoch if no previous execution
        fi
    elif [[ "$1" == "write" ]]; then
        date +%s | sed 's/^/@/' > "$timestamp_file"  # Store as @timestamp format
    fi
}

fd_safe() {
    local cmd_args=("$@")
    log "DEBUG: Executing fd command: $TRANSCODE_FD_BIN ${cmd_args[*]}"

    local output
    local exit_code

    # Capture both stdout and stderr
    if output=$("$TRANSCODE_FD_BIN" "${cmd_args[@]}" 2>&1); then
        exit_code=0
        # If there's output and it's not just whitespace, log it
        if [[ -n "${output// }" ]]; then
            log "DEBUG: fd command output: $output"
        fi
    else
        exit_code=$?
        log "ERROR: fd command failed with exit code $exit_code"
        log "ERROR: Command was: $TRANSCODE_FD_BIN ${cmd_args[*]}"
        log "ERROR: Working directory: $(pwd)"
        log "ERROR: fd output/error: $output"

        # Additional debugging info
        log "DEBUG: TRANSCODE_FD_BIN=$TRANSCODE_FD_BIN"
        log "DEBUG: TRANSCODE_FD_FILTERS=$TRANSCODE_FD_FILTERS"
        log "DEBUG: Current directory contents:"
        ls -la . | head -10 | while read -r line; do
            log "DEBUG:   $line"
        done

        exit 1
    fi
}

trap cleanup EXIT
trap 'log "Script interrupted by user"; exit 1' INT TERM

# Initialize variables with defaults
export MODE_DELETE=false
export MODE_CHECKSUM=false
export MODE_DRY_RUN=false
export TIMESTAMP=$(date "+%Y%m%d_%H%M%S")

# Check required environment variables
checkForVariable TRANSCODE_INPUT_DIR
checkForVariable TRANSCODE_OUTPUT_DIR

# Set defaults if not defined
export TRANSCODE_DB="${TRANSCODE_DB:-${TRANSCODE_OUTPUT_DIR}.transcode}"
export TRANSCODE_FREAC_BIN="${TRANSCODE_FREAC_BIN:-/app/freaccmd}"
export TRANSCODE_COVER_EXTENSIONS="${TRANSCODE_COVER_EXTENSIONS:-png jpg}"
export TRANSCODE_MUSIC_EXTENSIONS="${TRANSCODE_MUSIC_EXTENSIONS:-flac opus mp3 ogg wma m4a wav}"
if [[ -n "${TRANSCODE_FD_FILTERS+x}" ]]; then
    : # Keep existing value if explicitly set
else
    if [[ "$*" == *"-f"* ]]; then
        export TRANSCODE_FD_FILTERS=""
    else
        last_exec=$(manage_execution_time read)
        export TRANSCODE_FD_FILTERS="--changed-after $last_exec"
    fi
fi

# Validate directories and files
for dir in "$TRANSCODE_INPUT_DIR" "$TRANSCODE_OUTPUT_DIR"; do
    if [[ ! -d "$dir" ]]; then
        log "ERROR: Directory $dir does not exist"
        exit 1
    fi
done

if [[ ! -f "$TRANSCODE_FREAC_BIN" ]]; then
    log "ERROR: Binary $TRANSCODE_FREAC_BIN does not exist"
    exit 1
fi

if [[ ! -f "$(pwd)/transcode_exclude.cfg" ]]; then
    log "ERROR: transcode_exclude.cfg file is missing"
    exit 1
fi

# Determine fd binary name based on OS
if grep -q ID_LIKE=debian /etc/os-release; then
    export TRANSCODE_FD_BIN="fdfind"
else
    export TRANSCODE_FD_BIN="fd"
fi

command -v "$TRANSCODE_FD_BIN" >/dev/null 2>&1 || {
    log "ERROR: $TRANSCODE_FD_BIN is required but not installed"
    exit 1
}

export LD_LIBRARY_PATH="$(dirname "$TRANSCODE_FREAC_BIN")"

# Create transcode DB directory if it doesn't exist
mkdir -p "$TRANSCODE_DB"

# Parse command line options
while getopts ':frcd' OPTION; do
    case "$OPTION" in
        f)
            log "INFO: FULL MODE"
            export TRANSCODE_FD_FILTERS=""
            ;;
        r)
            log "INFO: DELETE MODE"
            export MODE_DELETE=true
            ;;
        c)
            log "INFO: CHECKSUM MODE"
            export MODE_CHECKSUM=true
            ;;
        d)
            log "INFO: DRY RUN MODE"
            export MODE_DRY_RUN=true
            ;;
        ?)
            log "script usage: $(basename "$0") [-f] [-r] [-c] [-d]"
            exit 1
            ;;
    esac
done

transcode() {
    local input_file="$1"
    local output_file="$2"
    local md5_file="$3"

    log "##: Processing file $input_file..."
    if [[ $MODE_DRY_RUN == false ]]; then
        local output
        if ! output=$("$TRANSCODE_FREAC_BIN" --encoder=opus --bitrate 96 "$input_file" -o "$output_file" 2>&1); then
            log "ERROR: Transcoding failed for $input_file"
            log "$output"
            return 1
        fi

        if echo "$output" | grep -q "Could not process"; then
            log "ERROR: Could not process $input_file"
            log "$output"
            return 1
        fi

        mkdir -p "$(dirname "$md5_file")"
        md5sum "$input_file" | cut -d' ' -f1 > "$md5_file"
        log "Successfully transcoded: $input_file -> $output_file"
    fi
}

write_cue() {
    local input_file="$1"
    local output_file="$2"
    local replacement_string="$3"
    local md5_file="$4"

    log "##: writing $input_file"
    if [[ $MODE_DRY_RUN == false ]]; then
        if ! sed -i "/FILE/c $replacement_string" "$output_file"; then
            log "ERROR: writing cuefile $output_file"
            return 1
        fi

        mkdir -p "$(dirname "$md5_file")"
        md5sum "$input_file" | cut -d' ' -f1 > "$md5_file"
        log "Successfully wrote cue: $output_file"
    fi
}

write_jpg() {
    local input_file="$1"
    local output_file="$2"
    local md5_file="$3"

    log "##: converting cover $input_file"
    if [[ $MODE_DRY_RUN == false ]]; then
        if ! convert "$input_file" -resize 1000 -quality 75 "$output_file"; then
            log "ERROR: converting cover $input_file"
            return 1
        fi

        mkdir -p "$(dirname "$md5_file")"
        md5sum "$input_file" | cut -d' ' -f1 > "$md5_file"
        log "Successfully converted cover: $input_file -> $output_file"
    fi
}

process_file() {
    local val="$1"
    local ext="$2"
    local type="$3"  # cover, music, or cue

    case "$type" in
        cover)
            local filename="$TRANSCODE_OUTPUT_DIR/${val%.*}.jpg"
            local md5_filename="$TRANSCODE_DB/${val}.md5"
            local process_file=false

            # Create output directory if it doesn't exist
            mkdir -p "$(dirname "$filename")"
            mkdir -p "$(dirname "$md5_filename")"

            # Check if we need to process this file
            if [[ ! -f "$md5_filename" ]]; then
                process_file=true
                log "Processing new file: $val"
            elif [[ $MODE_CHECKSUM == true ]]; then
                if [[ ! -f "$md5_filename" ]] || [[ "$(cat "$md5_filename" 2>/dev/null)" != "$(md5sum "$val" | cut -d' ' -f1)" ]]; then
                    process_file=true
                    log "File changed, reprocessing: $val"
                fi
            fi

            if [[ $process_file == true ]]; then
                write_jpg "$val" "$filename" "$md5_filename"
            fi
            ;;

        music)
            local filebasename="$TRANSCODE_OUTPUT_DIR/${val%.*}"
            local filename="${filebasename}.opus"
            local md5_filename="$TRANSCODE_DB/${val}.md5"
            local process_file=false

            # Create output directory if it doesn't exist
            mkdir -p "$(dirname "$filename")"
            mkdir -p "$(dirname "$md5_filename")"

            # Check if we need to process this file
            if [[ ! -f "$md5_filename" ]]; then
                process_file=true
                log "Processing new file: $val"
            elif [[ $MODE_CHECKSUM == true ]]; then
                if [[ ! -f "$md5_filename" ]] || [[ "$(cat "$md5_filename" 2>/dev/null)" != "$(md5sum "$val" | cut -d' ' -f1)" ]]; then
                    process_file=true
                    log "File changed, reprocessing: $val"
                fi
            fi

            if [[ $process_file == true ]]; then
                transcode "$val" "$filename" "$md5_filename"
            fi
            ;;

        cue)
            local output_file="$TRANSCODE_OUTPUT_DIR/$val"
            local md5_filename="$TRANSCODE_DB/${val}.md5"
            local replacement_text_string="FILE \"$(basename "${val%.*}").opus\" MP3"
            local process_file=false

            # Create output directory if it doesn't exist
            mkdir -p "$(dirname "$output_file")"
            mkdir -p "$(dirname "$md5_filename")"

            # Check if we need to process this file
            if [[ ! -f "$md5_filename" ]]; then
                process_file=true
                log "Processing new cuefile: $val"
            elif [[ $MODE_CHECKSUM == true ]]; then
                if [[ ! -f "$md5_filename" ]] || [[ "$(cat "$md5_filename" 2>/dev/null)" != "$(md5sum "$val" | cut -d' ' -f1)" ]]; then
                    process_file=true
                    log "Cuefile changed, reprocessing: $val"
                fi
            fi

            if [[ $process_file == true ]]; then
                cp -p "$val" "$output_file"
                write_cue "$val" "$output_file" "$replacement_text_string" "$md5_filename"
            fi
            ;;
    esac
}

directory_structure() {
    local dryrun_flag=""
    [[ $MODE_DRY_RUN == true ]] && dryrun_flag="--dry-run"

    log "INFO: Creating directory structure with rsync..."
    if ! rsync -rvz $dryrun_flag --exclude-from="./transcode_exclude.cfg" \
        --include="*/" --exclude="*" "$TRANSCODE_INPUT_DIR/" "$TRANSCODE_OUTPUT_DIR/"; then
        log "ERROR: rsync failed"
        return 1
    fi
}

# Export functions so they're available to subshells
export -f log
export -f transcode
export -f write_cue
export -f write_jpg
export -f process_file

convert_covers() {
    log "INFO: Looking for covers to convert..."
    log "DEBUG: Changing to directory: $TRANSCODE_INPUT_DIR"
    cd "$TRANSCODE_INPUT_DIR" || exit 1

    for ext in $TRANSCODE_COVER_EXTENSIONS; do
        log "INFO: Searching for .$ext files..."
        log "DEBUG: Processing extension: $ext"
        log "DEBUG: FD filters: $TRANSCODE_FD_FILTERS"

        # Create a temporary script for processing
        local temp_script=$(mktemp)
        log "DEBUG: Created temp script: $temp_script"
        cat > "$temp_script" << 'EOF'
#!/bin/bash
process_file "$1" "$2" "$3"
EOF
        chmod +x "$temp_script"

        log "DEBUG: About to run fd_safe for covers with extension $ext"
        fd_safe --extension "$ext" $TRANSCODE_FD_FILTERS --type f -x "$temp_script" {} "$ext" cover \;
        log "DEBUG: Completed fd_safe for covers with extension $ext"
        rm -f "$temp_script"
    done
}

convert_music() {
    log "INFO: Looking for music to transcode..."
    log "DEBUG: Changing to directory: $TRANSCODE_INPUT_DIR"
    cd "$TRANSCODE_INPUT_DIR" || exit 1

    for ext in $TRANSCODE_MUSIC_EXTENSIONS; do
        log "INFO: Searching for .$ext files..."
        log "DEBUG: Processing extension: $ext"
        log "DEBUG: FD filters: $TRANSCODE_FD_FILTERS"

        # Create a temporary script for processing
        local temp_script=$(mktemp)
        log "DEBUG: Created temp script: $temp_script"
        cat > "$temp_script" << 'EOF'
#!/bin/bash
process_file "$1" "$2" "$3"
EOF
        chmod +x "$temp_script"

        log "DEBUG: About to run fd_safe for music with extension $ext"
        fd_safe --extension "$ext" $TRANSCODE_FD_FILTERS --type f -x "$temp_script" {} "$ext" music \;
        log "DEBUG: Completed fd_safe for music with extension $ext"
        rm -f "$temp_script"
    done
}

fix_cuefiles() {
    log "INFO: Looking for cuefiles..."
    log "DEBUG: Changing to directory: $TRANSCODE_INPUT_DIR"
    cd "$TRANSCODE_INPUT_DIR" || exit 1

    log "DEBUG: FD filters: $TRANSCODE_FD_FILTERS"

    # Create a temporary script for processing
    local temp_script=$(mktemp)
    log "DEBUG: Created temp script: $temp_script"
    cat > "$temp_script" << 'EOF'
#!/bin/bash
process_file "$1" "$2" "$3"
EOF
    chmod +x "$temp_script"

    log "DEBUG: About to run fd_safe for cue files"
    fd_safe --extension cue $TRANSCODE_FD_FILTERS --type f -x "$temp_script" {} cue cue \;
    log "DEBUG: Completed fd_safe for cue files"
    rm -f "$temp_script"
}

remove_absent_from_source() {
    log "INFO: Looking for files to remove from output that no longer exist in source..."
    log "DEBUG: Changing to directory: $TRANSCODE_DB"
    cd "$TRANSCODE_DB" || exit 1

    # Create a temporary script file for the removal operation
    local temp_script=$(mktemp)
    log "DEBUG: Created temp script: $temp_script"
    cat > "$temp_script" << 'EOF'
#!/bin/bash
val="$1"
[[ -z "$val" ]] && exit 0

filename="$(dirname "$val")/$(basename "$val" .md5)"
source_path="$TRANSCODE_INPUT_DIR/$filename"

if [[ ! -e "$source_path" ]]; then
    if ! find "$TRANSCODE_INPUT_DIR/$(dirname "$filename")" -maxdepth 1 -name "$(basename "$filename")*" 2>/dev/null | grep -q .; then
        echo "[$(date "+%Y-%m-%d %H:%M:%S")] INFO: Confirmed - Transcoded file $filename doesnt have a source file: delete"
        if [[ $MODE_DELETE == true && $MODE_DRY_RUN == false ]]; then
            rm -f "$TRANSCODE_OUTPUT_DIR/$filename"*
            rm -f "$TRANSCODE_DB/$filename"*
        fi
    fi
fi
EOF
    chmod +x "$temp_script"

    log "DEBUG: About to run fd command for md5 files in removal check"
    log "DEBUG: Command: $TRANSCODE_FD_BIN --extension md5 -x $temp_script {} \\;"
    "$TRANSCODE_FD_BIN" --extension md5 -x "$temp_script" {} \;
    log "DEBUG: Completed fd command for md5 files in removal check"
    rm -f "$temp_script"

    log "INFO: removing empty directories..."
    if [[ $MODE_DRY_RUN == false ]]; then
        find "$TRANSCODE_OUTPUT_DIR" -type d -empty -delete 2>/dev/null || true
        find "$TRANSCODE_DB" -type d -empty -delete 2>/dev/null || true
    fi
}

# Main execution
cp -f ./transcode_exclude.cfg "$TRANSCODE_INPUT_DIR/.fdignore"
cp -f ./transcode_exclude.cfg "$TRANSCODE_OUTPUT_DIR/.fdignore"

if [[ $MODE_DELETE == false ]]; then
    directory_structure
    convert_covers
    convert_music
    fix_cuefiles
else
    remove_absent_from_source
fi

if [[ $MODE_DRY_RUN == false ]]; then
    manage_execution_time write
fi
