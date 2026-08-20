#!/system/bin/sh
#
# Fades the bottom panel's backlight down after a period without touch input on
# it, and restores the previous level on the first touch. The top panel is never
# touched.
#
# Install: /data/adb/service.d/bottom-autodim.sh (Magisk, runs as root at boot)

# Magisk runs service.d scripts with its own busybox ash whatever the shebang.
# There `read -t` returns 1 on timeout (indistinguishable from EOF) and rejects
# fractional delays; idle detection and the cancellable fade need both, so
# re-exec under mksh.
if [ -z "$AUTODIM_SH" ]; then
    export AUTODIM_SH=1
    exec /system/bin/sh "$0" "$@"
fi

# Touchscreen of the bottom panel, from `getevent -pl`. Resolved by name because
# /dev/input/eventN numbering can change between boots.
TOUCH_NAME="fts_ts_3"

# Backlight of the bottom panel (panel0 is the top one), scale 0-4095.
BL=/sys/class/backlight/panel1-backlight/brightness

# Settings, by precedence: the file written by the app, then the props (command
# line setup, or app uninstalled), then the defaults below.
APPDIR=/data/user/0/com.jeromegsq.thortoolbox
CONF=$APPDIR/files/config

DEF_ENABLED=0
DEF_TIMEOUT=5
DEF_MIN=0
DEF_FADE=800

# One fade step. Also the cancel window: the delay passed to `read`, hence the
# worst-case latency between a touch and the fade being aborted.
STEP_MS=40
STEP_S=0.04

LOG=/data/local/tmp/bottom-autodim.log

# "<original> <written>". On /dev (tmpfs): no flash writes, cleared at boot.
STATE=/dev/.bottom-autodim.state

# Line count kept in memory to avoid one fork per line just to size the file.
LOG_LINES=0
LOG_MAX_LINES=500
LOG_KEEP_LINES=100

log() {
    echo "$(date '+%m-%d %H:%M:%S') $*" >> "$LOG" 2>/dev/null
    LOG_LINES=$(( LOG_LINES + 1 ))
    if [ "$LOG_LINES" -ge "$LOG_MAX_LINES" ]; then
        tail -n "$LOG_KEEP_LINES" "$LOG" > "$LOG.tmp" 2>/dev/null \
            && mv "$LOG.tmp" "$LOG" 2>/dev/null
        LOG_LINES=$LOG_KEEP_LINES
    fi
}

prop() { # prop <suffix> <default>
    v=$(getprop "persist.autodim.$1")
    case "$v" in
        ""|*[!0-9]*) echo "$2" ;;
        *)           echo "$v" ;;
    esac
}

reset_conf() {
    CFG_ENABLED=$DEF_ENABLED
    CFG_TIMEOUT=$DEF_TIMEOUT
    CFG_MIN=$DEF_MIN
    CFG_FADE=$DEF_FADE
}
reset_conf

# Called on every idle cycle, so it forks nothing while the app is installed.
load_conf() {
    if [ -r "$CONF" ]; then
        reset_conf
        while read -r line; do
            v=${line#*=}
            case "$v" in ""|*[!0-9]*) continue ;; esac
            case "${line%%=*}" in
                enabled) CFG_ENABLED=$v ;;
                timeout) CFG_TIMEOUT=$v ;;
                min)     CFG_MIN=$v ;;
                fade)    CFG_FADE=$v ;;
            esac
        done < "$CONF"
    elif [ -d "$APPDIR" ]; then
        # App installed but its directory still encrypted, i.e. between boot and
        # first unlock. The props are not updated by the app, so falling back to
        # them would revive a stale setting: keep the current values instead.
        :
    else
        reset_conf
        CFG_ENABLED=$(prop enabled "$DEF_ENABLED")
        CFG_TIMEOUT=$(prop timeout "$DEF_TIMEOUT")
        CFG_MIN=$(prop min "$DEF_MIN")
        CFG_FADE=$(prop fade "$DEF_FADE")
    fi

    # A zero timeout would spin the loop; a fade shorter than one step is moot.
    [ "$CFG_TIMEOUT" -ge 1 ] 2>/dev/null || CFG_TIMEOUT=$DEF_TIMEOUT
    [ "$CFG_FADE" -ge "$STEP_MS" ] 2>/dev/null || CFG_FADE=$STEP_MS
}

