# Flux

## Install the CLI tool

```sh
brew install fluxcd/tap/flux
```

## Install the cluster components

_For full installation guide visit the [Flux installation guide](https://toolkit.fluxcd.io/guides/installation/)_

Check if you cluster is ready for Flux

```sh
flux check --pre
```

Install Flux into your cluster

```sh
flux bootstrap github \
--owner=auricom \
--repository=home-ops \
--path=cluster/base \
--personal \
--private=false \
--network-policy=false
```

## Useful commands

Force flux to sync your repository:

```sh
flux reconcile source git flux-system
```

Force flux to sync a helm release:

```sh
flux reconcile helmrelease sonarr -n default
```

Force flux to sync a helm repository:

```sh
flux reconcile source helm ingress-nginx-charts -n flux-system
```
