#!/usr/bin/env python3

# clearempty.py - Koen Vermeer <k.vermeer@eyehospital.nl>
# Inspired by rollup.py by Arno Hautala <arno@alum.wpi.edu>
# modifications by Arno Hautala
#   This work is licensed under a Creative Commons Attribution-ShareAlike 3.0 Unported License.
#   (CC BY-SA-3.0) http://creativecommons.org/licenses/by-sa/3.0/

# This script removes empty snapshots, based on their 'used' property.
# Note that one snapshot's 'used' value may change when another snapshot is
# destroyed. This script iteratively destroys the oldest empty snapshot. It
# does not remove the latest snapshot of each dataset or manual snapshots

import subprocess
import argparse
import sys
from collections import defaultdict

parser = argparse.ArgumentParser(description='Removes empty auto snapshots.')
parser.add_argument('datasets', nargs='+', help='the root dataset(s) from which to remove snapshots')
parser.add_argument('--test', '-t', action="store_true", default=False, help='only display the snapshots that would be deleted, without actually deleting them. Note that due to dependencies between snapshots, this may not match what would really happen.')
parser.add_argument('--recursive', '-r', action="store_true", default=False, help='recursively removes snapshots from nested datasets')
parser.add_argument('--prefix', '-p', action='append', help='list of snapshot name prefixes that will be considered')

args = parser.parse_args()

if not args.prefix:
    args.prefix = ['auto']

args.prefix = [prefix+"-" for prefix in set(args.prefix)]

deleted = defaultdict(lambda : defaultdict(lambda : defaultdict(int)))

snapshot_was_deleted = True

while snapshot_was_deleted:
    snapshot_was_deleted = False
    snapshots = defaultdict(lambda : defaultdict(lambda : defaultdict(int)))

    # Get properties of all snapshots of the selected datasets
    for dataset in args.datasets:
        subp = subprocess.Popen(["zfs", "get", "-Hrpo", "name,property,value", "type,creation,used,freenas:state", dataset], stdout=subprocess.PIPE)
        zfs_snapshots = subp.communicate()[0]
        if subp.returncode:
            print("zfs get failed with RC=%s" % subp.returncode)
            sys.exit(1)

        for snapshot in zfs_snapshots.splitlines():
            name,property,value = snapshot.decode().split('\t',3)

            # if the rollup isn't recursive, skip any snapshots from child datasets
            if not args.recursive and not name.startswith(dataset+"@"):
                continue

            try:
                dataset,snapshot = name.split('@',2)
            except ValueError:
                continue

            snapshots[dataset][snapshot][property] = value

    # Ignore non-snapshots and not-auto-snapshots
    # Remove already destroyed snapshots
    for dataset in list(snapshots.keys()):
        latest = None
        latestNEW = None
        for snapshot in sorted(snapshots[dataset], key=lambda snapshot: snapshots[dataset][snapshot]['creation'], reverse=True):
            if not any(map(snapshot.startswith, args.prefix)) \
                or snapshots[dataset][snapshot]['type'] != "snapshot":
                del snapshots[dataset][snapshot]
                continue
            if not latest:
                latest = snapshot
                del snapshots[dataset][snapshot]
                continue
            if not latestNEW and snapshots[dataset][snapshot]['freenas:state'] == 'NEW':
                latestNEW = snapshot
                del snapshots[dataset][snapshot]
                continue
            if snapshots[dataset][snapshot]['freenas:state'] == 'LATEST':
                del snapshots[dataset][snapshot]
                continue
            if snapshots[dataset][snapshot]['used'] != '0' \
                or snapshot in list(deleted[dataset].keys()):
                del snapshots[dataset][snapshot]
                continue

        # Stop if no snapshots are in the list
        if not snapshots[dataset]:
            del snapshots[dataset]
            continue

        # destroy the most recent empty snapshot
        snapshot = max(snapshots[dataset], key=lambda snapshot: snapshots[dataset][snapshot]['creation'])
        if not args.test:
            # destroy the snapshot
            subprocess.call(["zfs", "destroy", dataset+"@"+snapshot])

        deleted[dataset][snapshot] = snapshots[dataset][snapshot]
        snapshot_was_deleted = True

for dataset in sorted(deleted.keys()):
    if not deleted[dataset]:
        continue
    print(dataset)
    for snapshot in sorted(deleted[dataset].keys()):
        print("\t", snapshot, deleted[dataset][snapshot]['used'])
