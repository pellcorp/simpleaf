#!/bin/bash

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
ROOT_DIR=$(dirname $CURRENT_DIR)

sudo iptables -P FORWARD ACCEPT
sudo ufw allow in on incusbr0
sudo ufw route allow in on incusbr0
sudo ufw route allow out on incusbr0
incus network set incusbr0 ipv6.firewall false
incus network set incusbr0 ipv4.firewall false

incus init images:debian/12/cloud klipper --vm || exit $?
incus config set klipper security.secureboot false || exit $?
incus config set klipper limits.cpu 4 || exit $?
incus config set klipper limits.memory 2048MB || exit $?
incus config device override klipper root size=16GB || exit $?
incus config device add klipper projects disk source=$ROOT_DIR path=/opt/projects/ || exit $?
incus start klipper

echo -n "Waiting for klipper to start ."
while true; do
  incus exec klipper -- id -u debian > /dev/null 2>&1
  if [ $? -eq 0 ]; then
    break
  else
    echo -n "."
    sleep 1
  fi
done

incus exec klipper -- /opt/projects/incus/setup.sh
