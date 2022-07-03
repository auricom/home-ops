#!/bin/bash

mkdir -p /run/media/claude/local-backups/{backups,documents,downloads,photo,piracy,jails}

# Disk one (4TB)
sudo rsync -avhP /mnt/backups/ /run/media/claude/local-backups/backups/ --delete
sudo rsync -avhP /mnt/documents/ /run/media/claude/local-backups/documents/ --delete
sudo rsync -avhP /mnt/downloads/ /run/media/claude/local-backups/downloads/ --delete
sudo rsync -avhP /mnt/photo/ /run/media/claude/local-backups/photo/ --delete
sudo rsync -avhP /mnt/piracy/ /run/media/claude/local-backups/piracy/ --delete
sudo rsync -avhP /mnt/iocage/jails/ /run/media/claude/local-backups/jails/ --delete