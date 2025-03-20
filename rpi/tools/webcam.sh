#!/bin/sh

if [ "$1" = "stop" ] || [ "$1" = "start" ]; then
  sudo systemctl stop $1
fi
