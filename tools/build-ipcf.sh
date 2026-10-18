#!/bin/sh
# Builds kindlemtp.koplugin/bin/kindlemtp-ipcf (armhf, glibc 2.20 or later) with zig.
# KOBridge embeds a copy: cp it to ~/Developer/KOBridge/src-tauri/resources/ after a rebuild.
set -e
cd "$(dirname "$0")/.."
mkdir -p kindlemtp.koplugin/bin
zig cc -target arm-linux-gnueabihf.2.20 -Os -s -Wall -Wextra -Werror \
    -o kindlemtp.koplugin/bin/kindlemtp-ipcf ipcf/kindlemtp-ipcf.c -ldl -lpthread
ls -l kindlemtp.koplugin/bin/kindlemtp-ipcf
