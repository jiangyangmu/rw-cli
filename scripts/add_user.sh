#!/bin/bash

NEW_USER="$1"

if [ -z "$NEW_USER" ]; then
  echo "Usage: $0 <username>"
  exit 1
fi

if [ "$USER" != "root" ] && [ "$EUID" -ne 0 ]; then
  echo "Error: This script must be run as root."
  exit 1
fi

set -e

if [ ! -d "/home/$NEW_USER" ]; then
  adduser --disabled-password --gecos "" "$NEW_USER"
  echo "$NEW_USER:12345" | chpasswd

  usermod -aG sudo "$NEW_USER"
  usermod -aG root "$NEW_USER"
  apt-get update
  apt install sudo
  # no password for sudo
  if [ ! -f "/etc/sudoers.d/$NEW_USER" ]; then
    echo "$NEW_USER ALL=(ALL) NOPASSWD: ALL" >> "/etc/sudoers.d/$NEW_USER"
  fi
fi
exit 0
# su "$NEW_USER"
