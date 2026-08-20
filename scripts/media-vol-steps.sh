#!/system/bin/sh
# Finer media volume: split each step of the media stream in two.
#
# Android's media volume has 15 steps out of the box, and the smallest thing a
# volume key or a Shortcut combo can do is move by one of them — about 7% of the
# range at a time, which is a large jump when a game is already close to right.
#
# AudioService reads ro.config.media_vol_steps at startup and uses it as the
# stream's maximum index, so 30 halves every step. It is a read-only property:
# it has to be in place before the framework starts, which is why this belongs
# in post-fs-data rather than in service.d, and why it takes a reboot.
#
# Install:
#   adb push scripts/media-vol-steps.sh /data/local/tmp/
#   adb shell su -mm -c "cp /data/local/tmp/media-vol-steps.sh /data/adb/post-fs-data.d/ \
#       && chmod 755 /data/adb/post-fs-data.d/media-vol-steps.sh"
#   adb reboot
#
# Undo: delete the file and reboot. Nothing else changes — the stored level of
# each stream is rescaled by Android to the new maximum on the way in.
#
# 30 is a starting point, not a law. Higher is finer, at the cost of a longer
# press to cross the range; the volume panel draws the same slider whatever it
# is. Everything reads the maximum rather than assuming 15 — the app's shortcut
# commands included — so this is the only place the number lives.

resetprop ro.config.media_vol_steps 30

# The default level is expressed in the old scale, so scale it too or a fresh
# profile comes up half as loud as it used to.
resetprop ro.config.media_vol_default 14
