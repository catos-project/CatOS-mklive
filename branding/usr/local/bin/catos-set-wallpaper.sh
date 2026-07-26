#!/bin/sh
# xfdesktop keys backdrop properties by the full RandR output name
# (e.g. "eDP-1" -> "monitoreDP-1", "HDMI-1" -> "monitorHDMI-1").
# It never pre-populates these on its own, so we create them directly
# instead of waiting for them to appear.
IMG=/usr/share/backgrounds/catos/wallpaper.png

log() {
    logger -t catos-set-wallpaper "$1" 2>/dev/null
    echo "$1" >> /tmp/catos-set-wallpaper.log
}

outputs=""
# shellcheck disable=SC2034 # retry counter, not read in the loop body
for i in $(seq 1 60); do
    outputs=$(xrandr --query 2>/dev/null | awk '/ connected/{print $1}')
    [ -n "$outputs" ] && break
    sleep 1
done

if [ -z "$outputs" ]; then
    log "no connected RandR outputs found after 60s, falling back to monitor0"
    outputs="0"
fi

for out in $outputs; do
    base="/backdrop/screen0/monitor${out}/workspace0"
    xfconf-query -c xfce4-desktop -p "${base}/last-image" -n -t string -s "$IMG" 2>/dev/null \
        || xfconf-query -c xfce4-desktop -p "${base}/last-image" -s "$IMG"
    if [ $? -eq 0 ]; then
        log "set ${base}/last-image ($out -> monitor${out})"
    else
        log "failed to set ${base}/last-image ($out -> monitor${out})"
    fi
    xfconf-query -c xfce4-desktop -p "${base}/image-style" -n -t int -s 5 2>/dev/null \
        || xfconf-query -c xfce4-desktop -p "${base}/image-style" -s 5
done
