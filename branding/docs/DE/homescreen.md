# homescreen / wallpaper

Folders added:
- branding/etc/xdg/autostart/
- branding/usr/local/bin/
- branding/usr/share/backgrounds/catos/
- branding/docs/DE/ (this file)

Files added:
- branding/usr/share/backgrounds/catos/wallpaper.png - the actual wallpaper image
- branding/usr/local/bin/catos-set-wallpaper.sh - sets the wallpaper via xfconf-query
- branding/etc/xdg/autostart/catos-wallpaper.desktop - runs the script on XFCE login

Files changed:
- mkiso.sh - added `xrandr` to the xfce package list, the script needs it

## what happens where and why

xfdesktop (XFCE's desktop manager) doesn't read wallpaper.png directly, it reads
an xfconf property per monitor output, e.g. `/backdrop/screen0/monitorHDMI-1/workspace0/last-image`.
There's no default value for this on a fresh install, so on first login there's
just a blank/default desktop.

catos-set-wallpaper.sh runs once at XFCE login (via the autostart .desktop file),
finds the connected monitor(s) with `xrandr`, and writes that property for each one
using `xfconf-query`, pointing it at wallpaper.png. `xrandr` has to be installed
(added it to mkiso.sh) or the script can't find any monitors and silently does nothing.
