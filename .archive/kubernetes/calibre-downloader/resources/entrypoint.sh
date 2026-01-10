#!/bin/bash
LOG_DIR=${LOG_ROOT:-/var/log/}/cwa-book-downloader
mkdir -p $LOG_DIR
LOG_FILE=${LOG_DIR}/cwa-bd_entrypoint.log

# Cleanup any existing files or folders in the log directory
rm -rf $LOG_DIR/*

(
    if [ "$USING_TOR" = "true" ]; then
        ./tor.sh
    fi
)

exec 3>&1 4>&2
exec > >(tee -a $LOG_FILE) 2>&1
echo "Starting entrypoint script"
echo "Log file: $LOG_FILE"
set -e

# Print build version
echo "Build version: $BUILD_VERSION"
echo "Release version: $RELEASE_VERSION"

# Configure timezone
if [ "$TZ" ]; then
    echo "Setting timezone to $TZ"
    ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone
fi

# Set UID if not set
if [ -z "$UID" ]; then
    UID=1000
fi

# Set GID if not set
if [ -z "$GID" ]; then
    GID=100
fi

if ! getent group "$GID" >/dev/null; then
    echo "Adding group $GID with name appuser"
    groupadd -g "$GID" appuser
fi

# Get username for the UID (whether we just created it or it existed)
USERNAME=$(getent passwd "$UID" | cut -d: -f1)
echo "Username for UID $UID is $USERNAME"

test_write() {
    folder=$1
    test_file=$folder/calibre-web-automated-book-downloader_TEST_WRITE
    mkdir -p $folder
    (
        echo 0123456789_TEST | sudo -E -u "$USERNAME" HOME=/app tee $test_file > /dev/null
    )
    FILE_CONTENT=$(cat $test_file || echo "")
    rm -f $test_file
    [ "$FILE_CONTENT" = "0123456789_TEST" ]
    result=$?
    if [ $result -eq 0 ]; then
        result_text="true"
    else
        result_text="false"
    fi
    echo "Test write to $folder by $USERNAME: $result_text"
    return $result
}

# Always run Gunicorn (even when DEBUG=true) to ensure Socket.IO WebSocket
# upgrades work reliably on customer machines.
# Map app LOG_LEVEL (often DEBUG/INFO/...) to gunicorn's --log-level (lowercase).
gunicorn_loglevel=$([ "$DEBUG" = "true" ] && echo debug || echo "${LOG_LEVEL:-info}" | tr '[:upper:]' '[:lower:]')
command="gunicorn --log-level ${gunicorn_loglevel} --access-logfile - --error-logfile - --worker-class geventwebsocket.gunicorn.workers.GeventWebSocketWorker --workers 1 -t 300 -b ${FLASK_HOST:-0.0.0.0}:${FLASK_PORT:-8084} cwa_book_downloader.main:app"

# If DEBUG and not using an external bypass
if [ "$DEBUG" = "true" ] && [ "$USING_EXTERNAL_BYPASSER" != "true" ]; then
    set +e
    set -x
    echo "vvvvvvvvvvvv DEBUG MODE vvvvvvvvvvvv"
    echo "Starting Xvfb for debugging"
    python3 -c "from pyvirtualdisplay import Display; Display(visible=False, size=(1440,1880)).start()"
    id
    free -h
    uname -a
    ulimit -a
    df -h /tmp
    env | sort
    mount
    cat /proc/cpuinfo
    echo "==========================================="
    echo "Debugging Chrome itself"
    chromium --version
    mkdir -p /tmp/chrome_crash_dumps
    timeout --preserve-status 5s chromium \
            --headless=new \
            --no-sandbox \
            --disable-gpu \
            --enable-logging --v=1 --log-level=0 \
            --log-file=/tmp/chrome_entrypoint_test.log \
            --crash-dumps-dir=/tmp/chrome_crash_dumps \
            < /dev/null
    EXIT_CODE=$?
    echo "Chrome exit code: $EXIT_CODE"
    ls -lh /tmp/chrome_entrypoint_test.log
    ls -lh /tmp/chrome_crash_dumps
    if [[ "$EXIT_CODE" -ne 0 && "$EXIT_CODE" -le 127 ]]; then
        echo "Chrome failed to start. Lets trace it"
        apt-get update && apt-get install -y strace
        timeout --preserve-status 10s strace -f -o "/tmp/chrome_strace.log" chromium \
                --headless=new \
                --no-sandbox \
                --version \
                < /dev/null
        EXIT_CODE=$?
        echo "Strace exit code: $EXIT_CODE"
        echo "Strace log:"
        cat /tmp/chrome_strace.log
    fi

    pkill -9 -f Xvfb
    pkill -9 -f chromium
    sleep 1
    ps aux
    set +x
    set -e
    echo "^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^"
fi

# Hacky way to verify /tmp has at least 1MB of space and is writable/readable
echo "Verifying /tmp has enough space"
rm -f /tmp/test.cwa-bd
for i in {1..150000}; do printf "%04d\n" $i; done > /tmp/test.cwa-bd
sum=$(python3 -c "print(sum(int(l.strip()) for l in open('/tmp/test.cwa-bd').readlines()))")
[ "$sum" == 11250075000 ] && echo "Success: /tmp is writable" || (echo "Failure: /tmp is not writable" && exit 1)
rm /tmp/test.cwa-bd

echo "Running command: '$command' as '$USERNAME' (debug=$is_debug)"

# Stop logging
exec 1>&3 2>&4
exec 3>&- 4>&-

exec HOME=/app $command
