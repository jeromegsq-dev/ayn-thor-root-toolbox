#!/system/bin/sh
#
# SECURITY: this opens a listening ADB port on every boot and leaves it open.
# Anything that can reach the device on the network can attempt to connect; the
# only thing between that and a root shell is adbd's RSA check, so an authorized
# host key that leaks, or a host of yours that is compromised, is enough. Don't
# install this on a device you take onto networks you don't control. `adb usb`
# drops back to USB-only until the next reboot; deleting the file and rebooting
# undoes it for good.
#
# Wireless ADB on every boot, without running `adb tcpip 5555` over USB again
# each time. The RSA authorization itself is untouched by this: whatever host
# key is already in /data/misc/adb/adb_keys stays trusted, wired or wireless,
# since adbd checks the key and not the transport.
#
# Install: /data/adb/service.d/adb-wireless.sh (Magisk, runs as root at boot)
#
# Undo: delete the file and reboot; `adb usb` also drops back to USB-only
# until the next reboot, without needing one itself.

resetprop persist.adb.tcp.port 5555
stop adbd
start adbd
