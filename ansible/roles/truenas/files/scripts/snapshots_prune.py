#!/usr/bin/env python3

# rollup.py - Arno Hautala <arno@alum.wpi.edu>
#   This work is licensed under a Creative Commons Attribution-ShareAlike 3.0 Unported License.
#   (CC BY-SA-3.0) http://creativecommons.org/licenses/by-sa/3.0/

# For the latest version, visit:
#   https://github.com/fracai/zfs-rollup
#   https://bitbucket.org/fracai/zfs-rollup

# A snapshot pruning script, similar in behavior to Apple's TimeMachine
# Keep hourly snapshots for the last day, daily for the last week, and weekly thereafter.

# TODO:
#   rollup based on local time, not UTC
#     requires pytz, or manually determining and converting time offsets
#   improve documentation

# TEST:

import datetime
import calendar
import time
import subprocess
import argparse
import sys
from collections import defaultdict

intervals = {}
intervals['hourly']  = { 'max':24, 'abbreviation':'h', 'reference':'%Y-%m-%d %H' }
intervals['daily']   = { 'max': 7, 'abbreviation':'d', 'reference':'%Y-%m-%d' }
intervals['weekly']  = { 'max': 0, 'abbreviation':'w', 'reference':'%Y-%W' }
intervals['monthly'] = { 'max':12, 'abbreviation':'m', 'reference':'%Y-%m' }
intervals['yearly']  = { 'max':10, 'abbreviation':'y', 'reference':'%Y' }

modifiers = {
    'M' : 1,
    'H' : 60,
    'h' : 60,
    'd' : 60*24,
    'w' : 60*24*7,
    'm' : 60*24*28,
    'y' : 60*24*365,
}

used_intervals = {
    'hourly': intervals['hourly'],
    'daily' : intervals['daily'],
    'weekly': intervals['weekly']
}

parser = argparse.ArgumentParser(description='Prune excess snapshots, keeping hourly for the last day, daily for the last week, and weekly thereafter.')
parser.add_argument('datasets', nargs='+', help='The root dataset(s) from which to prune snapshots')
parser.add_argument('-t', '--test', action="store_true", default=False, help='Only display the snapshots that would be deleted, without actually deleting them')
parser.add_argument('-v', '--verbose', action="store_true", default=False, help='Display verbose information about which snapshots are kept, pruned, and why')
parser.add_argument('-r', '--recursive', action="store_true", default=False, help='Recursively prune snapshots from nested datasets')
parser.add_argument('--prefix', '-p', action='append', help='list of snapshot name prefixes that will be considered')
parser.add_argument('-c', '--clear', action="store_true", default=False, help='remove all snapshots')
parser.add_argument('-i', '--intervals',
    help="Modify and define intervals with which to keep and prune snapshots. Either name existing intervals ("+
    ", ".join(sorted(intervals, key=lambda interval: modifiers[intervals[interval]['abbreviation']]))+"), "+
    "modify the number of those to store (hourly:12), or define new intervals according to interval:count (2h:12). "+
    "Multiple intervals may be specified if comma seperated (hourly,daily:30,2h:12). Available modifier abbreviations are: "+
    ", ".join(sorted(modifiers, key=modifiers.get))
)

args = parser.parse_args()

if not args.prefix:
    args.prefix = ['auto']

args.prefix = [prefix+"-" for prefix in set(args.prefix)]

if args.test:
    args.verbose = True

if args.intervals:
    used_intervals = {}

    for interval in args.intervals.split(','):
        if interval.count(':') == 1:
            period,count = interval.split(':')

            try:
                int(count)
            except ValueError:
                print("invalid count: "+count)
                sys.exit(1)

            if period in intervals:
                used_intervals[period] = intervals[period]
                used_intervals[period]['max'] = count

            else:
                try:
                    if period[-1] in modifiers:
                        used_intervals[interval] = { 'max' : count, 'interval' : int(period[:-1]) * modifiers[period[-1]] }
                    else:
                        used_intervals[interval] = { 'max' : count, 'interval' : int(period) }

                except ValueError:
                    print("invalid period: "+period)
                    sys.exit(1)

        elif interval.count(':') == 0 and interval in intervals:
            used_intervals[interval] = intervals[interval]

        else:
            print("invalid interval: "+interval)
            sys.exit(1)

for interval in used_intervals:
    if 'abbreviation' not in used_intervals[interval]:
        used_intervals[interval]['abbreviation'] = interval

snapshots = defaultdict(lambda : defaultdict(lambda : defaultdict(int)))

for dataset in args.datasets:
    subp = subprocess.Popen(["zfs", "get", "-Hrpo", "name,property,value", "creation,type,used,freenas:state", dataset], stdout=subprocess.PIPE)
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

        # enforce that this is a snapshot starting with one of the requested prefixes
        if not any(map(snapshot.startswith, args.prefix)):
            if property == 'creation':
                print("will ignore:\t", dataset+"@"+snapshot)

        snapshots[dataset][snapshot][property] = value

