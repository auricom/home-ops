#!/bin/bash

#set -x

exec > >(awk '{ print strftime("[%Y-%m-%d %H:%M:%S]"), $0 }') 2>&1

checkForVariable()
{
    local env_var=
    env_var=$(declare -p "$1")
    if !  [[ -v $1 && $env_var =~ ^declare\ -x ]]; then
        echo "ERROR: $1 environment variable is not set"
        exit 1
    fi
}

export MODE_DELETE=false
export MODE_CHECKSUM=false
export MODE_DRY_RUN=false
export TIMESTAMP=$(date "+%Y%m%d_%H%M%S")

checkForVariable TRANSCODE_INPUT_DIR
checkForVariable TRANSCODE_OUTPUT_DIR

if [ -z "$TRANSCODE_DB" ]; then
    export TRANSCODE_DB="$TRANSCODE_OUTPUT_DIR.transcode"
fi

if [ -z "$TRANSCODE_FREAC_BIN" ]; then
    export TRANSCODE_FREAC_BIN="/app/freac.AppImage"
fi
if [ -z "$TRANSCODE_COVER_EXTENSIONS" ]; then
    export TRANSCODE_COVER_EXTENSIONS="png jpg"
fi
if [ -z "$TRANSCODE_MUSIC_EXTENSIONS" ]; then
    export TRANSCODE_MUSIC_EXTENSIONS="flac opus mp3 ogg wma m4a wav"
fi
if [ -z "$TRANSCODE_FD_FILTERS" ]; then
    export TRANSCODE_FD_FILTERS="--changed-within 1week"
fi

if [ ! -d "$TRANSCODE_INPUT_DIR" ]; then
    echo "ERROR: Directory $TRANSCODE_INPUT_DIR does not exists"
    exit 1
fi
if [ ! -d "$TRANSCODE_OUTPUT_DIR" ]; then
    echo "ERROR: Directory $TRANSCODE_OUTPUT_DIR does not exists"
    exit 1
fi
if [ ! -f "$TRANSCODE_FREAC_BIN" ]; then
    echo "ERROR: Binary $TRANSCODE_FREAC_BIN does not exists"
    exit 1
fi
grep -q ID_LIKE=debian /etc/os-release
if [ $? -eq 0 ]; then
    export TRANSCODE_FD_BIN="fdfind"
else
    export TRANSCODE_FD_BIN="fd"
fi

test ! -d $TRANSCODE_DB && mkdir -p $TRANSCODE_DB

if [ ! -f "$(pwd)/transcode_exclude.cfg" ]; then
    echo "ERROR : transcode_exclude.cfg file is missing"
    exit 1
fi


while getopts ':frcd' OPTION; do
    case "$OPTION" in
        f)
        echo "INFO: FULL MODE"
        export TRANSCODE_FD_FILTERS=""
        ;;
        r)
        echo "INFO: DELETE MODE"
        export MODE_DELETE=true
        ;;
        c)
        echo "INFO: CHECKSUM MODE"
        export MODE_CHECKSUM=true
        ;;
        d)
        echo "INFO: DRY RUN MODE"
        export MODE_DRY_RUN=true
        ;;
        ?)
        echo "script usage: $(basename \$0) [-f] [-r] [-c] [-d]"
        exit 1
        ;;
    esac
done

transcode()
{   
    input_file=$1
    output_file=$2
    md5_file=$3

    if [ $MODE_DRY_RUN == false ]; then
        $TRANSCODE_FREAC_BIN freaccmd --encoder=opus --bitrate 64 "$input_file" -o "$output_file"
        if [ $? -ne 0 ]; then exit 1; fi  
        mkdir -p "$TRANSCODE_DB/$(dirname "$input_file")"
        echo "$(md5sum "$input_file" | awk '{ print $1 }')" > "$md5_file"
    else
        echo "INFO: transcoding $1"
    fi
}

