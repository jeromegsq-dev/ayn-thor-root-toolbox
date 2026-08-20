#!/system/bin/sh
# Trace one button across the whole chain, to find where it gets lost:
#
#   physical pad  ->  AYN copy  ->  AYN Unified Gamepad  ->  Android
#
# Whatever reaches "AYN Unified Gamepad" is what Android receives. If a button
# shows up on the physical pad but not on the AYN copy, the AYN mapper is eating
# it; if it reaches our merged pad and still does nothing, the button simply has
# no action bound on the Android side.

secs=${1:-15}

echo "Device legend:"
awk '
	/^N: Name=/ { name = $0; sub(/^N: Name="/, "", name); sub(/"$/, "", name) }
	/^H: Handlers=/ {
		if (match($0, /event[0-9]+/))
			printf "  /dev/input/%s\t%s\n", substr($0, RSTART, RLENGTH), name
	}' /proc/bus/input/devices | grep -iE "controller|gamepad|unified"
echo
echo "Tracing every button for $secs seconds - press the button under test now."
echo

timeout "$secs" getevent -l 2>/dev/null | grep --line-buffered -E "EV_KEY|EV_ABS +ABS_HAT"

echo
echo "No line at all for a button means nothing emitted it."
