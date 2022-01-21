# Opnsense | PXE

## Setting up TFTP

- Setup TFTP and network booting on DHCPv4 server
- Create an `nginx` location to file system `/var/lib/tftpboot`
- Create an nginx http server listening on 30080 TCP
- Enable `dnsmasq` in the Opnsense services settings (set port to `63`)
- Copy over `pxe.conf` to `/usr/local/etc/dnsmasq.conf.d/pxe.conf`
- SSH into opnsense and run the following commands...

```console
$ mkdir -p /var/lib/tftpboot/pxelinux/
$ curl https://releases.ubuntu.com/20.04/ubuntu-20.04.3-live-server-amd64.iso -o /var/lib/tftpboot/ubuntu-20.04.3-live-server-amd64.iso
$ mount -t cd9660 /dev/`mdconfig -f /var/lib/tftpboot/ubuntu-20.04.3-live-server-amd64.iso` /mnt
$ cp /mnt/casper/vmlinuz /var/lib/tftpboot/pxelinux/
$ cp /mnt/casper/initrd /var/lib/tftpboot/pxelinux/
$ umount /mnt
$ curl http://archive.ubuntu.com/ubuntu/dists/focal/main/uefi/grub2-amd64/current/grubnetx64.efi.signed -o /var/lib/tftpboot/pxelinux/pxelinux.0
```

- Copy `grub/grub.conf` into `/var/lib/tftpboot/grub/grub.conf`
- Copy `nodes/` into `/var/lib/tftpboot/nodes`

## PXE boot on bare-metal servers

Press F12 key during 15-20 seconds to enter PXE IPv4 boot option
