set quiet
set shell := ['bash', '-eu', '-o', 'pipefail', '-c']

# This justfile is used to manage certain VolSync tasks for a given application, limitations are described below.
#   1. Fluxtomization, HelmRelease, PVC, ReplicationSource all have the same name (e.g. plex)
#   2. ReplicationSource and ReplicationDestination are a Restic repository
#   3. Applications are deployed as either a Kubernetes Deployment or StatefulSet
#   4. Each application only has one PVC that is being replicated

scripts_dir := justfile_directory() + '/.just/volsync/scripts'
templates_dir := justfile_directory() + '/.just/volsync/templates'

[private]
default:
    just --list volsync

[doc('List snapshots for an application')]
list app ns="default":
    #!/usr/bin/env bash
    set -euo pipefail

    # Check preconditions
    if [[ ! -f "{{scripts_dir}}/wait.sh" ]]; then
        echo "Wait script not found"
        exit 1
    fi
    if [[ ! -f "{{templates_dir}}/list.tmpl.yaml" ]]; then
        echo "List template not found"
        exit 1
    fi

    ts=$(date +%H%M%S)
    export app="{{app}}"
    export controller=""
    export claim=""
    export puid=""
    export pgid=""
    export ns="{{ns}}"
    export previous=""
    export ts="${ts}"

    envsubst < <(cat {{templates_dir}}/list.tmpl.yaml) | kubectl apply -f -
    bash {{scripts_dir}}/wait.sh list-{{app}}-${ts} {{ns}}
    kubectl -n {{ns}} wait job/list-{{app}}-${ts} --for condition=complete --timeout=1m
    kubectl -n {{ns}} logs job/list-{{app}}-${ts} --container list
    kubectl -n {{ns}} delete job list-{{app}}-${ts}

[doc('Unlock a Restic repository for an application')]
unlock app ns="default":
    #!/usr/bin/env bash
    set -euo pipefail

    # Check preconditions
    if [[ ! -f "{{scripts_dir}}/wait.sh" ]]; then
        echo "Wait script not found"
        exit 1
    fi
    if [[ ! -f "{{templates_dir}}/unlock.tmpl.yaml" ]]; then
        echo "Unlock template not found"
        exit 1
    fi

    ts=$(date +%H%M%S)
    export app="{{app}}"
    export controller=""
    export claim=""
    export puid=""
    export pgid=""
    export ns="{{ns}}"
    export previous=""
    export ts="${ts}"

    envsubst < <(cat {{templates_dir}}/unlock.tmpl.yaml) | kubectl apply -f -
    bash {{scripts_dir}}/wait.sh unlock-{{app}}-${ts} {{ns}}
    kubectl -n {{ns}} wait job/unlock-{{app}}-${ts} --for condition=complete --timeout=1m
    kubectl -n {{ns}} logs job/{{app}}-unlock-snapshots-${ts} --container unlock-minio
    kubectl -n {{ns}} logs job/{{app}}-unlock-snapshots-${ts} --container unlock-r2
    kubectl -n {{ns}} delete job unlock-{{app}}-${ts}

[doc('Snapshot a PVC for an application')]
snapshot app ns="default":
    #!/usr/bin/env bash
    set -euo pipefail

    # Check preconditions
    if [[ ! -f "{{scripts_dir}}/controller.sh" ]]; then
        echo "Controller script not found"
        exit 1
    fi
    if [[ ! -f "{{scripts_dir}}/wait.sh" ]]; then
        echo "Wait script not found"
        exit 1
    fi
    if ! kubectl -n {{ns}} get replicationsources {{app}} &>/dev/null; then
        echo "RepositorySource not found"
        exit 1
    fi

    ts=$(date +%H%M%S)
    controller=$({{scripts_dir}}/controller.sh {{app}} {{ns}})
    export app="{{app}}"
    export controller="${controller}"
    export claim=""
    export puid=""
    export pgid=""
    export ns="{{ns}}"
    export previous=""
    export ts="${ts}"

    kubectl -n {{ns}} patch replicationsources {{app}} --type merge -p '{"spec":{"trigger":{"manual":"'${ts}'"}}}'
    bash {{scripts_dir}}/wait.sh volsync-src-{{app}} {{ns}}
    kubectl -n {{ns}} wait job/volsync-src-{{app}} --for condition=complete --timeout=120m

