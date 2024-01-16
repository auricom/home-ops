#!/bin/sh

# DEBUG
# set -x

# Variables
VERSION=$(freebsd-version | sed 's|STABLE|RELEASE|g')
JAILS=$(iocage list --header | awk '{ print $2 }')

for jail in $JAILS; do
    iocage update $jail
    iocage exec $jail 'pkg update'
    iocage exec $jail 'pkg upgrade --yes'
done
