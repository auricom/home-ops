# README.md

<div align="center">

<img src="https://thumb.wikimedia.org/wikipedia/commons/thumb/3/39/Kubernetes_logo_without_workmark.svg/3840px-Kubernetes_logo_without_workmark.svg.png" align="center" width="144px" height="144px"/>

## My home Kubernetes cluster :sailboat:

... managed with Flux and Renovate :robot:
</div>

<div align="center">

[![Discord](https://img.shields.io/discord/673534664354430999?style=for-the-badge&label&logo=discord&logoColor=white&color=blue)](https://discord.gg/k8s-at-home)
[![Renovate](https://img.shields.io/github/actions/workflow/status/auricom/home-ops/renovate.yaml?branch=main&label=&logo=renovatebot&style=for-the-badge&color=blue)](https://github.com/auricom/home-ops/actions/workflows/renovate.yaml)

</div>

<div align="center">

[![Talos](https://kromgo.xpander.ovh/badges/talos_version)](https://talos.dev)&nbsp;&nbsp;
[![Kubernetes](https://kromgo.xpander.ovh/badges/kubernetes_version)](https://kubernetes.io)&nbsp;&nbsp;
[![Flux](https://kromgo.xpander.ovh/badges/flux_version)](https://fluxcd.io)

</div>

<div align="center">

[![Age](https://kromgo.xpander.ovh/badges/cluster_birth_age)](https://github.com/home-operations/kromgo)&nbsp;&nbsp;
[![Uptime](https://kromgo.xpander.ovh/badges/cluster_uptime_age)](https://github.com/home-operations/kromgo)&nbsp;&nbsp;
[![Nodes](https://kromgo.xpander.ovh/badges/cluster_node_count)](https://github.com/home-operations/kromgo)&nbsp;&nbsp;
[![Pods](https://kromgo.xpander.ovh/badges/cluster_pod_count)](https://github.com/home-operations/kromgo)&nbsp;&nbsp;
[![CPU](https://kromgo.xpander.ovh/badges/cluster_cpu_usage)](https://github.com/home-operations/kromgo)&nbsp;&nbsp;
[![Memory](https://kromgo.xpander.ovh/badges/cluster_memory_usage)](https://github.com/home-operations/kromgo)&nbsp;&nbsp;
[![Alerts](https://kromgo.xpander.ovh/badges/cluster_alert_count)](https://github.com/home-operations/kromgo)

</div>

## AdGuard allowlist

The [allowlist](filters/adguard-allowlist.txt) is served at
[this raw URL](https://raw.githubusercontent.com/auricom/home-ops/main/filters/adguard-allowlist.txt)
and configured as an enabled subscription in Ansible's shared AdGuard configuration.
Add one exception rule per line, such as `@@||celestia.dev^` to allow a domain and all its subdomains.

Merge the list to `main` and verify the raw URL is available before deploying the Ansible configuration.
AdGuard checks for filter updates every 24 hours.
