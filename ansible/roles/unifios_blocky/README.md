# unifios_blocky

Ansible role that runs [Blocky](https://github.com/0xERR0R/blocky) directly on a UniFi OS device (e.g. UDM Pro) for local network-wide ad/tracker blocking.

Based on the guide **"running blocky on the unifi dream machine pro"** by jmcglock:
<https://jmcglock.substack.com/p/running-blocky-on-the-unifi-dream>

## What it does

- Downloads and installs the Blocky ARM64 binary under `/data/blocky`
- Deploys the Blocky configuration file
- Creates a systemd service to start Blocky on boot
- Configures dnsmasq to forward client DNS queries to Blocky on port `5335`
- Installs the unifios-utilities on-boot script and persists the dnsmasq configuration across reboots

## Variables

See `defaults/main.yml` for configurable options.
