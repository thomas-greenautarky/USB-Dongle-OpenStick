#!/bin/sh
# led-status.sh — Configure status LEDs across different MSM8916 dongle variants.
#
# LED names come from the DTB and vary per dongle. We match by suffix so the
# same script works on any variant that follows the common naming convention:
#   <color>:wan   → data/modem/WWAN LED  → lights when Debian is up
#   <color>:wlan  → WiFi LED             → lights when a station is associated
#   <color>:power → power LED            → left at default-on (kernel usually
#                                          already sets this, but enforce)
#
# Missing LEDs are silently skipped — the script doesn't know which variant
# we're on, so it just tries what's there.

set -eu

set_trigger() {
    led="$1"
    preferred="$2"
    fallback="$3"
    [ -d "$led" ] || return 0
    if echo "$preferred" > "$led/trigger" 2>/dev/null; then
        return 0
    fi
    echo "$fallback" > "$led/trigger" 2>/dev/null || true
}

for led in /sys/class/leds/*; do
    [ -d "$led" ] || continue
    name=$(basename "$led")
    case "$name" in
        *:wan|*:wwan|*:lte|*:mobile)
            # WAN indicator — use default-on (no native trigger reflects
            # LTE bearer state, and we'd rather show "alive" than "off")
            set_trigger "$led" default-on default-on
            ;;
        *:wlan|*:wifi)
            # WiFi indicator — phy0assoc lights when a client is associated
            set_trigger "$led" phy0assoc default-on
            ;;
        *:power)
            # Power LED — enforce on
            echo 1 > "$led/brightness" 2>/dev/null || true
            ;;
    esac
done
