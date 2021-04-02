#!/bin/bash

set -x

curl --location https://github.com/DavidMoore/ipfilter/releases/download/lists/ipfilter.dat.gz --output /tmp/ipfilter.dat.gz
gunzip /tmp/ipfilter.dat.gz
result=$(kubectl get pod --selector app.kubernetes.io/name=qbittorrent --output custom-columns=:metadata.name --namespace media)
QBITTORRENT_POD=$(echo $result | awk '{ print $NF }')
echo $QBITTORRENT_POD | grep qbittorrent
test $? -eq 0 && kubectl cp /tmp/ipfilter.dat media/$QBITTORRENT_POD:/config/ipfilter.dat
