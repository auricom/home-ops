# 🗄️ Storage Installation Guide

> 📋 **Overview**: This guide walks you through creating a custom bootable ISO for deploying storage.feisar.ovh server using bootc-image-builder.

## ⚙️ Step 1: Create Configuration File

Create a `config.toml` file with the following content:

```toml
[customizations.installer.kickstart]
contents = """
text
zerombr
clearpart --all --initlabel --disklabel=gpt
autopart --type=lvm --fstype=xfs --noswap
network --hostname storage.${SECRET_INTERNAL_DOMAIN} --bootproto=dhcp --device=link --activate --onboot=on
timezone UTC
rootpw --lock
user --name=core --homedir=/var/home/core --password="password" --plaintext --groups=wheel
bootloader --append="console=tty0 console=ttyS0,115200"
"""

[customizations.installer.modules]
enable = [
  "org.fedoraproject.Anaconda.Modules.Localization",
  "org.fedoraproject.Anaconda.Modules.Storage",
  "org.fedoraproject.Anaconda.Modules.Timezone",
  "org.fedoraproject.Anaconda.Modules.Users",
  "org.fedoraproject.Anaconda.Modules.Network",
]
disable = [
  "org.fedoraproject.Anaconda.Modules.Security",
  "org.fedoraproject.Anaconda.Modules.Services",
  "org.fedoraproject.Anaconda.Modules.Subscription"
]
```

## 🚀 Step 2: Build the ISO

Run the bootc-image-builder using [bootc-image-builder](https://github.com/osbuild/bootc-image-builder):
```bash
sudo podman pull ghcr.io/ublue-os/cayo:centos10
mkdir output
sudo podman run \
    --rm \
    -it \
    --privileged \
    --security-opt label=type:unconfined_t \
    -v ./config.toml:/config.toml:ro \
    -v ./output:/output \
    -v /var/lib/containers/storage:/var/lib/containers/storage \
    quay.io/centos-bootc/bootc-image-builder:latest \
    --type anaconda-iso \
    --use-librepo=True \
    ghcr.io/ublue-os/cayo:centos10
```

## 📍 Step 3: Locate Your ISO

After successful completion, look for the `.iso` file in `./output` directory

---

📚 **References**:
- [Kickstart Documentation](https://pykickstart.readthedocs.io/en/latest/kickstart-docs.html)
- [bootc-image-builder GitHub](https://github.com/osbuild/bootc-image-builder)
- [Universal Blue Cayo](https://github.com/ublue-os/cayo)
