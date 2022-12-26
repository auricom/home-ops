#!/bin/bash

pip3 list --outdated --user --format=freeze | grep -v '^\-e' | cut -d = -f 1  | xargs -n1 pip3 install -U --user
