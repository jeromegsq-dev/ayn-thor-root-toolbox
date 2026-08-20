#!/system/bin/sh
# Follow the Home button through the whole chain and report where it stops.
#
#   source pad  ->  AYN Unified Gamepad  ->  Android key dispatch

CONF=/data/adb/modules/gpmerge/gpmerge.conf

echo "=== profile lines that touch KEY_HOME ==="
grep -nE "^\[|KEY_HOME" "$CONF" 2>/dev/null || echo "  (none)"
echo

echo "=== devices ==="
awk '
	/^N: Name=/ { name = $0; sub(/^N: Name="/, "", name); sub(/"$/, "", name) }
	/^H: Handlers=/ {
		if (match($0, /event[0-9]+/))
			printf "  /dev/input/%s\t%s\n", substr($0, RSTART, RLENGTH), name
	}' /proc/bus/input/devices | grep -iE "controller|unified"
echo

echo "Press HOME a few times on the pad under test (15 seconds)."
echo
timeout 15 getevent -l 2>/dev/null | grep --line-buffered -E "KEY_HOME|KEY_BACK|BTN_MODE"

echo
echo "=== what Android did with it ==="
# Anything that reacted to a HOME keycode shows up here.
logcat -d -t 300 2>/dev/null | grep -iE "KEYCODE_HOME|interceptKeyB.*HOME|GoHome|launchHome" | tail -6
echo
echo "Reading the result:"
echo "  no line at all            -> the pad did not emit Home"
echo "  only the source device    -> gpmerge did not forward it"
echo "  'AYN Unified Gamepad' too -> Android received it; the problem is what"
echo "                               Android or the AYN software does with it"
