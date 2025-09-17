set quiet
set shell := ['bash', '-eu', '-o', 'pipefail', '-c']

[private]
default:
    just --list kube

[doc('Spawn a shell on a node')]
node-shell node:
    kubectl node-shell -n kube-system -x {{node}}

[doc('Prune all unused Pods')]
prune-pods:
    for phase in Failed Pending Succeeded; do \
        kubectl delete pods -A --field-selector status.phase="${phase}" --ignore-not-found=true; \
    done

[doc('Mount a PersistentVolumeClaim to a temporary pod')]
mount claim ns='default':
    #!/usr/bin/env bash
    set -euo pipefail

    # Check if PVC exists
    if ! kubectl -n {{ns}} get persistentvolumeclaim {{claim}} >/dev/null 2>&1; then
        echo "Error: PVC '{{claim}}' not found in namespace '{{ns}}'"
        exit 1
    fi

    # Mount PVC to debug pod
    kubectl run -n {{ns}} debug-{{claim}} -i --tty --rm --image=null --privileged --overrides='
    {
      "apiVersion": "v1",
      "spec": {
        "containers": [
          {
            "name": "debug",
            "image": "cgr.dev/chainguard/wolfi-base",
            "command": ["sleep","infinity"],
            "stdin": true,
            "stdinOnce": true,
            "tty": true,
            "volumeMounts": [
              {
                "name": "config",
                "mountPath": "/config"
              }
            ]
          }
        ],
        "volumes": [
          {
            "name": "config",
            "persistentVolumeClaim": {
              "claimName": "{{claim}}"
            }
          }
        ],
        "restartPolicy": "Never"
      }
    }'
