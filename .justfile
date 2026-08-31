#!/usr/bin/env -S just --justfile

set default-script
set lazy
set quiet
set shell := ['bash', '-euo', 'pipefail', '-c']

# Bootstrap Recipes
[group: 'Bootstrap']
mod bootstrap "bootstrap"

# Kube Recipes
[group: 'Kube']
mod kube "kubernetes"

[doc('Sync Recipes')]
mod sync '.just/sync.just'

# Talos Recipes
[group: 'Talos']
mod talos "talos"

[doc('Volsync')]
mod volsync '.just/volsync.just'

[private]
default:
    just --list

[private]
log lvl msg *args:
    gum log -t rfc3339 -s -l "{{ lvl }}" "{{ msg }}" {{ args }}

[private]
template file *args:
    injected_file="$(mktemp)"
    trap 'rm -f "$injected_file"' EXIT
    minijinja-cli "{{ file }}" {{ args }} | op inject >"$injected_file"
    test -s "$injected_file" || { echo 'op inject produced no output; sign in with `op signin` first' >&2; exit 1; }
    vals eval -f "$injected_file" | yq -P
