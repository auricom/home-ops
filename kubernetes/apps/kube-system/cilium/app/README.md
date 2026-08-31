# Cilium

## UniFi BGP

```sh
router bgp 64513
  bgp router-id 192.168.16.1
  no bgp ebgp-requires-policy

  neighbor k8s peer-group
  neighbor k8s remote-as 64514

  neighbor 192.168.30.20 peer-group k8s
  neighbor 192.168.30.21 peer-group k8s
  neighbor 192.168.30.22 peer-group k8s

  address-family ipv4 unicast
    maximum-paths 3
    neighbor k8s next-hop-self
    neighbor k8s soft-reconfiguration inbound
  exit-address-family
exit
```
