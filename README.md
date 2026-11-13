# README.md

<div align="center">

<img src="https://thumb.wikimedia.org/wikipedia/commons/thumb/3/39/Kubernetes_logo_without_workmark.svg/3840px-Kubernetes_logo_without_workmark.svg.png" align="center" width="144px" height="144px"/>

## My home Kubernetes cluster :sailboat:

... managed with Flux and Renovate :robot:
</div>

<div align="center">

[![Discord](https://img.shields.io/discord/673534664354430999?style=for-the-badge&label&logo=discord&logoColor=white&color=blue)](https://discord.gg/k8s-at-home)
[![Kubernetes](https://img.shields.io/badge/talos-blue?style=for-the-badge&logo=kubernetes&logoColor=white)](https://talos.dev/)
[![Renovate](https://img.shields.io/github/actions/workflow/status/auricom/home-ops/renovate.yaml?branch=main&label=&logo=renovatebot&style=for-the-badge&color=blue)](https://github.com/auricom/home-ops/actions/workflows/renovate.yaml)

</div>

## AdGuard allowlist

The [allowlist](filters/adguard-allowlist.txt) is served at
[this raw URL](https://raw.githubusercontent.com/auricom/home-ops/main/filters/adguard-allowlist.txt)
and configured as an enabled subscription in Ansible's shared AdGuard configuration.
Add one exception rule per line, such as `@@||celestia.dev^` to allow a domain and all its subdomains.

Merge the list to `main` and verify the raw URL is available before deploying the Ansible configuration.
AdGuard checks for filter updates every 24 hours.
