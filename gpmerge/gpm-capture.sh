#!/system/bin/sh
# Show which raw button codes a controller sends, to decide what to remap.
# Reading alongside gpmerge is harmless: nothing is grabbed.
#
#   usage: gpm-capture.sh [name-fragment]     (default: Nintendo)
#
# A pad usually appears twice: the physical device, and the 2020:0111 copy the
# AYN mapper makes of it. gpmerge reads the AYN copy, so that is the one whose
# codes decide the profile. Both are listed; the AYN copy is captured.

want=${1:-Nintendo}

# Walk /proc/bus/input/devices, keeping the id line, the name and the handler
# that belong to the same record.
list=$(awk -v want="$want" '
	/^I: / { id = $0; sub(/^I: /, "", id) }
	/^N: Name=/ { name = $0; sub(/^N: Name="/, "", name); sub(/"$/, "", name) }
	/^H: Handlers=/ {
		if (index(tolower(name), tolower(want)) > 0 && match($0, /event[0-9]+/)) {
			vendor = id; sub(/.*Vendor=/, "", vendor); sub(/ .*/, "", vendor)
			bus = id; sub(/^Bus=/, "", bus); sub(/ .*/, "", bus)
			print substr($0, RSTART, RLENGTH) "\t" vendor "\t" bus "\t" name
		}
	}' /proc/bus/input/devices)

if [ -z "$list" ]; then
	echo "No controller matching '$want' is connected."
	echo "Connected devices:"
	grep '^N: Name=' /proc/bus/input/devices | sed 's/^N: Name=/  /'
	exit 1
fi

echo "Matching devices (bus 0003=USB, 0005=Bluetooth):"
echo "$list" | while IFS="$(printf '\t')" read -r ev vendor bus name; do
	case "$vendor" in
		2020) tag="AYN copy - this is what gpmerge reads" ;;
		*)    tag="physical device" ;;
	esac
	echo "  /dev/input/$ev  vendor=$vendor bus=$bus  $name   [$tag]"
done
echo

# Prefer the AYN copy; fall back to the physical device if there is no copy.
node=$(echo "$list" | awk -F'\t' '$2 == "2020" { print $1; exit }')
[ -z "$node" ] && node=$(echo "$list" | awk -F'\t' '{ print $1; exit }')

echo "Capturing /dev/input/$node for 20 seconds."
echo
echo "  1. press the face button at the BOTTOM"
echo "  2. press the face button on the RIGHT"
echo
timeout 20 getevent -l "/dev/input/$node" 2>/dev/null | grep --line-buffered EV_KEY
echo
echo "Reading the result, in Xbox reference terms:"
echo "  bottom -> BTN_SOUTH and right -> BTN_EAST : nothing to remap."
echo "  bottom -> BTN_EAST  and right -> BTN_SOUTH: use 'preset nintendo'."