for dataset in list(snapshots.keys()):
    latestNEW = None
    latest = None
    for snapshot in sorted(snapshots[dataset], key=lambda snapshot: snapshots[dataset][snapshot]['creation'], reverse=True):
        if not latest:
            latest = snapshot
            snapshots[dataset][snapshot]['keep'] = 'RECENT'
            continue
        if not any(map(snapshot.startswith, args.prefix)) \
            or snapshots[dataset][snapshot]['type'] != "snapshot":
            snapshots[dataset][snapshot]['keep'] = '!PREFIX'
            continue
        if not latestNEW and snapshots[dataset][snapshot]['freenas:state'] == 'NEW':
            latestNEW = snapshot
            snapshots[dataset][snapshot]['keep'] = 'NEW'
            continue
        if snapshots[dataset][snapshot]['freenas:state'] == 'LATEST':
            snapshots[dataset][snapshot]['keep'] = 'LATEST'
            continue

    if not len(list(snapshots[dataset].keys())):
        del snapshots[dataset]

for dataset in sorted(snapshots.keys()):
    print(dataset)

    sorted_snapshots = sorted(snapshots[dataset], key=lambda snapshot: snapshots[dataset][snapshot]['creation'])
    most_recent = sorted_snapshots[-1]

    rollup_intervals = defaultdict(lambda : defaultdict(int))

    for snapshot in sorted_snapshots:
        prune = True

        if args.clear:
            continue

        epoch = snapshots[dataset][snapshot]['creation']

        for interval in list(used_intervals.keys()):
            if 'reference' in used_intervals[interval]:
                reference = time.strftime(used_intervals[interval]['reference'], time.gmtime(float(epoch)))

                if reference not in rollup_intervals[interval]:
                    if int(used_intervals[interval]['max']) != 0 and len(rollup_intervals[interval]) >= int(used_intervals[interval]['max']):
                        rollup_intervals[interval].pop(sorted(rollup_intervals[interval].keys())[0])
                    rollup_intervals[interval][reference] = epoch

            elif 'interval' in used_intervals[interval]:
                if int(used_intervals[interval]['max']) != 0 and len(rollup_intervals[interval]) >= int(used_intervals[interval]['max']):
                    rollup_intervals[interval].pop(sorted(rollup_intervals[interval].keys())[0])

                if (not rollup_intervals[interval]) or int(sorted(rollup_intervals[interval].keys())[-1]) + (used_intervals[interval]['interval']*60*.9) < int(epoch):
                    rollup_intervals[interval][epoch] = epoch

    ranges = list()
    ranges.append(list())
    for snapshot in sorted_snapshots:
        prune = True

        epoch = snapshots[dataset][snapshot]['creation']

        if 'keep' in snapshots[dataset][snapshot]:
            prune = False
            ranges.append(list())


        for interval in list(used_intervals.keys()):
            if 'reference' in used_intervals[interval]:
                reference = time.strftime(used_intervals[interval]['reference'], time.gmtime(float(epoch)))
                if reference in rollup_intervals[interval] and rollup_intervals[interval][reference] == epoch:
                    prune = False
                    ranges.append(list())

            elif 'interval' in used_intervals[interval]:
                if epoch in rollup_intervals[interval]:
                    prune = False
                    ranges.append(list())

        if prune or args.verbose:
            print("\t","pruning\t" if prune else " \t", "@"+snapshot, end=' ')
            if args.verbose:
                for interval in list(used_intervals.keys()):
                    if 'reference' in used_intervals[interval]:
                        reference = time.strftime(used_intervals[interval]['reference'], time.gmtime(float(epoch)))
                        if reference in rollup_intervals[interval] and rollup_intervals[interval][reference] == epoch:
                            print(used_intervals[interval]['abbreviation'], end=' ')
                        else:
                            print('-', end=' ')
                    if 'interval' in used_intervals[interval]:
                        if epoch in rollup_intervals[interval]:
                            print(used_intervals[interval]['abbreviation'], end=' ')
                        else:
                            print('-', end=' ')
                if 'keep' in snapshots[dataset][snapshot]:
                    print(snapshots[dataset][snapshot]['keep'][0], end=' ')
                else:
                    print('-', end=' ')
                print(snapshots[dataset][snapshot]['used'])
            else:
                print()

        if prune:
            ranges[-1].append(snapshot)

    for range in ranges:
        if not range:
            continue
        to_delete = dataset+'@'+range[0]
        if len(range) > 1:
            to_delete += '%' + range[-1]
        to_delete = to_delete.replace(' ', '')
        if not to_delete:
            continue
        if args.verbose:
            print('zfs destroy ' + to_delete)
        if not args.test:
            # destroy the snapshot
            subprocess.call(['zfs', 'destroy', to_delete])
