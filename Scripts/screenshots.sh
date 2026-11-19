#!/bin/zsh
set -eu
project=${0:A:h:h}
home=/Users/Shared/alex
if [[ -e $home ]]; then echo "$home already exists"; exit 1; fi
work=$(mktemp -d)
trap 'rm -rf "$home" "$work"; sleep 3; rm -rf "$home"' EXIT INT TERM
python3 -I "$project/Scripts/demo-home.py" "$home" en
CFFIXED_USER_HOME="$home" "$project/dist/Disk Inventory.app/Contents/MacOS/DiskInventory" --screenshots "$home" "$work"
for name in main-window main-window-dark cleanup-tab; do
    sips -s format jpeg -s formatOptions 82 -Z 1800 "$work/$name.png" --out "$project/Research/Screenshots/$name.jpg" >/dev/null
done
ls -l "$project/Research/Screenshots"