[doc('Restore a PVC for an application')]
restore app ns="default" previous="2":
    #!/usr/bin/env bash
    set -euo pipefail

    # Check preconditions
    if [[ ! -f "{{scripts_dir}}/controller.sh" ]]; then
        echo "Controller script not found"
        exit 1
    fi
    if [[ ! -f "{{scripts_dir}}/wait.sh" ]]; then
        echo "Wait script not found"
        exit 1
    fi
    if [[ ! -f "{{templates_dir}}/replicationdestination.tmpl.yaml" ]]; then
        echo "ReplicationDestination script not found"
        exit 1
    fi
    if [[ ! -f "{{templates_dir}}/wipe.tmpl.yaml" ]]; then
        echo "Wipe template not found"
        exit 1
    fi

    ts=$(date +%H%M%S)
    controller=$({{scripts_dir}}/controller.sh {{app}} {{ns}})
    claim=$(kubectl -n {{ns}} get replicationsources/{{app}} -o jsonpath="{.spec.sourcePVC}")
    puid=$(kubectl -n {{ns}} get replicationsources/{{app}} -o jsonpath="{.spec.restic.moverSecurityContext.runAsUser}")
    pgid=$(kubectl -n {{ns}} get replicationsources/{{app}} -o jsonpath="{.spec.restic.moverSecurityContext.runAsGroup}")

    export app="{{app}}"
    export controller="${controller}"
    export claim="${claim}"
    export puid="${puid}"
    export pgid="${pgid}"
    export ns="{{ns}}"
    export previous="{{previous}}"
    export ts="${ts}"

    just volsync suspend {{app}} {{ns}} "${controller}"
    just volsync wipe {{app}} {{ns}} "${claim}" "${puid}" "${pgid}" "${ts}"
    just volsync restore-internal {{app}} {{ns}} "${claim}" "${puid}" "${pgid}" "${ts}"
    just volsync resume {{app}} {{ns}}

[doc('Delete volume populator PVCs in all namespaces')]
cleanup:
    #!/usr/bin/env bash
    set -euo pipefail

    # Delete destination PVCs
    kubectl get pvc --all-namespaces --no-headers | grep "dst-dest" | awk '{print $1 "/" $2}' | while IFS='/' read -r namespace pvc; do
        kubectl delete pvc -n "${namespace}" "${pvc}"
    done

    # Delete cache PVCs
    kubectl get pvc --all-namespaces --no-headers | grep "dst-cache" | awk '{print $1 "/" $2}' | while IFS='/' read -r namespace pvc; do
        kubectl delete pvc -n "${namespace}" "${pvc}"
    done

[private]
[doc('Suspend the Flux ks and hr')]
suspend app ns controller:
    #!/usr/bin/env bash
    set -euo pipefail

    flux -n {{ns}} suspend kustomization {{app}}
    flux -n {{ns}} suspend helmrelease {{app}}
    kubectl -n {{ns}} scale {{controller}} --replicas 0
    kubectl -n {{ns}} wait pod --for delete --selector="app.kubernetes.io/name={{app}}" --timeout=2m

[private]
[doc('Wipe the PVC of all data')]
wipe app ns claim puid pgid ts:
    #!/usr/bin/env bash
    set -euo pipefail

    export app="{{app}}"
    export controller=""
    export claim="{{claim}}"
    export puid="{{puid}}"
    export pgid="{{pgid}}"
    export ns="{{ns}}"
    export previous=""
    export ts="{{ts}}"

    envsubst < <(cat {{templates_dir}}/wipe.tmpl.yaml) | kubectl apply -f -
    bash {{scripts_dir}}/wait.sh wipe-{{app}}-{{ts}} {{ns}}
    kubectl -n {{ns}} wait job/wipe-{{app}}-{{ts}} --for condition=complete --timeout=120m
    kubectl -n {{ns}} logs job/wipe-{{app}}-{{ts}} --container wipe
    kubectl -n {{ns}} delete job wipe-{{app}}-{{ts}}

[private]
[doc('Create VolSync replicationdestination CR to restore data')]
restore-internal app ns claim puid pgid ts:
    #!/usr/bin/env bash
    set -euo pipefail

    export app="{{app}}"
    export controller=""
    export claim="{{claim}}"
    export puid="{{puid}}"
    export pgid="{{pgid}}"
    export ns="{{ns}}"
    export previous=""
    export ts="{{ts}}"

    envsubst < <(cat {{templates_dir}}/replicationdestination.tmpl.yaml) | kubectl apply -f -
    bash {{scripts_dir}}/wait.sh volsync-dst-{{app}}-{{ts}} {{ns}}
    kubectl -n {{ns}} wait job/volsync-dst-{{app}}-{{ts}} --for condition=complete --timeout=120m
    kubectl -n {{ns}} delete replicationdestination {{app}}-{{ts}}

[private]
[doc('Resume Flux ks and hr')]
resume app ns:
    #!/usr/bin/env bash
    set -euo pipefail

    flux -n {{ns}} resume helmrelease {{app}}
    flux -n {{ns}} resume kustomization {{app}}