find_touch_dev() {
    for n in /sys/class/input/event*/device/name; do
        [ -r "$n" ] || continue
        if [ "$(cat "$n")" = "$TOUCH_NAME" ]; then
            ev=${n#/sys/class/input/}
            echo "/dev/input/${ev%%/*}"
            return 0
        fi
    done
    return 1
}

# The fade runs inside the event loop: each step waits STEP_S for the next touch
# event, so a touch aborts it at once. No polling, no extra process.
fade_out() { # fade_out <min> <duration_ms>
    min=$1
    read -r cur < "$BL" 2>/dev/null || return
    # 0 means the panel is off (device asleep); writing would light it back up.
    [ "$cur" -gt "$min" ] 2>/dev/null || return

    steps=$(( $2 / STEP_MS ))
    [ "$steps" -lt 1 ] && steps=1
    delta=$(( cur - min ))

    i=1
    while [ "$i" -le "$steps" ]; do
        if read -r -t "$STEP_S" _line 2>/dev/null; then
            echo "$cur" > "$BL"
            : > "$STATE"
            log "fade cancelled at step $i/$steps, back to $cur"
            return
        fi
        v=$(( cur - delta * i / steps ))
        echo "$v" > "$BL"
        echo "$cur $v" > "$STATE"
        i=$(( i + 1 ))
    done
    log "dimmed: $cur -> $min over ${2}ms"
}

# Only restore if the current level is still the one we wrote: if the brightness
# slider, a game or a wakeup took over, drop our value instead of forcing it.
restore() {
    read -r saved last < "$STATE" 2>/dev/null
    : > "$STATE"
    [ -n "$saved" ] || return

    read -r cur < "$BL" 2>/dev/null
    if [ "$cur" = "$last" ]; then
        echo "$saved" > "$BL"
        log "restored: $cur -> $saved"
    else
        log "restore skipped, brightness changed elsewhere: $cur"
    fi
}

watch_touch() {
    dev=$1
    load_conf

    # mksh `read -t` returns 142 (128 + SIGALRM) on timeout and 1 on end of
    # stream: timeout means idle, EOF means getevent died and must be restarted.
    getevent -q "$dev" 2>/dev/null | while :; do
        if read -r -t "$CFG_TIMEOUT" _line 2>/dev/null; then
            [ -s "$STATE" ] && restore
        else
            [ "$?" = "142" ] || return 1

            # Settings are re-read here only; the branch above runs on every
            # touch event and must stay cheap.
            load_conf
            if [ "$CFG_ENABLED" = "1" ]; then
                [ -s "$STATE" ] || fade_out "$CFG_MIN" "$CFG_FADE"
            else
                [ -s "$STATE" ] && restore
            fi
        fi
    done
}

main() {
    while [ "$(getprop sys.boot_completed)" != "1" ]; do sleep 3; done
    : > "$STATE"

    # Non-persistent prop: how the app reports "service running" without root.
    setprop autodim.service 1

    load_conf
    log "start (enabled=$CFG_ENABLED timeout=${CFG_TIMEOUT}s min=$CFG_MIN fade=${CFG_FADE}ms)"

    while true; do
        dev=$(find_touch_dev)
        if [ -z "$dev" ]; then
            log "touchscreen '$TOUCH_NAME' not found, retrying in 10s"
            sleep 10
            continue
        fi

        log "watching $dev ($TOUCH_NAME)"
        watch_touch "$dev"

        log "event stream ended, restarting in 5s"
        sleep 5
    done
}

main &
