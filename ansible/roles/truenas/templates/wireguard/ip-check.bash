#!/bin/bash
# Check status of interface
# {{ wg_interface }}: name of the interface to check
# {{ dns_hostname }}: the name of the peer whose IP should be checked

cip=$(wg show {{ wg_interface }} endpoints | grep -E -o "([0-9]{1,3}[\.]){3}[0-9]{1,3}")
echo "Wireguard peer IP from Interface: $cip"
pingip=$(ping -c 1 {{ ping_ip }} &> /dev/null && echo success || echo fail) #change ip to target server
digIP=$(dig +short {{ dns_hostname }}) #the peer address must be set
echo "$digIP"
if [ "$digIP" != "$cip" ]
then
    echo "IPs doesn't match, restarting wireguard"
    wg-quick down {{ homelab_homedir }}/{{ wg_interface }}.conf
    wg-quick up {{ homelab_homedir }}/{{ wg_interface }}.conf
elif [ "$pingip" != "success" ]
then
    echo "Ping failed, restarting wireguard..."
    wg-quick down {{ homelab_homedir }}/{{ wg_interface }}.conf
    wg-quick up {{ homelab_homedir }}/{{ wg_interface }}.conf
else
    echo "OK"
    #nothing else todo
fi
