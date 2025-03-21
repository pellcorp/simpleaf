#!/bin/bash

apt-get update
apt-get install -y openssh-server sudo
systemctl enable ssh 2> /dev/null
echo "%sudo  ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/nopasswd > /dev/null
sudo useradd -m pi
sudo usermod -a -G sudo pi
echo "pi:raspberry" | sudo chpasswd
