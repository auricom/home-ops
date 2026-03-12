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

log() {
    # gum log --structured --level "$@"
    echo "$@"
}

checkForVariable() {
    if [[ -z "${!1:-}" ]]; then
        log error "$1 environment variable is not set"
        exit 1
    fi
}

cleanup() {
    local exit_code=$?
    log info "Cleaning up..."
    [[ -f "$TRANSCODE_INPUT_DIR/.fdignore" ]] && rm -f "$TRANSCODE_INPUT_DIR/.fdignore"
    [[ -f "$TRANSCODE_OUTPUT_DIR/.fdignore" ]] && rm -f "$TRANSCODE_OUTPUT_DIR/.fdignore"
    [[ -f "${TRANSCODE_OUTPUT_DIR}/.transcode.lock" ]] && rm -f "${TRANSCODE_OUTPUT_DIR}/.transcode.lock"
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

# Run a command at idle CPU and IO priority where supported
run_low_priority() {
    if command -v ionice >/dev/null 2>&1; then
        ionice -c3 nice -n 19 "$@"
    else
        nice -n 19 "$@"
    fi
}

fd_safe() {
    local cmd_args=("$@")
    log debug "Executing fd command: $TRANSCODE_FD_BIN ${cmd_args[*]}"

    local output
    local exit_code

    # Capture both stdout and stderr
    if output=$("$TRANSCODE_FD_BIN" "${cmd_args[@]}" 2>&1); then
        exit_code=0
        # If there's output and it's not just whitespace, log it
        if [[ -n "${output// }" ]]; then
            log debug "fd command output: $output"
        fi
    else
        exit_code=$?
        log error "fd command failed with exit code $exit_code"
        log error "Command was: $TRANSCODE_FD_BIN ${cmd_args[*]}"
        log error "Working directory: $(pwd)"
        log error "fd output/error: $output"

        # Additional debugging info
        log debug "TRANSCODE_FD_BIN=$TRANSCODE_FD_BIN"
        log debug "TRANSCODE_FD_FILTERS=$TRANSCODE_FD_FILTERS"
        log debug "Current directory contents:"
        ls -la . | head -10 | while read -r line; do
            log debug "  $line"
        done

        exit 1
    fi
}

trap cleanup EXIT
trap 'log warn "Script interrupted by user"; exit 1' INT TERM

# Initialize variables with defaults
export MODE_DELETE=false
export MODE_CHECKSUM=false
export MODE_DRY_RUN=false
export TIMESTAMP=$(date "+%Y%m%d_%H%M%S")

# Check required environment variables
checkForVariable TRANSCODE_INPUT_DIR
checkForVariable TRANSCODE_OUTPUT_DIR

# Set defaults if not defined
export TRANSCODE_DB="${TRANSCODE_DB:-${TRANSCODE_OUTPUT_DIR}/.transcode}"
export TRANSCODE_JOBS="${TRANSCODE_JOBS:-$(nproc)}"
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
        log error "Directory $dir does not exist"
        exit 1
    fi
done

LOCK_FILE="$TRANSCODE_OUTPUT_DIR/.transcode.lock"
if [ -f "$LOCK_FILE" ]; then
    log info "Lock file exists, another instance is running. Exiting."
    exit 0
fi
touch "$LOCK_FILE"

if [[ ! -f "$(pwd)/transcode_exclude.cfg" ]]; then
    log error "transcode_exclude.cfg file is missing"
    exit 1
fi

# Determine fd binary name based on OS
if grep -q ID_LIKE=debian /etc/os-release; then
    export TRANSCODE_FD_BIN="fdfind"
else
    export TRANSCODE_FD_BIN="fd"
fi

command -v "$TRANSCODE_FD_BIN" >/dev/null 2>&1 || {
    log error "$TRANSCODE_FD_BIN is required but not installed"
    exit 1
}

command -v ffmpeg >/dev/null 2>&1 || {
    log error "ffmpeg is required but not installed"
    exit 1
}

command -v xxh128sum >/dev/null 2>&1 || {
    log error "xxh128sum is required but not installed (install xxhash package)"
    exit 1
}

# Create transcode DB directory if it doesn't exist
mkdir -p "$TRANSCODE_DB"

# Parse command line options
while getopts ':frcd' OPTION; do
    case "$OPTION" in
        f)
            log info "FULL MODE"
            export TRANSCODE_FD_FILTERS=""
            ;;
        r)
            log info "DELETE MODE"
            export MODE_DELETE=true
            ;;
        c)
            log info "CHECKSUM MODE"
            export MODE_CHECKSUM=true
            ;;
        d)
            log info "DRY RUN MODE"
            export MODE_DRY_RUN=true
            ;;
        ?)
            log error "script usage: $(basename "$0") [-f] [-r] [-c] [-d]"
            exit 1
            ;;
    esac