write_cue()
{
    input_file=$1
    output_file=$2
    replacement_string=$3
    md5_file=$4

    echo "##: writing $input_file"
    if [ $MODE_DRY_RUN == false ]; then
        sed -i "/FILE/c $replacement_string" "$output_file"
        if [ $? -ne 0 ]; then
            echo "ERROR: writing cuefile $output_file"
            exit 1
        fi
        mkdir -p "$TRANSCODE_DB/$(dirname "$input_file")"
        echo "$(md5sum "$input_file" | awk '{ print $1 }')" > "$md5_file"
    fi
}

write_jpg()
{
    input_file=$1
    output_file=$2
    md5_file=$3

    echo "##: converting cover $input_file"
    if [ $MODE_DRY_RUN == false ]; then
        convert "$input_file" -resize 1000 -quality 75 "$output_file"
        if [ $? -ne 0 ]; then
            echo "ERROR: converting cover $input_file"
            exit 1
        fi
        mkdir -p "$TRANSCODE_DB/$(dirname "$input_file")"
        echo "$(md5sum "$input_file" | awk '{ print $1 }')" > "$md5_file"
    fi
}

directory_structure()
{
    if [ $MODE_DRY_RUN == true ]; then
        DRYRUN_FLAG="--dry-run"
    else
        DRYRUN_FLAG=""
    fi
    echo ""
    echo "INFO: Creating directory structure with rsync..."
    rsync -rvz $DRYRUN_FLAG --exclude-from="./transcode_exclude.cfg" --include="*/" --exclude="*" $TRANSCODE_INPUT_DIR $TRANSCODE_OUTPUT_DIR
}

convert_covers()
{   
    echo "INFO: Looking for covers to convert..."
    cd $TRANSCODE_INPUT_DIR

    trap "exit" INT
    for ext in $TRANSCODE_COVER_EXTENSIONS
    do
        FILES=$($TRANSCODE_FD_BIN --extension $ext $TRANSCODE_FD_FILTERS)
        mapfile -t StringArray <<< "$FILES"
        for val in "${StringArray[@]}"; do
            if [ ! -z "$val" ]; then
                FILENAME="$TRANSCODE_OUTPUT_DIR$(dirname "$val")/$(basename "$val" .$ext).jpg"
                MD5_FILENAME="$TRANSCODE_DB/$(dirname "$val")/$(basename "$val").md5"
                # Check if a MD5 checksum already exists
                RESULT=$($TRANSCODE_FD_BIN . "$(dirname "$MD5_FILENAME")" | grep -F "$(basename "$MD5_FILENAME")")
                if [ $? -ne 0 ] ; then
                    write_jpg "$val" "$FILENAME" "$MD5_FILENAME"
                # Check if an existing MD5 checksum is different
                elif [ $MODE_CHECKSUM == true ]; then
                    if [ "$(cat "$MD5_FILENAME")" != "$(md5sum "$val" | awk '{ print $1 }')" ]; then
                        write_jpg "$val" "$FILENAME" "$MD5_FILENAME"
                    fi
                fi
            fi
        done
    done
}

convert_music()
{
    echo "INFO: Looking for music to transcode..."
    cd $TRANSCODE_INPUT_DIR

    trap "exit" INT
    for ext in $TRANSCODE_MUSIC_EXTENSIONS
    do
        FILES=$($TRANSCODE_FD_BIN --extension $ext $TRANSCODE_FD_FILTERS)
        mapfile -t StringArray <<< "$FILES"
        for val in "${StringArray[@]}"; do
            if [ ! -z "$val" ]; then
                FILEBASENAME="$TRANSCODE_OUTPUT_DIR$(dirname "$val")/$(basename "$val" .$ext)"
                FILENAME="$FILEBASENAME.opus"
                MD5_FILENAME="$TRANSCODE_DB/$(dirname "$val")/$(basename "$val" .$ext).md5"
                # Check if a MD5 checksum already exists
                RESULT=$($TRANSCODE_FD_BIN . "$(dirname "$MD5_FILENAME")" | grep -F "$(basename "$MD5_FILENAME")")
                if [ $? -ne 0 ] ; then
                    transcode "$val" "$FILENAME" "$MD5_FILENAME"
                # Check if an existing MD5 checksum is different
                elif [ $MODE_CHECKSUM == true ]; then
                    if [ "$(cat "$MD5_FILENAME")" != "$(md5sum "$val" | awk '{ print $1 }')" ]; then
                        transcode "$val" "$FILENAME" "$MD5_FILENAME"
                    fi
                fi
            fi
        done
    done
}

