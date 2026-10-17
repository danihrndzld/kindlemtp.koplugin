#!/bin/sh
# Collects what is needed to add firmware 5.19 support to kindlemtp.koplugin.
# It only reads system files and writes into /mnt/us/kindlemtp-519.
# Run it on the Kindle (KOReader's Terminal emulator or kterm): sh /mnt/us/collect-519.sh
D=/mnt/us/kindlemtp-519
mkdir -p "$D/files"
{ cat /etc/prettyversion.txt; uname -a; } > "$D/version.txt" 2>&1
lipc-probe -v com.lab126.mtp > "$D/lipc-probe.txt" 2>&1
ps > "$D/ps.txt" 2>&1
dbus-send --system --print-reply --dest=org.freedesktop.DBus / org.freedesktop.DBus.ListNames > "$D/dbus-names.txt" 2>&1
find /usr /lib /etc /opt /bin /sbin -xdev \( -iname '*mtp*' -o -iname '*ipcf*' -o -iname '*volumd*' \) > "$D/files.txt" 2>/dev/null
while read -r p; do
    [ -f "$p" ] && cp "$p" "$D/files/$(echo "$p" | tr / _)"
done < "$D/files.txt"
cp /var/log/messages* "$D/" 2>/dev/null
echo "Done. $(du -sh "$D" | cut -f1) saved in $D"