done

transcode() {
    local input_file="$1"
    local output_file="$2"
    local hash_file="$3"
    local file_hash="$4"

    log info "Processing file $input_file..."
    if [[ $MODE_DRY_RUN == false ]]; then
        local output
        if ! output=$(run_low_priority ffmpeg -i "$input_file" -c:a libopus -b:a 96k -vn -y \
                -loglevel error "$output_file" 2>&1); then
            log error "Transcoding failed for $input_file"
            log error "$output"
            return 1
        fi

        mkdir -p "$(dirname "$hash_file")"
        echo "$file_hash" > "$hash_file"
        log info "Successfully transcoded: $input_file -> $output_file"
    fi
}

write_cue() {
    local input_file="$1"
    local output_file="$2"
    local replacement_string="$3"
    local hash_file="$4"
    local file_hash="$5"

    log info "Writing $input_file"
    if [[ $MODE_DRY_RUN == false ]]; then
        if ! sed -i "/FILE/c $replacement_string" "$output_file"; then
            log error "Writing cuefile $output_file failed"
            return 1
        fi

        mkdir -p "$(dirname "$hash_file")"
        echo "$file_hash" > "$hash_file"
        log info "Successfully wrote cue: $output_file"
    fi
}

write_jpg() {
    local input_file="$1"
    local output_file="$2"
    local hash_file="$3"
    local file_hash="$4"

    log info "Converting cover $input_file"
    if [[ $MODE_DRY_RUN == false ]]; then
        local output
        if ! output=$(run_low_priority ffmpeg -i "$input_file" \
                -vf "scale=1000:-2" -q:v 4 -y -loglevel error "$output_file" 2>&1); then
            log error "Converting cover $input_file failed"
            log error "$output"
            return 1
        fi

        mkdir -p "$(dirname "$hash_file")"
        echo "$file_hash" > "$hash_file"
        log info "Successfully converted cover: $input_file -> $output_file"
    fi
}

process_file() {
    local val="$1"
    local ext="$2"
    local type="$3"  # cover, music, or cue

    case "$type" in
        cover)
            local filename="$TRANSCODE_OUTPUT_DIR/${val%.*}.jpg"
            local hash_filename="$TRANSCODE_DB/${val}.hash"
            local do_process=false
            local current_hash=""

            mkdir -p "$(dirname "$filename")"
            mkdir -p "$(dirname "$hash_filename")"

            if [[ ! -f "$hash_filename" ]]; then
                do_process=true
                log info "Processing new file: $val"
            elif [[ $MODE_CHECKSUM == true ]]; then
                current_hash=$(xxh128sum "$val" | cut -d' ' -f1)
                if [[ "$(cat "$hash_filename" 2>/dev/null)" != "$current_hash" ]]; then
                    do_process=true
                    log info "File changed, reprocessing: $val"
                fi
            fi

            if [[ $do_process == true ]]; then
                [[ -z "$current_hash" ]] && current_hash=$(xxh128sum "$val" | cut -d' ' -f1)
                write_jpg "$val" "$filename" "$hash_filename" "$current_hash"
            fi
            ;;

        music)
            local filename="$TRANSCODE_OUTPUT_DIR/${val%.*}.opus"
            local hash_filename="$TRANSCODE_DB/${val}.hash"
            local do_process=false
            local current_hash=""

            mkdir -p "$(dirname "$filename")"
            mkdir -p "$(dirname "$hash_filename")"

            if [[ ! -f "$hash_filename" ]]; then
                do_process=true
                log info "Processing new file: $val"
            elif [[ $MODE_CHECKSUM == true ]]; then
                current_hash=$(xxh128sum "$val" | cut -d' ' -f1)
                if [[ "$(cat "$hash_filename" 2>/dev/null)" != "$current_hash" ]]; then
                    do_process=true
                    log info "File changed, reprocessing: $val"
                fi
            fi

            if [[ $do_process == true ]]; then
                [[ -z "$current_hash" ]] && current_hash=$(xxh128sum "$val" | cut -d' ' -f1)
                transcode "$val" "$filename" "$hash_filename" "$current_hash"
            fi
            ;;

        cue)
            local output_file="$TRANSCODE_OUTPUT_DIR/$val"
            local hash_filename="$TRANSCODE_DB/${val}.hash"
            local replacement_text_string="FILE \"$(basename "${val%.*}").opus\" MP3"
            local do_process=false
            local current_hash=""

            mkdir -p "$(dirname "$output_file")"
            mkdir -p "$(dirname "$hash_filename")"

            if [[ ! -f "$hash_filename" ]]; then
                do_process=true
                log info "Processing new cuefile: $val"
            elif [[ $MODE_CHECKSUM == true ]]; then
                current_hash=$(xxh128sum "$val" | cut -d' ' -f1)
                if [[ "$(cat "$hash_filename" 2>/dev/null)" != "$current_hash" ]]; then
                    do_process=true
                    log info "Cuefile changed, reprocessing: $val"
                fi
            fi

            if [[ $do_process == true ]]; then
                [[ -z "$current_hash" ]] && current_hash=$(xxh128sum "$val" | cut -d' ' -f1)
                cp -p "$val" "$output_file"
                write_cue "$val" "$output_file" "$replacement_text_string" "$hash_filename" "$current_hash"
            fi
            ;;
    esac
}

