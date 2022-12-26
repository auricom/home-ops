#!/bin/bash

# Disk two (2.5TB)
mkdir -p /run/media/claude/local-backups/music
mkdir -p /run/media/claude/local-backups/home/{claude,helene}

sudo rsync -avhP /mnt/home-claude/ /run/media/claude/local-backups/home/claude/ --delete
sudo rsync -avhP /mnt/home-helene/ /run/media/claude/local-backups/home/helene/ --delete
sudo rsync -avhP /mnt/music/ /run/media/claude/local-backups/music/ --delete
