#!/bin/bash

# set -x

export MODE_DELETE=false
export MODE_CHECKSUM=false

while getopts 'fdc:' OPTION; do
    case "$OPTION" in
        f)
        echo "INFO: FULL MODE"
        export TRANSCODE_FD_FILTERS=""
        ;;
        d)
        echo "INFO: DELETE MODE"
        export MODE_DELETE=true
        ;;
        c)
        echo "INFO: CHECKSUM MODE"
        export MODE_CHECKSUM=true
        ;;
        ?)
        echo "script usage: $(basename \$0) [-f] [-d] [-c]" >&2
        exit 1
        ;;
    esac
done
shift "$(($OPTIND -1))"


checkForVariable()
{
    local env_var=
    env_var=$(declare -p "$1")
    if !  [[ -v $1 && $env_var =~ ^declare\ -x ]]; then
        echo "ERROR: $1 environment variable is not set"
        exit 1
    fi
}

init()
{

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
        export TRANSCODE_MUSIC_EXTENSIONS="flac opus mp3 ogg wma m4a"
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

    cp ./transcode_exclude.cfg $TRANSCODE_INPUT_DIR/.fdignore
    cp ./transcode_exclude.cfg $TRANSCODE_OUTPUT_DIR/.fdignore
}

clean()
{
    rm $TRANSCODE_INPUT_DIR/.fdignore
    rm $TRANSCODE_OUTPUT_DIR/.fdignore
}

transcode()
{   
    input_file=$1
    output_file=$2
    md5_file=$3

    $TRANSCODE_FREAC_BIN freaccmd --encoder=opus --bitrate 64 "$input_file" -o "$output_file"
    if [ $? -ne 0 ]; then exit 1; fi  
    mkdir -p "$TRANSCODE_DB/$(dirname "$input_file")"
    echo "$(md5sum "$input_file" | awk '{ print $1 }')" > "$md5_file"
}

write_cue()
{
    input_file=$1
    replacement_string=$2
    md5_file=$3

    echo "##: writing $input_file"
    sed -i "/FILE/c $replacement_string" "$input_file"
    if [ $? -ne 0 ]; then
        echo "ERROR: writing cuefile $input_file"
        exit 1
    fi
    mkdir -p "$TRANSCODE_DB/$(dirname "$input_file")"
    echo "$(md5sum "$input_file" | awk '{ print $1 }')" > "$md5_file"
}

write_jpg()
{
    input_file=$1
    output_file=$2
    md5_file=$3

    echo "##: converting cover $input_file"
    convert "$input_file" -resize 500 -quality 75 "$output_file"
    if [ $? -ne 0 ]; then
        echo "ERROR: converting cover $input_file"
        exit 1
    fi
    mkdir -p "$TRANSCODE_DB/$(dirname "$input_file")"
    echo "$(md5sum "$input_file" | awk '{ print $1 }')" > "$md5_file"
}

directory_structure()
{
    rsync -rvz --exclude-from="./transcode_exclude.cfg" --include="*/" --exclude="*" $TRANSCODE_INPUT_DIR $TRANSCODE_OUTPUT_DIR
}

convert_covers()
{
    cd $TRANSCODE_INPUT_DIR

    trap "exit" INT
    for ext in $TRANSCODE_COVER_EXTENSIONS
    do
        FILES=$($TRANSCODE_FD_BIN --extension $ext $TRANSCODE_FD_FILTERS)
        mapfile -t StringArray <<< "$FILES"
        for val in "${StringArray[@]}"; do
            if [ ! -z "$val" ]; then
                FILENAME="$TRANSCODE_OUTPUT_DIR$(dirname "$val")/$(basename "$val" .$ext).jpg"
                MD5_FILENAME="$TRANSCODE_DB/$(dirname "$val")/$(basename "$val" .$ext).jpg.md5"
                # Check if a MD5 checksum already exists
                RESULT=$($TRANSCODE_FD_BIN . "$(dirname "$MD5_FILENAME")" | grep -F "$(basename "$MD5_FILENAME")")
                if [ $? -ne 0 ] ; then
                    write_jpg "$val" "$FILENAME" "$MD5_FILENAME"
                # Check if an existing MD5 checksum is different
                elif [ MODE_CHECKSUM == true ]; then
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
                elif [ MODE_CHECKSUM == true ]; then
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
                write_cue "$val" "$REPLACEMENT_TEXT_STRING" "$MD5_FILENAME"
            # Check if an existing MD5 checksum is different
            elif [ MODE_CHECKSUM == true ]; then
                if [ "$(cat "$MD5_FILENAME")" != "$(md5sum "$val" | awk '{ print $1 }')" ]; then
                    write_cue "$val" "$REPLACEMENT_TEXT_STRING" "$MD5_FILENAME"
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
                RESULT=$($TRANSCODE_FD_BIN . "$TRANSCODE_INPUT_DIR/$(dirname "$FILENAME")" | grep -F "$(basename "$FILENAME")")
                # Transcoded file don't have a source file : delete
                if [ $? -ne 0 ]; then
                    echo "INFO: Transcoded file $FILENAME don't have a source file : delete"
                    rm "$TRANSCODE_OUTPUT_DIR/$FILENAME"*
                    rm "$TRANSCODE_DB/$FILENAME"*
                fi
                
            fi
        done
    done

    echo "INFO: removing empty directories..."
    cd $TRANSCODE_OUTPUT_DIR
    find . -type d -empty -delete
}

init

if [ $MODE_DELETE == false ]; then
    directory_structure

    convert_covers

    convert_music

    fix_cuefiles
else
    remove_absent_from_source
fi

clean