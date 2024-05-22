#!/bin/bash

set -o nounset
set -o errexit

# File to store the list of databases
OUTPUT_FILE="/config/db_list"

# Export PG password to avoid password prompt
export PGPASSWORD="$POSTGRES_PASSWORD"

# Convert EXCLUDE_DBS to an array
IFS=' ' read -r -a EXCLUDE_ARRAY <<< "$EXCLUDE_DBS"

# List all databases and filter out the excluded ones
psql -h $POSTGRES_HOST -p $POSTGRES_PORT -U $POSTGRES_USER -lqt | \
cut -d \| -f 1 | \
sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | \
while read -r dbname; do
    skip=false
    for exclude in "${EXCLUDE_ARRAY[@]}"; do
        if [[ "$dbname" == "$exclude" ]]; then
            skip=true
            break
        fi
    done
    if [[ "$skip" == false ]]; then
        echo "$dbname"
    fi
done > "$OUTPUT_FILE"

# Unset PG password
unset PGPASSWORD

echo "Database list saved to $OUTPUT_FILE"

cat $OUTPUT_FILE
