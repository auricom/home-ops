#!/bin/bash

set -x

result=$(kubectl get pod --selector app.kubernetes.io/name=vikunja --output custom-columns=:metadata.name --namespace data)
VIKUNJA_POD=$(echo $result | awk '{ print $NF }')
echo $VIKUNJA_POD | grep vikunja
test $? -eq 0 && kubectl delete pod $VIKUNJA_POD --namespace data
