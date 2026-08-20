#!/system/bin/sh
# Keep the gamepad merger running for the whole session.
#
# This module hides the physical pads from Android (excluded-input-devices.xml),
# so if gpmerge is not running there is no usable controller at all. If it turns
# out to be unable to stay up, disable the module so the next boot comes back
# with the stock input setup instead of leaving the device unplayable.

MODDIR=${0%/*}
LOG=/data/local/tmp/gpmerge.log
BIN=$MODDIR/gpmerge
# Started by the app, not from here, but its mode is this script's business all
# the same: module files come back from a boot without their execute bit, and a
# helper that cannot be executed fails inside the app, where the only sign of it
# is one line in a log nobody reads. The NSO pad then connects, works in the
# diagnostic screen, and reaches no game at all.
FEED=$MODDIR/nsofeed

until [ "$(getprop sys.boot_completed)" = "1" ]; do
	sleep 2
done
# Let com.odin.mapping publish its virtual pads before the first scan.
sleep 8

: > "$LOG"
chmod 755 "$BIN" "$FEED" 2>/dev/null

fails=0
while true; do
	start=$(date +%s)
	"$BIN" >> "$LOG" 2>&1
	end=$(date +%s)

	# Exited almost immediately: count it as a failed start.
	if [ $((end - start)) -lt 10 ]; then
		fails=$((fails + 1))
		if [ "$fails" -ge 5 ]; then
			echo "gpmerge failed to stay up 5 times; disabling the module" >> "$LOG"
			touch "$MODDIR/disable"
			exit 1
		fi
	else
		fails=0
	fi

	# Trim the log so a restart loop cannot fill /data.
	if [ "$(wc -c < "$LOG" 2>/dev/null || echo 0)" -gt 262144 ]; then
		tail -c 65536 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
	fi

	sleep 3
done