fix_cuefiles()
{
    echo "INFO: Looking for cuefiles..."
    cd $TRANSCODE_INPUT_DIR

    FILES=$($TRANSCODE_FD_BIN --extension cue $TRANSCODE_FD_FILTERS)
    mapfile -t StringArray <<< "$FILES"
    for val in "${StringArray[@]}"; do
        if [ ! -z "$val" ]; then
            MD5_FILENAME="$TRANSCODE_DB/$val.md5"
            REPLACEMENT_TEXT_STRING="FILE \"$(basename "$val" .cue).opus\" MP3"
            # Check if a MD5 checksum already exists
            RESULT=$($TRANSCODE_FD_BIN . "$(dirname "$MD5_FILENAME")" | grep -F "$(basename "$MD5_FILENAME")")
            if [ $? -ne 0 ] ; then
                cp -pr "$val" "$TRANSCODE_OUTPUT_DIR/$val"
                write_cue "$val" "$TRANSCODE_OUTPUT_DIR/$val" "$REPLACEMENT_TEXT_STRING" "$MD5_FILENAME"
            # Check if an existing MD5 checksum is different
            elif [ $MODE_CHECKSUM == true ]; then
                if [ "$(cat "$MD5_FILENAME")" != "$(md5sum "$val" | awk '{ print $1 }')" ]; then
                cp -pr "$val" "$TRANSCODE_OUTPUT_DIR/$val"
                    write_cue "$val" "$TRANSCODE_OUTPUT_DIR/$val" "$REPLACEMENT_TEXT_STRING" "$MD5_FILENAME"
                fi
            fi
        fi
    done
}

remove_absent_from_source()
{
    cd $TRANSCODE_DB
    
    EXTENSIONS="md5"
    for ext in $EXTENSIONS
    do
        FILES=$($TRANSCODE_FD_BIN --extension $ext)
        mapfile -t StringArray <<< "$FILES"
        for val in "${StringArray[@]}"; do
            if [ ! -z "$val" ]; then
                FILENAME=$(dirname "$val")/$(basename "$val" .$ext)
                RESULT=$($TRANSCODE_FD_BIN . "$TRANSCODE_INPUT_DIR/$(dirname "$FILENAME")" | grep -F "$(basename "$FILENAME" .$ext)")
                # Transcoded file don't have a source file : delete
                if [ $? -ne 0 ]; then
                    echo "INFO: Transcoded file $FILENAME don't have a source file : delete"
                    if [ $MODE_DRY_RUN == false ]; then
                        rm "$TRANSCODE_OUTPUT_DIR/$FILENAME"*
                        rm "$TRANSCODE_DB/$FILENAME"*
                    fi
                fi
            fi
        done
    done

    echo "INFO: removing empty directories..."
    
    if [ $MODE_DRY_RUN == false ]; then
        cd "$TRANSCODE_OUTPUT_DIR"
        fd --type empty --exec-batch rmdir
        cd "$TRANSCODE_DB"
        fd --type empty --exec-batch rmdir
    fi
}

cp -r ./transcode_exclude.cfg $TRANSCODE_INPUT_DIR/.fdignore
cp -r ./transcode_exclude.cfg $TRANSCODE_OUTPUT_DIR/.fdignore

if [ $MODE_DELETE == false ]; then
    directory_structure

    convert_covers

    convert_music

    fix_cuefiles
else
    remove_absent_from_source
fi

rm "$TRANSCODE_INPUT_DIR/.fdignore"
rm "$TRANSCODE_OUTPUT_DIR/.fdignore"