directory_structure() {
    local dryrun_flag=""
    [[ $MODE_DRY_RUN == true ]] && dryrun_flag="--dry-run"

    log info "Creating directory structure with rsync..."
    if ! rsync -rq $dryrun_flag --exclude-from="./transcode_exclude.cfg" \
        --include="*/" --exclude="*" "$TRANSCODE_INPUT_DIR/" "$TRANSCODE_OUTPUT_DIR/"; then
        log error "rsync failed"
        return 1
    fi
}

# Export functions so they're available to subshells via bash -c
export -f log
export -f run_low_priority
export -f transcode
export -f write_cue
export -f write_jpg
export -f process_file

convert_covers() {
    log info "Looking for covers to convert..."
    cd "$TRANSCODE_INPUT_DIR" || exit 1

    for ext in $TRANSCODE_COVER_EXTENSIONS; do
        log info "Searching for .$ext files..."
        "$TRANSCODE_FD_BIN" --extension "$ext" $TRANSCODE_FD_FILTERS --type f \
            -j "$TRANSCODE_JOBS" \
            -x bash -c 'process_file "$1" "$2" "$3"' _ {} "$ext" cover \;
    done
}

convert_music() {
    log info "Looking for music to transcode..."
    cd "$TRANSCODE_INPUT_DIR" || exit 1

    for ext in $TRANSCODE_MUSIC_EXTENSIONS; do
        log info "Searching for .$ext files..."
        "$TRANSCODE_FD_BIN" --extension "$ext" $TRANSCODE_FD_FILTERS --type f \
            -j "$TRANSCODE_JOBS" \
            -x bash -c 'process_file "$1" "$2" "$3"' _ {} "$ext" music \;
    done
}

fix_cuefiles() {
    log info "Looking for cuefiles..."
    cd "$TRANSCODE_INPUT_DIR" || exit 1

    "$TRANSCODE_FD_BIN" --extension cue $TRANSCODE_FD_FILTERS --type f \
        -j "$TRANSCODE_JOBS" \
        -x bash -c 'process_file "$1" "$2" "$3"' _ {} cue cue \;
}

remove_absent_from_source() {
    log info "Looking for files to remove from output that no longer exist in source..."

    # Build source file index once to avoid per-file find invocations
    local source_list
    source_list=$(mktemp)
    log debug "Building source file list into $source_list"
    "$TRANSCODE_FD_BIN" --type f "$TRANSCODE_INPUT_DIR" | \
        sed "s|^${TRANSCODE_INPUT_DIR}/||" | sort > "$source_list"
    log debug "Source file list: $(wc -l < "$source_list") files"

    cd "$TRANSCODE_DB" || { rm -f "$source_list"; exit 1; }

    "$TRANSCODE_FD_BIN" --extension md5 --type f | while read -r val; do
        [[ -z "$val" ]] && continue
        local filename="${val%.hash}"
        local base="${filename%.*}"

        # Check exact source match, then any file sharing the same base name (handles format changes)
        if ! grep -qF "$filename" "$source_list" && \
           ! grep -qF "${base}." "$source_list"; then
            log info "Confirmed - Transcoded file $filename doesn't have a source file: delete"
            if [[ $MODE_DELETE == true && $MODE_DRY_RUN == false ]]; then
                rm -f "$TRANSCODE_OUTPUT_DIR/$filename"*
                rm -f "$TRANSCODE_DB/$filename"*
            fi
        fi
    done

    rm -f "$source_list"

    log info "Removing empty directories..."
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
