#!/bin/sh

if [ "$1" = "stop" ] || [ "$1" = "start" ]; then
  sudo systemctl $1 $2
fi
